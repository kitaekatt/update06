#!/usr/bin/env bash
# bootstrap-display.sh — Stop hook that surfaces bootstrap results once.
#
# The SessionStart hook fires the engine in the background. The engine writes
# its display JSON to bootstrap_display.pending when done. This hook checks for
# that file on every turn (~0ms when idle) and emits it once, then renames it
# to bootstrap_display.displayed so it won't be shown again.
#
# Handshake protocol:
#   .pending   = engine wrote this, needs to be shown
#   .displayed = stop hook read and renamed it, already shown
# If the engine needs to show new content, it writes a new .pending file.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MARKETPLACE_NAME="$(basename "$(cd "$PLUGIN_ROOT/../.." && pwd)")"
DATA_DIR="${HOME}/.claude/plugins/data/${MARKETPLACE_NAME}/update"
PENDING="${DATA_DIR}/bootstrap_display.pending"

[ -f "$PENDING" ] || exit 0
cat "$PENDING"
mv -f "$PENDING" "${DATA_DIR}/bootstrap_display.displayed"
