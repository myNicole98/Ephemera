# AGENTS.md

## Overview

Ephemera is a DankMaterialShell daemon plugin (`"type": "daemon"`) providing an AI chat slideout panel for Wayland. In-memory by default; optional persistence via PluginService.

## Setup

Symlink into the parent Quickshell config's plugin path and reload the shell. Source lives in `src/`. Hot-reload with `dms restart` (full restart required — DMS caches compiled QML in-process; `dms ipc call plugins reload ephemera` does NOT reliably pick up all changes).

Depends on parent config modules: `qs.Common` (Theme), `qs.Widgets` (Dank* components, StyledText), `qs.Services` (PluginService).

Unit tests: `node tests/run_tests.js` — tests pure JS modules (Providers.js, StreamParser.js, Markdown.js, ChatExport.js, VariantStore.js, ErrorHints.js, Backoff.js).

## Service Architecture

EphemeraService.qml is the **coordinator** that owns message state (`messagesModel`, `messageIndexMap`, `variantStore`) and orchestrates three child services:

- **KeyringService.qml** — D-Bus Secret Service integration. Manages `_keyringCache`, API key lookup/store/clear, `secret-tool` processes. Only needs `provider` from parent. `_cloneCache()` pattern lives here.
- **StreamingService.qml** — Curl process lifecycle, SSE parsing, stream state (`_streamContent`, `_streamThinking`), error backoff. Emits signals (`streamContentUpdated`, `streamFinalized`, `streamError`, `streamCancelled`) that the coordinator handles by applying changes to `messagesModel`.
- **OllamaManager.qml** — Ollama process lifecycle, model discovery, GPU status, idle shutdown.

The coordinator exposes `property alias` for child service properties so UI components continue to use `aiService.isStreaming`, `aiService._keyringAvailable`, etc. unchanged.

## UI Component Structure

EphemeraChat.qml is the main UI orchestrator, composed of:

- **ChatHeader.qml** — Title, provider pill with model selector popup, action buttons (settings, export, clear, expand, close), overflow menu.
- **ChatComposer.qml** — Multi-line TextArea with send/stop crossfade buttons, keyboard shortcuts (Escape, Enter, Ctrl+L/N/Shift+S, Up arrow recall).
- **ChatToast.qml** — Transient notification banner with auto-dismiss timer.
- **ClearChatDialog.qml** — Confirmation popup with dim overlay.
- **MessageList.qml** / **MessageBubble.qml** — Message display, variant navigation, thinking sections.

## Gotchas & Landmines

- **Qt textFormat binding bug** — switching `textFormat` between `RichText`/`PlainText` destroys the `text` binding. Must re-establish via `Qt.binding()` in a `Connections` handler. See `MessageBubble.qml`.
- **Provider switch clears chat** — changing providers clears history and index maps to prevent stale `messageIndexMap` lookups. Model changes within the same provider preserve conversation.
- **ListModel limitations** — QML `ListModel` can't store nested arrays or complex objects. Use JS side-channel maps (`variantStore`, `messageIndexMap`) alongside the model.
- **Ollama safety net** — `Component.onDestruction` fires `pkill` as last resort. The `_shuttingDown` flag prevents double-shutdown. External Ollama is never auto-stopped by the idle timer.
- **5MB stdout buffer cap** — exceeding it kills the curl process to prevent memory exhaustion from runaway responses.
- **DMS permissions are silent** — missing permission declarations in `plugin.json` prevent PluginService calls without logging errors. Current permissions: `settings_read`, `settings_write`.
- **pluginData null during init** — use `??` operator for `pluginData` access; values are `undefined` before first load.
- **DMS auto-injected properties** — `pluginData`, `pluginService`, `pluginId` are injected into the root component without declaration. Don't redeclare them.
- **`_keyringCache` clone requirement** — always use `_cloneCache()` in KeyringService when mutating `_keyringCache`. QML `property var` skips change notification when reassigned the same object reference, which silently breaks `hasApiKey`/`missingApiKey` bindings via the alias chain.
- **StreamingService signal ordering** — the coordinator must set up the message model entry and index map BEFORE calling `streamingService.launchCurl()`, or `findIndexById` will return -1 in signal handlers.

## Conventions (non-obvious)

- **Root IDs** — root items: `id: root`, delegate roots: `id: delegate`.
- **Private properties** — prefix with `_` (e.g., `_streamContent`, `_shuttingDown`).
- **JS libraries** — all `.js` files in `src/lib/` are `.pragma library` pure-function modules (no QML imports). Import with namespace aliases (`as Providers`). Testable via Node.js by stripping the pragma directive. All public functions have JSDoc comments.
- **State centralization** — all mutable state in EphemeraService.qml (coordinator). Child services own their internal state but communicate changes via signals/property aliases.
- **Property grouping** — use `// --- Section name ---` comment headers.
- **Theme** — never hardcode colors/spacing/fonts. Use `Theme` singleton from `qs.Common`.
- **UI component signals** — extracted components (ChatHeader, ChatComposer, etc.) communicate with parent via signals, not direct property writes. Parent wires signal handlers.

## Architecture Decisions

- **curl via Process, not native HTTP** — requests use `curl -K -` (config from stdin) so URL, auth headers, and body never appear in `/proc/cmdline`.
- **Deferred markdown** — `markdownToHtml()` runs only after streaming completes, never per-delta. `_lastRenderedText` cache prevents redundant re-renders.
- **Variants, not replacements** — regeneration saves current response into `variantStore[msgId]` and streams a new one. Capped at 10 (FIFO eviction).
- **Stream isolation** — `_streamContent`/`_streamThinking` buffers live in StreamingService, independent of the displayed variant. `_streamVariantIndex` tracks the write target. The coordinator applies updates to `messagesModel` in signal handlers.
- **Cancel preserves content** — partial responses become navigable variants, not discarded.
- **Three thinking paths** — (1) `<think>` tags in content stream (Ollama models), (2) `reasoning_content` fields (DeepSeek API), (3) Anthropic extended thinking API with interleaved-thinking header.
- **PluginService: settings vs state** — settings (`savePluginData`) for user preferences shown in UI; state (`savePluginState`) for runtime data like chat history. State writes are debounced (150ms) and atomic. State requires no permissions.
- **Exponential backoff with jitter** — error cooldown uses `Backoff.js` instead of a flat delay. Formula: `random(floor, min(maxDelay, base * 2^attempt))`. First error: 1–2s. Fifth error: 1–30s (capped). Resets to zero on successful stream finalization.
- **Coordinator pattern** — child services are instantiated inside EphemeraService.qml and communicate via signals and property aliases. This follows the same pattern as OllamaManager.qml but is applied to keyring and streaming.

## Security Invariants

- API keys: system keyring (D-Bus Secret Service) or env vars, never persisted by PluginService. Keyring secrets are encrypted at rest by the keyring daemon, unlocked with the user's session login.
- `secret-tool store` receives keys via stdin — never in `/proc/cmdline`. `_keyringCache` exists only in process memory.
- `curl -K -` for all API requests — URL, auth headers, and body are passed via stdin config, never visible in `/proc/cmdline` or `ps` output. The `escapeCurlConfig()` function handles proper escaping for the curl config format.
- HTML escaped before markdown rendering; link schemes whitelisted to http/https.
- Custom URLs validated: http(s) only, valid hostname, max 2048 chars, no unsafe characters (angle brackets, quotes, backticks, etc.).
- **Error backoff** — exponential backoff with jitter after request errors prevents rapid-fire retries against failing endpoints. See `Backoff.js`.
- `forceShutdownExternal()` uses `pkill -x` (exact process name match) to avoid killing unrelated processes.
- Chat persistence opt-in; API keys never stored in PluginService regardless.
