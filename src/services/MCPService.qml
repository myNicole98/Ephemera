import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/Mcp.js" as Mcp
import "../lib/Providers.js" as Providers

Item {
    id: root

    // --- Configuration ---
    property string mcpUrl: ""
    property string mcpCommand: "mcp-remote"
    property bool enabled: false

    // --- State ---
    property bool isConnected: false
    property bool connecting: false
    property string connectionError: ""
    property var tools: []          // Array of tool objects from tools/list
    property int _nextId: 1
    property var _pendingRequests: ({})   // id -> { resolve, reject }
    property string _readBuffer: ""
    property bool _initialized: false
    property bool _manualDisconnect: false
    property string _negotiatedProtocolVersion: ""
    readonly property int _connectionTimeoutMs: 15000
    readonly property int _maxStdoutBytes: 5242880
    readonly property string _preferredProtocolVersion: "2025-06-18"
    readonly property var _supportedProtocolVersions: ["2025-06-18", "2024-11-05"]

    // --- Signals ---
    signal toolCallCompleted(var callId, string result)
    signal toolCallFailed(var callId, string error)
    signal mcpToolsUpdated()
    signal mcpConnectionStateChanged()

    // --- Public API ---

    function connectToServer() {
        _manualDisconnect = false;
        if (connecting || isConnected) return;
        if (!enabled) {
            connectionError = "";
            return;
        }
        if (!mcpUrl || !mcpCommand) {
            connectionError = "MCP URL and bridge command are required.";
            return;
        }
        var validated = Providers.validateUrl(mcpUrl);
        if (!validated.valid) {
            connectionError = validated.error || "Invalid MCP URL.";
            return;
        }
        if (!_validCommand(mcpCommand)) {
            connectionError = "MCP bridge command must be exactly mcp-remote.";
            return;
        }
        connectionError = "";
        connecting = true;
        _initialized = false;
        _readBuffer = "";
        _pendingRequests = ({});
        _nextId = 1;
        tools = [];
        mcpStdout.lastLen = 0;
        connectionTimer.restart();

        var cmd = [mcpCommand, mcpUrl];
        if (mcpUrl.toLowerCase().indexOf("http://") === 0)
            cmd.push("--allow-http");
        mcpProcess.command = cmd;
        mcpProcess.running = true;
    }

    function disconnectFromServer() {
        connectionError = "";
        if (mcpProcess.running) {
            _manualDisconnect = true;
            mcpProcess.running = false;
        } else {
            _manualDisconnect = false;
        }
        _reset("MCP disconnected.");
    }

    function reconnectToServer() {
        disconnectFromServer();
        Qt.callLater(connectToServer);
    }

    // Call a tool by name with arguments. Returns the request id.
    function callTool(toolName, args) {
        if (!isConnected || !_findTool(toolName))
            return -1;
        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function(result) {
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
                name: toolName,
                arguments: args || {}
            }
        };
        _sendRequest(id, req);
        return id;
    }

    function cancelRequest(id, reason) {
        if (id === undefined || id === null)
            return false;
        if (!_pendingRequests[id])
            return false;
        delete _pendingRequests[id];
        if (mcpProcess.running)
            _sendNotification("notifications/cancelled", {
                requestId: id,
                reason: reason || "Request cancelled."
            });
        return true;
    }

    function isToolAllowed(toolName, approvedKeys) {
        return Mcp.isToolApproved(_findTool(toolName), approvedKeys);
    }

    function setToolAllowed(approvedKeys, toolName, allowed) {
        var current = Mcp.pruneApprovedTools(approvedKeys, tools);
        var tool = _findTool(toolName);
        if (!tool)
            return current;
        return Mcp.setToolApproved(current, tool, allowed === true);
    }

    // Get tools formatted for Ollama /api/chat tools array
    function getOllamaTools(approvedKeys) {
        var result = [];
        for (var i = 0; i < tools.length; i++) {
            var t = tools[i];
            if (!Mcp.isToolApproved(t, approvedKeys))
                continue;
            result.push({
                type: "function",
                function: {
                    name: t.name,
                    description: t.description || "",
                    parameters: t.inputSchema || { type: "object", properties: {} }
                }
            });
        }
        return result;
    }

    // --- Internal ---

    function _validCommand(command) {
        var c = String(command || "").trim();
        return c === "mcp-remote";
    }

    function _supportsProtocolVersion(version) {
        var v = String(version || "");
        for (var i = 0; i < _supportedProtocolVersions.length; i++) {
            if (_supportedProtocolVersions[i] === v)
                return true;
        }
        return false;
    }

    function _findTool(toolName) {
        var name = String(toolName || "").trim();
        if (!name) return null;
        for (var i = 0; i < tools.length; i++) {
            if (tools[i] && String(tools[i].name || "").trim() === name)
                return tools[i];
        }
        return null;
    }

    function _abortConnection(message) {
        connectionError = message;
        if (mcpProcess.running) {
            _manualDisconnect = true;
            mcpProcess.running = false;
        }
        _reset(message);
    }

    function _failPendingRequests(message) {
        var pending = _pendingRequests;
        _pendingRequests = ({});
        for (var id in pending) {
            if (pending[id] && pending[id].reject)
                pending[id].reject(message);
        }
    }

    function _reset(failMessage) {
        if (failMessage)
            _failPendingRequests(failMessage);
        else
            _pendingRequests = ({});
        connectionTimer.stop();
        isConnected = false;
        connecting = false;
        _initialized = false;
        _negotiatedProtocolVersion = "";
        _readBuffer = "";
        tools = [];
        mcpConnectionStateChanged();
    }

    function _sendRequest(id, req) {
        var line = JSON.stringify(req) + "\n";
        mcpProcess.write(line);
    }

    function _sendNotification(method, params) {
        var msg = { jsonrpc: "2.0", method: method };
        if (params) msg.params = params;
        var line = JSON.stringify(msg) + "\n";
        mcpProcess.write(line);
    }

    function _handleLine(line) {
        line = line.trim();
        if (!line) return;

        var msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            // Not JSON — could be mcp-remote status output, ignore
            return;
        }

        // Response to one of our requests
        if (msg.id !== undefined && msg.id !== null) {
            var pending = _pendingRequests[msg.id];
            if (pending) {
                delete _pendingRequests[msg.id];
                if (msg.error) {
                    pending.reject(msg.error.message || JSON.stringify(msg.error));
                } else {
                    pending.resolve(msg.result);
                }
            }
            return;
        }

        // Server notification
        if (msg.method) {
            _handleNotification(msg.method, msg.params);
        }
    }

    function _handleNotification(method, params) {
        // Handle server-initiated notifications if needed
        if (method === "notifications/tools/list_changed") {
            _listTools();
        }
    }

    function _sendInitialize() {
        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function(result) { _onInitialized(result); },
            reject: function(err) {
                _abortConnection("Initialize failed: " + err);
            }
        };
        _sendRequest(id, {
            jsonrpc: "2.0",
            id: id,
            method: "initialize",
            params: {
                protocolVersion: _preferredProtocolVersion,
                capabilities: {},
                clientInfo: { name: "ephemera", version: "1.0.0" }
            }
        });
    }

    function _onInitialized(result) {
        var version = result && result.protocolVersion ? String(result.protocolVersion) : "";
        if (!_supportsProtocolVersion(version)) {
            _abortConnection("Unsupported MCP protocol version: " + (version || "unknown") + ".");
            return;
        }
        if (!result || !result.capabilities || result.capabilities.tools === undefined) {
            _abortConnection("MCP server does not advertise tools capability.");
            return;
        }
        _negotiatedProtocolVersion = version;
        _sendNotification("notifications/initialized");
        _initialized = true;
        _listTools();
    }

    function _listTools(cursor, accumulated) {
        var id = _nextId++;
        var collected = Array.isArray(accumulated) ? accumulated.slice() : [];
        _pendingRequests[id] = {
            resolve: function(result) {
                var page = Mcp.appendToolsPage(collected, result);
                if (page.nextCursor) {
                    _listTools(page.nextCursor, page.tools);
                    return;
                }
                tools = page.tools;
                isConnected = true;
                connecting = false;
                connectionError = "";
                mcpConnectionStateChanged();
                mcpToolsUpdated();
                connectionTimer.stop();
            },
            reject: function(err) {
                _abortConnection("Failed to list tools: " + err);
            }
        };
        _sendRequest(id, {
            jsonrpc: "2.0",
            id: id,
            method: "tools/list",
            params: cursor ? { cursor: cursor } : {}
        });
    }

    function _processBuffer() {
        var lines = _readBuffer.split("\n");
        // Last element may be incomplete — keep it in the buffer
        _readBuffer = lines.pop();
        for (var i = 0; i < lines.length; i++) {
            _handleLine(lines[i]);
        }
    }

    // --- Process ---

    Timer {
        id: connectionTimer
        interval: root._connectionTimeoutMs
        repeat: false
        onTriggered: {
            root._abortConnection("MCP connection timed out.");
        }
    }

    Process {
        id: mcpProcess
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running) {
                // Send initialize once the process starts
                Qt.callLater(root._sendInitialize);
            } else {
                if (!root._manualDisconnect && (root.isConnected || root.connecting)) {
                    root.connectionError = "MCP process exited unexpectedly.";
                    root._reset(root.connectionError);
                }
            }
        }

        stdout: StdioCollector {
            id: mcpStdout
            waitForEnd: false
            property int lastLen: 0

            onTextChanged: {
                if (text.length > root._maxStdoutBytes) {
                    root.connectionError = "MCP output exceeded maximum buffer size.";
                    mcpProcess.running = false;
                    root._reset(root.connectionError);
                    return;
                }
                var newData = text.substring(lastLen);
                lastLen = text.length;
                root._readBuffer += newData;
                root._processBuffer();
            }
        }

        onExited: exitCode => {
            if (root._manualDisconnect) {
                root._manualDisconnect = false;
                root._reset("MCP disconnected.");
                return;
            }
            if (exitCode !== 0 && (root.isConnected || root.connecting)) {
                root.connectionError = "MCP process exited with code " + exitCode + ".";
            }
            root._reset(root.connectionError || "MCP process exited.");
        }
    }
}
