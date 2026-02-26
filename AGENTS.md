# AGENTS.md

> **Before modifying this file**, review the spec at <https://agents.md/> to ensure changes remain compliant.

## Project Overview

Ephemera is a Quickshell daemon plugin that provides an AI chat slideout panel for a Linux Wayland desktop shell. By default, all messages are in-memory only — nothing is persisted to disk. An optional "Save Chat History" toggle persists conversations via PluginService (API keys are never stored). It is defined in `plugin.json` as a `"type": "daemon"` plugin with `slideout` and `ai` capabilities.

## Setup & Development Environment

This is a QML plugin loaded by a parent Quickshell configuration. There is no standalone build or test system. To use it, place/symlink this directory into the parent Quickshell config's plugin path and reload the shell.

The plugin depends on shared QML modules from the parent config:
- `qs.Common` — Theme, StyledText
- `qs.Widgets` — DankButton, DankDropdown, DankTextField, DankSlider, DankActionButton, DankIcon, DankFlickable
- `qs.Services` — PluginService (settings persistence)

Environment variables required for non-Ollama providers:
- `OPENAI_API_KEY` — OpenAI
- `ANTHROPIC_API_KEY` — Anthropic
- `GEMINI_API_KEY` — Gemini
- `EPHEMERA_API_KEY` — Custom (OpenAI-compatible)

## Code Style

- **Language:** QML (Qt6/Quickshell) for UI and service logic; JavaScript (`.js`) for pure-function libraries
- **Naming:** PascalCase for QML component files and type names, camelCase for properties/functions/signals, `_prefixed` for private properties
- **Component IDs:** Root items use `id: root`; delegate roots use `id: delegate`
- **Properties:** Group with comment headers (e.g., `// --- Provider settings ---`); use `readonly property` for derived values
- **Signals:** Prefer signal declarations on components, connect via `Connections` or inline handlers
- **JS libraries:** `Providers.js` and `Markdown.js` are imported with namespace aliases (`as Providers`, etc.) — keep them as pure-function libraries with no QML dependencies
- **State management:** All mutable state lives in `EphemeraService.qml`; UI components read via property bindings and write via function calls on the service
- **ListModel usage:** Use JS side-channel maps (`variantStore`, `messageIndexMap`) for data that QML ListModel can't represent (nested arrays, O(1) lookups)

## Architecture

### File Map

| File | Role |
|------|------|
| `plugin.json` | Plugin manifest — type, capabilities, entry component |
| `EphemeraDaemon.qml` | Entry point — creates `EphemeraService` singleton + per-screen `EphemeraPanel` |
| `EphemeraPanel.qml` | Wayland layer-shell `PanelWindow` — slide animation, expand/collapse, focus management |
| `EphemeraService.qml` | Service layer — all state, API calls, Ollama lifecycle, streaming, variants |
| `EphemeraChat.qml` | Main chat view — header, message area, composer, settings overlay |
| `EphemeraSettings.qml` | Settings panel — provider, model, temperature, tokens, system prompt, Ollama controls |
| `MessageList.qml` | `ListView` wrapper — auto-scroll, entry animations, variant signal forwarding |
| `MessageBubble.qml` | Message rendering — markdown, thinking sections, variants, copy, regenerate |
| `Providers.js` | Provider abstraction — builds curl commands/JSON for Ollama, OpenAI, Anthropic, Gemini, custom |
| `Markdown.js` | Markdown-to-HTML — Qt-compatible rich text with security hardening |

### Data Flow

1. User types in `EphemeraChat` composer, triggers `sendMessage()` on `EphemeraService`
2. `EphemeraService.buildPayload()` collects the last N user turns (sliding context window) and calls `Providers.buildCurlCommand()` to construct the provider-specific request
3. API calls spawn `curl` via Quickshell's `Process` type with the request body piped through stdin (`-d @-`) so secrets never appear in `/proc/cmdline`
4. SSE stream chunks arrive via `handleStreamChunk` → `parseProviderDelta` → `routeContentDelta` (for `<think>` tag detection)
5. On stream completion, `MessageBubble` runs deferred `markdownToHtml()` rendering

### Panel Behavior

`EphemeraPanel.qml` — slide animation (400ms OutCubic), expand/collapse between 480px and 960px widths, keyboard focus (`OnDemand` when visible, `None` when hidden), DPR-aware rendering, mask-based input region. Fires `opened()` after slide-in, which triggers `focusInput()` on `EphemeraChat`.

### Ollama Lifecycle

On startup, pings Ollama; if unreachable, starts `ollama serve` with up to 15 retries (1s interval). Uses `ollamaStartPending` flag to avoid premature `ollamaWeStarted`. Re-pings on panel visibility via `ensureOllamaReady()`. Tracks external vs. plugin-started Ollama. Configurable idle timer (`ollamaIdleMinutes`, default 5 min, 0 = never) auto-stops if we started it; external Ollama is never auto-stopped. `shutdownOllama()` and `forceShutdownExternalOllama()` use `_shuttingDown` flag + `pkill` safety net. Unexpected death resets flags for auto-restart. `Component.onDestruction` fires `pkill` as safety net. Auto-discovers models via `/api/tags`.

## Security Considerations

- **API keys from env vars only** — never stored on disk, never persisted by PluginService. `EphemeraSettings` displays detection status but provides no input fields.
- **Secrets hidden from procfs** — curl requests use `-d @-` (stdin) so API keys and request bodies never appear in `/proc/cmdline`.
- **Stdout buffer cap** — 5MB limit (checked before processing) prevents memory exhaustion from malicious/runaway responses; exceeding it kills the curl process.
- **Markdown security** — HTML is escaped before rendering; link schemes are whitelisted to `http`/`https` only.
- **Custom URL validation** — must start with `http://` or `https://`, have a valid hostname, and be under 2048 characters. Errors shown inline.
- **Chat persistence is opt-in** — disabled by default; when enabled, saves messages/variants via PluginService but never API keys.

## Key Design Decisions

### Streaming & Parsing
- **SSE streaming for all providers** — `handleStreamChunk` parses `data:` lines incrementally; `parseProviderDelta` dispatches by provider. Falls back to `extractNonStreamingAssistantText()` if no streamed content was received.
- **Thinking/reasoning content** — Three paths: (1) `<think>...</think>` tags in content stream (Qwen3, DeepSeek via Ollama) detected by `routeContentDelta`. (2) Explicit `reasoning_content`/`reasoning` fields (DeepSeek via OpenAI-compatible APIs) handled in `parseProviderDelta`. (3) Anthropic extended thinking via `thinkingEnabled` toggle — adds `anthropic-beta: interleaved-thinking-2025-05-14` header, 80% of `maxTokens` thinking budget (min 1024), forces temperature to 1.0.

### Variant System
- **Regeneration creates variants, not replacements** — current `{content, thinking, modelName}` saved into `variantStore[msgId]`, variant count incremented, message reset for streaming. Navigate with `< 1/2 >` arrows. Each variant records its model. Capped at 10; overflow evicts oldest (FIFO).
- **Stream isolation** — `_streamContent`/`_streamThinking` buffers are independent of displayed message. `_streamVariantIndex` tracks which slot the stream writes to, regardless of which variant the user views.
- **Cancel preserves content** — `cancel()` flushes partial `<think>` buffer, saves partial content as a navigable variant, sets status to `"ok"`.

### Rendering
- **Deferred markdown** — `markdownToHtml()` runs only when streaming finishes, not on every delta. `_lastRenderedText` cache avoids redundant re-renders.
- **TextArea textFormat workaround** — Qt breaks `text` binding when `textFormat` switches between `RichText` and `PlainText`. Worked around by re-establishing the binding via `Qt.binding()` in a `Connections` handler.

### State Management
- **Message index map** — `findIndexById()` uses `messageIndexMap` for O(1) lookups, updated on append, cleared on `clearChat()`.
- **Provider switch cleanup** — changing providers clears chat history and index maps to prevent stale lookups. Model changes within the same provider preserve the conversation.
- **Sliding context window** — `buildPayload` collects the last N user turns (configurable `maxTurns`, up to 100).

### UI Details
- **Copy uses `wl-copy`** — Wayland-only clipboard. Checkmark feedback for 1.5s.
- **HTTP error hints** — `httpErrorHint()` provides contextual suggestions for common HTTP status codes (401 → check API key, 429 → rate limited, etc.).
- **Missing API key banner** — prominent banner showing which env var to set, in addition to the subtle red pill tint.
- **Header overflow menu** — copy/save/clear collapse into three-dots menu when not expanded; settings/expand/close always visible.
- **File export** — `exportConversationToFile()` writes markdown to `~/ephemera-chat-<timestamp>.md` via a `tee` process with stdin.
