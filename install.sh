#!/bin/bash
#
# install.sh — idempotent installer for the Claude Code iTerm2 status bar.
#
# Scriptable parts only. The GUI-gated steps (enable iTerm2 Python API, accept the
# runtime download, add the component to a profile's status bar) are in README.md and
# must be done by hand.
#
# What this does:
#   - verify jq + python3
#   - create the state dir and the iTerm2 AutoLaunch dir
#   - symlink iterm2_claude_statusbar.py into AutoLaunch (project = source of truth)
#   - surgically repoint settings.json statusLine.command at the wrapper
#     (validate -> backup -> replace only the exact expected value -> re-validate ->
#      auto-restore on failure). Idempotent.

set -u

# The project lives wherever this script is — derive it, so the install is portable.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="${HOME}/.claude/settings.json"
AUTOLAUNCH="${HOME}/Library/Application Support/iTerm2/Scripts/AutoLaunch"
STATE_DIR="${TMPDIR:-/tmp}/iterm2-claude-statusbar"

# settings.json stores statusLine.command as a string Claude Code tilde-expands, so
# collapse a $HOME prefix back to ~ (clones outside $HOME stay absolute).
case "$PROJECT_DIR" in
  "$HOME"/*) BRIDGE_CMD="~${PROJECT_DIR#"$HOME"}/iterm2-statusbar-bridge.sh" ;;
  *)         BRIDGE_CMD="$PROJECT_DIR/iterm2-statusbar-bridge.sh" ;;
esac

NEW_CMD="$BRIDGE_CMD"

# Claude renders the statusLine only on discrete events (new message, /compact, mode
# change), so the bridge — and thus our state file — can go stale during idle periods
# and long tool calls. refreshInterval (seconds, min 1) re-runs the command on a fixed
# timer on top of those events, keeping the 5h/7d usage % and reset countdown fresh.
# 10s clears the component's 30s staleness marker with room to spare while staying above
# the daemon's own 3s render cadence (anything shorter is invisible at the iTerm2 side).
REFRESH_INTERVAL=10

ok()   { printf '  \033[01;32mPASS\033[00m %s\n' "$1"; }
fail() { printf '  \033[01;31mFAIL\033[00m %s\n' "$1"; }
info() { printf '  \033[01;34m••••\033[00m %s\n' "$1"; }

echo "Claude Code iTerm2 status bar — installer"
echo

# --- Prerequisites -----------------------------------------------------------
fatal=0
if command -v jq >/dev/null 2>&1; then ok "jq found"; else fail "jq not found (brew install jq)"; fatal=1; fi
if command -v python3 >/dev/null 2>&1; then ok "python3 found"; else fail "python3 not found"; fatal=1; fi
if [ "$fatal" -ne 0 ]; then echo; echo "Aborting: install prerequisites first."; exit 1; fi

# --- Permissions on our scripts ----------------------------------------------
chmod +x "$PROJECT_DIR/iterm2-statusbar-bridge.sh" "$PROJECT_DIR/iterm2-statusbar-writer.sh" 2>/dev/null
ok "scripts marked executable"

# --- Directories -------------------------------------------------------------
mkdir -p "$STATE_DIR" && ok "state dir: $STATE_DIR"
mkdir -p "$AUTOLAUNCH" && ok "iTerm2 AutoLaunch dir ready"

# --- Symlink the component into AutoLaunch -----------------------------------
LINK="$AUTOLAUNCH/iterm2_claude_statusbar.py"
TARGET="$PROJECT_DIR/iterm2_claude_statusbar.py"
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$TARGET" ]; then
  ok "component symlink already in place"
elif [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  fail "$LINK exists and is not our symlink — leaving it alone, please inspect"
else
  ln -sf "$TARGET" "$LINK" && ok "symlinked component into AutoLaunch"
fi

# --- Patch settings.json (surgical + safe) -----------------------------------
echo
if [ ! -f "$SETTINGS" ]; then
  fail "settings.json not found at $SETTINGS — skipping repoint"
  echo; echo "Done (settings.json untouched)."; exit 0
fi

if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  fail "settings.json is not strict JSON — refusing to edit. Repoint statusLine.command manually."
  exit 1
fi

# Apply one surgical jq filter to settings.json with the project's safety contract:
# backup -> set -> re-validate -> auto-restore on failure. $1 is the jq program; any
# further args are passed through to jq (e.g. --arg/--argjson bindings).
apply_settings() {
  local filter="$1"; shift
  local stamp backup tmp
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${SETTINGS}.bak-${stamp}"
  cp "$SETTINGS" "$backup" && ok "backed up settings.json -> $(basename "$backup")"

  tmp="$(mktemp)"
  if jq "$@" "$filter" "$SETTINGS" > "$tmp" 2>/dev/null && jq empty "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$SETTINGS"
    return 0
  fi
  rm -f "$tmp"
  fail "edit produced invalid JSON — restoring backup"
  cp "$backup" "$SETTINGS"
  exit 1
}

current="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)"
if [ "$current" = "$NEW_CMD" ]; then
  # Command is already ours; make sure refreshInterval is set/correct too, so a setup
  # installed before this option existed gets the timer on a re-run. null compares unequal.
  current_ri="$(jq -r '.statusLine.refreshInterval // empty' "$SETTINGS" 2>/dev/null)"
  if [ "$current_ri" = "$REFRESH_INTERVAL" ]; then
    ok "settings.json already points at the wrapper (refreshInterval=$REFRESH_INTERVAL; idempotent no-op)"
  else
    apply_settings '.statusLine.refreshInterval = $ri' --argjson ri "$REFRESH_INTERVAL"
    ok "set statusLine.refreshInterval -> $REFRESH_INTERVAL"
  fi
elif [ -n "$current" ]; then
  fail "statusLine.command is already set to '$current'."
  info "Not overwriting it. Clear it and re-run, or set statusLine.command to: $NEW_CMD"
  exit 1
else
  # statusLine.command is unset/empty — safe to set (the common case). One jq sets both
  # the command (string) and refreshInterval (--argjson -> JSON number); key order is
  # preserved (insertion order).
  apply_settings '.statusLine.command = $cmd | .statusLine.refreshInterval = $ri' \
    --arg cmd "$NEW_CMD" --argjson ri "$REFRESH_INTERVAL"
  ok "repointed statusLine.command -> wrapper (refreshInterval=$REFRESH_INTERVAL)"
fi

echo
echo "Scripted install complete. Remaining MANUAL steps (see README.md):"
echo "  1. iTerm2 → Settings → General → Magic → enable \"Python API\""
echo "  2. Restart iTerm2, accept the runtime download + script API-access prompts"
echo "  3. Settings → Profiles → Session → Status bar → Configure → add \"Claude Status\""
echo "  4. Set the component's static color in that config UI"
