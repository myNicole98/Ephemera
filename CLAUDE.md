# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Ephemera is a Quickshell daemon plugin that provides an ephemeral AI chat slideout panel for a Linux Wayland desktop shell. All messages are in-memory only — nothing is persisted to disk. It is defined in `plugin.json` as a `"type": "daemon"` plugin with `slideout` and `ai` capabilities.

## Running

This is a QML plugin loaded by a parent Quickshell configuration. There is no standalone build or test system. To use it, place/symlink this directory into the parent Quickshell config's plugin path and reload the shell.

The plugin depends on shared QML modules from the parent config:
- `qs.Common` — Theme, StyledText
- `qs.Widgets` — DankButton, DankSlideout, DankDropdown, DankTextField, DankSlider, DankActionButton, DankIcon, DankFlickable
- `qs.Services` — PluginService (settings persistence)

## Architecture

**Entry point:** `EphemeraDaemon.qml` — registered in `plugin.json` as `component`. Creates the `EphemeraService` singleton and a per-screen `DankSlideout` containing `EphemeraChat`.

**Service layer:** `EphemeraService.qml` — owns all state: message model (`ListModel`), streaming status, provider settings, Ollama lifecycle. Uses a `messageIndexMap` for O(1) message lookups by ID. Performs API calls by spawning `curl` via Quickshell's `Process` QML type with the request body piped through stdin (`-d @-`) so secrets never appear in `/proc/cmdline`. Stdout buffer is capped at 10MB to prevent memory exhaustion. Exposes `missingApiKey` and `lastRequestFailed` for UI feedback. Supports `regenerate()` (re-send last user message) and `exportConversation()` (copy chat as markdown).

**Provider abstraction:** `Providers.js` — pure-function library (`buildCurlCommand`) that constructs provider-specific curl commands and JSON bodies for Ollama, OpenAI, Anthropic, Gemini, and custom (OpenAI-compatible) endpoints. A shared `extractSystemPrompt()` helper separates system messages from conversation messages; each provider's request builder then handles auth headers and format differences (e.g., Anthropic uses a top-level `system` field; Gemini uses `contents[].parts[]` format).

**UI components:**
- `EphemeraChat.qml` — main chat view with header, message area, and composer; loads `EphemeraSettings` as an overlay
- `EphemeraSettings.qml` — settings panel for provider, model, temperature, max tokens, context turns, system prompt (with presets), and request timeout
- `MessageList.qml` — `ListView` wrapper with auto-scroll-to-bottom behavior; passes `expanded` state and regenerate signals to bubbles
- `MessageBubble.qml` — renders user/assistant messages; assistant messages use rich-text HTML via `Markdown.js` (deferred until streaming completes for performance); includes a collapsible "Thinking" section with visual separation from content, copy button with feedback, and regenerate button on the last assistant message; model chips expand when the slideout is expanded

**Markdown rendering:** `Markdown.js` — converts markdown to Qt-compatible HTML with security hardening (HTML escaping, link scheme whitelist to http/https only).

## Key Design Decisions

- **API keys from env vars only:** `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `EPHEMERA_API_KEY` (for custom). Never stored on disk. `EphemeraSettings` displays detection status but provides no input fields for keys.
- **Ollama auto-lifecycle:** On startup, pings Ollama; if unreachable, attempts `ollama serve` and retries up to 5 times. Re-pings each time the panel becomes visible via `ensureOllamaReady()`. Tracks whether Ollama was externally managed vs. started by the plugin (only stops it on destruction if we started it). Auto-discovers available models via `/api/tags`.
- **Thinking/reasoning content:** Models that emit `<think>...</think>` tags in their content stream (e.g., Qwen3, DeepSeek via Ollama) are detected by `routeContentDelta`, which splits the stream into thinking vs. content. Providers that send explicit `reasoning_content` or `reasoning` fields (DeepSeek via OpenAI-compatible APIs) are handled directly in `parseProviderDelta`. Thinking text is stored in a separate `thinking` property on each message and rendered in a collapsible section in `MessageBubble`.
- **Streaming via SSE:** All providers use Server-Sent Events. `handleStreamChunk` parses the SSE `data:` lines incrementally; `parseProviderDelta` dispatches by provider to extract text deltas. Content deltas are routed through `routeContentDelta` for `<think>` tag detection. Falls back to non-streaming response parsing if no streamed content was received.
- **Sliding context window:** `buildPayload` collects the last N user turns (configurable via `maxTurns`, up to 100) from the in-memory model to send as conversation history.
- **Copy uses `wl-copy`:** Wayland-only clipboard via `Quickshell.execDetached(["wl-copy", ...])`. Copy button shows checkmark feedback for 1.5s.
- **Deferred markdown rendering:** `MessageBubble` only runs `markdownToHtml()` when streaming finishes (status changes to `"ok"`), not on every delta. A `_lastRenderedText` cache avoids redundant re-renders.
- **Message index map:** `findIndexById()` uses a `messageIndexMap` object for O(1) lookups instead of linear scan, updated on append and cleared on `clearChat()`.
- **Provider failure state:** The header pill and send button reflect `missingApiKey` and `lastRequestFailed` — red tint on the pill, disabled send with placeholder hint when a required API key is absent.
- **Custom URL validation:** Custom base URLs must start with `http://` or `https://`.
- **Stdout buffer cap:** `StdioCollector` output is capped at 10MB; exceeding it kills the curl process and shows an error.
