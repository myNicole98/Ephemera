import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/Mcp.js" as Mcp
import "../lib/McpSchema.js" as McpSchema
import "../lib/Providers.js" as Providers

Item {
    id: root

    // --- Configuration ---
    property string mcpUrl: ""
    property bool allowInsecureHttp: false
    property bool enabled: false

    // --- State ---
    property bool isConnected: false
    property bool connecting: false
    property string connectionError: ""
    property string nodeVersion: ""
    property string bridgeVersion: ""
    property string undiciVersion: ""
    property int ignoredToolCount: 0
    property var tools: []
    property int _nextId: 1
    property var _pendingRequests: ({})
    property bool _initialized: false
    property string _negotiatedProtocolVersion: ""
    property bool _listingTools: false
    property bool _toolRefreshPending: false
    property bool _stopRequested: false
    property bool _reconnectPending: false
    property bool _versionProbeCancelled: false
    property string _bridgeExecutable: ""
    property string _bridgeDiagnostics: ""
    property string _readBuffer: ""

    readonly property int _connectionTimeoutMs: 60000
    readonly property int _versionProbeTimeoutMs: 10000
    readonly property int _maxMessageChars: 1048576
    readonly property int _maxDiagnosticChars: 4096
    readonly property int _maxToolPages: 16
    readonly property int _maxTools: 128
    readonly property int _maxToolsJsonChars: 1048576
    readonly property int _maxCursorChars: 4096
    readonly property int _maxToolArgumentChars: 20000
    readonly property string _minimumNodeVersion: "20.18.1"
    readonly property string _reviewedBridgeVersion: "0.1.38"
    readonly property string _minimumUndiciVersion: "7.28.0"
    readonly property string _maximumUndiciVersionExclusive: "8.0.0"
    readonly property string _preferredProtocolVersion: "2025-11-25"
    readonly property var _supportedProtocolVersions: [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07"
    ]

    // --- Signals ---
    signal toolCallCompleted(var callId, string result)
    signal toolCallFailed(var callId, string error)
    signal mcpToolsUpdated()
    signal mcpConnectionStateChanged()

    // --- Lifecycle ---

    Component.onDestruction: {
        _reconnectPending = false;
        _cancelVersionProbe();
        if (mcpProcess.running) {
            _stopRequested = true;
            mcpProcess.running = false;
        }
    }

    // --- Public API ---

    function connectToServer() {
        if (!enabled) {
            connectionError = "";
            return;
        }
        if (isConnected || connecting)
            return;
        if (mcpProcess.running || _versionProbeRunning()) {
            _reconnectPending = true;
            return;
        }

        var error = _configurationError();
        if (error) {
            connectionError = error;
            return;
        }

        connectionError = "";
        connecting = true;
        tools = [];
        ignoredToolCount = 0;
        mcpConnectionStateChanged();

        _startVersionProbe();
    }

    function disconnectFromServer() {
        connectionError = "";
        _reconnectPending = false;
        _cancelVersionProbe();
        if (mcpProcess.running) {
            _stopRequested = true;
            mcpProcess.running = false;
        }
        _reset("MCP disconnected.");
    }

    function reconnectToServer() {
        if (!enabled)
            return;
        connectionError = "";
        _reconnectPending = true;

        if (_cancelVersionProbe()) {
            _reset("MCP reconnecting.");
            return;
        }
        if (mcpProcess.running) {
            _stopRequested = true;
            mcpProcess.running = false;
            _reset("MCP reconnecting.");
            return;
        }

        _reconnectPending = false;
        _reset("MCP reconnecting.");
        Qt.callLater(connectToServer);
    }

    // Call an exactly approved tool contract with validated object arguments.
    function callTool(toolName, args, approvedKeys) {
        var tool = _findTool(toolName);
        if (!isConnected || _listingTools || !tool
                || !Mcp.isToolApproved(tool, approvedKeys))
            return -1;
        if (!args || typeof args !== "object" || Array.isArray(args))
            return -1;
        if (!McpSchema.validateToolArguments(tool, args).valid)
            return -1;
        if (Mcp.formatToolArguments(args, 0).length > _maxToolArgumentChars)
            return -1;

        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function(result) {
                var validation = McpSchema.validateToolResult(tool, result);
                if (!validation.valid) {
                    root.toolCallFailed(id, validation.error);
                    return;
                }
                var text = Mcp.formatToolResult(result);
                if (Mcp.isToolError(result))
                    root.toolCallFailed(id, text || "MCP tool reported an error.");
                else
                    root.toolCallCompleted(id, text);
            },
            reject: function(err) {
                root.toolCallFailed(id, err);
            }
        };
        var req = {
            jsonrpc: "2.0",
            id: id,
            method: "tools/call",
            params: {
                name: tool.name,
                arguments: args
            }
        };
        if (!_writeMessage(req)) {
            delete _pendingRequests[id];
            return -1;
        }
        return id;
    }

    function cancelRequest(id, reason) {
        if (id === undefined || id === null || !_pendingRequests[id])
            return false;
        delete _pendingRequests[id];
        if (mcpProcess.running)
            _sendNotification("notifications/cancelled", {
                requestId: id,
                reason: reason || "Request cancelled."
            });
        return true;
    }

    function isToolApproved(toolName, approvedKeys) {
        return Mcp.isToolApproved(_findTool(toolName), approvedKeys);
    }

    function setToolApproved(approvedKeys, toolName, approved) {
        var current = Mcp.pruneApprovedTools(approvedKeys, tools);
        var tool = _findTool(toolName);
        if (!tool)
            return current;
        return Mcp.setToolApproved(current, tool, approved === true);
    }

    function toolDescription(toolName) {
        var tool = _findTool(toolName);
        return tool ? String(tool.description || tool.title || "") : "";
    }

    // Get approved tools formatted for the Ollama /api/chat tools array.
    function getOllamaTools(approvedKeys) {
        var result = [];
        for (var i = 0; i < tools.length; i++) {
            var tool = tools[i];
            if (!Mcp.isToolApproved(tool, approvedKeys))
                continue;
            result.push({
                type: "function",
                function: {
                    name: tool.name,
                    description: tool.description || "",
                    parameters: tool.inputSchema
                }
            });
        }
        return result;
    }

    // --- Internal: lifecycle and dependency gate ---

    function _configurationError() {
        if (!mcpUrl)
            return "MCP server URL is required.";
        var validated = Providers.validateUrl(mcpUrl);
        if (!validated.valid)
            return validated.error || "Invalid MCP URL.";
        var safetyError = Mcp.mcpUrlSafetyError(mcpUrl);
        if (safetyError)
            return safetyError;
        if (Mcp.requiresInsecureHttpConsent(mcpUrl) && !allowInsecureHttp)
            return "Remote HTTP MCP requires explicit insecure transport consent.";
        return "";
    }

    function _versionProbeRunning() {
        return nodeVersionProbe.running || bridgeVersionProbe.running;
    }

    function _cancelVersionProbe() {
        var wasRunning = _versionProbeRunning();
        if (!wasRunning)
            return false;
        _versionProbeCancelled = true;
        if (nodeVersionProbe.running)
            nodeVersionProbe.running = false;
        if (bridgeVersionProbe.running)
            bridgeVersionProbe.running = false;
        return true;
    }

    function _finishCancelledProbe() {
        if (!_versionProbeCancelled)
            return false;
        _versionProbeCancelled = false;
        _resumePendingReconnect();
        return true;
    }

    function _startVersionProbe() {
        _versionProbeCancelled = false;
        nodeVersion = "";
        bridgeVersion = "";
        undiciVersion = "";
        _bridgeExecutable = "";
        bridgeVersionTimer.restart();
        nodeVersionProbe.command = ["node", "--version"];
        nodeVersionProbe.running = true;
    }

    function _handleNodeVersionProbeFinished(exitCode, output) {
        bridgeVersionTimer.stop();
        if (_finishCancelledProbe())
            return;

        var version = String(output || "").trim();
        if (exitCode !== 0 || !Mcp.isVersionAtLeast(version, _minimumNodeVersion)) {
            _dependencyError("MCP requires Node.js " + _minimumNodeVersion + " or newer.");
            return;
        }
        nodeVersion = version.replace(/^v/, "");
        _startPackageProbe();
    }

    function _startPackageProbe() {
        bridgeVersionTimer.restart();
        bridgeVersionProbe.command = [
            "npm", "list", "--global", "--json", "--long", "--depth=1",
            "mcp-remote", "undici"
        ];
        bridgeVersionProbe.running = true;
    }

    function _handlePackageProbeFinished(exitCode, output) {
        bridgeVersionTimer.stop();
        if (_finishCancelledProbe())
            return;

        if (exitCode !== 0) {
            _dependencyError("Could not inspect the global mcp-remote installation.");
            return;
        }

        var packageInfo = Mcp.extractNpmPackageInfo(output, "mcp-remote");
        var version = packageInfo.version;
        if (!version || !packageInfo.executable) {
            _dependencyError("mcp-remote is not installed globally in a supported npm layout. Install the reviewed 0.1.38 release.");
            return;
        }
        if (version !== _reviewedBridgeVersion) {
            _dependencyError("mcp-remote " + version + " is unsupported. Install the reviewed " + _reviewedBridgeVersion + " release.");
            return;
        }
        if (!Mcp.isVersionInRange(packageInfo.undiciVersion,
                                  _minimumUndiciVersion,
                                  _maximumUndiciVersionExclusive)) {
            _dependencyError("mcp-remote must use undici " + _minimumUndiciVersion + " or newer within major version 7. Reinstall the reviewed bridge release.");
            return;
        }

        bridgeVersion = version;
        undiciVersion = packageInfo.undiciVersion;
        _bridgeExecutable = packageInfo.executable;
        _startBridge();
    }

    function _dependencyError(message) {
        connectionError = message;
        _reset(message);
    }

    function _startBridge() {
        var error = _configurationError();
        if (!enabled || error) {
            connectionError = error;
            _reset(error || "MCP disabled.");
            return;
        }

        _initialized = false;
        _pendingRequests = ({});
        _nextId = 1;
        _listingTools = false;
        _toolRefreshPending = false;
        _bridgeDiagnostics = "";
        _readBuffer = "";
        tools = [];
        connectionTimer.restart();

        if (!_bridgeExecutable) {
            _dependencyError("The version-checked mcp-remote executable is unavailable.");
            return;
        }
        var command = [_bridgeExecutable, mcpUrl];
        if (/^http:\/\//i.test(mcpUrl))
            command.push("--allow-http");
        mcpProcess.command = command;
        mcpProcess.running = true;
    }

    function _resumePendingReconnect() {
        if (!_reconnectPending)
            return;
        _reconnectPending = false;
        Qt.callLater(connectToServer);
    }

    function _supportsProtocolVersion(version) {
        var value = String(version || "");
        for (var i = 0; i < _supportedProtocolVersions.length; i++) {
            if (_supportedProtocolVersions[i] === value)
                return true;
        }
        return false;
    }

    function _findTool(toolName) {
        return Mcp.findTool(tools, toolName);
    }

    function _abortConnection(message) {
        connectionError = message;
        _reconnectPending = false;
        _cancelVersionProbe();
        if (mcpProcess.running) {
            _stopRequested = true;
            mcpProcess.running = false;
        }
        _reset(message);
    }

    function _reset(failMessage) {
        var pending = _pendingRequests;
        _pendingRequests = ({});
        connectionTimer.stop();
        bridgeVersionTimer.stop();
        isConnected = false;
        connecting = false;
        _initialized = false;
        _listingTools = false;
        _toolRefreshPending = false;
        _negotiatedProtocolVersion = "";
        _readBuffer = "";
        tools = [];
        ignoredToolCount = 0;
        mcpConnectionStateChanged();

        if (failMessage) {
            for (var id in pending) {
                if (pending[id] && pending[id].reject)
                    pending[id].reject(failMessage);
            }
        }
    }

    // --- Internal: JSON-RPC ---

    function _writeMessage(message) {
        if (!mcpProcess.running)
            return false;
        mcpProcess.write(JSON.stringify(message) + "\n");
        return true;
    }

    function _sendResponse(id, result) {
        _writeMessage({ jsonrpc: "2.0", id: id, result: result || {} });
    }

    function _sendError(id, code, message) {
        _writeMessage({
            jsonrpc: "2.0",
            id: id,
            error: { code: code, message: message }
        });
    }

    function _sendNotification(method, params) {
        var message = { jsonrpc: "2.0", method: method };
        if (params) message.params = params;
        _writeMessage(message);
    }

    function _handleStdoutChunk(data) {
        _readBuffer += String(data || "");
        var lines = _readBuffer.split("\n");
        _readBuffer = lines.pop();
        if (_readBuffer.length > _maxMessageChars) {
            _abortConnection("MCP message exceeded the size limit.");
            return;
        }
        for (var i = 0; i < lines.length; i++) {
            if (lines[i].length > _maxMessageChars) {
                _abortConnection("MCP message exceeded the size limit.");
                return;
            }
            _handleLine(lines[i]);
        }
    }

    function _handleLine(line) {
        var value = String(line || "").trim();
        if (!value) return;

        var message;
        try {
            message = JSON.parse(value);
        } catch (e) {
            return;
        }
        if (!message || message.jsonrpc !== "2.0")
            return;

        if (message.method && message.id !== undefined && message.id !== null) {
            _handleRequest(message.id, message.method, message.params);
            return;
        }

        if (message.id !== undefined && message.id !== null) {
            if (typeof message.id !== "number" || !isFinite(message.id)
                    || Math.floor(message.id) !== message.id || message.id < 1)
                return;
            var pending = _pendingRequests[message.id];
            if (pending) {
                delete _pendingRequests[message.id];
                if (message.error)
                    pending.reject(message.error.message || JSON.stringify(message.error));
                else if (message.result !== undefined)
                    pending.resolve(message.result);
                else
                    pending.reject("Invalid JSON-RPC response.");
            }
            return;
        }

        if (message.method)
            _handleNotification(message.method, message.params);
    }

    function _handleRequest(id, method, params) {
        if (method === "ping") {
            _sendResponse(id, {});
            return;
        }
        _sendError(id, -32601, "Method not found: " + method);
    }

    function _handleNotification(method, params) {
        if (method !== "notifications/tools/list_changed")
            return;
        if (_listingTools) {
            _toolRefreshPending = true;
            return;
        }
        _beginListTools();
    }

    function _sendInitialize() {
        if (!connecting || !mcpProcess.running)
            return;
        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function(result) { _onInitialized(result); },
            reject: function(err) { _abortConnection("Initialize failed: " + err); }
        };
        _writeMessage({
            jsonrpc: "2.0",
            id: id,
            method: "initialize",
            params: {
                protocolVersion: _preferredProtocolVersion,
                capabilities: {},
                clientInfo: { name: "ephemera", version: "1.1.0" }
            }
        });
    }

    function _onInitialized(result) {
        var version = result && result.protocolVersion ? String(result.protocolVersion) : "";
        if (!_supportsProtocolVersion(version)) {
            _abortConnection("Unsupported MCP protocol version: " + (version || "unknown") + ".");
            return;
        }
        var toolCapabilities = result && result.capabilities && result.capabilities.tools;
        if (!toolCapabilities || typeof toolCapabilities !== "object"
                || Array.isArray(toolCapabilities)) {
            _abortConnection("MCP server does not advertise tools capability.");
            return;
        }
        _negotiatedProtocolVersion = version;
        _sendNotification("notifications/initialized");
        _initialized = true;
        _beginListTools();
    }

    // --- Internal: bounded tool discovery ---

    function _beginListTools() {
        if (_listingTools || !_initialized)
            return;
        _listingTools = true;
        if (isConnected) {
            isConnected = false;
            connecting = true;
            tools = [];
            ignoredToolCount = 0;
            mcpConnectionStateChanged();
        }
        connectionTimer.restart();
        _listToolsPage("", [], ({}), 0);
    }

    function _listToolsPage(cursor, accumulated, seenCursors, pageCount) {
        if (pageCount >= _maxToolPages) {
            _abortConnection("MCP tool list exceeded the page limit.");
            return;
        }

        var cursorValue = String(cursor || "");
        if (cursorValue) {
            var cursorKey = "$" + cursorValue;
            if (seenCursors[cursorKey]) {
                _abortConnection("MCP tool list repeated a pagination cursor.");
                return;
            }
            seenCursors[cursorKey] = true;
        }

        var id = _nextId++;
        var collected = Array.isArray(accumulated) ? accumulated.slice() : [];
        _pendingRequests[id] = {
            resolve: function(result) {
                if (!result || !Array.isArray(result.tools)) {
                    _abortConnection("MCP server returned an invalid tool list.");
                    return;
                }
                if (result.nextCursor !== undefined && result.nextCursor !== null
                        && typeof result.nextCursor !== "string") {
                    _abortConnection("MCP server returned an invalid pagination cursor.");
                    return;
                }
                var page = Mcp.appendToolsPage(collected, result);
                if (page.tools.length > _maxTools) {
                    _abortConnection("MCP server advertised too many tools.");
                    return;
                }

                var serialized = "";
                try { serialized = JSON.stringify(page.tools); }
                catch (e) {
                    _abortConnection("MCP server returned an invalid tool schema.");
                    return;
                }
                if (serialized.length > _maxToolsJsonChars) {
                    _abortConnection("MCP tool schemas exceeded the size limit.");
                    return;
                }

                if (page.nextCursor.length > _maxCursorChars) {
                    _abortConnection("MCP pagination cursor exceeded the size limit.");
                    return;
                }
                if (page.nextCursor) {
                    _listToolsPage(page.nextCursor, page.tools, seenCursors, pageCount + 1);
                    return;
                }

                var sanitized = Mcp.sanitizeTools(page.tools);
                var supported = [];
                for (var ti = 0; ti < sanitized.length; ti++) {
                    if (!McpSchema.inputSchemaSupportError(sanitized[ti].inputSchema)
                            && !McpSchema.outputSchemaSupportError(sanitized[ti].outputSchema))
                        supported.push(sanitized[ti]);
                }
                ignoredToolCount = page.tools.length - supported.length;
                tools = supported;
                _listingTools = false;
                if (_toolRefreshPending) {
                    _toolRefreshPending = false;
                    _beginListTools();
                    return;
                }
                isConnected = true;
                connecting = false;
                connectionError = "";
                connectionTimer.stop();
                mcpConnectionStateChanged();
                mcpToolsUpdated();
            },
            reject: function(err) {
                _abortConnection("Failed to list tools: " + err);
            }
        };
        _writeMessage({
            jsonrpc: "2.0",
            id: id,
            method: "tools/list",
            params: cursorValue ? { cursor: cursorValue } : {}
        });
    }

    function _appendDiagnostic(line) {
        var value = String(line || "").trim();
        if (!value) return;
        _bridgeDiagnostics = (_bridgeDiagnostics + "\n" + value).slice(-_maxDiagnosticChars);
    }

    // --- Timers ---

    Timer {
        id: bridgeVersionTimer
        interval: root._versionProbeTimeoutMs
        repeat: false
        onTriggered: {
            root._versionProbeCancelled = true;
            if (nodeVersionProbe.running)
                nodeVersionProbe.running = false;
            if (bridgeVersionProbe.running)
                bridgeVersionProbe.running = false;
            root._dependencyError("Timed out while checking the MCP runtime dependencies.");
        }
    }

    Timer {
        id: connectionTimer
        interval: root._connectionTimeoutMs
        repeat: false
        onTriggered: root._abortConnection("MCP connection timed out.")
    }

    // --- Processes ---

    Process {
        id: nodeVersionProbe
        running: false

        stdout: StdioCollector {
            id: nodeVersionOutput
            waitForEnd: true
        }

        stderr: StdioCollector {
            waitForEnd: true
        }

        onExited: exitCode => root._handleNodeVersionProbeFinished(exitCode, nodeVersionOutput.text)
    }

    Process {
        id: bridgeVersionProbe
        running: false

        stdout: StdioCollector {
            id: bridgeVersionOutput
            waitForEnd: true
        }

        stderr: StdioCollector {
            waitForEnd: true
        }

        onExited: exitCode => root._handlePackageProbeFinished(exitCode, bridgeVersionOutput.text)
    }

    Process {
        id: mcpProcess
        running: false
        stdinEnabled: true

        onStarted: root._sendInitialize()

        stdout: SplitParser {
            splitMarker: ""
            onRead: data => root._handleStdoutChunk(data)
        }

        stderr: SplitParser {
            splitMarker: ""
            onRead: data => root._appendDiagnostic(data)
        }

        onExited: (exitCode, exitStatus) => {
            var expected = root._stopRequested;
            var reconnect = root._reconnectPending;
            root._stopRequested = false;

            if (!expected && (root.isConnected || root.connecting)) {
                var message = "MCP process exited unexpectedly";
                if (exitCode !== 0)
                    message += " with code " + exitCode;
                message += ".";
                var diagnostic = root._bridgeDiagnostics.trim();
                if (diagnostic)
                    message += "\n" + diagnostic.slice(-600);
                root.connectionError = message;
                root._reset(message);
            }

            if (reconnect)
                root._resumePendingReconnect();
        }
    }
}
