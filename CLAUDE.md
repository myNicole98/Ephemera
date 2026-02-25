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

**Service layer:** `EphemeraService.qml` — owns all state: message model (`ListModel`), streaming status, provider settings, Ollama lifecycle. Performs API calls by spawning `curl` via Quickshell's `Process` QML type with the request body piped through stdin (`-d @-`) so secrets never appear in `/proc/cmdline`.

**Provider abstraction:** `Providers.js` — pure-function library (`buildCurlCommand`) that constructs provider-specific curl commands and JSON bodies for Ollama, OpenAI, Anthropic, Gemini, and custom (OpenAI-compatible) endpoints. Each provider has its own request builder handling auth headers and message format differences (e.g., Anthropic extracts system prompt to a top-level `system` field; Gemini uses `contents[].parts[]` format).

**UI components:**
- `EphemeraChat.qml` — main chat view with header, message area, and composer; loads `EphemeraSettings` as an overlay
- `EphemeraSettings.qml` — settings panel for provider, model, temperature, max tokens, context turns, system prompt
- `MessageList.qml` — `ListView` wrapper with auto-scroll-to-bottom behavior
- `MessageBubble.qml` — renders user/assistant messages; assistant messages use rich-text HTML via `Markdown.js` when not actively streaming; includes a collapsible "Thinking" section for reasoning content

**Markdown rendering:** `Markdown.js` — converts markdown to Qt-compatible HTML with security hardening (HTML escaping, link scheme whitelist to http/https only).

## Key Design Decisions

- **API keys from env vars only:** `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `EPHEMERA_API_KEY` (for custom). Never stored on disk. `EphemeraSettings` displays detection status but provides no input fields for keys.
- **Ollama auto-lifecycle:** On startup, pings Ollama; if unreachable, attempts `ollama serve` and retries up to 5 times. Re-pings each time the panel becomes visible via `ensureOllamaReady()`. Tracks whether Ollama was externally managed vs. started by the plugin (only stops it on destruction if we started it). Auto-discovers available models via `/api/tags`.
- **Thinking/reasoning content:** Models that emit `<think>...</think>` tags in their content stream (e.g., Qwen3, DeepSeek via Ollama) are detected by `routeContentDelta`, which splits the stream into thinking vs. content. Providers that send explicit `reasoning_content` or `reasoning` fields (DeepSeek via OpenAI-compatible APIs) are handled directly in `parseProviderDelta`. Thinking text is stored in a separate `thinking` property on each message and rendered in a collapsible section in `MessageBubble`.
- **Streaming via SSE:** All providers use Server-Sent Events. `handleStreamChunk` parses the SSE `data:` lines incrementally; `parseProviderDelta` dispatches by provider to extract text deltas. Content deltas are routed through `routeContentDelta` for `<think>` tag detection. Falls back to non-streaming response parsing if no streamed content was received.
- **Sliding context window:** `buildPayload` collects the last N user turns (configurable via `maxTurns`) from the in-memory model to send as conversation history.
- **Copy uses `wl-copy`:** Wayland-only clipboard via `Quickshell.execDetached(["wl-copy", ...])`.
