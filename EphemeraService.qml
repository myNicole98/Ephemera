import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "./Providers.js" as Providers

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
    property string discoveryError: ""
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
    property int maxTurns: 10
    property int timeout: 300
    property string systemPrompt: ""
    property bool thinkingEnabled: false

    // --- Ollama state ---
    property ListModel availableModels: ListModel {}
    property bool ollamaWeStarted: false
    property bool ollamaStartPending: false
    property bool ollamaExternallyManaged: false
    property bool ollamaReady: false
    property int ollamaRetries: 0
    readonly property int ollamaMaxRetries: 15
    property bool _shuttingDown: false
    property int ollamaIdleMinutes: 5  // 0 = never auto-stop

    readonly property bool isOllama: provider === "ollama"
    readonly property bool needsApiKey: provider !== "ollama"
    readonly property bool hasApiKey: resolveApiKey().length > 0
    readonly property bool missingApiKey: needsApiKey && !hasApiKey

    Component.onCompleted: {
        loadSettings();
        loadChatHistory();
        pingOllama();
    }

    Component.onDestruction: {
        saveChatHistory();
        if (ollamaWeStarted) {
            ollamaProcess.running = false;
            ollamaKiller.running = true;
        }
    }

    function shutdownOllama() {
        _shuttingDown = true;
        ollamaIdleTimer.stop();
        retryTimer.stop();
        if (ollamaWeStarted && ollamaProcess.running)
            ollamaProcess.running = false;
        ollamaKiller.running = true;
        ollamaWeStarted = false;
        ollamaStartPending = false;
        ollamaReady = false;
    }

    function forceShutdownExternalOllama() {
        _shuttingDown = true;
        ollamaIdleTimer.stop();
        retryTimer.stop();
        ollamaKiller.running = true;
        ollamaReady = false;
        ollamaExternallyManaged = false;
        ollamaWeStarted = false;
        ollamaStartPending = false;
    }

    function ensureOllamaReady() {
        if (!isOllama) return;
        _shuttingDown = false;
        ollamaIdleTimer.stop();
        retryTimer.stop();
        ollamaRetries = 0;
        pingOllama();
    }

    function scheduleIdleShutdown() {
        if (!isOllama || !ollamaWeStarted || ollamaIdleMinutes <= 0) return;
        ollamaIdleTimer.restart();
    }

    // ─── Ollama lifecycle ───────────────────────────────────────────

    Process {
        id: ollamaProcess
        command: ["ollama", "serve"]
        running: false
        onRunningChanged: {
            if (running && root.ollamaStartPending) {
                root.ollamaWeStarted = true;
                root.ollamaStartPending = false;
            } else if (!running && root.ollamaWeStarted && !root._shuttingDown) {
                root.ollamaWeStarted = false;
                root.ollamaStartPending = false;
                root.ollamaReady = false;
            }
        }
    }

    Process {
        id: ollamaKiller
        command: ["pkill", "-f", "ollama serve"]
        running: false
    }

    Process {
        id: ollamaPing
        running: false
        stdout: StdioCollector {
            id: pingCollector
            onStreamFinished: {
                // If we got valid JSON back, Ollama is running
                try {
                    var data = JSON.parse(text);
                    if (data && data.models !== undefined) {
                        root.ollamaReady = true;
                        if (!root.ollamaWeStarted && !root.ollamaStartPending)
                            root.ollamaExternallyManaged = true;
                        discoverModels();
                        return;
                    }
                } catch (e) {
                    console.warn("Ephemera: Ollama ping parse error:", e);
                }
                handlePingFailed();
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0)
                handlePingFailed();
        }
    }

    function pingOllama() {
        ollamaPing.command = ["curl", "-s", "--connect-timeout", "2", ollamaUrl + "/api/tags"];
        ollamaPing.running = true;
    }

    function handlePingFailed() {
        if (ollamaReady) {
            ollamaReady = false;
            ollamaExternallyManaged = false;
        }

        if (!ollamaWeStarted && !ollamaStartPending && ollamaRetries === 0) {
            // First failure — try starting Ollama
            ollamaStartPending = true;
            ollamaProcess.running = true;
        }

        ollamaRetries++;
        if (ollamaRetries <= ollamaMaxRetries) {
            retryTimer.start();
        }
    }

    Timer {
        id: retryTimer
        interval: 1000
        repeat: false
        onTriggered: pingOllama()
    }

    Timer {
        id: ollamaIdleTimer
        interval: root.ollamaIdleMinutes * 60 * 1000
        repeat: false
        onTriggered: {
            if (root.ollamaWeStarted && !root.isStreaming)
                root.shutdownOllama();
        }
    }

    // ─── Ollama model discovery ─────────────────────────────────────

    Process {
        id: modelDiscovery
        running: false
        stdout: StdioCollector {
            id: discoveryCollector
            onStreamFinished: {
                try {
                    var data = JSON.parse(text);
                    var models = data.models || [];
                    availableModels.clear();
                    for (var i = 0; i < models.length; i++) {
                        availableModels.append({
                            name: models[i].name || "",
                            displayName: "ollama:" + (models[i].name || "")
                        });
                    }
                    // Auto-select first model if none selected
                    if (!root.model && availableModels.count > 0) {
                        root.model = availableModels.get(0).name;
                        saveSettingValue("model", root.model);
                    }
                } catch (e) {
                    console.warn("Ephemera: model discovery parse error:", e);
                    root.discoveryError = "Failed to parse model list from Ollama.";
                }
            }
        }
    }

    function discoverModels() {
        discoveryError = "";
        modelDiscovery.command = ["curl", "-s", "--connect-timeout", "2", ollamaUrl + "/api/tags"];
        modelDiscovery.running = true;
    }

    onOllamaUrlChanged: {
        if (isOllama && ollamaReady) {
            ollamaReady = false;
            ollamaRetries = 0;
            ollamaExternallyManaged = false;
            ollamaWeStarted = false;
            pingOllama();
        }
    }

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
        persistChat = PluginService.loadPluginData(pluginId, "persistChat", false) === true;
        ollamaIdleMinutes = Number(PluginService.loadPluginData(pluginId, "ollamaIdleMinutes", 5)) || 5;

        // Clear chat when provider changes to avoid stale index map entries
        if (oldProvider && oldProvider !== provider)
            clearChat();

        // Set baseUrl based on provider
        updateBaseUrl();
    }

    function updateBaseUrl() {
        switch (provider) {
        case "ollama":
            baseUrl = ollamaUrl;
            break;
        case "openai":
            baseUrl = "https://api.openai.com";
            break;
        case "anthropic":
            baseUrl = "https://api.anthropic.com";
            break;
        case "gemini":
            baseUrl = "https://generativelanguage.googleapis.com";
            break;
        default:
            baseUrl = String(PluginService.loadPluginData(pluginId, "customBaseUrl", "https://api.openai.com")).trim();
            break;
        }
    }

    function saveSettingValue(key, value) {
        PluginService.savePluginData(pluginId, key, value);
    }

    Connections {
        target: PluginService
        function onPluginDataChanged(pId) {
            if (pId !== root.pluginId) return;
            loadSettings();
        }
    }

    // ─── API key resolution (env vars only — never stored) ─────────

    function resolveApiKey() {
        switch (provider) {
        case "anthropic":
            return Quickshell.env("ANTHROPIC_API_KEY") || "";
        case "gemini":
            return Quickshell.env("GEMINI_API_KEY") || "";
        case "openai":
            return Quickshell.env("OPENAI_API_KEY") || "";
        case "ollama":
            return ""; // No key needed
        default:
            return Quickshell.env("EPHEMERA_API_KEY") || "";
        }
    }

    function _envVarForProvider(prov) {
        switch (prov) {
        case "anthropic": return "ANTHROPIC_API_KEY";
        case "gemini": return "GEMINI_API_KEY";
        case "openai": return "OPENAI_API_KEY";
        default: return "EPHEMERA_API_KEY";
        }
    }

    function _providerDisplayName(prov) {
        switch (prov) {
        case "anthropic": return "Anthropic";
        case "gemini": return "Gemini";
        case "openai": return "OpenAI";
        case "ollama": return "Ollama";
        default: return "custom provider";
        }
    }

    // ─── Chat (ephemeral, in-memory only) ──────────────────────────

    function clearChat() {
        messagesModel.clear();
        messageIndexMap = ({});
        variantStore = ({});
        isStreaming = false;
        activeStreamId = "";
        lastUserText = "";
        // Clear persisted history too
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
            if (m.status === "streaming") continue; // Don't persist incomplete messages
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
                messagesModel.append({
                    role: m.role, content: m.content, thinking: m.thinking || "",
                    id: m.id, timestamp: m.timestamp, status: m.status || "ok",
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
        if (isStreaming && chatFetcher.running) {
            markError(activeStreamId, "Please wait until the current response finishes.");
            return;
        }
        ollamaIdleTimer.stop();
        lastRequestFailed = false;
        startStreaming(text.trim());
    }

    function regenerate() {
        if (isStreaming || !lastUserText) return;
        if (messagesModel.count === 0) return;
        ollamaIdleTimer.stop();

        // Find the last assistant message
        var lastIdx = messagesModel.count - 1;
        var last = messagesModel.get(lastIdx);
        if (last.role !== "assistant") return;

        var msgId = last.id;

        // Save current content as a variant (with its model name)
        _saveVariant(msgId, last.variantIndex, last.content, last.thinking, last.modelName);

        // Increment variant count and set index to new slot
        var newCount = last.variantCount + 1;
        var newIndex = newCount - 1;
        messagesModel.setProperty(lastIdx, "variantCount", newCount);
        messagesModel.setProperty(lastIdx, "variantIndex", newIndex);

        // Reset message for new streaming with current model
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
        // Evict oldest variants if cap exceeded
        while (store[msgId].length > maxVariantsPerMessage) {
            store[msgId].shift();
        }
        variantStore = store;
    }

    function switchVariant(msgId, newIndex) {
        var idx = findIndexById(msgId);
        if (idx < 0) return;
        var msg = messagesModel.get(idx);
        if (newIndex < 0 || newIndex >= msg.variantCount) return;

        // Switching to the currently-streaming variant: show live buffers
        if (isStreaming && activeStreamId === msgId && newIndex === _streamVariantIndex) {
            messagesModel.setProperty(idx, "content", _streamContent);
            messagesModel.setProperty(idx, "thinking", _streamThinking);
            messagesModel.setProperty(idx, "variantIndex", newIndex);
            messagesModel.setProperty(idx, "modelName", model); // Current model for live stream
            messagesModel.setProperty(idx, "status", "streaming");
            return;
        }

        // Switching away from streaming variant or between completed variants
        var store = variantStore;
        if (!store[msgId] || !store[msgId][newIndex]) return;

        var variant = store[msgId][newIndex];
        messagesModel.setProperty(idx, "content", variant.content);
        messagesModel.setProperty(idx, "thinking", variant.thinking);
        messagesModel.setProperty(idx, "variantIndex", newIndex);
        if (variant.modelName)
            messagesModel.setProperty(idx, "modelName", variant.modelName);
        // Show as "ok" when viewing a completed variant (even if another is streaming)
        if (isStreaming && activeStreamId === msgId) {
            messagesModel.setProperty(idx, "status", "ok");
        }
    }

    function buildConversationMarkdown() {
        var lines = [];
        for (var i = 0; i < messagesModel.count; i++) {
            var m = messagesModel.get(i);
            var label = m.role === "user" ? "You" : "Assistant";
            lines.push("### " + label + "\n\n" + m.content);
        }
        return lines.join("\n\n---\n\n");
    }

    function exportConversation() {
        var text = buildConversationMarkdown();
        Quickshell.execDetached(["wl-copy", text]);
    }

    function exportConversationToFile() {
        var text = buildConversationMarkdown();
        var timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
        var filename = Quickshell.env("HOME") + "/ephemera-chat-" + timestamp + ".md";
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
                exportFileWriter.stdinEnabled = false; // EOF
                root.exportPendingBody = "";
            }
        }

        onExited: exitCode => {
            if (exitCode === 0) {
                root.lastExportedFile = exportFileWriter.command[1];
            }
        }
    }

    function cancel() {
        if (!isStreaming) return;
        var streamId = activeStreamId;
        isStreaming = false; // Prevent onExited race
        _insideThinkTag = false; // Reset before markCancelled to avoid state leaks
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

        // Add system prompt if set
        if (systemPrompt && systemPrompt.trim().length > 0) {
            msgs.push({ role: "system", content: systemPrompt.trim() });
        }

        // Sliding window of recent turns
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

        for (var j = 0; j < collected.length; j++) {
            msgs.push(collected[j]);
        }

        return {
            provider: provider,
            baseUrl: baseUrl,
            model: model,
            temperature: temperature,
            max_tokens: maxTokens,
            messages: msgs,
            stream: true,
            timeout: timeout,
            thinkingEnabled: thinkingEnabled
        };
    }

    function buildCurlCommand(payload) {
        var key = resolveApiKey();
        // Ollama doesn't need a key; everyone else does
        if (provider !== "ollama" && !key)
            return null;
        // Ollama needs to be ready or at least have a model
        if (provider === "ollama" && !model)
            return null;

        return Providers.buildCurlCommand(provider, payload, key);
    }

    // ─── Streaming ─────────────────────────────────────────────────

    property string streamBuffer: ""
    property string pendingStdinBody: ""
    property bool _insideThinkTag: false
    property string _tagBuffer: ""
    property string _streamContent: ""
    property string _streamThinking: ""
    property int _streamVariantIndex: 0

    // Route content deltas through <think> tag detection (Ollama/Qwen3/DeepSeek)
    function routeContentDelta(streamId, delta) {
        var text = _tagBuffer + delta;
        _tagBuffer = "";

        while (text.length > 0) {
            var tag = _insideThinkTag ? "</think>" : "<think>";
            var idx = text.indexOf(tag);

            if (idx >= 0) {
                var before = text.substring(0, idx);
                if (before.length > 0) {
                    if (_insideThinkTag)
                        updateStreamThinking(streamId, before);
                    else
                        updateStreamContent(streamId, before);
                }
                _insideThinkTag = !_insideThinkTag;
                text = text.substring(idx + tag.length);
                // Strip leading newline after tag
                if (text.startsWith("\n")) text = text.substring(1);
            } else {
                // Check for partial tag at end of buffer
                var partialLen = 0;
                for (var len = Math.min(text.length, tag.length - 1); len > 0; len--) {
                    if (text.substring(text.length - len) === tag.substring(0, len)) {
                        partialLen = len;
                        break;
                    }
                }

                if (partialLen > 0) {
                    _tagBuffer = text.substring(text.length - partialLen);
                    var output = text.substring(0, text.length - partialLen);
                    if (output.length > 0) {
                        if (_insideThinkTag)
                            updateStreamThinking(streamId, output);
                        else
                            updateStreamContent(streamId, output);
                    }
                } else {
                    if (_insideThinkTag)
                        updateStreamThinking(streamId, text);
                    else
                        updateStreamContent(streamId, text);
                }
                text = "";
            }
        }
    }

    function handleStreamChunk(chunk) {
        var buffer = streamBuffer + chunk;
        var parts = buffer.split(/\r?\n/);

        if (buffer.length > 0 && !buffer.endsWith("\n") && !buffer.endsWith("\r")) {
            streamBuffer = parts.pop();
        } else {
            streamBuffer = "";
        }

        for (var i = 0; i < parts.length; i++) {
            var line = parts[i].trim();
            if (!line) continue;

            if (line === "data: [DONE]" || line === "data:[DONE]") {
                finalizeStream(activeStreamId);
                continue;
            }

            if (line.startsWith("data:")) {
                var jsonPart = line.substring(5).trim();
                parseProviderDelta(jsonPart);
            }
        }
    }

    function parseProviderDelta(jsonText) {
        try {
            var data = JSON.parse(jsonText);
            if (provider === "anthropic") {
                if (data.type === "content_block_delta" && data.delta) {
                    if (data.delta.type === "thinking_delta" && data.delta.thinking)
                        updateStreamThinking(activeStreamId, data.delta.thinking);
                    else if (data.delta.type === "text_delta" && data.delta.text)
                        updateStreamContent(activeStreamId, data.delta.text);
                }
                if (data.type === "message_delta" && data.delta && data.delta.stop_reason)
                    finalizeStream(activeStreamId);
            } else if (provider === "gemini") {
                var chunks = Array.isArray(data) ? data : [data];
                for (var ci = 0; ci < chunks.length; ci++) {
                    var candidates = chunks[ci].candidates;
                    if (!candidates || !candidates[0] || !candidates[0].content) continue;
                    var cparts = candidates[0].content.parts || [];
                    for (var pi = 0; pi < cparts.length; pi++) {
                        if (cparts[pi].text)
                            updateStreamContent(activeStreamId, cparts[pi].text);
                    }
                }
            } else {
                // OpenAI / Ollama (OpenAI-compat)
                var choices = data.choices;
                if (choices && choices[0] && choices[0].delta) {
                    var d = choices[0].delta;
                    // Explicit reasoning field (DeepSeek via OpenAI-compat providers)
                    var reasoning = d.reasoning_content || d.reasoning || "";
                    var content = d.content || "";
                    if (reasoning)
                        updateStreamThinking(activeStreamId, reasoning);
                    if (content)
                        routeContentDelta(activeStreamId, content);
                }
                if (choices && choices[0] && choices[0].finish_reason)
                    finalizeStream(activeStreamId);
            }
        } catch (e) {
            // Malformed chunk — log but don't break streaming
            console.warn("Ephemera: stream chunk parse error:", e);
        }
    }

    function handleStreamFinished(text) {
        var match = text.match(/EPH_STATUS:(\d+)/);
        if (match)
            lastHttpStatus = parseInt(match[1]);

        var bodyText = text || "";
        var markerIdx = bodyText.lastIndexOf("\nEPH_STATUS:");
        if (markerIdx >= 0)
            bodyText = bodyText.substring(0, markerIdx);
        bodyText = bodyText.trim();

        // Try non-streaming fallback if no content was streamed
        if (isStreaming) {
            if (_streamContent.length === 0 && bodyText && lastHttpStatus > 0 && lastHttpStatus < 400) {
                var parsed = extractNonStreamingAssistantText(bodyText);
                if (parsed && parsed.length > 0) {
                    _streamContent = parsed;
                    var fbIdx = findIndexById(activeStreamId);
                    if (fbIdx >= 0) {
                        var fbMsg = messagesModel.get(fbIdx);
                        if (fbMsg.variantIndex === _streamVariantIndex)
                            messagesModel.setProperty(fbIdx, "content", parsed);
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
            // No HTTP status and no content — curl failed at the transport level
            // (e.g., connection refused, DNS failure, timeout)
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

    function extractNonStreamingAssistantText(bodyText) {
        try {
            var data = JSON.parse(bodyText);
            if (provider === "anthropic") {
                var content = data.content;
                if (Array.isArray(content)) {
                    var out = "";
                    for (var i = 0; i < content.length; i++) {
                        if (content[i] && content[i].text)
                            out += content[i].text;
                    }
                    return out;
                }
                return data.text || "";
            }
            if (provider === "gemini") {
                var gchunks = Array.isArray(data) ? data : [data];
                var gout = "";
                for (var gi = 0; gi < gchunks.length; gi++) {
                    var cands = gchunks[gi].candidates;
                    if (!cands || !cands[0] || !cands[0].content) continue;
                    var gparts = cands[0].content.parts || [];
                    for (var gpi = 0; gpi < gparts.length; gpi++) {
                        if (gparts[gpi].text) gout += gparts[gpi].text;
                    }
                }
                return gout;
            }
            // OpenAI / Ollama
            var choices = data.choices;
            if (choices && choices[0]) {
                if (choices[0].message && typeof choices[0].message.content === "string")
                    return choices[0].message.content;
                if (typeof choices[0].text === "string")
                    return choices[0].text;
            }
        } catch (e) {
            console.warn("Ephemera: non-streaming response parse error:", e);
        }
        return "";
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
            if (msg.variantIndex === _streamVariantIndex) {
                messagesModel.setProperty(idx, "content", message);
            }
            messagesModel.setProperty(idx, "status", "error");
        }
        isStreaming = false;
        activeStreamId = "";
        lastRequestFailed = true;
    }

    function markCancelled(streamId) {
        // Flush any remaining tag buffer as content
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
            if (msg.variantIndex === _streamVariantIndex) {
                messagesModel.setProperty(idx, "content", _streamContent);
            }
            messagesModel.setProperty(idx, "status", "streaming");
        }
    }

    function updateStreamThinking(streamId, deltaText) {
        if (!deltaText) return;
        _streamThinking += deltaText;
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === _streamVariantIndex) {
                messagesModel.setProperty(idx, "thinking", _streamThinking);
            }
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
        // Flush any remaining tag buffer
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
            // If still viewing the streaming variant, update content from buffers
            if (msg.variantIndex === _streamVariantIndex) {
                messagesModel.setProperty(idx, "content", _streamContent);
                messagesModel.setProperty(idx, "thinking", _streamThinking);
            }
            messagesModel.setProperty(idx, "status", "ok");
        }
        isStreaming = false;
        activeStreamId = "";
    }

    // ─── Curl process ──────────────────────────────────────────────

    Process {
        id: chatFetcher
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running && root.pendingStdinBody) {
                chatFetcher.write(root.pendingStdinBody);
                chatFetcher.stdinEnabled = false; // Signal EOF to curl
                root.pendingStdinBody = "";
            }
        }

        stdout: StdioCollector {
            id: streamCollector
            waitForEnd: false
            property int lastLen: 0

            onTextChanged: {
                // Cap buffer early to prevent memory exhaustion from rogue endpoints.
                // Check lastLen (pre-append size) so we reject before processing.
                if (lastLen > 5242880) { // 5MB
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
