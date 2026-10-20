# tmux-claude-resurrect

Resume Claude Code sessions per-pane when tmux-resurrect restores your environment.

## Problem

tmux-resurrect re-launches programs — it doesn't suspend them. When it restores a pane that was running `claude`, it runs bare `claude`, starting a fresh session. Your conversation history is lost.

Claude Code supports `claude -r <session_id>` to resume a specific conversation. The challenge is mapping each tmux pane to the session ID it was running.

## How it works

```
                          SAVE TIME
                          ─────────

  ┌─────────────┐    SessionStart hook    ┌──────────────────────────┐
  │ Claude Code  │ ──────────────────────► │ ~/.tmux/claude-sessions/ │
  │ (per pane)   │    writes session_id    │   %3  → uuid-aaa...     │
  │              │    keyed by $TMUX_PANE  │   %5  → uuid-bbb...     │
  └─────────────┘                          │   %10 → uuid-ccc...     │
                                           └──────────┬───────────────┘
                                                      │
  ┌─────────────┐    post-save hook        ┌──────────▼───────────────┐
  │ resurrect    │ ◄────────────────────── │ claude-resurrect-save.sh │
  │ save file    │    rewrites :claude     │   maps pane_id → save   │
  │              │    to :claude -r <id>   │   file entry, rewrites  │
  └─────────────┘                          └──────────────────────────┘


                         RESTORE TIME
                         ────────────

  ┌─────────────┐    send-keys             ┌──────────────────────────┐
  │ tmux pane    │ ◄────────────────────── │ resurrect restore        │
  │              │    "claude -r uuid-aaa" │   reads rewritten save   │
  │              │                          │   file, launches per-pane│
  └─────────────┘                          └──────────────────────────┘
```

Three components:

1. **Claude Code `SessionStart` hook** — fires on every session start/resume, writes `session_id` to `~/.tmux/claude-sessions/$TMUX_PANE`
2. **tmux-resurrect post-save hook** — after each save, maps pane IDs to save file entries and rewrites `:claude` → `:claude -r <session_id>`
3. **Strategy file (fallback)** — if no hook file exists for a pane, picks the most recent session by file mtime

## Installation

### 1. Claude Code SessionStart hook

Add to `~/.claude/settings.json` inside the `"hooks"` object:

```json
"SessionStart": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "[ -n \"$TMUX_PANE\" ] && mkdir -p \"$HOME/.tmux/claude-sessions\" && jq -r '.session_id' > \"$HOME/.tmux/claude-sessions/$TMUX_PANE\"; exit 0"
      }
    ]
  }
]
```

Requires `jq` on PATH.

### 2. Post-save hook script

Copy `claude-resurrect-save.sh` to `~/.tmux/hooks/` and make it executable:

```bash
cp claude-resurrect-save.sh ~/.tmux/hooks/
chmod +x ~/.tmux/hooks/claude-resurrect-save.sh
```

### 3. Strategy file (fallback)

Copy into your tmux-resurrect strategies directory:

```bash
cp claude_session.sh ~/.tmux/plugins/tmux-resurrect/strategies/
chmod +x ~/.tmux/plugins/tmux-resurrect/strategies/claude_session.sh
```

### 4. tmux.conf

Add before the `run-shell` line for tmux-resurrect:

```tmux
set -g @resurrect-processes 'claude'
set -g @resurrect-strategy-claude 'session'
set -g @resurrect-hook-post-save-all '~/.tmux/hooks/claude-resurrect-save.sh'
```

Then reload: `tmux source-file ~/.tmux.conf`

### 5. Seed existing sessions

The hook writes on session start. Existing running sessions won't have tracking files until restarted. Either wait for natural turnover or restart your claude sessions once.

## File layout

```
~/.claude/settings.json                    # SessionStart hook (step 1)
~/.tmux/hooks/claude-resurrect-save.sh     # post-save hook (step 2)
~/.tmux/plugins/tmux-resurrect/strategies/claude_session.sh  # fallback (step 3)
~/.tmux.conf                               # 3 config lines (step 4)
~/.tmux/claude-sessions/                   # runtime: session_id per pane_id
```

## Internals

### Session storage

Claude Code stores conversations as `<uuid>.jsonl` in `~/.claude/projects/<project-key>/`. The project key is the working directory with `/` replaced by `-`:

```
/Users/me/Developer/proj → -Users-me-Developer-proj
```

The UUID filename is the session ID passed to `claude -r`.

### Save file format

tmux-resurrect writes tab-delimited files with 11 fields per pane line:

```
pane  session_name  window_number  window_active  :window_flags  pane_index  pane_title  :dir  pane_active  pane_command  :full_command
$1    $2            $3             $4             $5             $6          $7          $8    $9           $10           $11
```

The post-save hook uses `$2:$3:$6` as the mapping key and rewrites `$11`.

### pane_current_command quirk

tmux reports claude's `pane_current_command` as the version number (e.g., `2.1.37`) from the inner binary path, not `claude`. However, the save file's `full_command` ($11) comes from `ps -ao ppid,args` on the shell PID, which correctly captures `claude` as the shell's direct child.

### Why not lsof?

Claude Code opens/writes/closes `.jsonl` files per turn — no persistent file descriptor. `lsof` can't reliably catch which session file belongs to which process. The `SessionStart` hook approach is deterministic.

### Fallback strategy

The strategy file at `strategies/claude_session.sh` is invoked by tmux-resurrect's built-in strategy mechanism (same pattern as `nvim_session.sh`). It receives `(original_command, directory)` and returns the command to execute. It picks the most recent `.jsonl` by mtime — works for the single-session-per-directory case but can't distinguish multiple sessions in the same directory.

## Limitations

- **`claude -p` (print mode)** sessions are intentionally not restored — they're one-shot commands
- **Strategy file location**: lives inside the tmux-resurrect plugin directory, which could be overwritten by plugin updates (though `claude_session.sh` doesn't exist upstream)
- **Requires `jq`**: the SessionStart hook parses JSON input with jq

## Dependencies

- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (with hooks support)
- `jq`
- `awk`
