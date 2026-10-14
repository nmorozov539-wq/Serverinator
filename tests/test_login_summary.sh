#!/usr/bin/env bash
# Login summary: installed into the chroot, runs only for interactive bash,
# stays at one external command, and can be silenced.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/svc" \
    SERVERINATOR_STATE_DIR="$tmp/state" SERVERINATOR_DEVICE_NAME=rn9p
source "$PHONE_SCRIPT"; set +e

echo "Test: installed into the chroot"
write_login_summary > /dev/null
stub="$tmp/root/etc/profile.d/serverinator-motd.sh"
lib="$tmp/root/usr/local/lib/serverinator/motd.bash"
assert_file_exists "$stub" 'profile.d stub'
assert_file_exists "$lib" 'summary script'
assert_contains "$(cat "$stub")" "__si_motd 'rn9p'" 'device name baked in'
sed "s|/usr/local/lib/serverinator|$tmp/root/usr/local/lib/serverinator|" "$stub" > "$tmp/stub"

echo "Test: output"
out="$(HOME="$tmp" bash -ic ". '$tmp/stub'" 2>/dev/null)"
assert_contains "$out" 'rn9p · up ' 'device and uptime line'
assert_contains "$out" 'mem ' 'memory line'
assert_contains "$out" 'tunnel ' 'service line'
assert_eq "" "$(HOME="$tmp" bash -c ". '$tmp/stub'" 2>/dev/null)" 'silent for non-interactive bash'
if command -v dash > /dev/null; then
    assert_eq "" "$(dash -c ". '$tmp/stub'" 2>&1)" 'sh logins skip it cleanly'
fi
touch "$tmp/.hushlogin"
assert_eq "" "$(HOME="$tmp" bash -ic ". '$tmp/stub'" 2>/dev/null)" '~/.hushlogin silences it'
rm -f "$tmp/.hushlogin"

echo "Test: at most one external command per login"
if command -v strace > /dev/null; then
    HOME="$tmp" strace -f -e trace=execve -o "$tmp/trace" bash -c "source '$lib'; __si_motd rn9p" > /dev/null 2>&1
    execs="$(grep -c 'execve(' "$tmp/trace")"
    assert_eq 2 "$execs" 'bash itself plus a single df'
else
    printf '%s\n' 'SKIP: strace unavailable; fork count unverified'
fi
exit "$TESTS_FAILED"
