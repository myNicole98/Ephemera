.pragma library

// Secure curl command builder for Ephemera.
// Security improvements over DMS AI Assistant:
//   1. Body via stdin (-d @-) — conversation never in /proc/cmdline
//   2. Gemini key as header (x-goog-api-key) — not in URL query param
//   3. No --compressed flag (breaks StdioCollector)

function normalizeBaseUrl(url) {
    var u = (url || "").trim();
    if (!u) return "";
    return u.endsWith("/") ? u.slice(0, -1) : u;
}

function openaiChatCompletionsUrl(baseUrl) {
    var b = normalizeBaseUrl(baseUrl || "https://api.openai.com");
    if (/\/v\d+$/.test(b))
        return b + "/chat/completions";
    return b + "/v1/chat/completions";
}

// Returns { cmd: string[], body: string } where body should be written to stdin.
function buildCurlCommand(provider, payload, apiKey) {
    var request = buildRequest(provider, payload, apiKey);
    if (!request || !request.url)
        return null;

    var timeout = payload.timeout || 30;
    var cmd = [
        "curl", "-N", "-sS", "--no-buffer", "--show-error",
        "--connect-timeout", "5",
        "--max-time", String(timeout),
        "-w", "\\nEPH_STATUS:%{http_code}\\n",
        "-H", "Content-Type: application/json"
    ];

    var headers = request.headers || [];
    for (var i = 0; i < headers.length; i++) {
        cmd.push(headers[i]);
    }

    // Body via stdin — never in /proc/cmdline
    cmd.push("-d", "@-");
    cmd.push(request.url);

    return { cmd: cmd, body: request.body || "{}" };
}

function buildRequest(provider, payload, apiKey) {
    switch (provider) {
    case "ollama":
        return ollamaRequest(payload);
    case "anthropic":
        return anthropicRequest(payload, apiKey);
    case "gemini":
        return geminiRequest(payload, apiKey);
    case "custom":
        return customRequest(payload, apiKey);
    default:
        return openaiRequest(payload, apiKey);
    }
}

function ollamaRequest(payload) {
    // Use OpenAI-compatible endpoint for SSE streaming
    var base = normalizeBaseUrl(payload.baseUrl || "http://localhost:11434");
    var url = base + "/v1/chat/completions";
    var body = {
        model: payload.model,
        messages: payload.messages,
        max_tokens: payload.max_tokens || 4096,
        temperature: payload.temperature || 0.7,
        stream: true
    };
    // No auth header for Ollama
    return { url: url, headers: [], body: JSON.stringify(body) };
}

function openaiRequest(payload, apiKey) {
    var url = openaiChatCompletionsUrl(payload.baseUrl || "https://api.openai.com");
    var headers = ["-H", "Authorization: Bearer " + apiKey];
    var body = {
        model: payload.model,
        messages: payload.messages,
        max_tokens: payload.max_tokens || 4096,
        temperature: payload.temperature || 0.7,
        stream: true
    };
    return { url: url, headers: headers, body: JSON.stringify(body) };
}

function anthropicRequest(payload, apiKey) {
    var base = normalizeBaseUrl(payload.baseUrl || "https://api.anthropic.com");
    var url = base + "/v1/messages";
    var headers = [
        "-H", "x-api-key: " + apiKey,
        "-H", "anthropic-version: 2023-06-01"
    ];

    // Extract system prompt from messages if present
    var systemText = "";
    var filteredMessages = [];
    for (var i = 0; i < payload.messages.length; i++) {
        var m = payload.messages[i];
        if (m.role === "system") {
            systemText = m.content;
        } else {
            filteredMessages.push({
                role: m.role === "assistant" ? "assistant" : "user",
                content: m.content
            });
        }
    }

    var body = {
        model: payload.model,
        messages: filteredMessages,
        max_tokens: payload.max_tokens || 4096,
        temperature: payload.temperature || 0.7,
        stream: true
    };
    if (systemText)
        body.system = systemText;

    return { url: url, headers: headers, body: JSON.stringify(body) };
}

function geminiRequest(payload, apiKey) {
    var base = normalizeBaseUrl(payload.baseUrl || "https://generativelanguage.googleapis.com");
    // Key as header, NOT in URL — security fix
    var url = base + "/v1beta/models/" + (payload.model || "gemini-2.5-flash")
        + ":streamGenerateContent?alt=sse";
    var headers = ["-H", "x-goog-api-key: " + apiKey];

    // Extract system prompt
    var systemText = "";
    var contents = [];
    for (var i = 0; i < payload.messages.length; i++) {
        var m = payload.messages[i];
        if (m.role === "system") {
            systemText = m.content;
        } else {
            contents.push({
                role: m.role === "user" ? "user" : "model",
                parts: [{ text: m.content }]
            });
        }
    }

    var body = {
        contents: contents,
        generationConfig: {
            temperature: payload.temperature || 0.7,
            maxOutputTokens: payload.max_tokens || 4096
        }
    };
    if (systemText)
        body.system_instruction = { parts: [{ text: systemText }] };

    return { url: url, headers: headers, body: JSON.stringify(body) };
}

function customRequest(payload, apiKey) {
    return openaiRequest(payload, apiKey);
}
