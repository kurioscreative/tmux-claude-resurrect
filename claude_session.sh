#!/usr/bin/env bash
# Fallback strategy: resumes the most recent claude session for the directory.
# Used when the SessionStart hook didn't write a session ID file.

ORIGINAL_COMMAND="$1"
DIRECTORY="$2"

# Don't restore print-mode sessions
[[ "$ORIGINAL_COMMAND" =~ \ -p(\ |$) || "$ORIGINAL_COMMAND" =~ \ --print(\ |$) ]] && exit 0

# Already has -r with a session ID, pass through
[[ "$ORIGINAL_COMMAND" =~ \ -r\  ]] && echo "$ORIGINAL_COMMAND" && exit 0

# Find the most recent session file for this directory
project_key="${DIRECTORY//\//-}"
project_dir="$HOME/.claude/projects/${project_key}"

if [[ -d "$project_dir" ]]; then
    latest=$(ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
        echo "claude -r $(basename "$latest" .jsonl)"
        exit 0
    fi
fi

echo "claude"
