#!/usr/bin/env bash
# Am I safe to restart? One line per live claude pane, then a verdict.
#
# A pane is "saved" when the last tmux-resurrect save file carries
# `claude -r <id>` for it, with <id> the session id stamped by
# claude-pane-stamp.sh. Exit 1 on any gap so this is scriptable.

set -uo pipefail

RESURRECT_DIR=$(tmux show-option -gqv @resurrect-dir 2>/dev/null)
: "${RESURRECT_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect}"
last="$RESURRECT_DIR/$(readlink "$RESURRECT_DIR/last" 2>/dev/null)"
[[ -f "$last" ]] || { echo "no tmux-resurrect save found in $RESURRECT_DIR"; exit 1; }

SESSION_DIR="$HOME/.tmux/claude-sessions"
procs=$(ps -o ppid=,command=)   # one snapshot: ppid then argv
total=0 saved=0 unstamped=0 unsaved=0

while read -r pane loc ppid; do
    # The pane runs claude when the pane shell's child is claude. argv's
    # first word may be an absolute path; `comm` would be the version number.
    cmd=$(awk -v p="$ppid" '$1 == p { print $2; exit }' <<<"$procs")
    [[ "$(basename "${cmd:-/}")" == claude ]] || continue
    total=$((total + 1))
    sid=$(cat "$SESSION_DIR/$pane" 2>/dev/null)
    row=$(awk -F'\t' -v k="$loc" '$1 == "pane" && $2 ":" $3 "." $6 == k { print $11; exit }' "$last")
    if [[ -z "$sid" ]]; then
        state="UNSTAMPED (take a turn in this pane; the Stop hook stamps it)"
        unstamped=$((unstamped + 1))
    elif [[ "$row" == *"-r $sid"* ]]; then
        state="saved"
        saved=$((saved + 1))
    else
        state="NOT IN SAVE (expected if the session is newer than the last autosave)"
        unsaved=$((unsaved + 1))
    fi
    printf '%-6s %-32s %-8s %s\n' "$pane" "$loc" "${sid:0:8}" "$state"
done < <(tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index} #{pane_pid}')

# A row whose pane_command field is all digits is a shifted row: tmux-resurrect
# collapses an empty pane_title under `IFS=tab read`, so history_size lands there.
corrupt=$(awk -F'\t' '$1 == "pane" && $10 ~ /^[0-9]+$/' "$last" | wc -l | tr -d ' ')
empty_titles=$(tmux list-panes -a -F '#{pane_title}' | grep -c '^$')

echo
echo "claude panes: $total   saved: $saved   not in save: $unsaved   unstamped: $unstamped"
echo "last save: $(basename "$last")   corrupt rows: $corrupt   panes with empty title now: $empty_titles"
if (( total == saved && corrupt == 0 )); then
    echo "VERDICT: OK. A restart restores every claude pane."
else
    echo "VERDICT: GAP. See the lines above."
    exit 1
fi
