#!/usr/bin/env python3
"""
iterm2_claude_statusbar.py — iTerm2 AutoLaunch status bar component.

Shows, per pane, the Claude Code context % and 5h/7d rate limits for the Claude
session running in that pane. Reads the per-pane state file written by
iterm2-statusbar-writer.sh; resolves liveness from ~/.claude/sessions/*.json (PID, not
file age). Always visible: shows "No Claude Session" when no live session is found.

Design notes (see the project plan for the full rationale):
  - update_cadence=3.0: re-render every 3s so "No Claude Session" appears within
    ~3s of Claude exiting, and reset countdowns tick. The statusline itself stays
    event-driven; this timer is independent.
  - Liveness is PID-based: state.session_id -> sessions/*.json by .sessionId ->
    os.kill(pid, 0). File age never blanks the bar (only PID death does); age only
    drives a cosmetic "stale" marker.
  - coro() is TOTAL: it must never raise, or it would crash the run_forever daemon.
    Everything is wrapped; any error degrades to "No Claude Session" and is logged.
"""

import json
import os
import time

import iterm2

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("TMPDIR", "/tmp"), "iterm2-claude-statusbar")
SESSIONS_DIR = os.path.join(HOME, ".claude", "sessions")
LOG_PATH = os.path.join(STATE_DIR, "component.log")

STALE_SECONDS = 30          # older than this (but PID alive) -> append the "⋯" marker
STALE_MARKER = " ⋯"

# Prefixed to live-session output only (not "No Claude Session"), so the glyph means
# "a Claude is running in this pane". iTerm2 returns plain text, so this is a Unicode
# mark (U+2733), rendered monochrome in the component's text color — not a logo image.
ICON_PREFIX = "✳ "

# Width-graded empty/error states (iTerm2 picks the longest that fits).
NO_SESSION = ["No Claude Session", "No Claude", "—"]


def _log(msg):
    """Best-effort diagnostic log; never raises."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG_PATH, "a") as fh:
            fh.write("[{}] {}\n".format(time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


def _fmt_time(secs):
    """Mirror of the shell fmt_time: 2h13m / 3d4h / 45m."""
    secs = int(secs)
    if secs <= 0:
        return ""
    days = secs // 86400
    hours = (secs % 86400) // 3600
    mins = (secs % 3600) // 60
    if days > 0:
        return "{}d{}h".format(days, hours)
    if hours > 0:
        return "{}h{}m".format(hours, mins)
    return "{}m".format(mins)


def _session_alive(session_id):
    """
    True iff a ~/.claude/sessions/*.json carries this session_id AND its pid is
    alive. Matching on session_id (not raw pid) guards against PID recycling.
    Claude is observed to delete the sessions file on exit, so "no match" = dead.
    """
    if not session_id:
        return False
    try:
        names = os.listdir(SESSIONS_DIR)
    except OSError:
        return False
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(SESSIONS_DIR, name)) as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            continue
        if meta.get("sessionId") != session_id:
            continue
        pid = meta.get("pid")
        if not isinstance(pid, int):
            return False
        try:
            os.kill(pid, 0)  # signal 0 = existence check, no signal sent
            return True
        except OSError:
            return False
    return False


def _render(state):
    """Build the width-graded inline list from a live state dict. ctx -> 5h -> 7d."""
    now = int(time.time())

    model = state.get("model")
    model_str = model if isinstance(model, str) and model else None

    ctx = state.get("ctx_pct")
    ctx_str = "ctx {}%".format(ctx) if isinstance(ctx, int) else None

    def limit_str(window, label):
        if not isinstance(window, dict):
            return None, None
        pct = window.get("pct")
        if not isinstance(pct, int):
            return None, None
        resets_at = window.get("resets_at")
        countdown = ""
        if isinstance(resets_at, (int, float)) and resets_at > now:
            countdown = _fmt_time(resets_at - now)
        short = "{} {}%".format(label, pct)
        full = "{} {}".format(short, countdown) if countdown else short
        return full, short

    five_full, five_short = limit_str(state.get("five_hour"), "5h")
    seven_full, seven_short = limit_str(state.get("seven_day"), "7d")

    # If we have literally nothing to show, fall back to the empty state.
    if ctx_str is None and five_short is None and seven_short is None:
        return NO_SESSION

    sep = " · "

    def join(parts):
        return sep.join(p for p in parts if p)

    candidates = [
        join([model_str, ctx_str, five_full, seven_full]),  # full: model + reset countdowns
        join([ctx_str, five_full, seven_full]),     # drop model (first to go when tight)
        join([ctx_str, five_short, seven_short]),    # drop reset times
        join([ctx_str, five_short]),                 # drop 7d
        ctx_str or five_short or seven_short,         # most essential single field
    ]
    # De-dup while preserving order (e.g. when reset times were absent).
    seen = set()
    options = []
    for c in candidates:
        if c and c not in seen:
            seen.add(c)
            options.append(c)

    # Cosmetic staleness marker: PID alive but data hasn't refreshed in a while.
    written_at = state.get("written_at")
    if isinstance(written_at, (int, float)) and (now - written_at) > STALE_SECONDS:
        options = [o + STALE_MARKER for o in options]

    # Prefix the Claude mark on live output only. The two NO_SESSION early-returns
    # above (and coro's no-session path) deliberately stay un-prefixed.
    options = [ICON_PREFIX + o for o in options]

    return options or NO_SESSION


async def main(connection):
    # No color knob: a component's own ColorKnob does NOT paint the rendered text
    # (verified empirically — the text stayed default-colored). Status bar text color
    # is governed solely by iTerm2's built-in shared "Text Color" field, which the
    # Python API cannot read, set, or default. So color is a documented manual step
    # (set the built-in Text Color to #d9774e); see README. Declaring a dead knob here
    # would only collide visually with that built-in field.
    component = iterm2.StatusBarComponent(
        short_description="Claude Status",
        detailed_description="Per-pane Claude Code model, context % and 5h/7d rate limits",
        knobs=[],
        exemplar="✳ Opus · ctx 23% · 5h 41% · 7d 60%",
        update_cadence=3.0,
        identifier="adrenth.iterm2.claude-statusbar",
    )

    @iterm2.StatusBarRPC
    async def coro(knobs, session_id=iterm2.Reference("id")):
        # TOTAL: must never raise — a crash here would kill the daemon.
        try:
            if not session_id:
                return NO_SESSION
            path = os.path.join(STATE_DIR, "{}.json".format(session_id))
            try:
                with open(path) as fh:
                    state = json.load(fh)
            except (OSError, ValueError):
                return NO_SESSION

            sid = state.get("session_id")
            if not _session_alive(sid):
                # Dead / no matching live process -> blank and clean up the file.
                try:
                    os.unlink(path)
                except OSError:
                    pass
                return NO_SESSION

            return _render(state)
        except Exception as exc:  # noqa: BLE001 — daemon must survive anything
            _log("coro error: {!r}".format(exc))
            return NO_SESSION

    await component.async_register(connection, coro)


iterm2.run_forever(main)
