#!/bin/bash
#
# iterm2-statusbar-writer.sh — extracts Claude Code statusLine data from stdin JSON and
# writes a small per-pane state file that the iTerm2 component reads.
#
# Invoked synchronously by iterm2-statusbar-bridge.sh with the statusLine stdin payload.
# All output is suppressed and all failures are swallowed by the caller; this script
# must never break the printed statusline. See the plan for the full design.
#
# State file: ${TMPDIR:-/tmp}/iterm2-claude-statusbar/<paneUUID>.json
#   keyed by the iTerm2 pane UUID (file->pane join), with session_id inside it
#   (file->liveness join, resolved by the component via ~/.claude/sessions/*.json).

set -u

# --- Guards: only write when running in a real, non-multiplexed iTerm2 pane ---

# Not under iTerm2 (no pane UUID to key by) -> no-op.
[ -n "${ITERM_SESSION_ID:-}" ] || exit 0

# Under tmux/screen the iTerm2 pane UUID is shared across multiplexer panes, so
# multiple Claude sessions would clobber the same file. Skip writing entirely.
[ -z "${TMUX:-}" ] || exit 0

# iTerm2 pane UUID is the part after the colon: "w0t1p0:UUID" -> "UUID".
uuid="${ITERM_SESSION_ID##*:}"
[ -n "$uuid" ] || exit 0

dir="${TMPDIR:-/tmp}/iterm2-claude-statusbar"
mkdir -p "$dir" 2>/dev/null || exit 0

# --- Extract the fields we need in a single jq pass over stdin ---
# Absent rate-limit windows (non-Claude.ai plans) come through as null and are
# dropped by the component; we still emit the keys for a stable schema.
payload="$(
  jq -c '{
    ctx_pct:        ((.context_window.used_percentage // null) | if . == null then null else floor end),
    five_hour:      (if .rate_limits.five_hour then {
                       pct:       (.rate_limits.five_hour.used_percentage | floor),
                       resets_at: .rate_limits.five_hour.resets_at
                     } else null end),
    seven_day:      (if .rate_limits.seven_day then {
                       pct:       (.rate_limits.seven_day.used_percentage | floor),
                       resets_at: .rate_limits.seven_day.resets_at
                     } else null end),
    model:          (.model.display_name // null),
    cost_usd:       (.cost.total_cost_usd // null),
    session_id:     (.session_id // null)
  }' 2>/dev/null
)"

# Bad/empty JSON -> bail without touching any file.
[ -n "$payload" ] || exit 0

# Stamp freshness (cosmetic staleness marker in the component; liveness is PID-based).
now="$(date +%s)"
out="$(printf '%s' "$payload" | jq -c --argjson written_at "$now" '. + {written_at: $written_at}' 2>/dev/null)"
[ -n "$out" ] || exit 0

# --- Atomic write: temp file in the SAME dir (same fs) then mv ---
tmp="$(mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || exit 0
printf '%s\n' "$out" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dir/$uuid.json" 2>/dev/null
rm -f "$tmp" 2>/dev/null

exit 0
