import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "../lib/Providers.js" as Providers
import "../lib/ChatExport.js" as ChatExport
import "../lib/VariantStore.js" as VariantStore

Item {
    id: root

    property string pluginId: "ephemera"

    // --- Message state (in-memory only, never persisted) ---
    property ListModel messagesModel: ListModel {}
    property int messageCount: messagesModel.count
    property var messageIndexMap: ({})
    property var variantStore: ({})
    property string lastUserText: ""

    // --- Streaming (delegated to StreamingService) ---
    property alias isStreaming: streamingService.isStreaming
    property alias activeStreamId: streamingService.activeStreamId
    property alias streamStartTime: streamingService.streamStartTime
    property alias streamTokenCount: streamingService.streamTokenCount
    property alias apiOutputTokens: streamingService._apiOutputTokens
    property alias lastRequestFailed: streamingService.lastRequestFailed
    property alias lastHttpStatus: streamingService.lastHttpStatus

    // --- Persistence (opt-in) ---
    property bool persistChat: false

    // --- Provider settings ---
    property string provider: "ollama"
    property string ollamaUrl: "http://localhost:11434"
    property string ollamaThinkingMode: "default"
    property string baseUrl: "http://localhost:11434"
    property string model: ""
    property real temperature: 0.7
    property int maxTokens: 4096
    property bool unlimitedTokens: false
    property int maxTurns: 10
    property int timeout: 300
    property string systemPrompt: ""
    property bool thinkingEnabled: false
    property bool panelOnLeft: false
    // --- MCP ---
    property bool mcpEnabled: false
    property string mcpUrl: ""
    property string mcpCommand: "mcp-remote"
    property alias mcpService: mcpServiceInstance

    // --- Ollama (delegated to OllamaManager) ---
    property alias availableModels: ollamaManager.availableModels
    property alias ollamaWeStarted: ollamaManager.ollamaWeStarted
    property alias ollamaStartPending: ollamaManager.ollamaStartPending
    property alias ollamaExternallyManaged: ollamaManager.ollamaExternallyManaged
    property alias ollamaReady: ollamaManager.ollamaReady
    property alias discoveryError: ollamaManager.discoveryError
    property alias ollamaIdleMinutes: ollamaManager.ollamaIdleMinutes
    property alias ollamaRetries: ollamaManager.ollamaRetries
    readonly property int ollamaMaxRetries: ollamaManager.ollamaMaxRetries

    // --- Keyring (delegated to KeyringService) ---
    property alias _keyringAvailable: keyringService._keyringAvailable
    property alias _keyringCache: keyringService._keyringCache

    // Per-provider temperature range
    readonly property var temperatureRange: Providers.getTemperatureRange(provider)
    readonly property real tempMax: temperatureRange.max
    readonly property real tempMin: temperatureRange.min

    readonly property var modelChoices: {
        var ollamaCount = availableModels.count;
        if (provider === "ollama") {
            var list = [];
            for (var i = 0; i < ollamaCount; i++)
                list.push(availableModels.get(i).name);
            return list;
        }
        return Providers.getModelList(provider);
    }

    readonly property bool isOllama: provider === "ollama"
    readonly property bool needsApiKey: provider !== "ollama"
    readonly property bool hasApiKey: resolveApiKey().length > 0
    readonly property bool missingApiKey: needsApiKey && !hasApiKey

    // --- Lifecycle ---

    Component.onCompleted: {
        loadSettings();
        loadChatHistory();
        ollamaManager.ping();
        keyringService.checkSecretToolAvailable();
    }

    Component.onDestruction: {
        try { _commitChatHistory(); }
        catch (e) { console.warn("Ephemera: error saving chat on destruction:", e); }
        ollamaManager.cleanupOnDestruction();
    }

    onProviderChanged: {
        streamingService.resetErrorState();
        if (_keyringAvailable)
            keyringService.refreshKeyringKey();
    }

    // ─── Child services ─────────────────────────────────────────────

    KeyringService {
        id: keyringService
        provider: root.provider
    }

    MCPService {
        id: mcpServiceInstance
        mcpUrl: root.mcpUrl
        mcpCommand: root.mcpCommand
        enabled: root.mcpEnabled
        onToolCallCompleted: (callId, result) => streamingService._onToolCallCompleted(callId, result)
        onToolCallFailed: (callId, error) => streamingService._onToolCallFailed(callId, error)
    }

    StreamingService {
        id: streamingService
        provider: root.provider
        ollamaUrl: root.ollamaUrl
        timeout: root.timeout

        onStreamContentUpdated: (streamId, deltaText) => root._applyStreamContent(streamId)
        onStreamThinkingUpdated: (streamId, deltaText) => root._applyStreamThinking(streamId)
        onStreamFinalized: (streamId, stats) => root._applyFinalize(streamId, stats)
        onStreamError: (streamId, message) => root._applyError(streamId, message)
        onStreamCancelled: (streamId, stats) => root._applyCancelled(streamId, stats)
        mcpService: root.mcpEnabled ? mcpServiceInstance : null
        onStreamToolRoundReady: (streamId, messages) => root._launchCurlWithMessages(messages)
    }

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

        onGpuStatusReady: label => {
            if (!streamingService._lastFinalizedStreamId) return;
            var idx = root.findIndexById(streamingService._lastFinalizedStreamId);
            if (idx >= 0) {
                var msg = root.messagesModel.get(idx);
                var stats = msg.streamStats || "";
                if (stats && label && stats.indexOf("GPU") === -1 && stats.indexOf("CPU") === -1)
                    root.messagesModel.setProperty(idx, "streamStats", stats + " · " + label);
            }
        }
    }

    // ─── Keyring facade ─────────────────────────────────────────────

    function resolveApiKey() { return keyringService.resolveApiKey(provider); }
    function hasApiKeyForProvider(prov) { return keyringService.hasApiKeyForProvider(prov); }
    function apiKeySource(prov) { return keyringService.apiKeySource(prov); }
    function storeKeyringKey(prov, key) { keyringService.storeKeyringKey(prov, key); }
    function clearKeyringKey(prov) { keyringService.clearKeyringKey(prov); }
    function refreshKeyringKey() { keyringService.refreshKeyringKey(); }

    function _envVarForProvider(prov) {
        var info = Providers.getProviderInfo(prov);
        return info.envVar || "EPHEMERA_API_KEY";
    }

    function _providerDisplayName(prov) {
        var info = Providers.getProviderInfo(prov);
        return info.name || "custom provider";
    }

    // ─── Ollama facade ──────────────────────────────────────────────

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
        ollamaThinkingMode = Providers.normalizeOllamaThinkingMode(PluginService.loadPluginData(pluginId, "ollamaThinkingMode", "default"));
        model = String(PluginService.loadPluginData(pluginId, "model", "")).trim();
        temperature = PluginService.loadPluginData(pluginId, "temperature", 0.7);
        maxTokens = PluginService.loadPluginData(pluginId, "maxTokens", 4096);
        maxTurns = PluginService.loadPluginData(pluginId, "maxTurns", 10);
        timeout = PluginService.loadPluginData(pluginId, "timeout", 300);
        systemPrompt = String(PluginService.loadPluginData(pluginId, "systemPrompt", "")).trim();
        thinkingEnabled = PluginService.loadPluginData(pluginId, "thinkingEnabled", false) === true;
        panelOnLeft = PluginService.loadPluginData(pluginId, "panelOnLeft", false) === true;
        mcpEnabled = PluginService.loadPluginData(pluginId, "mcpEnabled", false) === true;
        mcpUrl = String(PluginService.loadPluginData(pluginId, "mcpUrl", "")).trim();
        mcpCommand = String(PluginService.loadPluginData(pluginId, "mcpCommand", "mcp-remote")).trim() || "mcp-remote";
        if (mcpEnabled && mcpUrl && mcpCommand)
            mcpServiceInstance.connectToServer();
        unlimitedTokens = PluginService.loadPluginData(pluginId, "unlimitedTokens", false) === true;
        persistChat = PluginService.loadPluginData(pluginId, "persistChat", false) === true;
        ollamaManager.ollamaIdleMinutes = Number(PluginService.loadPluginData(pluginId, "ollamaIdleMinutes", 5)) || 5;

        if (oldProvider && oldProvider !== provider)
            clearChat();

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
            baseUrl = String(PluginService.loadPluginData(pluginId, "customBaseUrl", Providers.getProviderInfo("custom").defaultUrl)).trim();
        } else {
            baseUrl = Providers.getProviderInfo(provider).defaultUrl;
        }
    }

    function saveSettingValue(key, value) {
        _settingsReloadDebounce.restart();
        PluginService.savePluginData(pluginId, key, value);
    }

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

    // ─── Chat (ephemeral, in-memory only) ──────────────────────────

    function clearChat() {
        streamingService.reset();
        messagesModel.clear();
        messageIndexMap = ({});
        variantStore = ({});
        lastUserText = "";
        if (persistChat) {
            PluginService.savePluginData(pluginId, "chatHistory", "");
            PluginService.savePluginData(pluginId, "chatVariants", "");
        }
    }

    function saveChatHistory() {
        if (!persistChat) return;
        _chatSaveDebounce.restart();
    }

    function _commitChatHistory() {
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

    Timer {
        id: _chatSaveDebounce
        interval: 150
        repeat: false
        onTriggered: root._commitChatHistory()
    }

    function loadChatHistory() {
        if (!persistChat) return;
        try {
            var raw = PluginService.loadPluginData(pluginId, "chatHistory", "");
            if (!raw) return;
            var msgs = JSON.parse(raw);
            if (!Array.isArray(msgs) || msgs.length === 0) return;

            // Parse into temp arrays first — only commit on full success
            var tempEntries = [];
            var tempIndexMap = {};
            var tempLastUser = lastUserText;
            for (var i = 0; i < msgs.length; i++) {
                var m = msgs[i];
                var status = (m.status === "streaming") ? "ok" : (m.status || "ok");
                var entry = _createMessageEntry(m.role, m.content, m.id, m.timestamp, status, m.modelName);
                entry.thinking = m.thinking || "";
                entry.variantIndex = m.variantIndex || 0;
                entry.variantCount = m.variantCount || 1;
                tempEntries.push(entry);
                tempIndexMap[m.id] = i;
                if (m.role === "user") tempLastUser = m.content;
            }

            var tempVariants = {};
            var vRaw = PluginService.loadPluginData(pluginId, "chatVariants", "");
            if (vRaw) tempVariants = JSON.parse(vRaw);

            // Commit to model
            messagesModel.clear();
            for (var j = 0; j < tempEntries.length; j++)
                messagesModel.append(tempEntries[j]);
            messageIndexMap = tempIndexMap;
            variantStore = tempVariants;
            lastUserText = tempLastUser;
        } catch (e) {
            console.warn("Ephemera: failed to load chat history:", e);
        }
    }

    // ─── Messaging orchestration ───────────────────────────────────

    function sendMessage(text) {
        if (!text || text.trim().length === 0) return;
        if (isStreaming || streamingService.isStreaming) {
            if (activeStreamId)
                _applyError(activeStreamId, "Please wait until the current response finishes.");
            return;
        }
        if (streamingService.isInErrorCooldown()) return;
        ollamaManager.stopIdleTimer();
        _startStreaming(text.trim());
    }

    function regenerate() {
        if (isStreaming || !lastUserText) return;
        if (messagesModel.count === 0) return;
        if (streamingService.isInErrorCooldown()) return;
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

        streamingService.beginStream(msgId, newIndex);
        _launchCurl();
    }

    function editAndRegenerate(msgId, newText) {
        if (isStreaming || !newText || newText.trim().length === 0) return;
        if (streamingService.isInErrorCooldown()) return;

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
        variantStore = JSON.parse(JSON.stringify(variantStore));
        _rebuildIndexMap();

        lastUserText = newText.trim();
        ollamaManager.stopIdleTimer();

        var now = Date.now();
        var streamId = "assistant-" + now;
        messagesModel.append(_createMessageEntry("assistant", "", streamId, now, "streaming", model));
        messageIndexMap[streamId] = messagesModel.count - 1;

        streamingService.beginStream(streamId, 0);
        _launchCurl();
    }

    function cancel() {
        streamingService.cancel();
    }

    readonly property int maxVariantsPerMessage: 10

    function switchVariant(msgId, newIndex) {
        var idx = findIndexById(msgId);
        if (idx < 0) return;
        var msg = messagesModel.get(idx);
        if (newIndex < 0 || newIndex >= msg.variantCount) return;

        if (isStreaming && activeStreamId === msgId && newIndex === streamingService._streamVariantIndex) {
            messagesModel.setProperty(idx, "content", streamingService._streamContent);
            messagesModel.setProperty(idx, "thinking", streamingService._streamThinking);
            messagesModel.setProperty(idx, "variantIndex", newIndex);
            messagesModel.setProperty(idx, "modelName", model);
            messagesModel.setProperty(idx, "status", "streaming");
            return;
        }

        var variant = VariantStore.getVariant(variantStore, msgId, newIndex);
        if (!variant) return;
        messagesModel.setProperty(idx, "content", variant.content);
        messagesModel.setProperty(idx, "thinking", variant.thinking);
        messagesModel.setProperty(idx, "variantIndex", newIndex);
        if (variant.modelName)
            messagesModel.setProperty(idx, "modelName", variant.modelName);
        if (isStreaming && activeStreamId === msgId)
            messagesModel.setProperty(idx, "status", "ok");
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
        streamingService.exportToClipboard(buildConversationMarkdown());
    }

    function exportConversationToFile() {
        var text = buildConversationMarkdown();
        var filename = ChatExport.generateFilename(Quickshell.env("HOME"));
        streamingService.exportToFile(text, Quickshell.env("HOME"), filename);
        return filename;
    }

    // ─── Message helpers ───────────────────────────────────────────

    function _createMessageEntry(role, content, id, timestamp, status, modelName) {
        return {
            role: role, content: content || "", thinking: "",
            id: id, timestamp: timestamp, status: status || "ok",
            variantIndex: 0, variantCount: 1,
            modelName: modelName || "", streamStats: "", requestPayload: ""
        };
    }

    function _rebuildIndexMap() {
        var map = {};
        for (var i = 0; i < messagesModel.count; i++)
            map[messagesModel.get(i).id] = i;
        messageIndexMap = map;
    }

    function findIndexById(msgId) {
        return messageIndexMap[msgId] !== undefined ? messageIndexMap[msgId] : -1;
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

    // ─── Internal: streaming orchestration ─────────────────────────

    function _startStreaming(text) {
        var now = Date.now();
        var streamId = "assistant-" + now;

        var userId = "user-" + now;
        messagesModel.append(_createMessageEntry("user", text, userId, now, "ok", ""));
        messageIndexMap[userId] = messagesModel.count - 1;
        lastUserText = text;

        messagesModel.append(_createMessageEntry("assistant", "", streamId, now + 1, "streaming", model));
        messageIndexMap[streamId] = messagesModel.count - 1;

        streamingService.beginStream(streamId, 0);
        _launchCurl();
    }

    function _launchCurl() {
        var payload = _buildPayload(lastUserText);
        var result = _buildCurlCommand(payload);
        if (!result) {
            if (provider === "ollama") {
                _applyError(activeStreamId, ollamaReady ? "No Ollama model selected." : "Ollama is not running. Check that ollama is installed and running.");
            } else {
                var envVar = _envVarForProvider(provider);
                var hint = _keyringAvailable
                    ? "Store a key in Settings, or set the " + envVar + " environment variable."
                    : "Set the " + envVar + " environment variable before starting Quickshell.";
                _applyError(activeStreamId, "No API key found.\n" + hint);
            }
            return;
        }

        var payloadIdx = findIndexById(activeStreamId);
        if (payloadIdx >= 0)
            messagesModel.setProperty(payloadIdx, "requestPayload", JSON.stringify(payload, null, 2));
        streamingService.launchCurl(result, payload.messages);
    }

    function _buildPayload(latestText) {
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

        var payload = {
            provider: provider,
            baseUrl: baseUrl,
            model: model,
            temperature: temperature,
            max_tokens: unlimitedTokens ? 0 : maxTokens,
            messages: msgs,
            stream: true,
            timeout: timeout,
            ollamaThinkingMode: ollamaThinkingMode,
            thinkingEnabled: thinkingEnabled
        };
        if (provider === "ollama" && root.mcpEnabled && mcpServiceInstance.isConnected)
            payload.tools = mcpServiceInstance.getOllamaTools();
        return payload;
    }

    function _launchCurlWithMessages(messages) {
        var payload = _buildPayload(lastUserText);
        payload.messages = messages;
        if (provider === "ollama" && mcpEnabled && mcpServiceInstance.isConnected)
            payload.tools = mcpServiceInstance.getOllamaTools();
        var result = _buildCurlCommand(payload);
        if (!result) {
            _applyError(activeStreamId, "Could not resume after MCP tool call.");
            return;
        }
        streamingService.launchCurl(result, messages);
    }

    function _buildCurlCommand(payload) {
        var key = resolveApiKey();
        if (provider !== "ollama" && !key) return null;
        if (provider === "ollama" && !model) return null;
        return Providers.buildCurlCommand(provider, payload, key);
    }

    // ─── Stream signal handlers (apply to messagesModel) ───────────

    function _applyStreamContent(streamId) {
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === streamingService._streamVariantIndex)
                messagesModel.setProperty(idx, "content", streamingService._streamContent);
            messagesModel.setProperty(idx, "status", "streaming");
        }
    }

    function _applyStreamThinking(streamId) {
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === streamingService._streamVariantIndex)
                messagesModel.setProperty(idx, "thinking", streamingService._streamThinking);
            messagesModel.setProperty(idx, "status", "streaming");
        }
    }

    function _applyFinalize(streamId, stats) {
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            _saveVariant(streamId, streamingService._streamVariantIndex, streamingService._streamContent, streamingService._streamThinking, model);
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === streamingService._streamVariantIndex) {
                messagesModel.setProperty(idx, "content", streamingService._streamContent);
                messagesModel.setProperty(idx, "thinking", streamingService._streamThinking);
            }
            messagesModel.setProperty(idx, "streamStats", stats);
            messagesModel.setProperty(idx, "status", "ok");
        }
        if (isOllama) ollamaManager.queryGpuStatus(model);
        saveChatHistory();
    }

    function _applyError(streamId, message) {
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            _saveVariant(streamId, streamingService._streamVariantIndex, message, streamingService._streamThinking, model);
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === streamingService._streamVariantIndex)
                messagesModel.setProperty(idx, "content", message);
            messagesModel.setProperty(idx, "status", "error");
        }
    }

    function _applyCancelled(streamId, stats) {
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            _saveVariant(streamId, streamingService._streamVariantIndex, streamingService._streamContent, streamingService._streamThinking, model);
            var msg = messagesModel.get(idx);
            if (msg.variantIndex === streamingService._streamVariantIndex) {
                messagesModel.setProperty(idx, "content", streamingService._streamContent);
                messagesModel.setProperty(idx, "thinking", streamingService._streamThinking);
            }
            messagesModel.setProperty(idx, "streamStats", stats);
            messagesModel.setProperty(idx, "status", "ok");
        }
        saveChatHistory();
    }

    function _saveVariant(msgId, index, content, thinking, variantModel) {
        var store = JSON.parse(JSON.stringify(variantStore));
        var result = VariantStore.saveVariant(store, msgId, index, content, thinking, variantModel, maxVariantsPerMessage);

        if (result.evicted > 0) {
            var storeLen = store[msgId].length;
            streamingService._streamVariantIndex = Math.max(0, Math.min(streamingService._streamVariantIndex - result.evicted, storeLen - 1));
            var idx = findIndexById(msgId);
            if (idx >= 0) {
                var msg = messagesModel.get(idx);
                if (msg) {
                    var adjusted = VariantStore.adjustAfterEviction(
                        result.evicted, msg.variantIndex, storeLen,
                        isStreaming && activeStreamId === msgId
                    );
                    messagesModel.setProperty(idx, "variantIndex", adjusted.variantIndex);
                    messagesModel.setProperty(idx, "variantCount", adjusted.variantCount);
                }
            }
        }
        variantStore = store;
    }
}
