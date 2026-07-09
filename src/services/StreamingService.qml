import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/StreamParser.js" as StreamParser
import "../lib/ErrorHints.js" as ErrorHints
import "../lib/Backoff.js" as Backoff
import "../lib/Providers.js" as Providers
import "../lib/Mcp.js" as Mcp

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
    property var _pendingToolCalls: []
    property var _allToolCalls: []
    property var _toolResults: []
    property var mcpService: null
    property bool toolCallsAllowed: false
    property bool requireToolApproval: true
    property var allowedToolApprovals: []
    property var _conversationMessages: []
    property int _pendingCallId: -1
    property var _pendingToolCallMeta: null
    property var _pendingToolCallService: null
    property var _pendingApprovalToolCall: null
    property string _pendingApprovalToolName: ""
    property string _pendingApprovalToolDescription: ""
    property var _pendingApprovalToolArgs: ({})
    property string _pendingApprovalToolArgumentsText: ""
    property bool _awaitingToolExecution: false
    property int _toolRoundCount: 0
    readonly property int _maxToolRounds: 4
    readonly property int _maxToolResultChars: 20000
    readonly property int _maxToolArgumentChars: 20000
    readonly property int _toolCallTimeoutMs: 30000
    readonly property bool toolApprovalPending: _pendingApprovalToolCall !== null
    readonly property string pendingToolName: _pendingApprovalToolName
    readonly property string pendingToolDescription: _pendingApprovalToolDescription
    readonly property string pendingToolArgumentsText: _pendingApprovalToolArgumentsText
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
    signal streamToolRoundReady(string streamId, var messages)

    // --- Public API ---

    function isInErrorCooldown() {
        return Backoff.isInCooldown(_cooldownUntil);
    }

    function resetErrorState() {
        _cooldownUntil = 0;
        _consecutiveErrors = 0;
    }

    function launchCurl(curlResult, messages) {
        if (chatFetcher.running) return;

        streamCollector.lastLen = 0;
        streamBuffer = "";
        _insideThinkTag = false;
        _tagBuffer = "";
        if (messages)
            _conversationMessages = messages;
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
        _clearToolState(true, "Stream cancelled.");

        streamCancelled(streamId, _buildStreamStats());
        chatFetcher.running = false;
    }

    function approvePendingToolCall() {
        if (!toolApprovalPending || !isStreaming)
            return false;
        var toolName = _pendingApprovalToolName;
        var toolArgs = _pendingApprovalToolArgs;
        _clearPendingToolApproval();
        _invokeToolCall(toolName, toolArgs);
        return true;
    }

    function rejectPendingToolCall(reason) {
        if (!toolApprovalPending || !isStreaming)
            return false;
        var toolName = _pendingApprovalToolName;
        var message = reason || "Tool call rejected by user.";
        _applyThinkingDelta(activeStreamId, "Tool rejected: " + toolName + "\n");
        _recordToolResult(toolName, "Error: " + message);
        _clearPendingToolApproval();
        _executeNextToolCall();
        return true;
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
        _clearToolState(true, "Stream reset.");
        streamBuffer = "";
        pendingStdinBody = "";
    }

    function beginStream(streamId, variantIndex, messages) {
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
        _clearToolState(false, "");
        _conversationMessages = messages || [];
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

            if (line === "data: [DONE]" || line === "data:[DONE]") {
                if (_pendingToolCalls.length > 0)
                    _awaitingToolExecution = true;
                else
                    _finalizeStream(activeStreamId);
                continue;
            }

            var jsonPart;
            if (line.startsWith("data:")) {
                jsonPart = line.substring(5).trim();
            } else if (line.startsWith("{")) {
                jsonPart = line;
            } else {
                continue;
            }

            var delta = StreamParser.parseDelta(jsonPart, provider);

            if (delta.outputTokens > 0)
                _apiOutputTokens = delta.outputTokens;

            if (delta.toolCalls && delta.toolCalls.length > 0) {
                _seenToolCalls = true;
                for (var tci = 0; tci < delta.toolCalls.length; tci++) {
                    _pendingToolCalls.push(delta.toolCalls[tci]);
                    _allToolCalls.push(delta.toolCalls[tci]);
                }
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
                if (_pendingToolCalls.length > 0)
                    _awaitingToolExecution = true;
                else
                    _finalizeStream(activeStreamId);
            }
        }
    }

    function _truncateToolResult(text) {
        if (!text || text.length <= _maxToolResultChars)
            return text || "";
        return text.substring(0, _maxToolResultChars) + "\n\n[Tool result truncated]";
    }

    function _toolCallName(toolCall, fallbackName) {
        return fallbackName || toolCall.name || "unknown_tool";
    }

    function _recordToolResult(toolName, content) {
        _toolResults.push({
            role: "tool",
            tool_name: toolName,
            content: _truncateToolResult(content)
        });
    }

    function _clearToolState(cancelPending, reason) {
        var service = _pendingToolCallService || mcpService;
        if (cancelPending && _pendingCallId >= 0 && service && service.cancelRequest)
            service.cancelRequest(_pendingCallId, reason || "Tool call cancelled.");
        _clearPendingToolApproval();
        _seenToolCalls = false;
        _pendingToolCalls = [];
        _allToolCalls = [];
        _toolResults = [];
        _awaitingToolExecution = false;
        _toolRoundCount = 0;
        _pendingCallId = -1;
        _pendingToolCallMeta = null;
        _pendingToolCallService = null;
        toolCallTimer.stop();
    }

    function _clearPendingToolApproval() {
        _pendingApprovalToolCall = null;
        _pendingApprovalToolName = "";
        _pendingApprovalToolDescription = "";
        _pendingApprovalToolArgs = ({});
        _pendingApprovalToolArgumentsText = "";
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

        if (_awaitingToolExecution && _pendingToolCalls.length > 0) {
            _awaitingToolExecution = false;
            _executeNextToolCall();
            return;
        }

        if (isStreaming && !_seenToolCalls) {
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

    function _executeNextToolCall() {
        if (_pendingToolCalls.length === 0) {
            _resumeWithToolResults();
            return;
        }
        var toolCall = _pendingToolCalls.shift();
        var toolName = toolCall.function ? toolCall.function.name : toolCall.name;
        var toolArgs = toolCall.function ? toolCall.function.arguments : toolCall.arguments;
        toolArgs = Mcp.parseToolArguments(toolArgs);
        toolName = _toolCallName(toolCall, toolName);
        var blockMessage = _toolPermissionBlockMessage(toolName);
        if (blockMessage) {
            _markError(activeStreamId, blockMessage);
            return;
        }
        var argumentsText = Mcp.formatToolArguments(toolArgs, 0);
        var argumentBlockMessage = _toolArgumentBlockMessage(toolName, argumentsText);
        if (argumentBlockMessage) {
            _markError(activeStreamId, argumentBlockMessage);
            return;
        }
        if (!mcpService || !mcpService.isConnected) {
            _recordToolResult(toolName, "Error: MCP service not connected");
            _executeNextToolCall();
            return;
        }
        if (requireToolApproval) {
            _requestToolApproval(toolCall, toolName, toolArgs, argumentsText);
            return;
        }
        _invokeToolCall(toolName, toolArgs);
    }

    function _toolPermissionBlockMessage(toolName) {
        if (!toolCallsAllowed) {
            return "MCP tool call blocked. Enable model tool calls in MCP settings to let the model request tools.";
        }
        if (!mcpService) {
            return "MCP tool call blocked. MCP service is not available.";
        }
        if (!mcpService.isConnected) {
            return "MCP tool call blocked. MCP service is not connected.";
        }
        if (!mcpService.isToolAllowed(toolName, allowedToolApprovals)) {
            return "MCP tool call blocked. The tool '" + toolName + "' is not allowed in MCP settings.";
        }
        return "";
    }

    function _toolArgumentBlockMessage(toolName, argumentsText) {
        if (argumentsText.length <= _maxToolArgumentChars)
            return "";
        return "MCP tool call blocked. The arguments for '" + toolName + "' are too large to review safely.";
    }

    function _requestToolApproval(toolCall, toolName, toolArgs, argumentsText) {
        _pendingApprovalToolCall = toolCall;
        _pendingApprovalToolName = toolName;
        _pendingApprovalToolDescription = mcpService && mcpService.toolDescription ? mcpService.toolDescription(toolName) : "";
        _pendingApprovalToolArgs = toolArgs || {};
        _pendingApprovalToolArgumentsText = argumentsText || Mcp.formatToolArguments(toolArgs, 0);
        _applyThinkingDelta(activeStreamId, "\nTool request awaiting approval: " + toolName + "\n");
    }

    function _invokeToolCall(toolName, toolArgs) {
        var blockMessage = _toolPermissionBlockMessage(toolName);
        if (blockMessage) {
            _markError(activeStreamId, blockMessage);
            return;
        }
        var argumentBlockMessage = _toolArgumentBlockMessage(toolName, Mcp.formatToolArguments(toolArgs, 0));
        if (argumentBlockMessage) {
            _markError(activeStreamId, argumentBlockMessage);
            return;
        }
        if (!mcpService || !mcpService.isConnected) {
            _recordToolResult(toolName, "Error: MCP service not connected");
            _executeNextToolCall();
            return;
        }
        _applyThinkingDelta(activeStreamId, "\nCalling tool: " + toolName + "\n");
        var callId = mcpService.callTool(toolName, toolArgs);
        if (callId < 0) {
            _recordToolResult(toolName, "Error: MCP service not connected");
            _executeNextToolCall();
            return;
        }
        _pendingCallId = callId;
        _pendingToolCallMeta = { name: toolName };
        _pendingToolCallService = mcpService;
        toolCallTimer.restart();
    }

    function _onToolCallCompleted(callId, result) {
        if (callId !== _pendingCallId) return;
        toolCallTimer.stop();
        _pendingCallId = -1;
        _pendingToolCallService = null;
        var resultText = (typeof result === "string") ? result : JSON.stringify(result);
        var preview = resultText.substring(0, 200) + (resultText.length > 200 ? "..." : "");
        _applyThinkingDelta(activeStreamId, "Tool result: " + preview + "\n");
        _recordToolResult(_pendingToolCallMeta.name, resultText);
        _pendingToolCallMeta = null;
        _executeNextToolCall();
    }

    function _onToolCallFailed(callId, error) {
        if (callId !== _pendingCallId) return;
        toolCallTimer.stop();
        _pendingCallId = -1;
        _pendingToolCallService = null;
        _applyThinkingDelta(activeStreamId, "Tool error: " + error + "\n");
        _recordToolResult(_pendingToolCallMeta ? _pendingToolCallMeta.name : "unknown_tool", "Error: " + error);
        _pendingToolCallMeta = null;
        _executeNextToolCall();
    }

    function _resumeWithToolResults() {
        if (_toolResults.length === 0) { _finalizeStream(activeStreamId); return; }
        if (_toolRoundCount >= _maxToolRounds) {
            _markError(activeStreamId, "MCP tool call limit reached.");
            return;
        }
        _toolRoundCount++;
        var updatedMessages = Mcp.buildToolResumeMessages(
            _conversationMessages,
            _streamContent,
            _streamThinking,
            _allToolCalls,
            _toolResults
        );
        _conversationMessages = updatedMessages;
        _toolResults = [];
        _seenToolCalls = false;
        _pendingToolCalls = [];
        _allToolCalls = [];
        streamToolRoundReady(activeStreamId, updatedMessages);
    }

    Timer {
        id: toolCallTimer
        interval: root._toolCallTimeoutMs
        repeat: false
        onTriggered: {
            if (root._pendingCallId >= 0) {
                var callId = root._pendingCallId;
                var service = root._pendingToolCallService || root.mcpService;
                if (service && service.cancelRequest)
                    service.cancelRequest(callId, "MCP tool call timed out.");
                root._onToolCallFailed(callId, "MCP tool call timed out.");
            }
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
