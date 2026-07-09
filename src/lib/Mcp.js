.pragma library

/**
 * Build the trust key used to bind automatic tool execution to one MCP server.
 *
 * @param {string} url - MCP server URL.
 * @param {string} command - Bridge executable command.
 * @returns {string} Stable key for the current MCP bridge target.
 */
function trustKey(url, command) {
    return String(command || "").trim() + "\n" + String(url || "").trim();
}

/**
 * Append one tools/list page to an accumulated tool array.
 *
 * @param {Array} existing - Previously collected tools.
 * @param {Object} result - MCP tools/list result.
 * @returns {{ tools: Array, nextCursor: string }}
 */
function appendToolsPage(existing, result) {
    var merged = Array.isArray(existing) ? existing.slice() : [];
    var page = (result && Array.isArray(result.tools)) ? result.tools : [];
    for (var i = 0; i < page.length; i++)
        merged.push(page[i]);
    var next = (result && result.nextCursor !== undefined && result.nextCursor !== null)
        ? String(result.nextCursor)
        : "";
    return { tools: merged, nextCursor: next };
}

/**
 * Convert an MCP tools/call result into compact text suitable for a chat model.
 *
 * @param {Object|string} result - MCP tool result payload.
 * @returns {string} Text representation of the result.
 */
function formatToolResult(result) {
    if (result === undefined || result === null)
        return "";
    if (typeof result === "string")
        return result;

    var parts = [];
    if (Array.isArray(result.content)) {
        for (var i = 0; i < result.content.length; i++) {
            var item = result.content[i];
            if (!item) continue;
            if (item.type === "text" && item.text !== undefined) {
                parts.push(String(item.text));
            } else if (item.type === "resource" && item.resource) {
                if (item.resource.text !== undefined)
                    parts.push(String(item.resource.text));
                else
                    parts.push("[resource: " + (item.resource.uri || item.resource.mimeType || "embedded") + "]");
            } else if (item.type === "resource_link") {
                parts.push("[resource: " + (item.name || item.uri || "link") + "]");
            } else if (item.type === "image") {
                parts.push("[image: " + (item.mimeType || "image") + "]");
            } else if (item.type === "audio") {
                parts.push("[audio: " + (item.mimeType || "audio") + "]");
            } else {
                parts.push(JSON.stringify(item));
            }
        }
    }

    if (result.structuredContent !== undefined)
        parts.push(JSON.stringify(result.structuredContent));

    if (parts.length > 0)
        return parts.join("\n");

    return JSON.stringify(result);
}

/**
 * Return true when a successful JSON-RPC tools/call response reports tool-level
 * failure through the MCP result's isError flag.
 *
 * @param {Object} result - MCP tool result payload.
 * @returns {boolean}
 */
function isToolError(result) {
    return !!(result && result.isError === true);
}
