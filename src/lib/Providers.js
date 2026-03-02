.pragma library

// Secure curl command builder for Ephemera.
// Security improvements over DMS AI Assistant:
//   1. Body via stdin (-d @-) — conversation never in /proc/cmdline
//   2. Gemini key as header (x-goog-api-key) — not in URL query param
//   3. No --compressed flag (breaks StdioCollector)

function normalizeBaseUrl(url) {
    var u = (url || "").trim();
    if (!u) return "";
    if (!/^https?:\/\//i.test(u)) return "";
    if (u.length > 2048) return "";
    return u.endsWith("/") ? u.slice(0, -1) : u;
}

// Sanitize API key: strip newlines and control characters to prevent header injection.
function sanitizeApiKey(key) {
    if (!key) return "";
    return key.replace(/[\r\n\x00-\x1f]/g, "").trim();
}

// Shared helper: separates system messages from conversation messages.
// Returns { systemText: string, filtered: Array<{role, content}> }
function extractSystemPrompt(messages) {
    var systemText = "";
    var filtered = [];
    for (var i = 0; i < messages.length; i++) {
        var m = messages[i];
        if (m.role === "system") {
            systemText = m.content;
        } else {
            filtered.push(m);
        }
    }
    return { systemText: systemText, filtered: filtered };
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
    var temp = clampTemperature("ollama", payload.model, payload.temperature);
    var body = {
        model: payload.model,
        messages: payload.messages,
        stream: true
    };
    if (payload.max_tokens > 0) body.max_tokens = payload.max_tokens;
    if (temp !== undefined) body.temperature = temp;
    // No auth header for Ollama
    return { url: url, headers: [], body: JSON.stringify(body) };
}

function openaiRequest(payload, apiKey) {
    var url = openaiChatCompletionsUrl(payload.baseUrl || "https://api.openai.com");
    var safeKey = sanitizeApiKey(apiKey);
    if (!safeKey) return null;
    var headers = ["-H", "Authorization: Bearer " + safeKey];
    var temp = clampTemperature("openai", payload.model, payload.temperature);
    var body = {
        model: payload.model,
        messages: payload.messages,
        stream: true
    };
    if (payload.max_tokens > 0) body.max_tokens = payload.max_tokens;
    if (temp !== undefined) body.temperature = temp;
    return { url: url, headers: headers, body: JSON.stringify(body) };
}

function anthropicRequest(payload, apiKey) {
    var base = normalizeBaseUrl(payload.baseUrl || "https://api.anthropic.com");
    var url = base + "/v1/messages";
    var safeKey = sanitizeApiKey(apiKey);
    if (!safeKey) return null;
    var headers = [
        "-H", "x-api-key: " + safeKey,
        "-H", "anthropic-version: 2023-06-01"
    ];

    if (payload.thinkingEnabled)
        headers.push("-H", "anthropic-beta: interleaved-thinking-2025-05-14");

    // Extract system prompt from messages if present
    var extracted = extractSystemPrompt(payload.messages);
    var filteredMessages = [];
    for (var i = 0; i < extracted.filtered.length; i++) {
        var m = extracted.filtered[i];
        filteredMessages.push({
            role: m.role === "assistant" ? "assistant" : "user",
            content: m.content
        });
    }

    // Anthropic requires max_tokens — use 128000 as high cap when unlimited
    var maxTokens = (payload.max_tokens > 0) ? payload.max_tokens : 128000;
    // Anthropic requires temperature=1 when extended thinking is enabled
    var temp = payload.thinkingEnabled ? 1 : clampTemperature("anthropic", payload.model, payload.temperature);
    var body = {
        model: payload.model,
        messages: filteredMessages,
        max_tokens: maxTokens,
        stream: true
    };
    if (temp !== undefined) body.temperature = temp;

    if (payload.thinkingEnabled)
        body.thinking = { type: "enabled", budget_tokens: Math.max(1024, Math.floor(maxTokens * 0.8)) };

    if (extracted.systemText)
        body.system = extracted.systemText;

    return { url: url, headers: headers, body: JSON.stringify(body) };
}

function geminiRequest(payload, apiKey) {
    var base = normalizeBaseUrl(payload.baseUrl || "https://generativelanguage.googleapis.com");
    // Key as header, NOT in URL — security fix
    var url = base + "/v1beta/models/" + (payload.model || "gemini-2.5-flash")
        + ":streamGenerateContent?alt=sse";
    var safeKey = sanitizeApiKey(apiKey);
    if (!safeKey) return null;
    var headers = ["-H", "x-goog-api-key: " + safeKey];

    // Extract system prompt
    var extracted = extractSystemPrompt(payload.messages);
    var contents = [];
    for (var i = 0; i < extracted.filtered.length; i++) {
        var m = extracted.filtered[i];
        contents.push({
            role: m.role === "user" ? "user" : "model",
            parts: [{ text: m.content }]
        });
    }

    var temp = clampTemperature("gemini", payload.model, payload.temperature);
    var genConfig = {};
    if (payload.max_tokens > 0) genConfig.maxOutputTokens = payload.max_tokens;
    if (temp !== undefined) genConfig.temperature = temp;
    var body = {
        contents: contents,
        generationConfig: genConfig
    };
    if (extracted.systemText)
        body.system_instruction = { parts: [{ text: extracted.systemText }] };

    return { url: url, headers: headers, body: JSON.stringify(body) };
}

function customRequest(payload, apiKey) {
    return openaiRequest(payload, apiKey);
}

// ─── Provider Registry ──────────────────────────────────────────
// Centralized metadata for each provider. Adding a new provider only requires
// adding one entry here and a buildRequest function above.

var registry = {
    "ollama": {
        name: "Ollama",
        envVar: null,
        defaultUrl: "http://localhost:11434",
        needsKey: false,
        tempMin: 0.0, tempMax: 2.0, tempDefault: 0.8
    },
    "openai": {
        name: "OpenAI",
        envVar: "OPENAI_API_KEY",
        defaultUrl: "https://api.openai.com",
        needsKey: true,
        tempMin: 0.0, tempMax: 2.0, tempDefault: 1.0,
        // o1/o3 reasoning models don't support temperature
        tempUnsupportedModels: ["o1", "o3"]
    },
    "anthropic": {
        name: "Anthropic",
        envVar: "ANTHROPIC_API_KEY",
        defaultUrl: "https://api.anthropic.com",
        needsKey: true,
        tempMin: 0.0, tempMax: 1.0, tempDefault: 1.0
    },
    "gemini": {
        name: "Gemini",
        envVar: "GEMINI_API_KEY",
        defaultUrl: "https://generativelanguage.googleapis.com",
        needsKey: true,
        tempMin: 0.0, tempMax: 2.0, tempDefault: 1.0
    },
    "custom": {
        name: "custom provider",
        envVar: "EPHEMERA_API_KEY",
        defaultUrl: "https://api.openai.com",
        needsKey: true,
        tempMin: 0.0, tempMax: 2.0, tempDefault: 0.7
    }
};

function getProviderInfo(provider) {
    return registry[provider] || registry["custom"];
}

function getProviderNames() {
    return Object.keys(registry);
}

// Clamp temperature to the provider's valid range.
// Returns undefined if the model doesn't support temperature (e.g. OpenAI o1/o3).
function clampTemperature(provider, model, temperature) {
    var info = registry[provider] || registry["custom"];
    // Check if model doesn't support temperature
    if (info.tempUnsupportedModels) {
        var m = (model || "").toLowerCase();
        for (var i = 0; i < info.tempUnsupportedModels.length; i++) {
            if (m.indexOf(info.tempUnsupportedModels[i]) === 0)
                return undefined;
        }
    }
    var t = (temperature !== undefined && temperature !== null) ? temperature : info.tempDefault;
    return Math.max(info.tempMin, Math.min(info.tempMax, t));
}

function getTemperatureRange(provider) {
    var info = registry[provider] || registry["custom"];
    return { min: info.tempMin, max: info.tempMax, defaultValue: info.tempDefault };
}
