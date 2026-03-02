import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "../lib/Providers.js" as Providers
import "../lib/StreamParser.js" as StreamParser
import "../lib/ChatExport.js" as ChatExport

Item {
    id: root

    property string pluginId: "ephemera"

    // --- Message state (in-memory only, never persisted) ---
    property ListModel messagesModel: ListModel {}
    property int messageCount: messagesModel.count
    property var messageIndexMap: ({})
    property var variantStore: ({})
    property bool isStreaming: false
    property bool lastRequestFailed: false
    property string activeStreamId: ""
    property string lastUserText: ""
    property int lastHttpStatus: 0

    // --- Persistence (opt-in) ---
    property bool persistChat: false

    // --- Provider settings ---
    property string provider: "ollama"
    property string ollamaUrl: "http://localhost:11434"
    property string baseUrl: "http://localhost:11434"
    property string model: ""
    property real temperature: 0.7
    property int maxTokens: 4096
    property bool unlimitedTokens: false
    property int maxTurns: 10
    property int timeout: 300
    property string systemPrompt: ""
    property bool thinkingEnabled: false

    // --- Ollama (delegated to OllamaManager) ---
    property alias availableModels: ollamaManager.availableModels
    property alias ollamaWeStarted: ollamaManager.ollamaWeStarted
    property alias ollamaStartPending: ollamaManager.ollamaStartPending
    property alias ollamaExternallyManaged: ollamaManager.ollamaExternallyManaged
    property alias ollamaReady: ollamaManager.ollamaReady
    property alias discoveryError: ollamaManager.discoveryError
    property alias ollamaIdleMinutes: ollamaManager.ollamaIdleMinutes

    // Per-provider temperature range
    readonly property var temperatureRange: Providers.getTemperatureRange(provider)
    readonly property real tempMax: temperatureRange.max
    readonly property real tempMin: temperatureRange.min

    readonly property bool isOllama: provider === "ollama"
    readonly property bool needsApiKey: provider !== "ollama"
    readonly property bool hasApiKey: resolveApiKey().length > 0
    readonly property bool missingApiKey: needsApiKey && !hasApiKey

    Component.onCompleted: {
        loadSettings();
        loadChatHistory();
        ollamaManager.ping();
    }

    Component.onDestruction: {
        try { saveChatHistory(); }
        catch (e) { console.warn("Ephemera: error saving chat on destruction:", e); }
        ollamaManager.cleanupOnDestruction();
    }

    // ─── Ollama lifecycle (delegated) ─────────────────────────────

    OllamaManager {
        id: ollamaManager
        ollamaUrl: root.ollamaUrl
        isStreaming: root.isStreaming

        onModelAutoSelected: name => {
            if (!root.model || root.model.length === 0) {
                root.model = name;
                root.saveSettingValue("model", name);
            }
        }
    }

    function shutdownOllama() { ollamaManager.shutdown(); }
    function forceShutdownExternalOllama() { ollamaManager.forceShutdownExternal(); }
    function ensureOllamaReady() { if (isOllama) ollamaManager.ensureReady(); }
    function scheduleIdleShutdown() { if (isOllama) ollamaManager.scheduleIdleShutdown(); }
    function discoverModels() { ollamaManager.discoverModels(); }

    // ─── Settings persistence (non-secret only) ────────────────────

    function loadSettings() {
        var oldProvider = provider;

        provider = String(PluginService.loadPluginData(pluginId, "provider", "ollama")).trim() || "ollama";
        ollamaUrl = String(PluginService.loadPluginData(pluginId, "ollamaUrl", "http://localhost:11434")).trim();
        model = String(PluginService.loadPluginData(pluginId, "model", "")).trim();
        temperature = PluginService.loadPluginData(pluginId, "temperature", 0.7);
        maxTokens = PluginService.loadPluginData(pluginId, "maxTokens", 4096);
        maxTurns = PluginService.loadPluginData(pluginId, "maxTurns", 10);
        timeout = PluginService.loadPluginData(pluginId, "timeout", 300);
        systemPrompt = String(PluginService.loadPluginData(pluginId, "systemPrompt", "")).trim();
        thinkingEnabled = PluginService.loadPluginData(pluginId, "thinkingEnabled", false) === true;
        unlimitedTokens = PluginService.loadPluginData(pluginId, "unlimitedTokens", false) === true;
        persistChat = PluginService.loadPluginData(pluginId, "persistChat", false) === true;
        ollamaManager.ollamaIdleMinutes = Number(PluginService.loadPluginData(pluginId, "ollamaIdleMinutes", 5)) || 5;

        if (oldProvider && oldProvider !== provider)
            clearChat();

        // Clamp temperature to the new provider's valid range
        var range = Providers.getTemperatureRange(provider);
        if (temperature > range.max) {
            temperature = range.max;
            saveSettingValue("temperature", temperature);
        } else if (temperature < range.min) {
            temperature = range.min;
            saveSettingValue("temperature", temperature);
        }

        updateBaseUrl();
    }

    function updateBaseUrl() {
        if (provider === "ollama") {
            baseUrl = ollamaUrl;
        } else if (provider === "custom") {
            baseUrl = String(PluginService.loadPluginData(pluginId, "customBaseUrl", "https://api.openai.com")).trim();
        } else {
            var info = Providers.getProviderInfo(provider);
            baseUrl = info.defaultUrl;
        }
    }

    function saveSettingValue(key, value) {
        _settingsReloadDebounce.restart();
        PluginService.savePluginData(pluginId, key, value);
    }

    // Debounce external settings changes to avoid reloading mid-save
    Timer {
        id: _settingsReloadDebounce
        interval: 150
        repeat: false
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(pId) {
            if (pId !== root.pluginId) return;
            if (_settingsReloadDebounce.running) return;
            loadSettings();
        }
    }

    // ─── API key resolution (env vars only — never stored) ─────────

    function resolveApiKey() {
        var info = Providers.getProviderInfo(provider);
        if (!info.envVar) return "";
        return Quickshell.env(info.envVar) || "";
    }

    function _envVarForProvider(prov) {
        var info = Providers.getProviderInfo(prov);
        return info.envVar || "EPHEMERA_API_KEY";
    }

    function _providerDisplayName(prov) {
        var info = Providers.getProviderInfo(prov);
        return info.name || "custom provider";
    }

    // ─── Chat (ephemeral, in-memory only) ──────────────────────────

    function clearChat() {
        messagesModel.clear();
        messageIndexMap = ({});
        variantStore = ({});
        isStreaming = false;
        activeStreamId = "";
        lastUserText = "";
        if (persistChat) {
            PluginService.savePluginData(pluginId, "chatHistory", "");
            PluginService.savePluginData(pluginId, "chatVariants", "");
        }
    }

    function saveChatHistory() {
        if (!persistChat) return;
        var msgs = [];
        for (var i = 0; i < messagesModel.count; i++) {
            var m = messagesModel.get(i);
            if (m.status === "streaming") continue;
            msgs.push({
                role: m.role, content: m.content, thinking: m.thinking || "",
                id: m.id, timestamp: m.timestamp, status: m.status || "ok",
                variantIndex: m.variantIndex || 0, variantCount: m.variantCount || 1,
                modelName: m.modelName || ""
            });
        }
        PluginService.savePluginData(pluginId, "chatHistory", JSON.stringify(msgs));
        PluginService.savePluginData(pluginId, "chatVariants", JSON.stringify(variantStore));
    }

    function loadChatHistory() {
        if (!persistChat) return;
        try {
            var raw = PluginService.loadPluginData(pluginId, "chatHistory", "");
            if (!raw) return;
            var msgs = JSON.parse(raw);
            if (!Array.isArray(msgs) || msgs.length === 0) return;
            messagesModel.clear();
            messageIndexMap = ({});
            for (var i = 0; i < msgs.length; i++) {
                var m = msgs[i];
                // Messages stuck in "streaming" from a previous crash are stale — mark them ok
                var status = (m.status === "streaming") ? "ok" : (m.status || "ok");
                messagesModel.append({
                    role: m.role, content: m.content, thinking: m.thinking || "",
                    id: m.id, timestamp: m.timestamp, status: status,
                    variantIndex: m.variantIndex || 0, variantCount: m.variantCount || 1,
                    modelName: m.modelName || ""
                });
                messageIndexMap[m.id] = messagesModel.count - 1;
                if (m.role === "user") lastUserText = m.content;
            }
            var vRaw = PluginService.loadPluginData(pluginId, "chatVariants", "");
            if (vRaw) variantStore = JSON.parse(vRaw);
        } catch (e) {
            console.warn("Ephemera: failed to load chat history:", e);
        }
    }

    function sendMessage(text) {
        if (!text || text.trim().length === 0) return;
        if (isStreaming || chatFetcher.running) {
            if (activeStreamId)
                markError(activeStreamId, "Please wait until the current response finishes.");
            return;
        }
        ollamaManager.stopIdleTimer();
        lastRequestFailed = false;
        startStreaming(text.trim());
    }

    function regenerate() {
        if (isStreaming || !lastUserText) return;
        if (messagesModel.count === 0) return;
        ollamaManager.stopIdleTimer();

        var lastIdx = messagesModel.count - 1;
        var last = messagesModel.get(lastIdx);
        if (last.role !== "assistant") return;

        var msgId = last.id;
        _saveVariant(msgId, last.variantIndex, last.content, last.thinking, last.modelName);

        var newCount = last.variantCount + 1;
        var newIndex = newCount - 1;
        messagesModel.setProperty(lastIdx, "variantCount", newCount);
        messagesModel.setProperty(lastIdx, "variantIndex", newIndex);
        messagesModel.setProperty(lastIdx, "content", "");
        messagesModel.setProperty(lastIdx, "thinking", "");
        messagesModel.setProperty(lastIdx, "status", "streaming");
        messagesModel.setProperty(lastIdx, "modelName", model);

        activeStreamId = msgId;
        isStreaming = true;
        lastHttpStatus = 0;
        lastRequestFailed = false;
        _streamContent = "";
        _streamThinking = "";
        _streamVariantIndex = newIndex;

        _launchCurl();
    }

    readonly property int maxVariantsPerMessage: 10

    function _saveVariant(msgId, index, content, thinking, variantModel) {
        var store = variantStore;
        if (!store[msgId]) store[msgId] = [];
        store[msgId][index] = { content: content || "", thinking: thinking || "", modelName: variantModel || "" };
        var evicted = 0;
        while (store[msgId].length > maxVariantsPerMessage) {
            store[msgId].shift();
            evicted++;
        }
        if (evicted > 0) {
            var storeLen = store[msgId].length;
            _streamVariantIndex = Math.max(0, Math.min(_streamVariantIndex - evicted, storeLen - 1));
            var idx = findIndexById(msgId);
            if (idx >= 0) {
                var msg = messagesModel.get(idx);
                if (msg) {
                    var newVariantIndex = Math.max(0, Math.min(msg.variantIndex - evicted, storeLen - 1));
                    // Account for a currently-streaming variant not yet in the store
                    var logicalCount = (isStreaming && activeStreamId === msgId) ? storeLen + 1 : storeLen;
                    messagesModel.setProperty(idx, "variantIndex", newVariantIndex);
                    messagesModel.setProperty(idx, "variantCount", logicalCount);
                }
            }
        }
        variantStore = store;
    }

    function switchVariant(msgId, newIndex) {
        var idx = findIndexById(msgId);
        if (idx < 0) return;
        var msg = messagesModel.get(idx);
        if (newIndex < 0 || newIndex >= msg.variantCount) return;

        if (isStreaming && activeStreamId === msgId && newIndex === _streamVariantIndex) {
            messagesModel.setProperty(idx, "content", _streamContent);
            messagesModel.setProperty(idx, "thinking", _streamThinking);
            messagesModel.setProperty(idx, "variantIndex", newIndex);
            messagesModel.setProperty(idx, "modelName", model);
            messagesModel.setProperty(idx, "status", "streaming");
            return;
        }

        var store = variantStore;
        if (!store[msgId] || newIndex >= store[msgId].length || !store[msgId][newIndex]) return;

        var variant = store[msgId][newIndex];
        messagesModel.setProperty(idx, "content", variant.content);
        messagesModel.setProperty(idx, "thinking", variant.thinking);
        messagesModel.setProperty(idx, "variantIndex", newIndex);
        if (variant.modelName)
            messagesModel.setProperty(idx, "modelName", variant.modelName);
        if (isStreaming && activeStreamId === msgId)
            messagesModel.setProperty(idx, "status", "ok");
    }

    function editAndRegenerate(msgId, newText) {
        if (isStreaming || !newText || newText.trim().length === 0) return;

        var idx = findIndexById(msgId);
        if (idx < 0) return;
        var msg = messagesModel.get(idx);
        if (msg.role !== "user") return;

        messagesModel.setProperty(idx, "content", newText.trim());

        var removeCount = messagesModel.count - idx - 1;
        for (var i = 0; i < removeCount; i++) {
            var removedMsg = messagesModel.get(idx + 1);
            delete messageIndexMap[removedMsg.id];
            if (variantStore[removedMsg.id])
                delete variantStore[removedMsg.id];
            messagesModel.remove(idx + 1);
        }
        variantStore = variantStore;

        lastUserText = newText.trim();
        ollamaManager.stopIdleTimer();
        lastRequestFailed = false;

        var now = Date.now();
        var streamId = "assistant-" + now;
        messagesModel.append({ role: "assistant", content: "", thinking: "", timestamp: now, id: streamId, status: "streaming", variantIndex: 0, variantCount: 1, modelName: model });
        messageIndexMap[streamId] = messagesModel.count - 1;
        activeStreamId = streamId;
        isStreaming = true;
        lastHttpStatus = 0;
        _streamContent = "";
        _streamThinking = "";
        _streamVariantIndex = 0;

        _launchCurl();
    }

    // ─── Export ─────────────────────────────────────────────────────

    function buildConversationMarkdown() {
        var msgs = [];
        for (var i = 0; i < messagesModel.count; i++) {
            var m = messagesModel.get(i);
            msgs.push({ role: m.role, content: m.content });
        }
        return ChatExport.buildMarkdown(msgs);
    }

    function exportConversation() {
        var text = buildConversationMarkdown();
        Quickshell.execDetached(["wl-copy", "--", text]);
    }

    function exportConversationToFile() {
        var text = buildConversationMarkdown();
        var filename = ChatExport.generateFilename(Quickshell.env("HOME"));
        exportFileWriter.command = ["tee", filename];
        exportPendingBody = text;
        exportFileWriter.stdinEnabled = true;
        exportFileWriter.running = true;
        return filename;
    }

    property string exportPendingBody: ""
    property string lastExportedFile: ""

    Process {
        id: exportFileWriter
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root.exportPendingBody) {
                exportFileWriter.write(root.exportPendingBody);
                exportFileWriter.stdinEnabled = false;
                root.exportPendingBody = "";
            }
        }

        onExited: exitCode => {
            if (exitCode === 0)
                root.lastExportedFile = exportFileWriter.command[1];
        }
    }

    // ─── Streaming ─────────────────────────────────────────────────

    property string streamBuffer: ""
    property string pendingStdinBody: ""
    property bool _insideThinkTag: false
    property string _tagBuffer: ""
    property string _streamContent: ""
    property string _streamThinking: ""
    property int _streamVariantIndex: 0

    function cancel() {
        if (!isStreaming) return;
        var streamId = activeStreamId;
        isStreaming = false;
        _insideThinkTag = false;
        _tagBuffer = "";
        markCancelled(streamId);
        chatFetcher.running = false;
    }

    function startStreaming(text) {
        var now = Date.now();
        var streamId = "assistant-" + now;

        var userId = "user-" + now;
        messagesModel.append({ role: "user", content: text, thinking: "", timestamp: now, id: userId, status: "ok", variantIndex: 0, variantCount: 1, modelName: "" });
        messageIndexMap[userId] = messagesModel.count - 1;
        lastUserText = text;

        messagesModel.append({ role: "assistant", content: "", thinking: "", timestamp: now + 1, id: streamId, status: "streaming", variantIndex: 0, variantCount: 1, modelName: model });
        messageIndexMap[streamId] = messagesModel.count - 1;
        activeStreamId = streamId;
        isStreaming = true;
        lastHttpStatus = 0;
        _streamContent = "";
        _streamThinking = "";
        _streamVariantIndex = 0;

        _launchCurl();
    }

    function _launchCurl() {
        if (chatFetcher.running) return;

        var payload = buildPayload(lastUserText);
        var result = buildCurlCommand(payload);
        if (!result) {
            if (provider === "ollama") {
                markError(activeStreamId, ollamaReady ? "No Ollama model selected." : "Ollama is not running. Check that ollama is installed and running.");
            } else {
                var envVar = _envVarForProvider(provider);
                markError(activeStreamId, "No API key found.\nSet the " + envVar + " environment variable to connect to " + _providerDisplayName(provider) + ".");
            }
            return;
        }

        streamCollector.lastLen = 0;
        streamBuffer = "";
        _insideThinkTag = false;
        _tagBuffer = "";
        pendingStdinBody = result.body;
        chatFetcher.stdinEnabled = true;
        chatFetcher.command = result.cmd;
        chatFetcher.running = true;
    }

    function buildPayload(latestText) {
        var msgs = [];

        if (systemPrompt && systemPrompt.trim().length > 0)
            msgs.push({ role: "system", content: systemPrompt.trim() });

        var turns = 0;
        var collected = [];
        for (var i = messagesModel.count - 1; i >= 0; i--) {
            var m = messagesModel.get(i);
            if (!m || m.status !== "ok") continue;
            if (m.role !== "user" && m.role !== "assistant") continue;
            collected.unshift({ role: m.role, content: m.content });
            if (m.role === "user") {
                turns++;
                if (turns >= maxTurns) break;
            }
        }

        for (var j = 0; j < collected.length; j++)
            msgs.push(collected[j]);

        return {
            provider: provider,
            baseUrl: baseUrl,
            model: model,
            temperature: temperature,
            max_tokens: unlimitedTokens ? 0 : maxTokens,
            messages: msgs,
            stream: true,
            timeout: timeout,
            thinkingEnabled: thinkingEnabled
        };
    }

    function buildCurlCommand(payload) {
        var key = resolveApiKey();
        if (provider !== "ollama" && !key)
            return null;
        if (provider === "ollama" && !model)
            return null;
        return Providers.buildCurlCommand(provider, payload, key);
    }

    // ─── Stream processing (using StreamParser.js) ─────────────────

    function handleStreamChunk(chunk) {
        var result = StreamParser.splitLines(chunk, streamBuffer);
        streamBuffer = result.buffer;

        for (var i = 0; i < result.lines.length; i++) {
            var line = result.lines[i];

            if (line === "data: [DONE]" || line === "data:[DONE]") {
                finalizeStream(activeStreamId);
                continue;
            }

            if (line.startsWith("data:")) {
                var jsonPart = line.substring(5).trim();
                var delta = StreamParser.parseDelta(jsonPart, provider);

                if (delta.thinking)
                    updateStreamThinking(activeStreamId, delta.thinking);
                if (delta.content) {
                    // For OpenAI/Ollama, route through think-tag detection
                    if (provider !== "anthropic" && provider !== "gemini") {
                        var tagResult = StreamParser.routeThinkTags(delta.content, _tagBuffer, _insideThinkTag);
                        _tagBuffer = tagResult.tagBuffer;
                        _insideThinkTag = tagResult.insideThinkTag;
                        for (var ti = 0; ti < tagResult.thinkingParts.length; ti++)
                            updateStreamThinking(activeStreamId, tagResult.thinkingParts[ti]);
                        for (var ci = 0; ci < tagResult.contentParts.length; ci++)
                            updateStreamContent(activeStreamId, tagResult.contentParts[ci]);
                    } else {
                        updateStreamContent(activeStreamId, delta.content);
                    }
                }
                if (delta.done)
                    finalizeStream(activeStreamId);
            }
        }
    }

    function handleStreamFinished(text) {
        var parsed = StreamParser.extractHttpStatus(text);
        lastHttpStatus = parsed.status;
        var bodyText = parsed.body;

        // Try non-streaming fallback if no content was streamed
        if (isStreaming) {
            if (_streamContent.length === 0 && bodyText && lastHttpStatus > 0 && lastHttpStatus < 400) {
                var fallback = StreamParser.extractNonStreamingText(bodyText, provider);
                if (fallback && fallback.length > 0) {
                    _streamContent = fallback;
                    var fbIdx = findIndexById(activeStreamId);
                    if (fbIdx >= 0) {
                        var fbMsg = messagesModel.get(fbIdx);
                        if (fbMsg.variantIndex === _streamVariantIndex)
                            messagesModel.setProperty(fbIdx, "content", fallback);
                    }
                }
            }
        }

        if (lastHttpStatus >= 400 && isStreaming) {
            var preview = bodyText.length > 600 ? bodyText.slice(0, 600) + "\u2026" : bodyText;
            var hint = httpErrorHint(lastHttpStatus);
            var msg = "Request failed (HTTP " + lastHttpStatus + ")";
            if (hint) msg += "\n" + hint;
            if (preview) msg += "\n\n" + preview;
            markError(activeStreamId, msg);
            return;
        }

        if (isStreaming) {
            if (lastHttpStatus === 0 && _streamContent.length === 0) {
                var connMsg = provider === "ollama"
                    ? "Could not connect to Ollama.\nMake sure Ollama is running at " + ollamaUrl + "."
                    : "Could not connect to " + _providerDisplayName(provider) + ".\nCheck your network connection and provider settings.";
                markError(activeStreamId, connMsg);
                return;
            }
            finalizeStream(activeStreamId);
        }
    }

    function httpErrorHint(status) {
        switch (status) {
        case 401: return "Check your API key \u2014 it may be missing or invalid.";
        case 403: return "Access denied \u2014 verify your API key has the required permissions.";
        case 404: return "Endpoint not found \u2014 check the model name and base URL.";
        case 429: return "Rate limited \u2014 wait a moment and try again.";
        case 500: return "Server error \u2014 the provider may be experiencing issues.";
        case 503: return "Service unavailable \u2014 the provider may be overloaded.";
        default: return "";
        }
    }

    function _curlExitHint(exitCode) {
        switch (exitCode) {
        case 6: return "Could not resolve host.\nCheck the provider URL and your DNS settings.";
        case 7: return provider === "ollama"
            ? "Connection refused \u2014 Ollama appears to be down.\nMake sure Ollama is running at " + ollamaUrl + "."
            : "Connection refused \u2014 " + _providerDisplayName(provider) + " is unreachable.";
        case 28: return "Request timed out.\nThe provider took too long to respond.";
        case 35: return "TLS/SSL connection error.\nCheck the provider URL and your network.";
        default: return "Request failed (exit code " + exitCode + ").";
        }
    }

    // ─── Message helpers ───────────────────────────────────────────

    function findIndexById(msgId) {
        return messageIndexMap[msgId] !== undefined ? messageIndexMap[msgId] : -1;
    }

    function markError(streamId, message) {
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            _streamContent = message;
            _saveVariant(streamId, _streamVariantIndex, _streamContent, _streamThinking, model);
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === _streamVariantIndex)
                messagesModel.setProperty(idx, "content", message);
            messagesModel.setProperty(idx, "status", "error");
        }
        isStreaming = false;
        activeStreamId = "";
        lastRequestFailed = true;
    }

    function markCancelled(streamId) {
        if (_tagBuffer.length > 0) {
            if (_insideThinkTag)
                updateStreamThinking(streamId, _tagBuffer);
            else
                updateStreamContent(streamId, _tagBuffer);
            _tagBuffer = "";
        }
        _insideThinkTag = false;

        var idx = findIndexById(streamId);
        if (idx >= 0) {
            _saveVariant(streamId, _streamVariantIndex, _streamContent, _streamThinking, model);
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === _streamVariantIndex) {
                messagesModel.setProperty(idx, "content", _streamContent);
                messagesModel.setProperty(idx, "thinking", _streamThinking);
            }
            messagesModel.setProperty(idx, "status", "ok");
        }
        isStreaming = false;
        activeStreamId = "";
        saveChatHistory();
    }

    function updateStreamContent(streamId, deltaText) {
        if (!deltaText) return;
        _streamContent += deltaText;
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === _streamVariantIndex)
                messagesModel.setProperty(idx, "content", _streamContent);
            messagesModel.setProperty(idx, "status", "streaming");
        }
    }

    function updateStreamThinking(streamId, deltaText) {
        if (!deltaText) return;
        _streamThinking += deltaText;
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === _streamVariantIndex)
                messagesModel.setProperty(idx, "thinking", _streamThinking);
            messagesModel.setProperty(idx, "status", "streaming");
        }
    }

    function getMessageContentById(msgId) {
        var idx = findIndexById(msgId);
        if (idx >= 0) return messagesModel.get(idx).content || "";
        return "";
    }

    function setMessageContentById(msgId, text) {
        var idx = findIndexById(msgId);
        if (idx >= 0)
            messagesModel.setProperty(idx, "content", text || "");
    }

    function finalizeStream(streamId) {
        if (!isStreaming || activeStreamId !== streamId) return;

        if (_tagBuffer.length > 0) {
            if (_insideThinkTag)
                updateStreamThinking(streamId, _tagBuffer);
            else
                updateStreamContent(streamId, _tagBuffer);
            _tagBuffer = "";
        }
        _insideThinkTag = false;

        var idx = findIndexById(streamId);
        if (idx >= 0) {
            _saveVariant(streamId, _streamVariantIndex, _streamContent, _streamThinking, model);
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === _streamVariantIndex) {
                messagesModel.setProperty(idx, "content", _streamContent);
                messagesModel.setProperty(idx, "thinking", _streamThinking);
            }
            messagesModel.setProperty(idx, "status", "ok");
        }
        isStreaming = false;
        activeStreamId = "";
        saveChatHistory();
    }

    // ─── Curl process ──────────────────────────────────────────────

    Process {
        id: chatFetcher
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root.pendingStdinBody) {
                chatFetcher.write(root.pendingStdinBody);
                chatFetcher.stdinEnabled = false;
                root.pendingStdinBody = "";
            }
        }

        stdout: StdioCollector {
            id: streamCollector
            waitForEnd: false
            property int lastLen: 0

            onTextChanged: {
                if (lastLen > 5242880) {
                    chatFetcher.running = false;
                    root.markError(root.activeStreamId, "Response exceeded maximum buffer size (5 MB).");
                    return;
                }
                var newData = text.substring(lastLen);
                lastLen = text.length;
                handleStreamChunk(newData);
            }

            onStreamFinished: {
                handleStreamFinished(text);
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0 && root.isStreaming) {
                markError(root.activeStreamId, root._curlExitHint(exitCode));
            }
        }
    }
}
