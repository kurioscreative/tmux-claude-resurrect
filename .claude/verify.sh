#!/bin/bash
# .claude/verify.sh <quick|full> — exit 0 when shippable.
# The whole suite takes a few seconds and needs no network, so quick and
# full are the same run; quick only skips when nothing has changed.
mode="${1:-quick}"
cd "$(dirname "$0")/.." || exit 1
[ -z "$(git status --porcelain)" ] && [ "$mode" = quick ] && exit 0
test/run.sh 2>&1 | tail -40
exit "${PIPESTATUS[0]}"
