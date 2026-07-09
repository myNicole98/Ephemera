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
 * Normalize a list of allowed tool names into unique trimmed strings.
 *
 * @param {Array|string} names - Tool names or a JSON-encoded array.
 * @returns {Array<string>} Unique tool names.
 */
function normalizeToolNames(names) {
    var input = names;
    if (typeof input === "string") {
        try { input = JSON.parse(input); } catch (e) { input = []; }
    }
    if (!Array.isArray(input))
        return [];
    var seen = {};
    var result = [];
    for (var i = 0; i < input.length; i++) {
        var name = String(input[i] || "").trim();
        if (!name || seen[name]) continue;
        seen[name] = true;
        result.push(name);
    }
    return result;
}

/**
 * Return true if a tool name is in the explicit allowlist.
 *
 * @param {string} toolName - Tool name requested by the model.
 * @param {Array|string} allowedNames - Explicitly allowed tool names.
 * @returns {boolean} Whether the tool may be executed.
 */
function isToolAllowed(toolName, allowedNames) {
    var name = String(toolName || "").trim();
    if (!name) return false;
    var allowed = normalizeToolNames(allowedNames);
    for (var i = 0; i < allowed.length; i++) {
        if (allowed[i] === name)
            return true;
    }
    return false;
}

/**
 * Add or remove a tool from an allowlist.
 *
 * @param {Array|string} allowedNames - Current allowlist.
 * @param {string} toolName - Tool name to update.
 * @param {boolean} allowed - Whether the tool should be present.
 * @returns {Array<string>} Updated allowlist.
 */
function setToolAllowed(allowedNames, toolName, allowed) {
    var current = normalizeToolNames(allowedNames);
    var name = String(toolName || "").trim();
    if (!name) return current;

    var result = [];
    var found = false;
    for (var i = 0; i < current.length; i++) {
        if (current[i] === name) {
            found = true;
            if (allowed === true)
                result.push(current[i]);
        } else {
            result.push(current[i]);
        }
    }
    if (allowed === true && !found)
        result.push(name);
    return result;
}

/**
 * Keep only allowed names that still exist in the current tool list.
 *
 * @param {Array|string} allowedNames - Current allowlist.
 * @param {Array} tools - MCP tools/list entries.
 * @returns {Array<string>} Pruned allowlist.
 */
function pruneAllowedTools(allowedNames, tools) {
    var allowed = normalizeToolNames(allowedNames);
    if (!Array.isArray(tools) || tools.length === 0)
        return [];

    var available = {};
    for (var i = 0; i < tools.length; i++) {
        if (tools[i] && tools[i].name !== undefined)
            available[String(tools[i].name).trim()] = true;
    }

    var result = [];
    for (var j = 0; j < allowed.length; j++) {
        if (available[allowed[j]])
            result.push(allowed[j]);
    }
    return result;
}

/**
 * Build the message list used to resume an Ollama chat after tool execution.
 *
 * @param {Array} conversationMessages - Messages already sent to the model.
 * @param {string} assistantContent - Assistant content from the tool-call turn.
 * @param {string} assistantThinking - Native Ollama thinking from the tool-call turn.
 * @param {Array} toolCalls - Tool calls requested by the model.
 * @param {Array} toolResults - Tool result messages.
 * @returns {Array} New message list with assistant tool call and tool results.
 */
function buildToolResumeMessages(conversationMessages, assistantContent, assistantThinking, toolCalls, toolResults) {
    var updated = Array.isArray(conversationMessages) ? conversationMessages.slice() : [];
    var assistantMessage = {
        role: "assistant",
        content: assistantContent || "",
        tool_calls: Array.isArray(toolCalls) ? toolCalls.slice() : []
    };
    if (assistantThinking && String(assistantThinking).length > 0)
        assistantMessage.thinking = String(assistantThinking);
    updated.push(assistantMessage);

    var results = Array.isArray(toolResults) ? toolResults : [];
    for (var i = 0; i < results.length; i++)
        updated.push(results[i]);
    return updated;
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
