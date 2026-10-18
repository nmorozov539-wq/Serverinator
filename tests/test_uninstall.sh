#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/phone/root" SERVERINATOR_SERVICE_D="$tmp/phone/service" SERVERINATOR_STATE_DIR="$tmp/phone/state" SERVERINATOR_SSH_HOSTKEY_DIR="$tmp/phone/hostkeys"
mkdir -p "$SERVERINATOR_CHROOT/etc/wireguard" "$SERVERINATOR_SERVICE_D" "$SERVERINATOR_SSH_HOSTKEY_DIR"
touch "$SERVERINATOR_SSH_HOSTKEY_DIR/ssh_host_ed25519_key" "$SERVERINATOR_SERVICE_D/10-serverinator-wstunnel.sh" "$SERVERINATOR_SERVICE_D/personal.sh"
echo "Test: uninstall asks first"
rc=0; out="$(bash "$PHONE_SCRIPT" --uninstall < /dev/null 2>&1)" || rc=$?
assert_eq 1 "$rc" 'without a terminal or --yes it refuses'
assert_contains "$out" 'pass --yes' 'and says how'
assert_contains "$out" 'with everything in it' 'after saying what it would delete'
assert_file_exists "$SERVERINATOR_SSH_HOSTKEY_DIR/ssh_host_ed25519_key" 'nothing deleted'
rc=0; out="$(bash "$PHONE_SCRIPT" --uninstall --purge < /dev/null 2>&1)" || rc=$?
assert_contains "$out" 'see a new phone' '--purge says the identity goes'
if command -v script > /dev/null; then
    out="$(printf 'n\n' | script -qec "bash $PHONE_SCRIPT --uninstall" /dev/null 2>&1)"
    assert_contains "$out" 'Nothing was changed' 'answering n in a terminal keeps everything'
    assert_file_exists "$SERVERINATOR_SSH_HOSTKEY_DIR/ssh_host_ed25519_key" 'still nothing deleted'
fi
rc=0
bash "$PHONE_SCRIPT" --uninstall --yes > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'phone uninstall succeeds in DEV'
assert_file_missing "$SERVERINATOR_CHROOT" 'phone root removed after unmount checks'
assert_file_exists "$SERVERINATOR_SSH_HOSTKEY_DIR/ssh_host_ed25519_key" 'host identity preserved'
assert_file_exists "$SERVERINATOR_SERVICE_D/personal.sh" 'personal service preserved'
rc=0; bash "$PHONE_SCRIPT" --uninstall --purge --yes > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'purge succeeds'
assert_file_missing "$SERVERINATOR_SSH_HOSTKEY_DIR" 'explicit purge removes identity'
export SERVERINATOR_DEV_ROOT="$tmp/vps"
mkdir -p "$tmp/vps/etc/wireguard/serverinator" "$tmp/vps/etc/systemd/system" "$tmp/vps/usr/local/bin"
touch "$tmp/vps/etc/wireguard/wg-si.conf" "$tmp/vps/etc/wireguard/awg0.conf" "$tmp/vps/etc/systemd/system/wstunnel-serverinator.service" "$tmp/vps/usr/local/bin/wstunnel" "$tmp/vps/usr/local/bin/personal"
rc=0; bash "$VPS_SCRIPT" --uninstall --yes > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'VPS uninstall succeeds in DEV'
assert_file_missing "$tmp/vps/etc/wireguard/wg-si.conf" 'owned WG config removed'
assert_file_missing "$tmp/vps/etc/wireguard/serverinator" 'owned keys removed'
assert_file_exists "$tmp/vps/etc/wireguard/awg0.conf" 'foreign WG preserved'
assert_file_exists "$tmp/vps/usr/local/bin/personal" 'foreign binary preserved'
assert_file_exists "$tmp/vps/usr/local/bin/wstunnel" 'reused binary preserved without receipt'
mkdir -p "$tmp/vps/etc/wireguard/serverinator"
touch "$tmp/vps/etc/wireguard/serverinator/wstunnel-owned"
rc=0; bash "$VPS_SCRIPT" --uninstall --yes > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'owned binary uninstall succeeds'
assert_file_missing "$tmp/vps/usr/local/bin/wstunnel" 'installer-owned binary removed'
# Refuse deletion if mount remains. Mock only /proc/mounts reader via function.
source "$PHONE_SCRIPT"; set +e; ASSUME_YES=1
mkdir -p "$CHROOT"; touch "$CHROOT/valuable"
phone_mounts() { printf '%s\n' "$CHROOT/dev"; }
unmount_chroot() { return 1; }
rc=0; (uninstall_phone) > "$tmp/out" 2>&1 || rc=$?
assert_eq 1 "$rc" 'failed unmount blocks deletion'
assert_file_exists "$CHROOT/valuable" 'failed unmount preserves root'
exit "$TESTS_FAILED"
