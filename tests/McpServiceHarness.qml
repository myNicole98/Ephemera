import QtQuick
import Quickshell
import "./src/services"

ShellRoot {
    id: root

    property int connectionCount: 0
    property var echoApprovals: []
    property bool invalidResultRejected: false
    property bool toolCompleted: false
    property bool finished: false

    function finish(success, message) {
        if (finished) return;
        finished = true;
        console.log("EPHEMERA_MCP_QML_TEST " + (success ? "PASS" : "FAIL") + ": " + message);
        Qt.quit();
    }

    Component.onCompleted: mcp.connectToServer()

    Timer {
        interval: 8000
        running: true
        repeat: false
        onTriggered: root.finish(false, "timed out")
    }

    MCPService {
        id: mcp
        enabled: true
        mcpUrl: "https://mcp.example.test/sse"

        onMcpConnectionStateChanged: {
            if (!isConnected) return;
            root.connectionCount++;
            if (root.connectionCount === 1) {
                if (tools.length !== 1 || tools[0].name !== "echo" || ignoredToolCount !== 1) {
                    root.finish(false, "unsupported output schema was exposed");
                    return;
                }
                root.echoApprovals = setToolApproved([], "echo", true);
                if (callTool("echo", { text: "blocked" }, []) >= 0) {
                    root.finish(false, "unapproved direct tool call was accepted");
                    return;
                }
                if (callTool(" echo ", { text: "blocked" }, root.echoApprovals) >= 0) {
                    root.finish(false, "non-canonical tool name was accepted");
                    return;
                }
                var callId = callTool("echo", { text: "__invalid_result__" }, root.echoApprovals);
                if (callId < 0)
                    root.finish(false, "tool call was not started");
            } else if (root.connectionCount === 2 && root.toolCompleted && root.invalidResultRejected) {
                root.finish(true, "connect, reject invalid result, call, and reconnect completed");
            }
        }

        onToolCallCompleted: (callId, result) => {
            if (!root.invalidResultRejected) {
                root.finish(false, "invalid result reached the completion boundary");
                return;
            }
            if (result !== "hello") {
                root.finish(false, "unexpected tool result: " + result);
                return;
            }
            root.toolCompleted = true;
            reconnectToServer();
        }

        onToolCallFailed: (callId, error) => {
            if (!root.invalidResultRejected && error.indexOf("invalid content") >= 0) {
                root.invalidResultRejected = true;
                var validCallId = callTool("echo", { text: "hello" }, root.echoApprovals);
                if (validCallId < 0)
                    root.finish(false, "valid tool call was not started after result rejection");
                return;
            }
            root.finish(false, "tool call failed: " + error);
        }
    }
}
