#!/bin/bash
# Unload and remove wispr-media-pause. Keeps the log file for reference.
set -euo pipefail

BIN="$HOME/.local/bin/wispr-media-pause"
PLIST="$HOME/Library/LaunchAgents/io.kierz.wispr-media-pause.plist"
LABEL="io.kierz.wispr-media-pause"

echo "Unloading LaunchAgent..."
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

rm -f "$PLIST" "$BIN"

echo "OK: removed $PLIST and $BIN."
echo "Log kept at: $HOME/Library/Logs/wispr-media-pause.log"
