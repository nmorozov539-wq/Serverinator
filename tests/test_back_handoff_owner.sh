#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export SERVERINATOR_DEV=0
source "$VPS_SCRIPT"
set +e

echo "Test: sudo invocation publishes back-handoff to the invoking user"
SUDO_USER=vpsuser
id() {
    case "$1" in
        -u) printf '%s\n' 1234 ;;
        -g) printf '%s\n' 2345 ;;
        *) return 2 ;;
    esac
}
chown() { printf '%s\n' "$*" > "$tmp/chown-call"; }

rc=0
set_back_handoff_owner /tmp/back-handoff.json > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" "owner publication helper succeeds"
assert_file_exists "$tmp/chown-call" "owner change requested"
if [[ -f "$tmp/chown-call" ]]; then
    assert_eq "1234:2345 /tmp/back-handoff.json" "$(cat "$tmp/chown-call")" \
        "back-handoff assigned to sudo caller"
fi

echo "Test: direct root invocation keeps root ownership"
SUDO_USER=root
rm -f "$tmp/chown-call"
rc=0
set_back_handoff_owner /tmp/back-handoff.json > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" "root publication helper succeeds"
assert_file_missing "$tmp/chown-call" "direct root ownership unchanged"

exit "$TESTS_FAILED"
