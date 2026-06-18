# Claude Code status bar for iTerm2

A native iTerm2 status bar component that shows, **per pane**, the Claude Code
context-window usage and 5h/7d rate limits for the Claude session running in that
pane. The in-Claude statusline row is intentionally left blank — all stats live in
the iTerm2 status bar instead.

```
✳ Opus · xhigh · ctx 23% · 5h 41% 2h13m · 7d 60% 3d4h  (a live Claude pane)
No Claude Session                                      (a pane with no live Claude session)
```

## Why it's built this way

iTerm2's status bar runs at the app level and **cannot read a running Claude Code
instance's data**. The live `rate_limits` / `context_window` data exists *only* in
the JSON Claude pipes to its `statusLine` command — it is not in hook payloads and
not persisted to disk. So we sit in the statusLine path and bridge the data out to a
small per-pane state file that the iTerm2 component reads.

```
Claude Code ──stdin JSON──► iterm2-statusbar-bridge.sh   (the statusLine.command)
                               │  prints NOTHING (in-Claude statusline row is blank)
                               └─► iterm2-statusbar-writer.sh ─► $TMPDIR/iterm2-claude-statusbar/<paneUUID>.json
                                                                        ▲
                                          iterm2_claude_statusbar.py (iTerm2 AutoLaunch daemon)
                                          reads its pane's file, checks liveness ─► status bar
```

- **The in-Claude statusline is intentionally blank.** The wrapper exists only to
  receive Claude's stdin payload (the sole source of live rate-limit data) and feed
  the writer; it prints nothing, so the iTerm2 bar is the only stats surface. Any
  existing `~/.claude/statusline.sh` is no longer called (and never modified).
  Only your own `settings.json` changes (the `statusLine.command` value).
- **Per pane** via two keys: the iTerm2 pane UUID names the state file; the Claude
  `session_id` stored inside it drives liveness.
- **Liveness is process-based, not age-based.** The component resolves the
  `session_id` to a PID via `~/.claude/sessions/*.json` and checks `os.kill(pid, 0)`.
  So it flips to "No Claude Session" within ~3s of Claude exiting, but never during a
  long tool call (which can legitimately run many minutes with no statusline refresh).

## Install

### 1. Scripted part

Clone this repo anywhere, then run the installer from inside it:

```bash
git clone https://github.com/adrenth/iterm2-claude-statusbar.git
cd iterm2-claude-statusbar
./install.sh
```

This is idempotent. It verifies `jq`/`python3`, creates the dirs, symlinks the
component into iTerm2's AutoLaunch folder, and surgically repoints
`settings.json`'s `statusLine.command` at the wrapper (with a timestamped backup,
JSON validation before and after, and auto-restore on any failure). The installer
derives all paths from its own location, so the project can live anywhere — it does
**not** have to be under `~/Packages/`.

### 2. Manual part (GUI-only — this is where people get stuck)

1. **iTerm2 → Settings → General → Magic → enable "Python API".** (Off by default.)
2. **Restart iTerm2.** On first launch it will:
   - offer to **download the Python runtime** (`iterm2env`) — accept;
   - prompt that *iterm2_claude_statusbar.py* wants **API access** — allow.
3. **Settings → Profiles → Session →** enable the **Status bar**, click
   **Configure Status Bar**, and drag **"Claude Status"** into the layout.
4. In that same config panel, set **Text Color** to **`#d9774e`** (the Claude orange;
   RGB 217, 119, 78). This is iTerm2's shared status-bar text color — a component
   cannot set it from code, so it must be done here once. It's a single static color
   (inline per-value coloring isn't possible via the iTerm2 API).

That's it. Open a pane, run `claude`, and the bar shows live stats.

## How it behaves

- **Always visible.** A pane with no live Claude session shows `No Claude Session`
  (shrinking to `No Claude` / `—` in a narrow bar).
- **Stale hint.** If Claude is alive but its data hasn't refreshed in >30s (e.g. a
  long tool call), a subtle `⋯` is appended. The numbers stay shown; the bar does
  **not** blank.
- **Refresh.** The component re-renders every 3s (`update_cadence`). The statusline
  itself stays event-driven (no `refreshInterval`).
- **Multiple panes** each show their own session's stats simultaneously.

## Editing / reloading

The AutoLaunch entry is a **symlink** to `iterm2_claude_statusbar.py` in this folder, so
edit it here. The running daemon does **not** hot-reload: after editing, restart it
via **iTerm2 → Scripts menu** (re-run it) or restart iTerm2. Errors are logged to
`$TMPDIR/iterm2-claude-statusbar/component.log`; iTerm2's Script Console
(Scripts → Manage → Console) also shows daemon output.

## Files

| File | Role |
|------|------|
| `iterm2-statusbar-bridge.sh` | The `statusLine.command`. Feeds the writer from stdin and prints nothing (blank in-Claude line). |
| `iterm2-statusbar-writer.sh` | Extracts fields from the statusLine JSON, writes the per-pane state file. |
| `iterm2_claude_statusbar.py` | iTerm2 AutoLaunch component. Reads the state file, checks liveness, renders. |
| `install.sh` | Idempotent installer (dirs, symlink, settings.json repoint). |

State lives in `$TMPDIR/iterm2-claude-statusbar/` (transient; auto-cleared on reboot).

## Couplings & limitations

- **The in-Claude statusline row is blank, and stats only exist in iTerm2.** The
  wrapper prints nothing, so inside Claude there is no statusline (Claude may render a
  thin empty row — there is no way to fully remove it while keeping the stdin payload
  the writer needs). In any non-iTerm2 terminal (SSH, Terminal.app, VS Code) there is
  **no stats surface at all** — the bar is iTerm2-only. Any prior `statusline.sh` is
  no longer the data source; restoring the in-Claude line means pointing
  `statusLine.command` back at it.
- **settings.json can be reverted.** If something else rewrites your `settings.json`
  (a dotfiles sync, a corporate config push), `statusLine.command` may revert away
  from the wrapper: the in-Claude line reappears and the iTerm2 bar stops updating.
  **First troubleshooting step:** confirm
  `statusLine.command` still points at `iterm2-statusbar-bridge.sh`; re-run `install.sh`.
- **tmux is a non-goal.** Under tmux the iTerm2 pane UUID is shared across panes, so
  the writer **skips** writing when `$TMUX` is set (prevents wrong-pane attribution).
- **SSH-to-remote is out of scope.** A remote Claude writes its state on the remote
  host; your local component can't read it.
- **Recycled-PID edge (accepted).** Liveness matches `sessionId` in `sessions/*.json`
  then checks the PID. Claude is observed to delete that file on exit, so this is
  reliable in practice. The only theoretical false-positive: Claude leaves a stale
  `sessions/*.json` AND that exact PID is recycled to an unrelated process. Not
  defended against (would reintroduce age fragility); noted here for completeness.
- **No inline color, and no code-set color.** The iTerm2 API returns plain text only.
  Status bar text color is iTerm2's built-in shared **Text Color** field, set in the
  config UI; a component's own ColorKnob does **not** paint the rendered text, and the
  API cannot read or default the shared field. So `#d9774e` is a one-time manual step,
  not a shipped default. There is intentionally no per-value severity glyph.

## Roadmap

- **v2:** click the component to open a popover (`async_open_popover`) with the full
  breakdown including **session cost** (captured in the state file, not rendered
  inline). The model name and effort level are shown inline as separate segments
  (leftmost, e.g. `Opus · xhigh`); effort drops first when the bar narrows, then the
  model. Effort is omitted for models that don't support it.
