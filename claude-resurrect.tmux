#!/usr/bin/env bash
# tmux plugin entry point (run by tpm/tempo at every server start).
# Wires tmux-resurrect to this plugin's scripts. Idempotent on config reload.
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# tmux-resurrect restores only processes listed here. Append rather than set,
# so a user's own list (vim, ssh, ...) survives whatever order tmux.conf uses.
procs=$(tmux show-option -gqv @resurrect-processes)
case " $procs " in
    *" claude "*) ;;
    *) tmux set-option -g @resurrect-processes "${procs:+$procs }claude" ;;
esac

tmux set-option -g @resurrect-hook-post-save-all "$CURRENT_DIR/claude-resurrect-save.sh"

# Claude Code clears the pane title on exit, and an empty title shifts every
# field of that pane's row in the resurrect save file (tmux-resurrect parses
# with `IFS=tab read`, which collapses adjacent tabs). Refill it immediately.
# Formats only expand inside run-shell, and the if-guard stops the re-fire.
tmux set-hook -g pane-title-changed "if -F '#{pane_title}' '' \"run-shell 'tmux select-pane -t #{hook_pane} -T #{host}'\""

# Optional key (prefix table) that opens the status check in a floating popup,
# e.g. `set -g @claude-resurrect-status-key 'C-i'`. Unset by default so the
# plugin never claims a key on its own. display-popup needs tmux >= 3.2.
key=$(tmux show-option -gqv @claude-resurrect-status-key)
if [ -n "$key" ]; then
    tmux bind-key "$key" display-popup -E -w 90% -h 70% "'$CURRENT_DIR/claude-resurrect-status.sh' --pause"
fi
