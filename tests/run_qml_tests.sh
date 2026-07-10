#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUNTIME_DIR=$(mktemp -d /tmp/ephemera-qml-test.XXXXXX)
trap 'rm -rf "$RUNTIME_DIR"' EXIT
chmod 700 "$RUNTIME_DIR"
CONFIG_DIR="$RUNTIME_DIR/config"
mkdir -p "$CONFIG_DIR/src/services" "$CONFIG_DIR/src/lib"
cp "$ROOT/tests/McpServiceHarness.qml" "$CONFIG_DIR/McpServiceHarness.qml"
cp "$ROOT/tests/McpApprovalHarness.qml" "$CONFIG_DIR/McpApprovalHarness.qml"
cp "$ROOT/src/services/MCPService.qml" "$CONFIG_DIR/src/services/MCPService.qml"
cp "$ROOT/src/services/StreamingService.qml" "$CONFIG_DIR/src/services/StreamingService.qml"
cp "$ROOT/src/lib/Mcp.js" "$CONFIG_DIR/src/lib/Mcp.js"
cp "$ROOT/src/lib/McpSchema.js" "$CONFIG_DIR/src/lib/McpSchema.js"
cp "$ROOT/src/lib/Providers.js" "$CONFIG_DIR/src/lib/Providers.js"
cp "$ROOT/src/lib/StreamParser.js" "$CONFIG_DIR/src/lib/StreamParser.js"
cp "$ROOT/src/lib/ErrorHints.js" "$CONFIG_DIR/src/lib/ErrorHints.js"
cp "$ROOT/src/lib/Backoff.js" "$CONFIG_DIR/src/lib/Backoff.js"

run_harness() {
    harness=$1
    marker=$2
    harness_runtime="$RUNTIME_DIR/$harness"
    mkdir -p "$harness_runtime"
    chmod 700 "$harness_runtime"

    output=$(PATH="$ROOT/tests/fixtures/bin:$PATH" \
        XDG_RUNTIME_DIR="$harness_runtime" \
        QT_QPA_PLATFORM=offscreen \
        QS_NO_RELOAD_POPUP=1 \
        timeout 12s qs -p "$CONFIG_DIR/$harness.qml" 2>&1) || {
        printf '%s\n' "$output"
        exit 1
    }

    printf '%s\n' "$output"
    if ! printf '%s\n' "$output" | grep -Fq "$marker PASS"; then
        exit 1
    fi
}

run_harness McpServiceHarness EPHEMERA_MCP_QML_TEST
run_harness McpApprovalHarness EPHEMERA_MCP_APPROVAL_TEST
