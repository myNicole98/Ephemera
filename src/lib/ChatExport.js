.pragma library

// Pure functions for exporting Ephemera chat conversations.

/**
 * Build a markdown representation of a conversation.
 *
 * Each message becomes a "### You" or "### Assistant" section, separated by
 * horizontal rules. User messages use "You" as the label.
 *
 * @param {Array<{role: string, content: string}>} messages - Conversation messages.
 * @returns {string} Markdown-formatted conversation text.
 */
function buildMarkdown(messages) {
    var lines = [];
    for (var i = 0; i < messages.length; i++) {
        var m = messages[i];
        var label = m.role === "user" ? "You" : "Assistant";
        lines.push("### " + label + "\n\n" + m.content);
    }
    return lines.join("\n\n---\n\n");
}

/**
 * Generate a timestamped filename for chat export.
 *
 * @param {string} homeDir - User's home directory path (e.g. "/home/user").
 * @returns {string} Full path like "/home/user/ephemera-chat-2024-01-15T10-30-00.md".
 */
function generateFilename(homeDir) {
    var timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
    return (homeDir || "") + "/ephemera-chat-" + timestamp + ".md";
}
