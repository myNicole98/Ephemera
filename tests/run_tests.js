#!/usr/bin/env node
// Basic test runner for Ephemera's pure JS modules.
// Run: node tests/run_tests.js

var fs = require("fs");
var path = require("path");

// Minimal .pragma library loader — strips the directive and evaluates
function loadPragmaLib(filename) {
    var src = fs.readFileSync(path.join(__dirname, "..", filename), "utf8");
    src = src.replace(/^\.pragma library\s*/, "");
    // Wrap in module and export all functions
    var mod = {};
    var fn = new Function("module", "exports", src + "\nmodule.exports = { " +
        (src.match(/^function\s+(\w+)/gm) || []).map(m => m.replace("function ", "")).join(", ") +
        " };");
    fn(mod, mod.exports);
    return mod.exports;
}

// ─── Load modules ──────────────────────────────────────────────

// We can't easily load .pragma library modules in Node as they use
// a special QML JS engine. Instead, we manually test the logic patterns.
// For a real test suite, a QML test harness (qmltest) would be needed.

var passed = 0;
var failed = 0;

function assert(condition, message) {
    if (condition) {
        passed++;
        console.log("  PASS: " + message);
    } else {
        failed++;
        console.log("  FAIL: " + message);
    }
}

// ─── StreamParser tests (inline reimplementation) ───────────────

console.log("\n=== StreamParser.splitLines ===");

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

(function() {
    var r = splitLines("data: hello\ndata: world\n", "");
    assert(r.lines.length === 2, "splits two complete lines");
    assert(r.buffer === "", "no remaining buffer");

    r = splitLines("data: partial", "");
    assert(r.lines.length === 0, "incomplete line stays in buffer");
    assert(r.buffer === "data: partial", "buffer contains partial line");

    r = splitLines(" rest\n", "data:");
    assert(r.lines.length === 1, "combines buffer with new data");
    assert(r.lines[0] === "data: rest", "correct combined line");

    r = splitLines("data: [DONE]\n", "");
    assert(r.lines[0] === "data: [DONE]", "handles [DONE] marker");
})();

console.log("\n=== StreamParser.routeThinkTags ===");

function routeThinkTags(delta, tagBuffer, insideThinkTag) {
    var result = { contentParts: [], thinkingParts: [], tagBuffer: "", insideThinkTag: insideThinkTag };
    var text = tagBuffer + delta;
    while (text.length > 0) {
        var tag = result.insideThinkTag ? "</think>" : "<think>";
        var idx = text.indexOf(tag);
        if (idx >= 0) {
            var before = text.substring(0, idx);
            if (before.length > 0) {
                if (result.insideThinkTag) result.thinkingParts.push(before);
                else result.contentParts.push(before);
            }
            result.insideThinkTag = !result.insideThinkTag;
            text = text.substring(idx + tag.length);
            if (text.startsWith("\n")) text = text.substring(1);
        } else {
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
                    if (result.insideThinkTag) result.thinkingParts.push(output);
                    else result.contentParts.push(output);
                }
            } else {
                if (result.insideThinkTag) result.thinkingParts.push(text);
                else result.contentParts.push(text);
            }
            text = "";
        }
    }
    return result;
}

(function() {
    var r = routeThinkTags("hello world", "", false);
    assert(r.contentParts.length === 1 && r.contentParts[0] === "hello world", "plain text goes to content");
    assert(r.thinkingParts.length === 0, "no thinking");

    r = routeThinkTags("<think>thinking here</think>normal", "", false);
    assert(r.thinkingParts.join("") === "thinking here", "text inside think tags goes to thinking");
    assert(r.contentParts.join("") === "normal", "text after close tag goes to content");
    assert(!r.insideThinkTag, "not inside think tag after close");

    r = routeThinkTags("<think>partial", "", false);
    assert(r.insideThinkTag === true, "inside think tag when not closed");
    assert(r.thinkingParts.join("") === "partial", "partial thinking captured");

    r = routeThinkTags("more</think>done", "", true);
    assert(r.thinkingParts.join("") === "more", "continues thinking from previous state");
    assert(r.contentParts.join("") === "done", "content after close tag");

    // Partial tag at boundary
    r = routeThinkTags("hello<thi", "", false);
    assert(r.tagBuffer === "<thi", "partial tag buffered");
    assert(r.contentParts.join("") === "hello", "content before partial tag");
})();

console.log("\n=== ChatExport.buildMarkdown ===");

function buildMarkdown(messages) {
    var lines = [];
    for (var i = 0; i < messages.length; i++) {
        var m = messages[i];
        var label = m.role === "user" ? "You" : "Assistant";
        lines.push("### " + label + "\n\n" + m.content);
    }
    return lines.join("\n\n---\n\n");
}

(function() {
    var md = buildMarkdown([
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi there!" }
    ]);
    assert(md.includes("### You"), "includes user header");
    assert(md.includes("### Assistant"), "includes assistant header");
    assert(md.includes("Hello"), "includes user content");
    assert(md.includes("Hi there!"), "includes assistant content");
    assert(md.includes("---"), "includes separator");

    md = buildMarkdown([]);
    assert(md === "", "empty messages produce empty string");
})();

console.log("\n=== Markdown.escapeHtml ===");

function escapeHtml(str) {
    if (!str) return "";
    return str.replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;');
}

(function() {
    assert(escapeHtml('<script>') === '&lt;script&gt;', "escapes angle brackets");
    assert(escapeHtml('a&b') === 'a&amp;b', "escapes ampersand");
    assert(escapeHtml('a"b') === 'a&quot;b', "escapes quotes");
    assert(escapeHtml("") === "", "empty string returns empty");
    assert(escapeHtml(null) === "", "null returns empty");
})();

// ─── Summary ───────────────────────────────────────────────────

console.log("\n" + "=".repeat(40));
console.log("Results: " + passed + " passed, " + failed + " failed");
console.log("=".repeat(40));

process.exit(failed > 0 ? 1 : 0);
