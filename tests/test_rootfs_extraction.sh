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

# A half-extracted rootfs looked installed and was skipped on the next run.
echo "Test: an interrupted rootfs install is redone, not skipped"
bootstrap() { # CHROOT -> prints what happened
    SERVERINATOR_DEV=0 SERVERINATOR_YES=1 SERVERINATOR_CHROOT="$1" SERVERINATOR_SERVICE_D="$tmp/svc" \
        bash -c 'source "$1"; set +e; ARCH=aarch64
            debootstrap_missing=1; command() { [[ "$2" == debootstrap ]] && return 1; builtin command "$@"; }
            curl() { echo DOWNLOAD; : > "${@: -1}"; }
            verify_download() { :; }
            extract_rootfs() { mkdir -p "$CHROOT/bin" "$CHROOT/usr/bin" "$CHROOT/etc"
                touch "$CHROOT/bin/sh" "$CHROOT/usr/bin/env" "$CHROOT/usr/bin/dpkg" "$CHROOT/etc/os-release"; }
            bootstrap_chroot' _ "$PHONE_SCRIPT" 2>&1
}
mkdir -p "$tmp/partial/bin"
out="$(bootstrap "$tmp/partial")"
assert_contains "$out" 'is incomplete' 'partial chroot detected'
assert_contains "$out" 'DOWNLOAD' 'rootfs installed again'
assert_file_exists "$tmp/partial/.serverinator-rootfs-complete" 'marker written after success'
out="$(bootstrap "$tmp/partial")"
assert_not_contains "$out" 'DOWNLOAD' 'complete chroot is skipped next time'
mkdir -p "$tmp/legacy/bin" "$tmp/legacy/usr/bin" "$tmp/legacy/etc"
touch "$tmp/legacy/bin/sh" "$tmp/legacy/usr/bin/env" "$tmp/legacy/usr/bin/dpkg" "$tmp/legacy/etc/os-release"
out="$(bootstrap "$tmp/legacy")"
assert_not_contains "$out" 'DOWNLOAD' 'chroot from before the marker is accepted'
assert_file_exists "$tmp/legacy/.serverinator-rootfs-complete" 'and marked'

exit "$TESTS_FAILED"
