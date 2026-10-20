#!/usr/bin/env bash
# Tests for tmux-claude-resurrect. Run: test/run.sh
#   1. rewrite: feeds a save file in tmux-resurrect's real format through the awk.
#   2. stamp:   runs the hook under a throwaway tmux server with a fake claude,
#               including a nested claude that must not overwrite the stamp.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
fail=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; fail=1; }
T=$'\t'

# ---------- 1. rewrite ----------
tmp=$(mktemp -d); trap 'rm -rf "$tmp"; tmux -L "claude-resurrect-test-$$" kill-server 2>/dev/null' EXIT
cat > "$tmp/map" <<MAP
proj:1:1=aaaaaaaa-0000-0000-0000-000000000001
proj:2:1=bbbbbbbb-0000-0000-0000-000000000002
proj:3:1=cccccccc-0000-0000-0000-000000000003
proj:6:1=dddddddd-0000-0000-0000-000000000006
MAP
row() { printf 'pane\tproj\t%s\t0\t:\t%s\t%s\t:/Users/me/proj\t1\t%s\t:%s\n' "$@"; }
{
  row 1 1 'title' 2.1.304 '/Users/me/.local/bin/claude'              # stamped, absolute path
  row 2 1 'title' 2.1.304 '/Users/me/.local/bin/claude -r old-id'    # stamped after /clear: id must change
  row 3 1 'title' 2.1.304 '/Users/me/.local/bin/claude -p "hi"'      # print mode: untouched
  row 4 1 'title' 2.1.304 '/Users/me/.local/bin/claude'              # unstamped: bare claude
  row 5 1 'title' nvim    'nvim /tmp/claude-501/x/.claude/notes.md'  # not claude
  row 6 1 'title' zsh     ''                                         # stamped but running a shell
  # shifted row from an empty pane_title: $10 is history_size, $11 is garbage
  printf 'pane\tproj\t7\t0\t:\t1\t:/Users/me/proj\t1\tzsh\t9648\t:/Users/me/.local/bin/claude -r ghost\n'
  printf 'window\tproj\t1\t:w\t1\t:*\tlayout\toff\n'
} > "$tmp/save"
./claude-resurrect-rewrite.awk -v mapfile="$tmp/map" "$tmp/save" > "$tmp/out"
f11() { awk -F'\t' -v w="$1" '$1=="pane" && $3==w {print $11}' "$tmp/out"; }
[[ "$(f11 1)" == ':claude -r aaaaaaaa-0000-0000-0000-000000000001' ]] && ok "absolute path rewritten to claude -r <id>" || bad "absolute path: $(f11 1)"
[[ "$(f11 2)" == ':claude -r bbbbbbbb-0000-0000-0000-000000000002' ]] && ok "stale -r replaced by the stamped id" || bad "stale -r: $(f11 2)"
[[ "$(f11 3)" == ':/Users/me/.local/bin/claude -p "hi"' ]]        && ok "print mode left alone" || bad "print mode: $(f11 3)"
[[ "$(f11 4)" == ':claude' ]]                                     && ok "unstamped claude normalized to bare claude" || bad "unstamped: $(f11 4)"
[[ "$(f11 5)" == ':nvim /tmp/claude-501/x/.claude/notes.md' ]]    && ok "non-claude command untouched" || bad "nvim: $(f11 5)"
[[ "$(f11 6)" == ':' ]]                                           && ok "stamped shell pane untouched" || bad "shell: $(f11 6)"
[[ "$(f11 7)" == ':/Users/me/.local/bin/claude -r ghost' ]]       && ok "shifted row left alone" || bad "shifted: $(f11 7)"
[[ "$(grep -c '' "$tmp/out")" == 8 ]]                              && ok "row count preserved" || bad "row count"
[[ "$(tail -1 "$tmp/out")" == "$(tail -1 "$tmp/save")" ]]         && ok "window row untouched" || bad "window row"

# ---------- 2. stamp hook under a throwaway tmux server ----------
S="claude-resurrect-test-$$"
home="$tmp/home"; mkdir -p "$home" "$tmp/bin" "$tmp/nested"
# A fake claude must show `.../claude` as argv[0], as the real Mach-O binary does,
# so it is a symlink to bash named claude running a body script (a copy of
# /bin/bash is killed by macOS code-signing enforcement).
ln -s /bin/bash "$tmp/bin/claude"; ln -s /bin/bash "$tmp/nested/claude"
cat > "$tmp/outer.sh" <<SH
printf '{"session_id":"outer-session"}' | "$ROOT/claude-pane-stamp.sh"
sh -c '"$tmp/nested/claude" "$tmp/inner.sh"'
touch "$tmp/done"
SH
cat > "$tmp/inner.sh" <<SH
printf '{"session_id":"inner-session"}' | "$ROOT/claude-pane-stamp.sh"
SH
tmux -L "$S" -f /dev/null new-session -d -s t -x 80 -y 24
tmux -L "$S" send-keys -t t "HOME='$home' '$tmp/bin/claude' '$tmp/outer.sh'" Enter
for _ in $(seq 1 50); do [[ -f "$tmp/done" ]] && break; sleep 0.1; done
pane=$(tmux -L "$S" display -p -t t '#{pane_id}')
stamp=$(cat "$home/.tmux/claude-sessions/$pane" 2>/dev/null)
[[ -f "$tmp/done" ]] && ok "fake claude ran in the pane" || bad "fake claude never finished"
[[ "$stamp" == "outer-session" ]] && ok "pane stamped by the top-level claude, nested claude ignored" || bad "stamp is '$stamp'"

echo; [[ $fail == 0 ]] && echo "all tests passed" || { echo "some tests FAILED"; exit 1; }
