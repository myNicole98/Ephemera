import QtQuick
import Quickshell
import "./src/services"

ShellRoot {
    id: root

    property int connectionCount: 0
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
                var callId = callTool("echo", { text: "hello" });
                if (callId < 0)
                    root.finish(false, "tool call was not started");
            } else if (root.connectionCount === 2 && root.toolCompleted) {
                root.finish(true, "connect, call, and reconnect completed");
            }
        }

        onToolCallCompleted: (callId, result) => {
            if (result !== "hello") {
                root.finish(false, "unexpected tool result: " + result);
                return;
            }
            root.toolCompleted = true;
            reconnectToServer();
        }

        onToolCallFailed: (callId, error) => root.finish(false, "tool call failed: " + error)
    }
}
