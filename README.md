# Ephemera

Ephemeral AI chat for your desktop — ask quick questions, keep nothing.

Ephemera is a [Quickshell](https://github.com/quickshell-mirror/quickshell) plugin that adds an AI chat slideout panel to your Wayland desktop shell. All conversations live in memory and disappear when you close the panel or reload the shell.

## Features

- **Multiple providers** — Ollama, OpenAI, Anthropic, Gemini, or any OpenAI-compatible endpoint
- **Streaming responses** — real-time token-by-token output via SSE
- **Ollama auto-management** — automatically starts `ollama serve` if not running and discovers available models
- **Markdown rendering** — assistant responses rendered as rich text with code blocks, tables, lists, and blockquotes
- **Zero persistence** — messages are never written to disk; API keys are read from environment variables only
- **Security-first** — request bodies sent via stdin (never in `/proc/cmdline`), API keys passed as headers (not URL params), link scheme restricted to http/https

## Requirements

- [Quickshell](https://github.com/quickshell-mirror/quickshell) with a configuration that provides `qs.Common`, `qs.Widgets`, and `qs.Services` modules
- `curl` (used for API requests)
- `wl-copy` from [wl-clipboard](https://github.com/bugaevc/wl-clipboard) (for the copy button)
- For Ollama: [Ollama](https://ollama.com) installed and at least one model pulled

## Installation

Place or symlink this directory into your Quickshell configuration's plugin path, then reload the shell.

## Configuration

### API Keys

Set the appropriate environment variable before starting Quickshell:

| Provider   | Environment Variable  |
|------------|-----------------------|
| OpenAI     | `OPENAI_API_KEY`      |
| Anthropic  | `ANTHROPIC_API_KEY`   |
| Gemini     | `GEMINI_API_KEY`      |
| Custom     | `EPHEMERA_API_KEY`    |
| Ollama     | *(none required)*     |

### Settings

All settings are configurable from the in-app settings panel (gear icon):

- **Provider** — ollama, openai, anthropic, gemini, or custom
- **Model** — auto-discovered dropdown for Ollama, free-text for others
- **Ollama URL** — defaults to `http://localhost:11434`
- **Custom Base URL** — for OpenAI-compatible endpoints
- **System Prompt** — prepended to every request
- **Temperature** — 0.0 (focused) to 2.0 (creative)
- **Max Tokens** — 256 to 16384
- **Context Turns** — number of recent conversation turns sent to the API (2–40)

Settings are persisted via Quickshell's `PluginService`. API keys are never stored.

## Usage

Open the slideout panel via your shell's configured keybind or action. Type a message and press **Enter** to send (Shift+Enter for newline). Press **Escape** to dismiss the panel.

## License

MIT
