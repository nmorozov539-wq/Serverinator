#!/usr/bin/env bash
# Logging: plain tags when not a terminal (logs stay greppable), colour when
# forced, NO_COLOR respected; section/step headers carry the [N/M] counter.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
lib="$REPO_ROOT/core/lib.sh"
esc=$'\e['
out="$(bash -c "source '$lib'; info hello; warn w; ok y" 2>&1)"
assert_not_contains "$out" "$esc" 'no escape codes when piped'
assert_contains "$out" '[INFO]  hello' 'plain INFO tag'
out="$(SERVERINATOR_COLOR=always bash -c "source '$lib'; info hello" 2>&1)"
assert_contains "$out" "$esc" 'colour when forced'
assert_contains "$out" '[INFO]' 'tag text kept inside colour'
out="$(SERVERINATOR_COLOR=never bash -c "source '$lib'; error boom" 2>&1)"
assert_eq '[ERROR] boom' "$out" 'never means plain'
out="$(bash -c "source '$lib'; section 2/5 'Copying files'; step 3/6 'Setting up WireGuard'" 2>&1)"
assert_contains "$out" '[2/5] Copying files' 'section header'
assert_contains "$out" '── [3/6] Setting up WireGuard' 'step header'
longest=0
while IFS= read -r line; do
    n="$(LC_ALL=C.UTF-8 bash -c 'printf %s "${#1}"' _ "$line")"
    ((n > longest)) && longest=$n
done <<< "$out"
[[ "$longest" -le 40 ]] && pass 'headers fit a phone terminal' || failtest "header too wide ($longest)"
exit "$TESTS_FAILED"
