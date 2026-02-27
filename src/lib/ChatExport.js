.pragma library

// Pure functions for exporting Ephemera chat conversations.

// Build a markdown representation of a conversation from a messages array.
// Each item should have { role: string, content: string }.
function buildMarkdown(messages) {
    var lines = [];
    for (var i = 0; i < messages.length; i++) {
        var m = messages[i];
        var label = m.role === "user" ? "You" : "Assistant";
        lines.push("### " + label + "\n\n" + m.content);
    }
    return lines.join("\n\n---\n\n");
}

// Generate a timestamped filename for export.
function generateFilename(homeDir) {
    var timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
    return (homeDir || "") + "/ephemera-chat-" + timestamp + ".md";
}
