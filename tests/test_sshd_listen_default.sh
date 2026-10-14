#!/usr/bin/env bash
# Phone setup must never write an sshd drop-in that listens on every
# interface: it keeps the tunnel address from a previous apply, or uses
# loopback until the back-handoff supplies one.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/svc" \
    SERVERINATOR_STATE_DIR="$tmp/state" SERVERINATOR_SSH_HOSTKEY_DIR="$tmp/hostkeys"
mkdir -p "$tmp/root/usr/sbin" "$tmp/root/etc/ssh"
touch "$tmp/root/usr/sbin/sshd"
source "$PHONE_SCRIPT"; set +e
chroot_run() { :; }
conf="$tmp/root/etc/ssh/sshd_config.d/00-serverinator.conf"

echo "Test: fresh setup listens on loopback only"
install_ssh_server > /dev/null 2>&1
assert_contains "$(cat "$conf")" 'ListenAddress 127.0.0.1' 'loopback before back-handoff'
assert_eq 127.0.0.1 "$SSHD_LISTEN_IP" 'listen IP exported for runtime validation'

echo "Test: re-running setup keeps the applied tunnel address"
write_sshd_dropin "$TEST_PHONE_IP" > /dev/null
install_ssh_server > /dev/null 2>&1
assert_contains "$(cat "$conf")" "ListenAddress $TEST_PHONE_IP" 'tunnel address preserved on re-run'
assert_eq 1 "$(grep -c '^ListenAddress' "$conf")" 'exactly one ListenAddress'

echo "Test: a legacy drop-in without ListenAddress falls back to loopback"
sed -i '/^ListenAddress/d' "$conf"
install_ssh_server > /dev/null 2>&1
assert_contains "$(cat "$conf")" 'ListenAddress 127.0.0.1' 'legacy drop-in fixed'

echo "Test: garbage ListenAddress is not trusted"
sed -i 's/^ListenAddress .*/ListenAddress 0.0.0.0;rm/' "$conf"
assert_eq 127.0.0.1 "$(current_sshd_listen_ip)" 'invalid address ignored'
exit "$TESTS_FAILED"
