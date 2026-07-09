#!/usr/bin/env node

if (process.argv.length !== 3 || process.argv[2] !== "https://mcp.example.test/sse") {
    process.stderr.write("unexpected bridge invocation\n");
    process.exit(2);
}

var buffer = "";

function write(message) {
    process.stdout.write(JSON.stringify(message) + "\n");
}

function handle(message) {
    if (!message || message.jsonrpc !== "2.0") return;
    if (message.method === "initialize") {
        write({ jsonrpc: "2.0", id: "__proto__", result: {} });
        write({
            jsonrpc: "2.0",
            id: message.id,
            result: {
                protocolVersion: message.params.protocolVersion,
                capabilities: { tools: { listChanged: true } },
                serverInfo: { name: "ephemera-test-bridge", version: "1.0.0" }
            }
        });
    } else if (message.method === "tools/list") {
        write({
            jsonrpc: "2.0",
            id: message.id,
            result: {
                tools: [
                    {
                        name: "echo",
                        description: "Echo one string",
                        inputSchema: {
                            type: "object",
                            properties: { text: { type: "string" } },
                            required: ["text"]
                        }
                    },
                    {
                        name: "unsupported_output",
                        description: "Must be ignored before exposure",
                        inputSchema: { type: "object" },
                        outputSchema: {
                            type: "object",
                            properties: {
                                value: { "$ref": "https://attacker.example/output.json" }
                            }
                        }
                    }
                ]
            }
        });
    } else if (message.method === "tools/call") {
        if (message.params.arguments.text === "__invalid_result__") {
            write({
                jsonrpc: "2.0",
                id: message.id,
                result: { content: "not-an-array", isError: false }
            });
            return;
        }
        write({
            jsonrpc: "2.0",
            id: message.id,
            result: {
                content: [{ type: "text", text: String(message.params.arguments.text || "") }],
                isError: false
            }
        });
    }
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", function(chunk) {
    buffer += chunk;
    var lines = buffer.split("\n");
    buffer = lines.pop();
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line) continue;
        try { handle(JSON.parse(line)); }
        catch (e) { process.exitCode = 1; }
    }
});

process.on("SIGTERM", function() {
    setTimeout(function() { process.exit(0); }, 150);
});
