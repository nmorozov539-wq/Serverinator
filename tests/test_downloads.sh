#!/usr/bin/env bash
# Downloads: architecture names, and the pinned SHA-256 hash each one is checked against.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# The VPS can be x86_64 or ARM; an unknown machine must stop, not fetch a wrong binary.
echo "Test: VPS wstunnel architecture mapping"
for pair in x86_64:amd64 aarch64:arm64 arm64:arm64 armv7l:armv7; do
    got="$(SERVERINATOR_VPS_ARCH="${pair%%:*}" bash -c 'source "$1"; wstunnel_vps_suffix' _ "$VPS_SCRIPT" 2>/dev/null)"
    assert_eq "${pair##*:}" "$got" "uname ${pair%%:*} -> ${pair##*:}"
done
rc=0; SERVERINATOR_VPS_ARCH=mips bash -c 'source "$1"; wstunnel_vps_suffix' _ "$VPS_SCRIPT" > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'unknown architecture refused'

echo "Test: downloads are checked against pinned SHA-256 hashes"
printf 'hello\n' > "$tmp/file"
hash="$(sha256sum "$tmp/file" | cut -d' ' -f1)"
run_verify() { # NAME PINNED
    PINNED="$2" bash -c 'source "$1"; pinned_sha256() { [[ "$1" == known.tar.gz ]] && echo "$PINNED"; }
        verify_download "$2" "$3"' _ "$REPO_ROOT/core/lib.sh" "$tmp/file" "$1" 2>&1
}
out="$(run_verify known.tar.gz "$hash")"; assert_eq 0 "$?" 'matching file accepted'
assert_contains "$out" 'Checksum OK: known.tar.gz' 'reports the check'
out="$(run_verify known.tar.gz "${hash//[0-9]/0}")"; assert_eq 1 "$?" 'mismatch refused'
assert_contains "$out" 'Checksum mismatch for known.tar.gz' 'explains the mismatch'
out="$(run_verify other.tar.gz "$hash")"; assert_eq 1 "$?" 'file without a pinned hash refused'
assert_contains "$out" 'No pinned checksum for other.tar.gz' 'explains the missing hash'

# A download without a pinned hash is refused, so every one we fetch needs one.
echo "Test: every file the scripts can download has a pinned hash"
for arch in aarch64 armv7 x86_64; do
    names="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/p" SERVERINATOR_SERVICE_D="$tmp/svc" bash -c 'source "$1"; ARCH="$2"
        echo "ubuntu-base-24.04.4-base-$(debian_arch).tar.gz wstunnel_${WSTUNNEL_VERSION}_linux_$(wstunnel_arch_suffix).tar.gz"' \
        _ "$PHONE_SCRIPT" "$arch" 2>/dev/null)"
    for n in $names; do
        bash -c 'source "$1"; pinned_sha256 "$2" >/dev/null' _ "$REPO_ROOT/core/lib.sh" "$n"
        assert_eq 0 "$?" "phone $arch: $n"
    done
done
for arch in x86_64 aarch64 armv7l; do
    n="$(SERVERINATOR_VPS_ARCH="$arch" bash -c 'source "$1"; echo "wstunnel_${WSTUNNEL_VERSION}_linux_$(wstunnel_vps_suffix).tar.gz"' _ "$VPS_SCRIPT" 2>/dev/null)"
    bash -c 'source "$1"; pinned_sha256 "$2" >/dev/null' _ "$REPO_ROOT/core/lib.sh" "$n"
    assert_eq 0 "$?" "VPS $arch: $n"
done

echo "Test: Debian architecture names"
for pair in aarch64:arm64 armv7:armhf x86_64:amd64; do
    got="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/p" SERVERINATOR_SERVICE_D="$tmp/svc" bash -c 'source "$1"; ARCH="$2"; debian_arch' _ "$PHONE_SCRIPT" "${pair%%:*}" 2>/dev/null)"
    assert_eq "${pair##*:}" "$got" "${pair%%:*} -> ${pair##*:}"
done

exit "$TESTS_FAILED"
