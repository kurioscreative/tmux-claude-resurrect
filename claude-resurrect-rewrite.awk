#!/usr/bin/env -S awk -f
# Rewrites claude pane rows of a tmux-resurrect save file. Kept separate from
# the hook so the test can feed it a fixture without a tmux server.
#
# Usage: claude-resurrect-rewrite.awk -v mapfile=<key=sid lines> <save file>
#   key is "session_name:window_index:pane_index"
#
# Row layout (tab-separated): $1 "pane", $2 session, $3 window, $6 pane index,
# $11 ":"-prefixed full command. Only pane rows whose command's basename is
# claude are touched; print-mode (`-p`/`--print`) runs are one-shot and left
# alone, which tmux-resurrect then ignores because the path form never matches.
BEGIN {
    FS = "\t"; OFS = "\t"
    if (mapfile != "") {
        while ((getline line < mapfile) > 0) {
            eq = index(line, "=")
            if (eq > 0) map[substr(line, 1, eq - 1)] = substr(line, eq + 1)
        }
    }
}
# A row whose pane_command ($10) is all digits is a shifted row: tmux-resurrect
# collapses an empty pane_title under `IFS=tab read`, so pane_pid lands in $10
# and $11 is the argv of whatever process history_size happens to name. Never
# turn that into a claude. (A real claude row has a version string there.)
$1 == "pane" && $10 !~ /^[0-9]+$/ {
    cmd = substr($11, 2)
    split(cmd, words, " ")
    n = split(words[1], parts, "/")
    if (parts[n] == "claude" && cmd !~ /(^| )(-p|--print)( |$)/) {
        key = $2 ":" $3 ":" $6
        if (key in map)
            $11 = ":claude -r " map[key]
        else if (match(cmd, /(^| )(-r|--resume) [^ ]+/)) {
            # Unstamped but already resuming (restored before the hook existed):
            # keep that target rather than starting a fresh session.
            split(substr(cmd, RSTART, RLENGTH), r, " ")
            $11 = ":claude -r " r[2]
        } else
            $11 = ":claude"
    }
}
{ print }
