#!/usr/bin/env bash
# Verifies that core-phone.sh functions are safe under `set -e` with DEV=0
# (the production code path), and that genuine failures still abort.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_STATE_DIR="$tmp/state"

echo "Test: phone setup functions return 0 under set -e (DEV=0)"
out="$(SERVERINATOR_DEV=0 \
    SERVERINATOR_CHROOT="$tmp/chroot" \
    SERVERINATOR_SERVICE_D="$tmp/service.d" \
    SERVERINATOR_ARCH_OVERRIDE=aarch64 \
    bash -c 'source "$1"; write_mount_script; echo REACHED_END' \
    _ "$PHONE_SCRIPT" 2>&1)"
rc=$?
assert_eq 0 "$rc" "functions exit 0 with set -e active"
assert_contains "$out" "REACHED_END" "control flow continues past both functions"
assert_file_exists "$tmp/service.d/00-serverinator-mount.sh" "mount script generated"
# wstunnel autostart is written by apply_back_handoff (needs VPS IP), not during setup

echo "Test: calling the functions repeatedly is safe/idempotent"
out2="$(SERVERINATOR_DEV=0 \
    SERVERINATOR_CHROOT="$tmp/chroot" \
    SERVERINATOR_SERVICE_D="$tmp/service.d" \
    bash -c 'source "$1"; write_mount_script; echo AGAIN_OK' \
    _ "$PHONE_SCRIPT" 2>&1)"
rc2=$?
assert_eq 0 "$rc2" "second call exits 0"
assert_contains "$out2" "AGAIN_OK" "second call completes"

echo "Test: genuinely failing command still aborts under set -e"
out3="$(SERVERINATOR_DEV=0 \
    SERVERINATOR_CHROOT="$tmp/chroot" \
    SERVERINATOR_SERVICE_D="$tmp/service.d" \
    bash -c 'source "$1"; definitely_not_a_real_command_xyz; echo SHOULD_NOT_REACH' \
    _ "$PHONE_SCRIPT" 2>&1)"
rc3=$?
if [[ "$rc3" -ne 0 ]]; then
    pass "real failure propagates (rc=$rc3)"
else
    failtest "real failure did not abort the shell"
fi
assert_not_contains "$out3" "SHOULD_NOT_REACH" "shell stopped at the failing command"

exit "$TESTS_FAILED"
