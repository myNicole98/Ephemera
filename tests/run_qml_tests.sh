#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUNTIME_DIR=$(mktemp -d /tmp/ephemera-qml-test.XXXXXX)
trap 'rm -rf "$RUNTIME_DIR"' EXIT
chmod 700 "$RUNTIME_DIR"
CONFIG_DIR="$RUNTIME_DIR/config"
mkdir -p "$CONFIG_DIR/src/services" "$CONFIG_DIR/src/lib"
cp "$ROOT/tests/McpServiceHarness.qml" "$CONFIG_DIR/McpServiceHarness.qml"
cp "$ROOT/src/services/MCPService.qml" "$CONFIG_DIR/src/services/MCPService.qml"
cp "$ROOT/src/lib/Mcp.js" "$CONFIG_DIR/src/lib/Mcp.js"
cp "$ROOT/src/lib/Providers.js" "$CONFIG_DIR/src/lib/Providers.js"

OUTPUT=$(PATH="$ROOT/tests/fixtures/bin:$PATH" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    QT_QPA_PLATFORM=offscreen \
    QS_NO_RELOAD_POPUP=1 \
    timeout 12s qs -p "$CONFIG_DIR/McpServiceHarness.qml" 2>&1) || {
    printf '%s\n' "$OUTPUT"
    exit 1
}

printf '%s\n' "$OUTPUT"
if ! printf '%s\n' "$OUTPUT" | grep -Fq "EPHEMERA_MCP_QML_TEST PASS"; then
    exit 1
fi
