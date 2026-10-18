#!/usr/bin/env bash
# --help and --version on every entry point.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ver="$(bash -c 'source "$1"; echo "$SERVERINATOR_VERSION"' _ "$REPO_ROOT/core/lib.sh")"
[[ "$ver" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]; assert_eq 0 "$?" 'version looks like a date'
export SERVERINATOR_DEV=1 SERVERINATOR_SERVICE_D=/nonexistent
for s in "$REPO_ROOT/serverinator.sh" "$PHONE_SCRIPT" "$VPS_SCRIPT"; do
    n="${s##*/}"
    assert_eq "ServerInator $ver" "$(bash "$s" --version 2>&1)" "$n --version"
    out="$(bash "$s" --help 2>&1)"; rc=$?
    assert_eq 0 "$rc" "$n --help succeeds"
    assert_contains "$out" "$n" "$n --help shows its usage"
    assert_not_contains "$out" '───' "$n --help has no rule lines"
done
for w in phone chroot vps; do
    assert_eq "ServerInator $ver" "$(bash "$REPO_ROOT/core/si" "$w" version 2>&1)" "si version ($w)"
done
exit "$TESTS_FAILED"
