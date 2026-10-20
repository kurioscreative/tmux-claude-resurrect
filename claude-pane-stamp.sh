#!/usr/bin/env bash
# Claude Code hook (SessionStart + Stop): records this pane's session id at
# ~/.tmux/claude-sessions/<pane_id> so claude-resurrect-save.sh can rewrite the
# tmux-resurrect save file to `claude -r <id>`.
#
# Only the claude whose parent is the pane's shell counts. A nested claude
# (e.g. `claude -p` run from a tool call) inherits the same $TMUX_PANE and would
# otherwise overwrite the file with its own throwaway session id.
#
# Always exits 0: a hook failure must never break Claude Code.

[ -n "$TMUX_PANE" ] || exit 0
pane_pid=$(tmux display -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null) || exit 0

# Walk up from the hook's parent to the nearest ancestor whose command is claude.
# `ps -o command=` shows argv, whose first word may be an absolute path (a mise
# shim execs it that way); `comm` would show the version number instead.
p=$PPID
while [ "${p:-0}" -gt 1 ]; do
    cmd=$(ps -o command= -p "$p" 2>/dev/null); cmd=${cmd%% *}
    [ "$(basename "${cmd:-/}")" = claude ] && break
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done
[ "${p:-0}" -gt 1 ] || exit 0

# That claude must be the pane shell's direct child.
[ "$(ps -o ppid= -p "$p" | tr -d ' ')" = "$pane_pid" ] || exit 0

sid=$(jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
mkdir -p "$HOME/.tmux/claude-sessions"
printf '%s\n' "$sid" > "$HOME/.tmux/claude-sessions/$TMUX_PANE"
exit 0
