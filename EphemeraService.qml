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
    property bool isStreaming: false
    property string activeStreamId: ""
    property string lastUserText: ""
    property int lastHttpStatus: 0

    // --- Provider settings ---
    property string provider: "ollama"
    property string ollamaUrl: "http://localhost:11434"
    property string baseUrl: "http://localhost:11434"
    property string model: ""
    property real temperature: 0.7
    property int maxTokens: 4096
    property int maxTurns: 10
    property int timeout: 30
    property string systemPrompt: ""

    // --- Ollama state ---
    property ListModel availableModels: ListModel {}
    property bool ollamaWeStarted: false
    property bool ollamaExternallyManaged: false
    property bool ollamaReady: false
    property int ollamaRetries: 0
    readonly property int ollamaMaxRetries: 5

    readonly property bool isOllama: provider === "ollama"

    Component.onCompleted: {
        loadSettings();
        pingOllama();
    }

    Component.onDestruction: {
        // Only stop Ollama if we started it
        if (ollamaWeStarted && ollamaProcess.running) {
            ollamaProcess.running = false;
        }
    }

    // ─── Ollama lifecycle ───────────────────────────────────────────

    Process {
        id: ollamaProcess
        command: ["ollama", "serve"]
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
                        if (!root.ollamaWeStarted)
                            root.ollamaExternallyManaged = true;
                        discoverModels();
                        return;
                    }
                } catch (e) {}
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
        if (ollamaReady) return; // Already connected

        if (!ollamaWeStarted && ollamaRetries === 0) {
            // First failure — try starting Ollama
            ollamaWeStarted = true;
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
                } catch (e) {}
            }
        }
    }

    function discoverModels() {
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
        provider = String(PluginService.loadPluginData(pluginId, "provider", "ollama")).trim() || "ollama";
        ollamaUrl = String(PluginService.loadPluginData(pluginId, "ollamaUrl", "http://localhost:11434")).trim();
        model = String(PluginService.loadPluginData(pluginId, "model", "")).trim();
        temperature = PluginService.loadPluginData(pluginId, "temperature", 0.7);
        maxTokens = PluginService.loadPluginData(pluginId, "maxTokens", 4096);
        maxTurns = PluginService.loadPluginData(pluginId, "maxTurns", 10);
        systemPrompt = String(PluginService.loadPluginData(pluginId, "systemPrompt", "")).trim();

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

    // ─── Chat (ephemeral, in-memory only) ──────────────────────────

    function clearChat() {
        messagesModel.clear();
        isStreaming = false;
        activeStreamId = "";
        lastUserText = "";
    }

    function sendMessage(text) {
        if (!text || text.trim().length === 0) return;
        if (isStreaming && chatFetcher.running) {
            markError(activeStreamId, "Please wait until the current response finishes.");
            return;
        }
        startStreaming(text.trim());
    }

    function cancel() {
        if (!isStreaming) return;
        chatFetcher.running = false;
        markError(activeStreamId, "Cancelled");
    }

    function startStreaming(text) {
        var now = Date.now();
        var streamId = "assistant-" + now;

        messagesModel.append({ role: "user", content: text, timestamp: now, id: "user-" + now, status: "ok" });
        lastUserText = text;

        messagesModel.append({ role: "assistant", content: "", timestamp: now + 1, id: streamId, status: "streaming" });
        activeStreamId = streamId;
        isStreaming = true;
        lastHttpStatus = 0;

        var payload = buildPayload(text);
        var result = buildCurlCommand(payload);
        if (!result) {
            if (provider === "ollama") {
                markError(streamId, ollamaReady ? "No Ollama model selected." : "Ollama is not running. Check that ollama is installed.");
            } else {
                markError(streamId, "No API key found. Set the appropriate environment variable.");
            }
            return;
        }

        streamCollector.lastLen = 0;
        streamBuffer = "";
        pendingStdinBody = result.body;
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

        msgs.push({ role: "user", content: latestText });

        return {
            provider: provider,
            baseUrl: baseUrl,
            model: model,
            temperature: temperature,
            max_tokens: maxTokens,
            messages: msgs,
            stream: true,
            timeout: timeout
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
                var delta = (data.delta && data.delta.text) ? data.delta.text : "";
                if (delta)
                    updateStreamContent(activeStreamId, delta);
                if (data.stop_reason)
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
                    var content = choices[0].delta.content;
                    if (typeof content === "string")
                        updateStreamContent(activeStreamId, content);
                }
                if (choices && choices[0] && choices[0].finish_reason)
                    finalizeStream(activeStreamId);
            }
        } catch (e) {
            // Ignore malformed chunks
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
            var existing = getMessageContentById(activeStreamId);
            if ((!existing || existing.length === 0) && bodyText && lastHttpStatus > 0 && lastHttpStatus < 400) {
                var parsed = extractNonStreamingAssistantText(bodyText);
                if (parsed && parsed.length > 0)
                    setMessageContentById(activeStreamId, parsed);
            }
        }

        if (lastHttpStatus >= 400 && isStreaming) {
            var preview = bodyText.length > 600 ? bodyText.slice(0, 600) : bodyText;
            var msg = preview
                ? ("Request failed (HTTP " + lastHttpStatus + "): " + preview)
                : ("Request failed (HTTP " + lastHttpStatus + ")");
            markError(activeStreamId, msg);
            return;
        }

        if (isStreaming)
            finalizeStream(activeStreamId);
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
        } catch (e) {}
        return "";
    }

    // ─── Message helpers ───────────────────────────────────────────

    function findIndexById(msgId) {
        for (var i = 0; i < messagesModel.count; i++) {
            if (messagesModel.get(i).id === msgId)
                return i;
        }
        return -1;
    }

    function markError(streamId, message) {
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            messagesModel.setProperty(idx, "content", message);
            messagesModel.setProperty(idx, "status", "error");
        }
        isStreaming = false;
        activeStreamId = "";
    }

    function updateStreamContent(streamId, deltaText) {
        if (!deltaText) return;
        var idx = findIndexById(streamId);
        if (idx >= 0) {
            var cur = messagesModel.get(idx).content || "";
            messagesModel.setProperty(idx, "content", cur + deltaText);
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
        var idx = findIndexById(streamId);
        if (idx >= 0)
            messagesModel.setProperty(idx, "status", "ok");
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
                chatFetcher.closeStdin();
                root.pendingStdinBody = "";
            }
        }

        stdout: StdioCollector {
            id: streamCollector
            property int lastLen: 0

            onTextChanged: {
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
                markError(root.activeStreamId, "Request failed (exit " + exitCode + ")");
            }
        }
    }
}
