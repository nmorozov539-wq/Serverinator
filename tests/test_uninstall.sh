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
echo "Test: uninstall takes add-on boot scripts with it"
mkdir -p "$SERVERINATOR_CHROOT/etc/wireguard" "$tmp/phone/modules/serverinator-personal" "$tmp/phone/modules/other"
touch "$tmp/phone/modules/other/module.prop" "$SERVERINATOR_SERVICE_D/50-personal-vaultwarden.sh" "$SERVERINATOR_SERVICE_D/50-personal-vaultwarden.sh.bak" "$SERVERINATOR_SERVICE_D/50-other-x.sh"
rc=0; out="$(SERVERINATOR_MODULES_DIR="$tmp/phone/modules" bash "$PHONE_SCRIPT" --uninstall --yes 2>&1)" || rc=$?
assert_eq 0 "$rc" 'uninstall with an add-on succeeds'
assert_contains "$out" 'add-on services that run in it, and their boot scripts: personal-vaultwarden' 'the summary names them'
assert_file_missing "$SERVERINATOR_SERVICE_D/50-personal-vaultwarden.sh" 'add-on boot script removed'
assert_file_missing "$SERVERINATOR_SERVICE_D/50-personal-vaultwarden.sh.bak" 'and its backup'
assert_file_exists "$SERVERINATOR_SERVICE_D/50-other-x.sh" 'a script with no serverinator- module stays'
assert_file_missing "$tmp/phone/modules/serverinator-personal" 'add-on module removed'
assert_file_exists "$tmp/phone/modules/other/module.prop" 'foreign module stays'
rc=0; bash "$PHONE_SCRIPT" --uninstall --purge --yes > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'purge succeeds'
assert_file_missing "$SERVERINATOR_SSH_HOSTKEY_DIR" 'explicit purge removes identity'
assert_contains "$(cat "$tmp/out")" 'host keys removed too (--purge)' 'the summary says the keys went'
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

# The admin's own keys in the same authorized_keys must stay.
echo "Test: VPS uninstall removes jump entries and nothing else"
admin="$tmp/admin"; mkdir -p "$admin/.ssh"
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/u" SERVERINATOR_VPS_ADMIN_HOME="$admin" \
    bash -c 'source "$1"; _authorize_vps_jump_key "ssh-ed25519 AAAAJUMP1 a" 10.66.69.2 2222
        _authorize_vps_jump_key "ssh-ed25519 AAAAJUMP2 b" 10.66.69.3 2222' _ "$VPS_SCRIPT" > /dev/null 2>&1
printf 'ssh-ed25519 AAAAMINE me@laptop\n' >> "$admin/.ssh/authorized_keys"
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/u" SERVERINATOR_VPS_ADMIN_HOME="$admin" bash "$VPS_SCRIPT" --uninstall --yes > "$tmp/u.log" 2>&1
assert_eq 0 "$?" 'uninstall succeeds'
assert_eq 'ssh-ed25519 AAAAMINE me@laptop' "$(cat "$admin/.ssh/authorized_keys")" 'only the jump entries are gone'
assert_contains "$(cat "$tmp/u.log")" 'Removed ServerInator jump entries' 'reported'

exit "$TESTS_FAILED"
