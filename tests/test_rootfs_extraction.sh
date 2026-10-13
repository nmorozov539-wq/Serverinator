#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service"
source "$PHONE_SCRIPT"; set +e
mkdir -p "$CHROOT"
scenario=broken
tar() {
 case "$scenario" in
  broken) echo 'tar: Unexpected EOF in archive' >&2; return 2;;
  incomplete) return 0;;
  warning|valid)
   mkdir -p "$CHROOT/bin" "$CHROOT/usr/bin" "$CHROOT/etc"
   touch "$CHROOT/bin/sh" "$CHROOT/usr/bin/env" "$CHROOT/usr/bin/dpkg" "$CHROOT/etc/os-release"
   if [[ "$scenario" == warning ]]; then echo "tar: Removing leading '/' from member names" >&2; fi;;
 esac
}
chroot_run() { return 0; }
for scenario in broken incomplete warning valid; do
 rc=0; (extract_rootfs "$tmp/archive") > "$tmp/out" 2>&1 || rc=$?
 if [[ "$scenario" == broken || "$scenario" == incomplete ]]; then expected=1; else expected=0; fi
 assert_eq "$expected" "$rc" "rootfs $scenario handled"
done
exit "$TESTS_FAILED"
