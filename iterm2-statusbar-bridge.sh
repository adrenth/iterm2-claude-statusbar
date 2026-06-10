#!/bin/bash
#
# iterm2-statusbar-bridge.sh — the statusLine.command target.
#
# This is the ONLY way to obtain Claude's live rate_limits / context_window data:
# it arrives on stdin precisely because a statusLine command is configured. We use
# that payload solely to feed the iTerm2 status bar writer, and deliberately print
# NOTHING — the in-Claude statusline row is intentionally blank; all stats live in
# the iTerm2 status bar instead.
#
# (Any existing ~/.claude/statusline.sh is no longer called. There is no way to keep
# the stdin payload flowing while fully removing the statusline row, so Claude may
# render a thin empty row — that is expected.)

set -u

# Resolve the writer relative to this script, so the project can live anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITER="${SCRIPT_DIR}/iterm2-statusbar-writer.sh"

input="$(cat)"

# Feed the iTerm2 bar; fully isolated, can never emit anything to the statusline.
printf '%s' "$input" | "$WRITER" >/dev/null 2>&1 || true

# Print nothing: the iTerm2 status bar is the stats surface, not the in-Claude line.
exit 0
