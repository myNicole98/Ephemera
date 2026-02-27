.pragma library

// Pure SSE stream parsing functions for Ephemera.
// These functions take state as input and return updates — no side effects.

// Split raw SSE data into complete lines and a remaining buffer.
// Returns { lines: string[], buffer: string }
function splitLines(chunk, buffer) {
    var combined = buffer + chunk;
    var parts = combined.split(/\r?\n/);

    var remaining = "";
    if (combined.length > 0 && !combined.endsWith("\n") && !combined.endsWith("\r")) {
        remaining = parts.pop();
    }

    var lines = [];
    for (var i = 0; i < parts.length; i++) {
        var line = parts[i].trim();
        if (line) lines.push(line);
    }

    return { lines: lines, buffer: remaining };
}

// Parse a single SSE data line's JSON payload for a given provider.
// Returns { content: string, thinking: string, done: bool }
function parseDelta(jsonText, provider) {
    var result = { content: "", thinking: "", done: false };
    try {
        var data = JSON.parse(jsonText);
        if (provider === "anthropic") {
            if (data.type === "content_block_delta" && data.delta) {
                if (data.delta.type === "thinking_delta" && data.delta.thinking)
                    result.thinking = data.delta.thinking;
                else if (data.delta.type === "text_delta" && data.delta.text)
                    result.content = data.delta.text;
            }
            if (data.type === "message_delta" && data.delta && data.delta.stop_reason)
                result.done = true;
        } else if (provider === "gemini") {
            var chunks = Array.isArray(data) ? data : [data];
            for (var ci = 0; ci < chunks.length; ci++) {
                var candidates = chunks[ci].candidates;
                if (!candidates || !candidates[0] || !candidates[0].content) continue;
                var cparts = candidates[0].content.parts || [];
                for (var pi = 0; pi < cparts.length; pi++) {
                    if (cparts[pi].text)
                        result.content += cparts[pi].text;
                }
            }
        } else {
            // OpenAI / Ollama (OpenAI-compat)
            var choices = data.choices;
            if (choices && choices[0] && choices[0].delta) {
                var d = choices[0].delta;
                result.thinking = d.reasoning_content || d.reasoning || "";
                result.content = d.content || "";
            }
            if (choices && choices[0] && choices[0].finish_reason)
                result.done = true;
        }
    } catch (e) {
        // Malformed chunk — ignore
    }
    return result;
}

// Process <think> tags in content delta text.
// Takes the delta and current tag-parsing state; returns updated state.
// Returns { contentParts: string[], thinkingParts: string[], tagBuffer: string, insideThinkTag: bool }
function routeThinkTags(delta, tagBuffer, insideThinkTag) {
    var result = { contentParts: [], thinkingParts: [], tagBuffer: "", insideThinkTag: insideThinkTag };
    var text = tagBuffer + delta;

    while (text.length > 0) {
        var tag = result.insideThinkTag ? "</think>" : "<think>";
        var idx = text.indexOf(tag);

        if (idx >= 0) {
            var before = text.substring(0, idx);
            if (before.length > 0) {
                if (result.insideThinkTag)
                    result.thinkingParts.push(before);
                else
                    result.contentParts.push(before);
            }
            result.insideThinkTag = !result.insideThinkTag;
            text = text.substring(idx + tag.length);
            if (text.startsWith("\n")) text = text.substring(1);
        } else {
            // Check for partial tag at end of buffer
            var partialLen = 0;
            for (var len = Math.min(text.length, tag.length - 1); len > 0; len--) {
                if (text.substring(text.length - len) === tag.substring(0, len)) {
                    partialLen = len;
                    break;
                }
            }

            if (partialLen > 0) {
                result.tagBuffer = text.substring(text.length - partialLen);
                var output = text.substring(0, text.length - partialLen);
                if (output.length > 0) {
                    if (result.insideThinkTag)
                        result.thinkingParts.push(output);
                    else
                        result.contentParts.push(output);
                }
            } else {
                if (result.insideThinkTag)
                    result.thinkingParts.push(text);
                else
                    result.contentParts.push(text);
            }
            text = "";
        }
    }

    return result;
}

// Parse a non-streaming response body for all provider formats.
// Returns the assistant text content or "" on failure.
function extractNonStreamingText(bodyText, provider) {
    try {
        var data = JSON.parse(bodyText);
        if (provider === "anthropic") {
            var content = data.content;
            if (Array.isArray(content)) {
                var out = "";
                for (var i = 0; i < content.length; i++) {
                    if (content[i] && content[i].text)
                        out += content[i].text;
                }
                return out;
            }
            return data.text || "";
        }
        if (provider === "gemini") {
            var gchunks = Array.isArray(data) ? data : [data];
            var gout = "";
            for (var gi = 0; gi < gchunks.length; gi++) {
                var cands = gchunks[gi].candidates;
                if (!cands || !cands[0] || !cands[0].content) continue;
                var gparts = cands[0].content.parts || [];
                for (var gpi = 0; gpi < gparts.length; gpi++) {
                    if (gparts[gpi].text) gout += gparts[gpi].text;
                }
            }
            return gout;
        }
        // OpenAI / Ollama
        var choices = data.choices;
        if (choices && choices[0]) {
            if (choices[0].message && typeof choices[0].message.content === "string")
                return choices[0].message.content;
            if (typeof choices[0].text === "string")
                return choices[0].text;
        }
    } catch (e) {
        // Parse error — return empty
    }
    return "";
}

// Extract HTTP status from EPH_STATUS marker in curl output.
// Returns { status: int, body: string }
function extractHttpStatus(text) {
    var match = (text || "").match(/EPH_STATUS:(\d+)/);
    var status = match ? parseInt(match[1]) : 0;
    var body = text || "";
    var markerIdx = body.lastIndexOf("\nEPH_STATUS:");
    if (markerIdx >= 0) body = body.substring(0, markerIdx);
    return { status: status, body: body.trim() };
}
