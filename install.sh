#!/bin/bash
# Compile, install, and (re)load the wispr-media-pause LaunchAgent. No sudo.
# Safe to re-run (bootout-then-bootstrap makes it idempotent).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin/wispr-media-pause"
PLIST_SRC="$DIR/io.kierz.wispr-media-pause.plist"
PLIST_DST="$HOME/Library/LaunchAgents/io.kierz.wispr-media-pause.plist"
LABEL="io.kierz.wispr-media-pause"

echo "Compiling..."
mkdir -p "$(dirname "$BIN")"
swiftc -O "$DIR/main.swift" -o "$BIN"

echo "Installing plist..."
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__HOME__#$HOME#g" "$PLIST_SRC" > "$PLIST_DST"

# Forward any extra ./install.sh arguments (e.g. --skip-output AirPods) into
# the plist's ProgramArguments array, one <string> per token, inserted right
# after the binary's own <string> line. Args here are simple flag/value
# tokens (no spaces, no XML metacharacters), so a plain per-token <string>
# insert is safe without escaping gymnastics. Built via a temp file + sed's
# `r` (read-file) command rather than an awk -v string, since macOS awk
# rejects a literal newline embedded in a -v argument.
if [[ $# -gt 0 ]]; then
    EXTRA_ARGS_FILE="$(mktemp)"
    for arg in "$@"; do
        printf '\t\t<string>%s</string>\n' "$arg" >> "$EXTRA_ARGS_FILE"
    done
    sed -i '' "/<string>.*\.local\/bin\/wispr-media-pause<\/string>/r $EXTRA_ARGS_FILE" "$PLIST_DST"
    rm -f "$EXTRA_ARGS_FILE"
fi

echo "Loading LaunchAgent..."
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST_DST"

sleep 1
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    echo "OK: $LABEL is loaded and running."
    echo "Binary: $BIN"
    echo "Log:    $HOME/Library/Logs/wispr-media-pause.log"
    echo ""
    echo "Note: the first dictation with music playing will trigger one-time"
    echo "macOS Automation permission prompts (one per player app) - approve"
    echo "them. Run '$BIN --probe' to check permission/player state now."
else
    echo "WARNING: $LABEL did not come up. Check $HOME/Library/Logs/wispr-media-pause.log" >&2
    exit 1
fi
