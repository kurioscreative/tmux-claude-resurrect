#!/usr/bin/env bash
# tmux-resurrect post-save hook: rewrites every claude pane in the save file so
# tmux-resurrect restores `claude -r <session_id>` instead of a fresh claude.
# Session ids come from ~/.tmux/claude-sessions/<pane_id>, written by
# claude-pane-stamp.sh (a Claude Code SessionStart/Stop hook).
#
# Why rewrite at all: the save file records the full argv, which on this machine
# is `$HOME/.local/bin/claude` (a mise shim execs by absolute path), and
# tmux-resurrect only restores a process whose command *starts with* the bare
# word listed in @resurrect-processes. So every claude row is normalized to a
# bare `claude`, with `-r <id>` when the pane is stamped.

set -euo pipefail

SESSION_DIR="$HOME/.tmux/claude-sessions"

# Resolve the resurrect save directory (respects @resurrect-dir if set)
RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null)
: "${RESURRECT_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect}"
[[ -d "$RESURRECT_DIR" ]] || exit 0

LAST="$RESURRECT_DIR/last"
[[ -L "$LAST" || -f "$LAST" ]] || exit 0

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
        if [[ -f "$sf" ]]; then
            sid=$(cat "$sf")
            [[ -n "$sid" ]] && echo "${sess}:${win}:${pane_idx}=${sid}"
        fi
    done > "$MAPPING"
fi

"$(dirname "$0")/claude-resurrect-rewrite.awk" -v mapfile="$MAPPING" "$SAVE_FILE" > "$TEMP"

mv "$TEMP" "$SAVE_FILE"
