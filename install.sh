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

current="$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)"
if [ "$current" = "$NEW_CMD" ]; then
  ok "settings.json already points at the wrapper (idempotent no-op)"
elif [ -n "$current" ]; then
  fail "statusLine.command is already set to '$current'."
  info "Not overwriting it. Clear it and re-run, or set statusLine.command to: $NEW_CMD"
  exit 1
else
  # statusLine.command is unset/empty — safe to set (the common case).
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${SETTINGS}.bak-${stamp}"
  cp "$SETTINGS" "$backup" && ok "backed up settings.json -> $(basename "$backup")"

  # Surgical: jq sets only the one value; key order is preserved (insertion order).
  tmp="$(mktemp)"
  if jq --arg cmd "$NEW_CMD" '.statusLine.command = $cmd' "$SETTINGS" > "$tmp" 2>/dev/null \
     && jq empty "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$SETTINGS"
    ok "repointed statusLine.command -> wrapper"
  else
    rm -f "$tmp"
    fail "edit produced invalid JSON — restoring backup"
    cp "$backup" "$SETTINGS"
    exit 1
  fi
fi

echo
echo "Scripted install complete. Remaining MANUAL steps (see README.md):"
echo "  1. iTerm2 → Settings → General → Magic → enable \"Python API\""
echo "  2. Restart iTerm2, accept the runtime download + script API-access prompts"
echo "  3. Settings → Profiles → Session → Status bar → Configure → add \"Claude Status\""
echo "  4. Set the component's static color in that config UI"
