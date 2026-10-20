#!/usr/bin/env bash
# Rewrites tmux-resurrect save file with per-pane claude session IDs.
# Reads from ~/.tmux/claude-sessions/<pane_id>, written by Claude Code's SessionStart hook.

set -euo pipefail

SESSION_DIR="$HOME/.tmux/claude-sessions"
[[ -d "$SESSION_DIR" ]] || exit 0

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

tmux list-panes -a -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_id}' 2>/dev/null |
while IFS='|' read -r sess win pane_idx pane_id; do
    sf="$SESSION_DIR/$pane_id"
    if [[ -f "$sf" ]]; then
        sid=$(cat "$sf")
        [[ -n "$sid" ]] && echo "${sess}:${win}:${pane_idx}=${sid}"
    fi
done > "$MAPPING"

[[ -s "$MAPPING" ]] || exit 0

# Rewrite: bare ":claude" or ":claude -c" -> ":claude -r <session_id>"
awk -F'\t' -v OFS='\t' -v mapfile="$MAPPING" '
BEGIN {
    while ((getline line < mapfile) > 0) {
        eq = index(line, "=")
        key = substr(line, 1, eq - 1)
        val = substr(line, eq + 1)
        map[key] = val
    }
}
{
    if ($1 == "pane") {
        key = $2 ":" $3 ":" $6
        if (key in map && ($11 == ":claude" || $11 == ":claude -c")) {
            $11 = ":claude -r " map[key]
        }
    }
    print
}
' "$SAVE_FILE" > "$TEMP"

mv "$TEMP" "$SAVE_FILE"
