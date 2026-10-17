#!/usr/bin/env bash
# serverinator.sh with its input ended before a question is answered: it says
# which answer is missing and how to pass it, instead of quitting silently.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_COLOR=never SERVERINATOR_IDENTITY_DIR="$tmp/identity" \
    SERVERINATOR_STATE_DIR="$tmp/state"
orch="$REPO_ROOT/serverinator.sh"

rc=0; out="$(bash "$orch" < /dev/null 2>&1)" || rc=$?
assert_eq 1 "$rc" 'no VPS answer fails'
assert_contains "$out" 'No answer to "VPS address"' 'names the VPS question'
assert_contains "$out" '--vps user@host' 'says how to pass the VPS'

rc=0; out="$(bash "$orch" --vps root@1.2.3.4 < /dev/null 2>&1)" || rc=$?
assert_eq 1 "$rc" 'no device name fails'
assert_contains "$out" '--device-name NAME' 'says how to pass the device name'

mkdir -p "$tmp/identity"; echo rn9p > "$tmp/identity/device-name"
rc=0; out="$(bash "$orch" --vps root@1.2.3.4 < /dev/null 2>&1)" || rc=$?
assert_contains "$out" '--device-name rn9p' 'suggests the saved device name'

# A last line without a newline still counts as an answer.
rm -rf "$tmp/identity"
rc=0; out="$(printf 'rn9p' | bash "$orch" --vps root@1.2.3.4 2>&1)" || rc=$?
assert_contains "$out" 'No answer to "SSH alias"' 'unterminated answer accepted, next question named'
assert_contains "$out" '--alias rn9p' 'alias hint uses the device name'

exit "$TESTS_FAILED"
