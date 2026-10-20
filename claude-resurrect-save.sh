#!/usr/bin/env bash
# tmux-resurrect post-save hook: rewrites every claude pane in the save file so
# tmux-resurrect restores `claude -r <session_id>` instead of a fresh claude.
# Session ids come from ~/.tmux/claude-sessions/<pane_id>, written by
# claude-pane-stamp.sh (a Claude Code SessionStart/Stop hook).
#
# Why rewrite at all: the save file records the full argv, which on this machine
# is `/Users/ge/.local/bin/claude` (a mise shim execs by absolute path), and
# tmux-resurrect only restores a process whose command *starts with* the bare
# word listed in @resurrect-processes. So every claude row is normalized to a
# bare `claude`, with `-r <id>` when the pane is stamped.

set -euo pipefail

SESSION_DIR="$HOME/.tmux/claude-sessions"

# Resolve the save directory the way tmux-resurrect does: @resurrect-dir with
# ~ and $HOME expanded, else ~/.tmux/resurrect if it exists, else the XDG path.
RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null | sed "s,\$HOME,$HOME,g; s,~,$HOME,g")
if [[ -z "$RESURRECT_DIR" ]]; then
    RESURRECT_DIR="$HOME/.tmux/resurrect"
    [[ -d "$RESURRECT_DIR" ]] || RESURRECT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
fi
[[ -d "$RESURRECT_DIR" ]] || exit 0

LAST="$RESURRECT_DIR/last"   # tmux-resurrect always writes this as a symlink
[[ -L "$LAST" ]] || exit 0

SAVE_FILE="$RESURRECT_DIR/$(readlink "$LAST")"
[[ -f "$SAVE_FILE" ]] || exit 0

# Build mapping: "session_name:window:pane_idx" -> claude_session_id
MAPPING=$(mktemp)
TEMP=$(mktemp)
trap 'rm -f "$MAPPING" "$TEMP"' EXIT

if [[ -d "$SESSION_DIR" ]]; then
    tmux list-panes -a -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_id}' 2>/dev/null |
    while IFS='|' read -r sess win pane_idx pane_id; do
        sf="$SESSION_DIR/$pane_id"
        # `|| true` keeps an empty stamp (mid-write, or a stamp that vanished
        # between the test and the read) from failing the loop under errexit.
        sid=$(cat "$sf" 2>/dev/null || true)
        [[ -z "$sid" ]] || echo "${sess}:${win}:${pane_idx}=${sid}"
    done > "$MAPPING"
fi

"$(dirname "$0")/claude-resurrect-rewrite.awk" -v mapfile="$MAPPING" "$SAVE_FILE" > "$TEMP"

mv "$TEMP" "$SAVE_FILE"
