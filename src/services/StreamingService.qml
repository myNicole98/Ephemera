import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/StreamParser.js" as StreamParser
import "../lib/ErrorHints.js" as ErrorHints
import "../lib/Backoff.js" as Backoff
import "../lib/Providers.js" as Providers

Item {
    id: root

    // --- Input from coordinator ---
    property string provider: "ollama"
    property string ollamaUrl: "http://localhost:11434"
    property int timeout: 300

    // --- Streaming state ---
    property bool isStreaming: false
    property string activeStreamId: ""
    property string streamBuffer: ""
    property string pendingStdinBody: ""
    property real streamStartTime: 0
    property int streamTokenCount: 0
    property int _apiOutputTokens: 0
    property bool _insideThinkTag: false
    property string _tagBuffer: ""
    property string _streamContent: ""
    property string _streamThinking: ""
    property int _streamVariantIndex: 0
    property string _lastFinalizedStreamId: ""
    property bool _seenToolCalls: false
    property int lastHttpStatus: 0
    property bool lastRequestFailed: false

    // --- Error backoff state ---
    property real _cooldownUntil: 0
    property int _consecutiveErrors: 0
    readonly property int _backoffBaseMs: 2000
    readonly property int _backoffMaxMs: 30000

    // --- Export state ---
    property string exportPendingBody: ""
    property string lastExportedFile: ""

    // --- Signals to coordinator ---
    signal streamContentUpdated(string streamId, string deltaText)
    signal streamThinkingUpdated(string streamId, string deltaText)
    signal streamFinalized(string streamId, string stats)
    signal streamError(string streamId, string message)
    signal streamCancelled(string streamId, string stats)

    // --- Public API ---

    function isInErrorCooldown() {
        return Backoff.isInCooldown(_cooldownUntil);
    }

    function resetErrorState() {
        _cooldownUntil = 0;
        _consecutiveErrors = 0;
    }

    function launchCurl(curlResult, requestPayloadJson) {
        if (chatFetcher.running) return;

        streamCollector.lastLen = 0;
        streamBuffer = "";
        _insideThinkTag = false;
        _tagBuffer = "";
        pendingStdinBody = curlResult.body;
        chatFetcher.stdinEnabled = true;
        chatFetcher.command = curlResult.cmd;
        chatFetcher.running = true;
    }

    function cancel() {
        if (!isStreaming) return;
        var streamId = activeStreamId;

        // Flush any remaining tag buffer before clearing state
        if (_tagBuffer.length > 0) {
            if (_insideThinkTag)
                _streamThinking += _tagBuffer;
            else
                _streamContent += _tagBuffer;
            _tagBuffer = "";
        }
        _insideThinkTag = false;
        isStreaming = false;

        streamCancelled(streamId, _buildStreamStats());
        chatFetcher.running = false;
    }

    function reset() {
        if (chatFetcher.running)
            chatFetcher.running = false;
        isStreaming = false;
        activeStreamId = "";
        streamStartTime = 0;
        streamTokenCount = 0;
        _apiOutputTokens = 0;
        _streamContent = "";
        _streamThinking = "";
        _insideThinkTag = false;
        _tagBuffer = "";
        _seenToolCalls = false;
        streamBuffer = "";
        pendingStdinBody = "";
    }

    function beginStream(streamId, variantIndex) {
        activeStreamId = streamId;
        isStreaming = true;
        streamStartTime = 0;
        streamTokenCount = 0;
        lastHttpStatus = 0;
        lastRequestFailed = false;
        _streamContent = "";
        _streamThinking = "";
        _apiOutputTokens = 0;
        _streamVariantIndex = variantIndex;
        _seenToolCalls = false;
    }

    function exportToClipboard(markdownText) {
        Quickshell.execDetached(["wl-copy", "--", markdownText]);
    }

    function exportToFile(markdownText, homeDir, filename) {
        // install -m 0600 sets restrictive permissions (owner-only read/write)
        exportFileWriter.command = ["install", "-m", "0600", "/dev/stdin", filename];
        exportPendingBody = markdownText;
        exportFileWriter.stdinEnabled = true;
        exportFileWriter.running = true;
    }

    // --- Internal: stream processing ---
    function handleStreamChunk(chunk) {
    var result = StreamParser.splitLines(chunk, streamBuffer);
    streamBuffer = result.buffer;

    for (var i = 0; i < result.lines.length; i++) {
        var line = result.lines[i];

        if (line === "data: [DONE]" || line === "data:[DONE]")
            continue;

        var jsonPart;
        if (line.startsWith("data:")) {
            jsonPart = line.substring(5).trim();
        } else if (line.startsWith("{")) {
            // Bare NDJSON (Ollama native /api/chat, etc.)
            jsonPart = line;
        } else {
            continue;
        }

        var delta = StreamParser.parseDelta(jsonPart, provider);

        if (delta.outputTokens > 0)
            _apiOutputTokens = delta.outputTokens;

        if (delta.toolCalls) {
            _seenToolCalls = true;
        }
        if (delta.thinking) {
            streamTokenCount++;
            _applyThinkingDelta(activeStreamId, delta.thinking);
        }
        if (delta.content) {
            streamTokenCount++;
            if (!Providers.getProviderInfo(provider).hasNativeThinking) {
                var tagResult = StreamParser.routeThinkTags(delta.content, _tagBuffer, _insideThinkTag);
                _tagBuffer = tagResult.tagBuffer;
                _insideThinkTag = tagResult.insideThinkTag;
                for (var ti = 0; ti < tagResult.thinkingParts.length; ti++)
                    _applyThinkingDelta(activeStreamId, tagResult.thinkingParts[ti]);
                for (var ci = 0; ci < tagResult.contentParts.length; ci++)
                    _applyContentDelta(activeStreamId, tagResult.contentParts[ci]);
            } else {
                _applyContentDelta(activeStreamId, delta.content);
            }
        }
        if (delta.done) {
            if (_seenToolCalls && provider === "ollama") {
                _seenToolCalls = false;
            } else {
                _finalizeStream(activeStreamId);
            }
        }
    }
}




    function handleStreamFinished(text) {
        var parsed = StreamParser.extractHttpStatus(text);
        lastHttpStatus = parsed.status;
        var bodyText = parsed.body;

        if (isStreaming) {
            if (_streamContent.length === 0 && bodyText && lastHttpStatus > 0 && lastHttpStatus < 400) {
                var fallback = StreamParser.extractNonStreamingText(bodyText, provider);
                if (fallback && fallback.length > 0) {
                    _streamContent = fallback;
                    streamContentUpdated(activeStreamId, fallback);
                }
            }
        }

        if (lastHttpStatus >= 400 && isStreaming) {
            var preview = bodyText.length > 600 ? bodyText.slice(0, 600) + "\u2026" : bodyText;
            var hint = ErrorHints.httpErrorHint(lastHttpStatus);
            var msg = "Request failed (HTTP " + lastHttpStatus + ")";
            if (hint) msg += "\n" + hint;
            if (preview) msg += "\n\n" + preview;
            _markError(activeStreamId, msg);
            return;
        }

        if (isStreaming) {
            if (lastHttpStatus === 0 && _streamContent.length === 0) {
                var providerName = _providerDisplayName();
                var connMsg = provider === "ollama"
                    ? "Could not connect to Ollama.\nMake sure Ollama is running at " + ollamaUrl + "."
                    : "Could not connect to " + providerName + ".\nCheck your network connection and provider settings.";
                _markError(activeStreamId, connMsg);
                return;
            }
            _finalizeStream(activeStreamId);
        }
    }

    function _applyContentDelta(streamId, deltaText) {
        if (!deltaText) return;
        if (streamStartTime === 0) streamStartTime = Date.now();
        _streamContent += deltaText;
        streamContentUpdated(streamId, deltaText);
    }

    function _applyThinkingDelta(streamId, deltaText) {
        if (!deltaText) return;
        if (streamStartTime === 0) streamStartTime = Date.now();
        _streamThinking += deltaText;
        streamThinkingUpdated(streamId, deltaText);
    }

    function _finalizeStream(streamId) {
        if (!isStreaming || activeStreamId !== streamId) return;

        if (_tagBuffer.length > 0) {
            if (_insideThinkTag)
                _applyThinkingDelta(streamId, _tagBuffer);
            else
                _applyContentDelta(streamId, _tagBuffer);
            _tagBuffer = "";
        }
        _insideThinkTag = false;

        _lastFinalizedStreamId = streamId;
        isStreaming = false;
        activeStreamId = "";
        _cooldownUntil = 0;
        _consecutiveErrors = 0;
        streamFinalized(streamId, _buildStreamStats());
    }

    function _markError(streamId, message) {
        _streamContent = message;
        isStreaming = false;
        activeStreamId = "";
        lastRequestFailed = true;
        _consecutiveErrors++;
        _cooldownUntil = Backoff.computeCooldownUntil(_consecutiveErrors, _backoffBaseMs, _backoffMaxMs);
        streamError(streamId, message);
    }

    function _buildStreamStats() {
        if (streamStartTime === 0) return "";
        var elapsed = (Date.now() - streamStartTime) / 1000;
        var label = elapsed.toFixed(1) + "s";
        // Prefer API-reported token count (accurate); fall back to delta count (approximate)
        var tokens = _apiOutputTokens > 0 ? _apiOutputTokens : streamTokenCount;
        if (tokens > 0 && elapsed > 0.5) {
            var tps = tokens / elapsed;
            var prefix = _apiOutputTokens > 0 ? "" : "~";
            label += " · " + prefix + tps.toFixed(1) + " tok/s";
        }
        return label;
    }

    function _providerDisplayName() {
        return Providers.getProviderInfo(provider).name;
    }

    function _curlExitHint(exitCode) {
        return ErrorHints.curlExitHint(exitCode, provider, _providerDisplayName(), ollamaUrl);
    }

    // --- Processes ---

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
                    root._markError(root.activeStreamId, "Response exceeded maximum buffer size (5 MB).");
                    return;
                }
                var newData = text.substring(lastLen);
                lastLen = text.length;
                root.handleStreamChunk(newData);
            }

            onStreamFinished: {
                root.handleStreamFinished(text);
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0 && root.isStreaming) {
                root._markError(root.activeStreamId, root._curlExitHint(exitCode));
            }
        }
    }

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
}
