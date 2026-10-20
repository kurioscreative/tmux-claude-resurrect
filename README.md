# tmux-claude-resurrect

Resume Claude Code sessions per-pane when tmux-resurrect restores your environment.

## Problem

tmux-resurrect re-launches programs. It doesn't suspend them. When it restores a pane that was running `claude`, it runs bare `claude`, starting a fresh session. Your conversation history is lost.

Claude Code supports `claude -r <session_id>` to resume a specific conversation. The challenge is mapping each tmux pane to the session ID it was running, and getting tmux-resurrect to actually launch that command.

## How it works

```
                          RUN TIME
                          ────────

  ┌─────────────┐  SessionStart + Stop    ┌──────────────────────────┐
  │ Claude Code  │  claude-pane-stamp.sh   │ ~/.tmux/claude-sessions/ │
  │ (per pane)   │ ──────────────────────► │   %3  → uuid-aaa...      │
  │              │  writes session_id      │   %5  → uuid-bbb...      │
  │              │  keyed by $TMUX_PANE    │   %10 → uuid-ccc...      │
  └─────────────┘  (pane shell's child     └──────────┬───────────────┘
                    claude only)                      │
                                                      │
                          SAVE TIME                   │
                          ─────────                   │
  ┌─────────────┐    post-save hook        ┌──────────▼───────────────┐
  │ resurrect    │ ◄────────────────────── │ claude-resurrect-save.sh │
  │ save file    │  any row whose argv     │   maps pane_id → save    │
  │              │  basename is claude →   │   row, runs              │
  │              │  :claude -r <id>        │   claude-resurrect-      │
  └─────────────┘  (or bare :claude)       │   rewrite.awk            │
                                           └──────────────────────────┘


                         RESTORE TIME
                         ────────────

  ┌─────────────┐    send-keys             ┌──────────────────────────┐
  │ tmux pane    │ ◄────────────────────── │ resurrect restore        │
  │              │  "claude -r uuid-aaa"   │   command starts with    │
  │              │                         │   "claude" → launches it │
  └─────────────┘                          └──────────────────────────┘
```

Three moving parts, plus a check. They ship as two plugins from this one repo, whose only contract is the directory `~/.tmux/claude-sessions/<pane_id>`, so either half can be installed, upgraded or removed on its own:

1. **Claude Code hook `claude-pane-stamp.sh`** (on `SessionStart` and `Stop`, registered by the Claude Code plugin `tmux-pane-stamp`): writes `session_id` to `~/.tmux/claude-sessions/$TMUX_PANE`, but only when the claude that fired it is the pane shell's direct child
2. **tmux-resurrect post-save hook `claude-resurrect-save.sh`** (wired up by the tmux plugin): after each save, maps pane IDs to save-file rows and rewrites every claude row to bare `claude`, with `-r <session_id>` when the pane is stamped
3. **tmux `pane-title-changed` hook** (installed by the tmux plugin): refills empty pane titles, which otherwise corrupt the save file (see [Empty pane titles](#empty-pane-titles-corrupt-the-save-file))
4. **`claude-resurrect-status.sh`**: answers "am I safe to restart?" by reconciling live claude panes against the last save

## Installation

### 1. tmux half (tpm or tempo)

Requires [tmux-plugins/tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect); declare it too, since neither tpm nor tempo can declare a dependency. In `~/.tmux.conf`:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'kurioscreative/tmux-claude-resurrect'
```

Then `prefix + I` (tpm) or `tempo install`. This clones the repo to `~/.tmux/plugins/tmux-claude-resurrect`, and at every server start `claude-resurrect.tmux`:

- appends `claude` to `@resurrect-processes` if it isn't there, keeping your own list (`vim`, `ssh`, ...)
- sets `@resurrect-hook-post-save-all` to its own `claude-resurrect-save.sh`
- installs the `pane-title-changed` refill hook

Nothing else goes in `tmux.conf`. Order relative to tmux-resurrect and tmux-continuum doesn't matter: tmux-resurrect reads these options at save time, not at load time.

### 2. Claude Code half (plugin)

The repo is also a Claude Code marketplace named `tmux-claude-resurrect`, holding one plugin, `tmux-pane-stamp` (plugin names starting with `claude-` are reserved). On Claude Code 2.1.275 or later, one step:

```
/plugin install tmux-pane-stamp --marketplace kurioscreative/tmux-claude-resurrect
```

or from a shell: `claude plugin install tmux-pane-stamp --marketplace kurioscreative/tmux-claude-resurrect`. On older versions, two steps:

```bash
claude plugin marketplace add kurioscreative/tmux-claude-resurrect
claude plugin install tmux-pane-stamp@tmux-claude-resurrect
```

`hooks/hooks.json` registers `claude-pane-stamp.sh` on `SessionStart` and `Stop` via `${CLAUDE_PLUGIN_ROOT}`. Plugin hooks merge with any hooks in `~/.claude/settings.json`, so there is nothing to edit there. Plugins load at session start; in a session that is already running, `/reload-plugins`. Claude Code copies plugins into a versioned cache, so `${CLAUDE_PLUGIN_ROOT}` is not your git clone; that's fine, since the stamp script only writes to `~/.tmux/claude-sessions`.

Requires `jq` on PATH. `Stop` re-stamps on every turn, so sessions that were already running when you installed this register themselves the next time they finish a turn (after `/reload-plugins`). No seeding step, no restarts.

### 3. Refill titles that are already empty

The title hook only fires on a title change. Panes that are empty right now need a one-time fix:

```bash
tmux list-panes -a -F '#{pane_id}	#{pane_title}' | awk -F'\t' '$2==""{print $1}' | xargs -I{} tmux select-pane -t {} -T "$(hostname)"
```

(The separator in the `-F` format is a literal tab.)

### 4. Check

```bash
~/.tmux/plugins/tmux-claude-resurrect/claude-resurrect-status.sh
```

(The path differs if you set `TMUX_PLUGIN_MANAGER_PATH` or keep plugins under the XDG config dir.) Run it after the next save (`prefix + Ctrl-s`, or wait for tmux-continuum's autosave). See [Am I safe to restart?](#am-i-safe-to-restart)

### Optional: a key for the status check

```tmux
set -g @claude-resurrect-status-key 'C-i'
```

With this set, `prefix + Ctrl-i` opens the status check in a floating popup that closes on any key (tmux ≥ 3.2). Unset by default, so the plugin never claims a key on its own. Note that Ctrl-i and Tab are the same byte in a terminal, so this also takes `prefix + Tab`.

### Manual install

Without tpm/tempo, or if you'd rather have `settings.json` entries than a plugin, clone the repo anywhere (say `~/src/tmux-claude-resurrect`). The scripts must stay together: the save hook finds `claude-resurrect-rewrite.awk` via `$(dirname "$0")`.

tmux: add `run-shell ~/src/tmux-claude-resurrect/claude-resurrect.tmux` to `~/.tmux.conf` (anywhere; order doesn't matter), then `tmux source-file ~/.tmux.conf`.

Claude Code: add to the `"hooks"` object in `~/.claude/settings.json`:

```json
"SessionStart": [
  { "hooks": [ { "type": "command", "command": "~/src/tmux-claude-resurrect/claude-pane-stamp.sh" } ] }
],
"Stop": [
  { "hooks": [ { "type": "command", "command": "~/src/tmux-claude-resurrect/claude-pane-stamp.sh" } ] }
]
```

Steps 3 and 4 apply unchanged (with the status script at its clone path).

## File layout

```
.claude-plugin/plugin.json        # Claude Code plugin manifest (tmux-pane-stamp)
.claude-plugin/marketplace.json   # the repo as a one-plugin marketplace (tmux-claude-resurrect)
hooks/hooks.json                  # SessionStart + Stop -> claude-pane-stamp.sh
claude-pane-stamp.sh              # stamp hook (Claude Code half)
claude-resurrect.tmux             # tpm/tempo entry: wires resurrect options + title hook (tmux half)
claude-resurrect-save.sh          # post-save hook
claude-resurrect-rewrite.awk      # row rewrite, called by the save hook
claude-resurrect-status.sh        # restart-safety check
test/run.sh                       # tests
```

Installed, the tmux half lives in `~/.tmux/plugins/tmux-claude-resurrect/`, the Claude Code half in Claude Code's plugin cache, and the only state either writes is `~/.tmux/claude-sessions/` (runtime: session_id per pane_id).

## Am I safe to restart?

`claude-resurrect-status.sh` prints one line per live claude pane, then totals and a verdict:

```
%3     proj:1.1                         aaaaaaaa saved
%5     proj:2.1                         bbbbbbbb NOT IN SAVE (expected if the session is newer than the last autosave)
%10    work:1.2                                  UNSTAMPED (take a turn in this pane; the Stop hook stamps it)

claude panes: 3   saved: 1   not in save: 1   unstamped: 1
last save: tmux_resurrect_20261020T150000.txt   corrupt rows: 0   panes with empty title now: 0
VERDICT: GAP. See the lines above.
```

A pane is **saved** when the last save file's row for it reads `claude -r <id>` with the stamped id. It also counts **corrupt rows** (shifted by an empty title) and panes whose title is empty right now. Exit status is 1 on any gap, so it can gate a script.

This is the check that would have caught the earlier silent breakage, where every save looked fine and nothing was ever restored.

## Internals

### Session storage

Claude Code stores conversations as `<uuid>.jsonl` in `~/.claude/projects/<project-key>/`. The project key is the working directory with both `/` and `.` replaced by `-`:

```
/Users/me/Developer/proj          → -Users-me-Developer-proj
/a/ExampleSite.com/.claude/x      → -a-ExampleSite-com--claude-x
```

The UUID filename is the session ID passed to `claude -r`. Nothing here reads these directories any more; the hook receives `session_id` directly on stdin.

### Save file format

tmux-resurrect writes tab-delimited files with 11 fields per pane line:

```
pane  session_name  window_number  window_active  :window_flags  pane_index  pane_title  :dir  pane_active  pane_command  :full_command
$1    $2            $3             $4             $5             $6          $7          $8    $9           $10           $11
```

The save file lives at `~/.local/share/tmux/resurrect/` (XDG default) unless `@resurrect-dir` is set; both scripts honour it. The post-save hook uses `$2:$3:$6` as the mapping key and rewrites `$11`.

### Why every claude row is rewritten, not just `:claude`

`$11` is the process's argv, not its name. When claude runs through a mise shim, argv is `/Users/<you>/.local/bin/claude`. That breaks two things:

- **Save time**: the original hook matched `$11 == ":claude"` exactly. It never fired.
- **Restore time**: tmux-resurrect only restores a process whose command *starts with* a bare word in `@resurrect-processes`. `/Users/<you>/.local/bin/claude` doesn't start with `claude`, so even an unrewritten row was skipped. Nothing was restored, and nothing reported an error.

`claude-resurrect-rewrite.awk` therefore matches on the **basename of argv's first word** and normalizes every claude row to bare `:claude`, adding `-r <id>` when the pane is stamped. A row that already carries a stale `-r` (e.g. after `/clear` started a new session) gets the current id. Print-mode rows (`-p` / `--print`) are one-shot and left as recorded. The awk is its own file so the test can feed it a fixture without a tmux server.

### Only the pane's own claude may stamp

A nested claude (say, `claude -p` run from a tool call) inherits the same `$TMUX_PANE` and fires the same hooks. Left alone, it would overwrite the pane's stamp with a throwaway session id. `claude-pane-stamp.sh` walks up from its parent to the nearest ancestor whose argv basename is `claude`, and writes only if that process's parent is the pane shell (`#{pane_pid}`).

### Empty pane titles corrupt the save file

Claude Code clears the pane title on exit. tmux-resurrect's `dump_panes` parses `list-panes` output with `IFS=$'\t' read`, and because tab is whitespace to `read`, adjacent tabs collapse. An empty `pane_title` shifts every later field one to the left:

- `dir` lands in `pane_title`
- `history_size` lands in `pane_command` and gets passed to `ps` as a pid
- `full_command` becomes argv of some unrelated process, which can be *another pane's* `claude -r <id>`

Upstream hasn't fixed this. The mitigation needs no fork: the `pane-title-changed` hook that `claude-resurrect.tmux` installs refills an empty title with the hostname, and [installation step 3](#3-refill-titles-that-are-already-empty) fixes panes that are already empty. The hook must be exactly the shape in that script (verified on tmux 3.7c): `#{hook_pane}` and `#{host}` only expand inside `run-shell`, and the `if -F` guard stops the hook from re-firing on its own title change forever. As a backstop, the awk refuses to touch a shifted row (one whose `pane_command` field is all digits), so it never turns garbage into a claude, and the status script counts such rows.

### pane_current_command quirk

tmux reports claude's `pane_current_command` as the version number (e.g., `2.1.37`) from the inner binary path, not `claude`. The scripts never use it, or `ps -o comm`, which has the same problem; they read argv with `ps -o command=` and take the basename of its first word.

### Why not lsof?

Claude Code opens/writes/closes `.jsonl` files per turn, so there is no persistent file descriptor. `lsof` can't reliably catch which session file belongs to which process. The hook approach is deterministic.

### Why the fallback strategy is gone

Earlier versions shipped `claude_session.sh`, a tmux-resurrect strategy that resumed the newest `.jsonl` in the pane's directory. It was removed because:

- It built the project key with `${DIRECTORY//\//-}`, which is wrong for any path containing a `.` (see [Session storage](#session-storage))
- It resumed the *same* newest session in every pane sharing a directory
- With the hook stamping on every `Stop`, there is no unstamped long-lived pane left for it to serve

Dropping it also removes `@resurrect-strategy-claude` and the need for a forked tmux-resurrect branch to host the strategy file.

## Tests

```bash
test/run.sh
```

1. **Rewrite**: runs `claude-resurrect-rewrite.awk` over a fixture in the real save format: absolute-path argv, stale `-r`, print mode, unstamped claude, an nvim path containing "claude", a stamped pane running a shell, and a shifted row from an empty title.
2. **Stamp**: runs `claude-pane-stamp.sh` under a throwaway tmux server (`tmux -L`) with a fake claude, including a nested claude that must not overwrite the stamp. The fake claude is a *symlink* to bash named `claude`, so argv shows `.../claude` the way the real binary does. A *copy* of `/bin/bash` is killed by macOS code-signing enforcement.
3. **Save hook**: runs `claude-resurrect-save.sh` itself against that server, with `@resurrect-dir` pointed at a fixture and the last listed pane holding an empty stamp file, the case that once aborted the hook under `errexit` before it rewrote anything.
4. **Entry script**: runs `claude-resurrect.tmux` twice against that server and checks it appends `claude` to an existing `@resurrect-processes` once, points the post-save hook at the clone, and that the title hook refills a title cleared by the escape sequence.

## Limitations

- **Wrappers**: a claude launched through a wrapper script, so that its parent is not the pane shell, is never stamped and restores as a fresh `claude`
- **Empty titles**: a pane whose title is empty at save time produces a corrupt row until the title is refilled; the hook prevents this going forward, but check `panes with empty title now` in the status output
- **`@resurrect-processes 'claude'` is an exact word match**: the `~claude` (substring) form isn't needed, since every row is normalized to bare `claude`, and would also match e.g. `nvim` editing a path containing "claude"
- **Print-mode (`claude -p`)** sessions are intentionally not restored; they're one-shot commands. The check is on argv as `ps` shows it, so a prompt argument containing ` -p ` also looks like print mode
- **Other flags are dropped**: a row restores as `claude -r <id>` (or bare `claude`), so `--model`, `--permission-mode` and the like are not replayed. An unstamped row that already carries `-r`/`--resume <id>` keeps that target
- **Stale stamps after a server restart**: pane ids start again at `%0`, and stamp files are never pruned. A claude that never stamps (started before the hooks were installed, or through a wrapper) in a reused pane id would be saved with the previous server's session for that id. Every claude started after install stamps on `SessionStart`, so this needs the hooks to be off
- **Panes started directly as claude** (`tmux new-window claude`) have no pane shell, so neither the stamp hook nor the status script sees them; tmux-resurrect cannot restore such panes either
- **tmux-resurrect's own `ps.sh`** matches the pane pid as a prefix (`grep "^${PANE_PID}"`) and lists every child of the pane shell, so `$11` can hold several lines or a background job rather than claude. The status script looks at every child; the rewrite only sees what resurrect recorded
- **Freshness**: a session started after the last save isn't in it yet; the status script reports this as `NOT IN SAVE`

## Dependencies

- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) (upstream; declare it alongside this plugin)
- [tpm](https://github.com/tmux-plugins/tpm) or tempo, or the [manual install](#manual-install)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with plugin support (2.1.275+ for the one-step install)
- `jq`
- `awk`
