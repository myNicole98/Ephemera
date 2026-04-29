import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

Item {
    id: root

    // --- Configuration ---
    property string mcpUrl: ""
    property string mcpToken: ""
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

    // --- Signals ---
    signal toolCallCompleted(var callId, string result)
    signal toolCallFailed(var callId, string error)
    signal mcpToolsUpdated()
    signal mcpConnectionStateChanged()

    // --- Public API ---

    function connectToServer() {
        if (connecting || isConnected) return;
        if (!mcpUrl || !mcpToken) {
            connectionError = "MCP URL and token are required.";
            return;
        }
        connectionError = "";
        connecting = true;
        _initialized = false;
        _readBuffer = "";
        _pendingRequests = ({});
        _nextId = 1;
        tools = [];

        mcpProcess.command = [
            "npx", "-y", "mcp-remote",
            mcpUrl,
            "--allow-http",
            "--header", "Authorization: Bearer " + mcpToken
        ];
        mcpProcess.running = true;
    }

    function disconnectFromServer() {
        if (mcpProcess.running)
            mcpProcess.running = false;
        _reset();
    }

    function reconnectToServer() {
        disconnectFromServer();
        Qt.callLater(connectToServer);
    }

    // Call a tool by name with arguments. Returns the request id.
    function callTool(toolName, args) {
        var id = _nextId++;
        _pendingRequests[id] = {
                resolve: function(result) {
                    root.toolCallCompleted(id, typeof result === "string" ? result : JSON.stringify(result));
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

    // Get tools formatted for Ollama /api/chat tools array
    function getOllamaTools() {
        var result = [];
        for (var i = 0; i < tools.length; i++) {
            var t = tools[i];
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

    function _reset() {
        isConnected = false;
        connecting = false;
        _initialized = false;
        _readBuffer = "";
        _pendingRequests = ({});
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
                connectionError = "Initialize failed: " + err;
                connecting = false;
                mcpConnectionStateChanged();
            }
        };
        _sendRequest(id, {
            jsonrpc: "2.0",
            id: id,
            method: "initialize",
            params: {
                protocolVersion: "2024-11-05",
                capabilities: { tools: {} },
                clientInfo: { name: "ephemera", version: "1.0.0" }
            }
        });
    }

    function _onInitialized(result) {
        _sendNotification("notifications/initialized");
        _initialized = true;
        _listTools();
    }

    function _listTools() {
        var id = _nextId++;
        _pendingRequests[id] = {
            resolve: function(result) {
                var toolList = (result && result.tools) ? result.tools : [];
                tools = toolList;
                isConnected = true;
                connecting = false;
                connectionError = "";
                mcpConnectionStateChanged();
                mcpToolsUpdated();
            },
            reject: function(err) {
                connectionError = "Failed to list tools: " + err;
                connecting = false;
                mcpConnectionStateChanged();
            }
        };
        _sendRequest(id, {
            jsonrpc: "2.0",
            id: id,
            method: "tools/list",
            params: {}
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

    Process {
        id: mcpProcess
        running: false
        stdinEnabled: true

        onRunningChanged: {
            if (running) {
                // Send initialize once the process starts
                Qt.callLater(root._sendInitialize);
            } else {
                if (root.isConnected || root.connecting) {
                    root.connectionError = "MCP process exited unexpectedly.";
                    root._reset();
                }
            }
        }

        stdout: StdioCollector {
            id: mcpStdout
            waitForEnd: false
            property int lastLen: 0

            onTextChanged: {
                var newData = text.substring(lastLen);
                lastLen = text.length;
                root._readBuffer += newData;
                root._processBuffer();
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0 && (root.isConnected || root.connecting)) {
                root.connectionError = "MCP process exited with code " + exitCode + ".";
            }
            root._reset();
        }
    }
}
