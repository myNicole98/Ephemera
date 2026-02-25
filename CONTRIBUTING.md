# Contributing to Ephemera

This guide covers everything you need to know to work on Ephemera — a Quickshell daemon plugin that provides an ephemeral AI chat slideout for Wayland desktops.

## Prerequisites

- A running [DankMaterialShell (DMS)](https://danklinux.com) installation (provides Quickshell + `qs.Common`, `qs.Widgets`, `qs.Services`)
- `curl`, `wl-copy` (from wl-clipboard), and optionally [Ollama](https://ollama.com)
- Basic familiarity with QML and JavaScript

## Project structure

```
ephemera/
├── plugin.json              # Plugin manifest (id, type, capabilities, entry point)
├── EphemeraDaemon.qml       # Entry point — service init, per-screen slideouts, IPC handler
├── EphemeraService.qml      # Core state machine — messages, streaming, Ollama lifecycle, curl
├── EphemeraChat.qml         # Main UI — header, message area, composer, overlays
├── EphemeraSettings.qml     # Settings panel — provider, model, parameters, API key status
├── MessageList.qml          # ListView wrapper with auto-scroll and entry animations
├── MessageBubble.qml        # Individual message rendering (markdown, copy, regenerate, streaming dots)
├── Providers.js             # Pure functions — builds provider-specific curl commands (shared extractSystemPrompt helper)
├── Markdown.js              # Markdown-to-HTML converter with security hardening
├── CLAUDE.md                # AI assistant context file
└── README.md                # User-facing documentation
```

## Architecture

```
EphemeraDaemon (entry point)
│
├─ EphemeraService (singleton)
│  ├─ Message ListModel (in-memory, never persisted)
│  ├─ messageIndexMap (O(1) message lookups by ID)
│  ├─ Provider settings (persisted via PluginService)
│  ├─ Ollama lifecycle (ping → auto-start → discover models)
│  ├─ Curl process (stdin body, SSE streaming, 10MB buffer cap)
│  └─ Providers.js (curl command builders per provider, shared extractSystemPrompt)
│
└─ Variants (one per screen)
   └─ DankSlideout
      └─ EphemeraChat
         ├─ MessageList → MessageBubble (uses Markdown.js)
         ├─ Composer (auto-growing text input)
         └─ EphemeraSettings (overlay)
```

**Data flow:** User types → `EphemeraChat.sendCurrentMessage()` → `EphemeraService.sendMessage()` → builds payload with sliding context window → `Providers.buildCurlCommand()` → spawns curl via `Process` with body on stdin → `StdioCollector` captures SSE chunks → `handleStreamChunk()` parses `data:` lines → `parseProviderDelta()` extracts text per provider → `updateStreamContent()` appends to ListModel → UI updates live.

## Setup for development

1. Symlink or copy this directory into your DMS plugin path:
   ```sh
   ln -s /path/to/ephemera ~/.config/DankMaterialShell/plugins/ephemera
   ```

2. Enable the plugin:
   ```sh
   dms ipc call plugins enable ephemera
   ```

3. To open the panel, either use the configured keybind or:
   ```sh
   dms ipc call ephemera toggle
   ```

## Testing changes

There is no automated test suite — Ephemera is a QML plugin loaded by Quickshell at runtime. Testing is manual.

### Reload cycle

After editing any `.qml` or `.js` file:

```sh
# Full restart (required — DMS caches compiled QML in-process)
dms restart

# Wait a few seconds for DMS to initialize, then re-enable
dms ipc call plugins enable ephemera

# Open the panel
dms ipc call ephemera toggle
```

**Important:** `dms ipc call plugins reload ephemera` does NOT reliably pick up all changes (especially IPC handlers and JS files). Always use `dms restart` during development.

### Plugin debugging commands

```sh
dms ipc call plugins list              # List all plugins and their status
dms ipc call plugins status ephemera   # Check if enabled/disabled and any errors
dms ipc call plugins enable ephemera   # Enable the plugin
dms ipc call plugins disable ephemera  # Disable the plugin
```

### Checking for errors

QML errors appear in the systemd journal:

```sh
journalctl --user -n 50 --no-pager | grep -i -e error -e warn -e Ephemera
```

Common error patterns:
- `Cannot assign to non-existent property "X"` — property doesn't exist on that type
- `Unable to assign [undefined] to QColor` — using a Theme property that doesn't exist
- `ReferenceError: X is not defined` — typo or missing import

### Testing streaming manually

You can test the exact curl command the plugin would issue:

```sh
# Ollama (LiquidAI example)
echo '{"model":"huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF:latest","messages":[{"role":"user","content":"Hello"}],"max_tokens":4096,"temperature":0.7,"stream":true}' \
  | curl -N -sS --no-buffer --show-error --connect-timeout 5 --max-time 30 \
    -w '\nEPH_STATUS:%{http_code}\n' \
    -H 'Content-Type: application/json' \
    -d @- http://localhost:11434/v1/chat/completions
```

You should see `data:` lines streaming in, ending with `data: [DONE]` and `EPH_STATUS:200`.

### Testing Ollama lifecycle

```sh
# Check if Ollama is running
curl -s http://localhost:11434/api/tags

# List available models
curl -s http://localhost:11434/api/tags | python3 -c "import sys,json; [print(m['name']) for m in json.load(sys.stdin)['models']]"

# Start Ollama manually (plugin also does this automatically)
ollama serve &
```

### What to verify after changes

- Messages appear with entry animation (fade + scale)
- Streaming shows pulsing dots (tertiary color during thinking, primary during generating), then renders markdown when done
- Copy button appears on hover over assistant messages; shows checkmark feedback for 1.5s
- Regenerate button appears on hover over the last assistant message
- Error messages trigger a shake animation
- Composer grows/shrinks as text is typed (44–160px)
- Send button disabled and placeholder turns red when API key is missing
- Send/stop buttons crossfade during streaming
- Empty state shows breathing vapor animation
- Scroll-to-bottom pill appears when scrolled up
- Settings panel fades in/out, accordion fields animate
- System prompt presets dropdown works and populates the text field
- Request timeout slider saves and persists
- Provider pill in header truncates long names with ellipsis; turns red when API key missing or last request failed
- Provider pill and model chips in message bubbles expand when slideout is expanded
- Thinking section has clear visual separation from content (spacing + divider)
- Export button in header copies full conversation as markdown
- Close button handles Ollama shutdown (auto-stop if plugin started it, dialog if external)
- Escape key triggers close flow (same as close button)
- Expand/collapse button works on the slideout
- Custom base URLs are validated (http/https only)

## Quickshell QML constraints

Quickshell's QML engine has differences from standard Qt Quick. These will save you debugging time:

### Animations

**Do not** use `target` on standalone animations. This will fail silently or throw `Cannot assign to non-existent property "target"`:

```qml
// WRONG — will not work in Quickshell
NumberAnimation { target: someItem; property: "opacity"; to: 1 }
```

Instead, use one of these patterns:

```qml
// Pattern 1: Behavior on property (reacts to property changes)
Behavior on opacity {
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
}

// Pattern 2: Animation on property (runs automatically)
SequentialAnimation on opacity {
    loops: Animation.Infinite
    NumberAnimation { to: 0.75; duration: 1200 }
    NumberAnimation { to: 0.5; duration: 1200 }
}
```

### Process stdin

The `Process` type (from `Quickshell.Io`) supports writing to stdin but **does not** have a `closeStdin()` method. To signal EOF:

```qml
Process {
    id: proc
    stdinEnabled: true  // Must be set BEFORE process starts

    onRunningChanged: {
        if (running) {
            proc.write("data to send");
            proc.stdinEnabled = false;  // Signals EOF — this is the correct way
        }
    }
}
```

Once `stdinEnabled` is set to `false`, it cannot be re-enabled for that process run. Re-enable it before starting the next run.

### IPC handlers

Daemon plugins need an explicit `IpcHandler` (from `Quickshell.Io`) to receive IPC calls:

```qml
import Quickshell.Io

IpcHandler {
    target: "ephemera"          // IPC namespace
    function toggle(): string { // Must return string
        doSomething();
        return "SUCCESS";
    }
}
```

Call with: `dms ipc call ephemera toggle`

### Theme properties

Use only properties that exist on `Theme`. Some that **do** exist:
- `Theme.primary`, `Theme.onPrimary`, `Theme.error`, `Theme.onSurface`
- `Theme.surfaceContainer`, `Theme.surfaceContainerHigh`, `Theme.surfaceContainerHighest`
- `Theme.surfaceText`, `Theme.surfaceTextMedium`, `Theme.surfaceVariant`, `Theme.surfaceVariantText`
- `Theme.outline`, `Theme.outlineMedium`, `Theme.outlineVariant`
- `Theme.withAlpha(color, alpha)`, `Theme.cornerRadius`, `Theme.spacingS/M/L/XS`

Some that **do not** exist: `Theme.scrim`, `Theme.errorText`.

### StyledText defaults

`StyledText` (from `qs.Widgets`) extends `Text` with:
- `wrapMode: Text.WordWrap` (default)
- `elide: Text.ElideRight` (default)

Elide only works when wrapping is disabled. To truncate text, you must explicitly set:
```qml
StyledText {
    wrapMode: Text.NoWrap  // Required for elide to take effect
    elide: Text.ElideRight
    width: 160             // Must be constrained
}
```

## Security considerations

These are non-negotiable design decisions:

- **API keys from environment variables only.** Never add input fields for API keys. Never store them to disk.
- **Curl body via stdin** (`-d @-`). Never pass the request body as a command-line argument — it would be visible in `/proc/cmdline`.
- **Link scheme whitelist.** Only `http://` and `https://` links are opened. No `file://`, `javascript:`, or other schemes.
- **HTML escaping in Markdown.js.** All user content is escaped before rendering as rich text. Code blocks, table cells, and language labels are all escaped independently.
- **Gemini API key as header** (`x-goog-api-key`), not as a URL query parameter.
- **Custom URL validation.** Custom base URLs must start with `http://` or `https://`. Reject anything else.
- **Stdout buffer cap.** The `StdioCollector` is capped at 10MB. A rogue endpoint cannot exhaust memory.

## Adding a new provider

1. **`Providers.js`** — Add a new `fooRequest(payload, apiKey)` function that returns `{ url, headers, body }`. Use the shared `extractSystemPrompt(payload.messages)` helper to separate system messages if the provider needs them in a different field. Add a case in `buildRequest()`.

2. **`EphemeraService.qml`** — Add the provider to `resolveApiKey()` (map to env var name) and `updateBaseUrl()` (set default URL). Update `parseProviderDelta()` if the streaming format differs from OpenAI's SSE.

3. **`EphemeraSettings.qml`** — Add the provider to the dropdown model and add any provider-specific fields (URL, etc.) with accordion animation.

## Code style

- No automated linter or formatter. Follow existing patterns.
- Use `Theme.*` for all colors, spacing, and sizing — never hardcode values.
- Prefer `Behavior on property` for reactive animations.
- Keep JS logic in `.js` files (Providers.js, Markdown.js); keep QML files focused on UI and state.
- Security-sensitive code should be commented with the rationale.
