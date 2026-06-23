# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native iTerm2 status bar component showing per-pane Claude Code context % and 5h/7d
rate limits. The whole project exists to solve one constraint: **iTerm2's status bar
runs at the app level and cannot read a running Claude Code instance's data.** The
live `rate_limits` / `context_window` data is available *only* in the JSON Claude
pipes to its `statusLine` command — not in hook payloads, not persisted to disk. So
the data is bridged out of the statusLine path into a per-pane file the iTerm2 daemon
reads. Read `README.md` for the user-facing install/behavior; this file is the
architecture and the gotchas that aren't obvious from any single file.

Re-verified against Anthropic docs (mid-2026): the 5h/7d **subscription** windows have
no API or on-disk source. The `anthropic-ratelimit-*` response headers and the Admin
Usage/Cost API are a *different* limit system (per-API-key token buckets / historical
usage), not the Pro/Max 5h/7d windows — do not chase them as a "more accurate" source;
that path is dead. The only freshness lever is making Claude re-render the statusLine
more often (`refreshInterval`, set by `install.sh` — see below).

## Data flow (the big picture)

```
Claude Code --stdin JSON--> iterm2-statusbar-bridge.sh   (the statusLine.command in ~/.claude/settings.json)
                               |  prints NOTHING (in-Claude statusline row is intentionally blank)
                               '-> iterm2-statusbar-writer.sh -> $TMPDIR/iterm2-claude-statusbar/<paneUUID>.json
                                                                  ^
                                          iterm2_claude_statusbar.py (iTerm2 AutoLaunch daemon) reads its pane's file
```

Three processes, two of them transient (wrapper + writer, spawned per statusline
render) and one long-lived (the Python daemon). They communicate **only** through the
state file in `$TMPDIR/iterm2-claude-statusbar/`. There is no other IPC.

Claude renders the statusLine only on discrete events (new message, `/compact`, mode
change), so without help the state file goes stale during idle/long turns. `install.sh`
therefore sets `statusLine.refreshInterval` (seconds, min 1; we ship `10`) in
`settings.json`, which re-runs the bridge on a fixed timer on top of those events. This
keeps the usage % / reset countdown fresh during idle periods; whether the timer also
fires *during* a long tool call is undocumented (idle gap closed, busy gap
probable-but-unverified). The data-age segment `⦿Ns` (`now - written_at`, see `_render`)
surfaces this directly: it ticks up per second and resets on refresh, so a high `⦿`
value during a busy turn is the visible symptom of the busy gap.

The wrapper does **not** call any existing `~/.claude/statusline.sh` — it prints
nothing. Its sole job is to receive Claude's stdin payload (the only source of live
rate-limit data) and feed the writer. The in-Claude statusline is deliberately blank;
all stats live in the iTerm2 bar. (To restore the in-Claude line, repoint
`statusLine.command` back at your own statusline script.)

## Hard constraints — do not violate without re-reading the design

- **Never edit `~/.claude/statusline.sh`.** It may be managed elsewhere (e.g. a
  dotfiles repo or a corporate sync). We no longer call it at all (the wrapper prints
  nothing), but it must remain untouched in case the user repoints
  `statusLine.command` back at it. The only file we change in `~/.claude/` is the
  user's own `settings.json` (the `statusLine.command` and `statusLine.refreshInterval`
  values), done surgically by `install.sh`.
- **The wrapper must stay a silent, total data-feed.** It captures stdin, pipes it to
  the writer with output suppressed (`>/dev/null 2>&1 || true`), and prints nothing on
  its own stdout. Any change must preserve empty stdout — if the wrapper ever prints,
  that text becomes the in-Claude statusline row.
- **`iterm2_claude_statusbar.py`'s `coro()` must never raise.** It is the callback of a
  `run_forever` daemon; an unhandled exception kills the whole status bar. The body is
  wrapped in `try/except Exception` returning `NO_SESSION` and logging. Keep it total.
- **Liveness is PID-based, not file-age.** Do not "simplify" it to a staleness
  timeout. Real Claude turn gaps were measured at up to 844s (long tool calls), so age
  cannot distinguish "busy" from "exited". The component resolves `state.session_id` ->
  `~/.claude/sessions/*.json` by matching `.sessionId` -> `os.kill(pid, 0)`. File age
  drives only the cosmetic `⦿Ns` data-age segment (`now - written_at`, via `_fmt_age`),
  never the hard "No Claude Session".

## Two-key model (why there are two identifiers)

- **iTerm2 pane UUID** = `${ITERM_SESSION_ID##*:}` in the writer; the same value the
  component gets via `iterm2.Reference("id")`. Names the state file (file<->pane join).
- **Claude `session_id`** = taken from the statusLine stdin JSON, stored *inside* the
  file. Drives liveness (file<->process join). Note the confusing-but-correct naming
  in `iterm2_claude_statusbar.py`: the `coro` parameter `session_id=iterm2.Reference("id")` is
  actually the **pane UUID** (used for the filename); the Claude session id is
  `state.get("session_id")` read from the file.

## Testing without a live iTerm2

The Python daemon can't run outside iTerm2 (needs the `iterm2` module + a live
connection), but its logic is pure and unit-testable by **stubbing the `iterm2`
module** before import, then loading the file via `importlib`:

```python
import sys, types, importlib.util, time
stub = types.ModuleType("iterm2")
stub.Reference = lambda *a, **k: None
stub.StatusBarComponent = lambda *a, **k: None
stub.StatusBarRPC = lambda f: f
stub.run_forever = lambda f: None
sys.modules["iterm2"] = stub
spec = importlib.util.spec_from_file_location("cs", "iterm2_claude_statusbar.py")
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
# now test cs._render(state), cs._fmt_time(secs), cs._session_alive(session_id)
```

Shell pieces are tested by piping a sample statusLine JSON payload:
- **Writer:** `ITERM_SESSION_ID=w0t1p0:TEST printf '%s' "$SAMPLE" | ./iterm2-statusbar-writer.sh`
  then inspect `$TMPDIR/iterm2-claude-statusbar/TEST.json`. Set `TMUX=x` to confirm the guard
  produces no file; unset `ITERM_SESSION_ID` to confirm the no-op.
- **Bridge:** `ITERM_SESSION_ID=w0t1p0:T printf '%s' "$SAMPLE" | ./iterm2-statusbar-bridge.sh` must print **nothing** to stdout and write `$TMPDIR/iterm2-claude-statusbar/T.json`.
- Syntax: `bash -n *.sh` and `python3 -c "import ast; ast.parse(open('iterm2_claude_statusbar.py').read())"`.

`_session_alive("<a real running session id>")` returns True when that Claude is
running — the cheapest end-to-end liveness check available outside iTerm2. Find a live
id under `~/.claude/sessions/*.json` (each has `pid`, `sessionId`, `status`).

## Reload / install

- `install.sh` is idempotent: prerequisites check, dir creation, AutoLaunch symlink,
  and a surgical `settings.json` repoint (validate -> backup -> replace only the exact
  expected value -> re-validate -> auto-restore on failure). Safe to re-run.
- The AutoLaunch entry is a **symlink** to `iterm2_claude_statusbar.py` here, so edit in
  place — but the running daemon does **not** hot-reload. After editing it, restart via
  iTerm2's Scripts menu (or restart iTerm2). Errors go to
  `$TMPDIR/iterm2-claude-statusbar/component.log` and iTerm2's Script Console.
- `~/Library/Application Support/iTerm2` may be reached via a `~/.config/iterm2/AppSupport`
  symlink — same directory, not a second install location.

## Scope boundaries (intentional non-goals)

tmux (writer skips when `$TMUX` is set — shared pane UUID would clobber), SSH-to-remote
(state written on the wrong host), and inline ANSI color (iTerm2 API returns plain text
only; text color is iTerm2's built-in shared "Text Color" field, set in the UI to
`#d9774e` — a component's own ColorKnob does NOT paint the text and the API cannot set
or default the shared field, so this is a documented manual step, not shipped). Model
is rendered inline
(leftmost, first to drop under width pressure); cost is captured in the state file but
not rendered — a v2 click-popover is the planned consumer.
