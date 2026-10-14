#!/usr/bin/env bash
# Chroot /tmp choice: tmpfs (boot mount) or disk (periodic cleaner script).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/svc" SERVERINATOR_STATE_DIR="$tmp/state"
source "$PHONE_SCRIPT"; set +e
mount_script="$tmp/svc/00-serverinator-mount.sh"
cleaner="$tmp/svc/40-serverinator-tmpclean.sh"

echo "Test: disk mode writes a cleaner and no tmpfs mount"
CHROOT_TMP_MODE=disk; resolve_chroot_tmp_mode > /dev/null
write_mount_script > /dev/null; write_tmpclean_autostart > /dev/null
assert_not_contains "$(cat "$mount_script")" 'mount -t tmpfs' 'no tmpfs mount in disk mode'
assert_file_exists "$cleaner" 'cleaner script written'
assert_contains "$(cat "$cleaner")" '-mtime +7 -atime +7' 'only old, unused files are removed'
assert_contains "$(cat "$cleaner")" '-xdev' 'cleaner stays on the /tmp filesystem'
assert_eq disk "$(cat "$tmp/state/chroot-tmp-mode")" 'choice remembered'

echo "Test: the remembered choice is the default on the next run"
CHROOT_TMP_MODE=""; resolve_chroot_tmp_mode > /dev/null
assert_eq disk "$CHROOT_TMP_MODE" 'previous choice reused'

echo "Test: switching to tmpfs mounts at boot and removes the cleaner"
CHROOT_TMP_MODE=tmpfs; CHROOT_TMP_SIZE=512M; resolve_chroot_tmp_mode > /dev/null
write_mount_script > /dev/null; write_tmpclean_autostart > /dev/null
assert_contains "$(cat "$mount_script")" 'mount -t tmpfs -o size=512M,mode=1777,nosuid,nodev tmpfs' 'tmpfs boot mount'
assert_contains "$(cat "$mount_script")" 'mountpoint -q "${CHROOT}/tmp" ||' 'boot mount is idempotent'
assert_file_missing "$cleaner" 'cleaner removed in tmpfs mode'

echo "Test: invalid values are refused"
rc=0; (CHROOT_TMP_MODE=ramdisk; resolve_chroot_tmp_mode) > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'unknown mode rejected'
rc=0; (CHROOT_TMP_MODE=tmpfs; CHROOT_TMP_SIZE='256M;reboot'; resolve_chroot_tmp_mode) > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'unsafe size rejected'

echo "Test: first-install default follows RAM"
total_ram_mb() { echo 2048; }; assert_eq disk "$(default_chroot_tmp_mode)" '2 GB phone -> disk'
total_ram_mb() { echo 8192; }; assert_eq tmpfs "$(default_chroot_tmp_mode)" '8 GB phone -> tmpfs'

if command -v dash > /dev/null; then
    CHROOT_TMP_MODE=disk; write_tmpclean_autostart > /dev/null
    for f in "$mount_script" "$cleaner"; do dash -n "$f"; assert_eq 0 "$?" "POSIX syntax: $(basename "$f")"; done
fi
exit "$TESTS_FAILED"
