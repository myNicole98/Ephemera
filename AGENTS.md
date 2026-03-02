# AGENTS.md

## Overview

Ephemera is a DankMaterialShell daemon plugin (`"type": "daemon"`) providing an AI chat slideout panel for Wayland. In-memory by default; optional persistence via PluginService.

## Setup

No standalone build or test system. Symlink into the parent Quickshell config's plugin path and reload the shell. Source lives in `src/`. Hot-reload with `dms ipc call plugins reload ephemera`.

Depends on parent config modules: `qs.Common` (Theme, StyledText), `qs.Widgets` (Dank* components), `qs.Services` (PluginService).

## Gotchas & Landmines

- **Qt textFormat binding bug** — switching `textFormat` between `RichText`/`PlainText` destroys the `text` binding. Must re-establish via `Qt.binding()` in a `Connections` handler. See `MessageBubble.qml`.
- **Provider switch clears chat** — changing providers clears history and index maps to prevent stale `messageIndexMap` lookups. Model changes within the same provider preserve conversation.
- **ListModel limitations** — QML `ListModel` can't store nested arrays or complex objects. Use JS side-channel maps (`variantStore`, `messageIndexMap`) alongside the model.
- **Ollama safety net** — `Component.onDestruction` fires `pkill` as last resort. The `_shuttingDown` flag prevents double-shutdown. External Ollama is never auto-stopped by the idle timer.
- **5MB stdout buffer cap** — exceeding it kills the curl process to prevent memory exhaustion from runaway responses.
- **DMS permissions are silent** — missing permission declarations in `plugin.json` prevent PluginService calls without logging errors. Current permissions: `settings_read`, `settings_write`.
- **pluginData null during init** — use `??` operator for `pluginData` access; values are `undefined` before first load.
- **DMS auto-injected properties** — `pluginData`, `pluginService`, `pluginId` are injected into the root component without declaration. Don't redeclare them.

## Conventions (non-obvious)

- **Root IDs** — root items: `id: root`, delegate roots: `id: delegate`.
- **Private properties** — prefix with `_` (e.g., `_streamContent`, `_shuttingDown`).
- **JS libraries** — `Providers.js` and `Markdown.js` are pure-function, no QML imports. Import with namespace aliases (`as Providers`).
- **State centralization** — all mutable state in `EphemeraService.qml`. UI reads via bindings, writes via function calls.
- **Property grouping** — use `// --- Section name ---` comment headers.
- **Theme** — never hardcode colors/spacing/fonts. Use `Theme` singleton from `qs.Common`.

## Architecture Decisions

- **curl via Process, not native HTTP** — requests pipe body via stdin (`-d @-`) so secrets never appear in `/proc/cmdline`.
- **Deferred markdown** — `markdownToHtml()` runs only after streaming completes, never per-delta. `_lastRenderedText` cache prevents redundant re-renders.
- **Variants, not replacements** — regeneration saves current response into `variantStore[msgId]` and streams a new one. Capped at 10 (FIFO eviction).
- **Stream isolation** — `_streamContent`/`_streamThinking` buffers are independent of the displayed variant. `_streamVariantIndex` tracks the write target.
- **Cancel preserves content** — partial responses become navigable variants, not discarded.
- **Three thinking paths** — (1) `<think>` tags in content stream (Ollama models), (2) `reasoning_content` fields (DeepSeek API), (3) Anthropic extended thinking API with interleaved-thinking header.
- **PluginService: settings vs state** — settings (`savePluginData`) for user preferences shown in UI; state (`savePluginState`) for runtime data like chat history. State writes are debounced (150ms) and atomic. State requires no permissions.

## Security Invariants

- API keys: env vars only, never persisted by PluginService.
- curl stdin for request bodies (not `/proc/cmdline`-visible args).
- **Known trade-off: API key header visibility** — API keys are passed via curl `-H` headers (e.g., `Authorization: Bearer ...`), which are visible in `/proc/<pid>/cmdline` and `ps` output for the brief lifetime of the curl process. Request *bodies* (containing conversation content) are safely passed via stdin. Moving headers to a temp file or `--header @file` would add complexity and race conditions with cleanup; the current approach matches how most CLI tools handle auth headers.
- HTML escaped before markdown rendering; link schemes whitelisted to http/https.
- Custom URLs validated: http(s) only, valid hostname, max 2048 chars.
- Chat persistence opt-in; API keys never stored regardless.
