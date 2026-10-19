#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/vps" \
       SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service" \
       SERVERINATOR_STATE_DIR="$tmp/state"
mkdir -p "$tmp/root/etc/wireguard" "$tmp/service" "$tmp/state/backups"
printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= > "$tmp/root/etc/wireguard/client.key"
printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= > "$tmp/root/etc/wireguard/client.pub"
source "$PHONE_SCRIPT"; set +e

make_back() { cat > "$tmp/back.json" <<JSON
{"version":1,"device_name":"phone","vps_ip":"$1","phone_wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","vps_wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","phone_wg_ip":"$TEST_PHONE_IP","vps_wg_ip":"10.66.69.1","ssh_enabled":0}
JSON
}
BACK_HANDOFF_FILE="$tmp/back.json"

# First apply creates the wstunnel autostart with the first VPS IP
make_back 203.0.113.5; apply_back_handoff > "$tmp/out" 2>&1
# Second apply with a different VPS IP should reconcile (update) the script
make_back 203.0.113.9; apply_back_handoff > "$tmp/out" 2>&1

assert_contains "$(cat "$tmp/service/10-serverinator-wstunnel.sh")" 'wss://203.0.113.9:9443' 'changed VPS reconciled'
assert_file_exists "$STATE_DIR/backups/10-serverinator-wstunnel.sh.bak" 'startup backup outside boot directory'
assert_file_missing "$tmp/service/10-serverinator-wstunnel.sh.bak" 'no adjacent bootable backup'

# Test legacy .bak migration: simulate an old install that left a .bak in service dir
cp "$tmp/service/10-serverinator-wstunnel.sh" "$tmp/service/10-serverinator-wstunnel.sh.bak"
chmod 700 "$tmp/service/10-serverinator-wstunnel.sh.bak"
# Re-applying same back-handoff (unchanged content) should migrate the .bak without changing the script
make_back 203.0.113.9; apply_back_handoff > "$tmp/out" 2>&1
assert_file_missing "$tmp/service/10-serverinator-wstunnel.sh.bak" 'legacy bootable backup migrated on unchanged reconcile'
[[ ! -x "$STATE_DIR/backups/10-serverinator-wstunnel.sh.bak" ]]
assert_eq 0 "$?" 'archived service backup is not executable'

assert_contains "$(cat "$tmp/service/20-serverinator-wireguard.sh")" 'ip route replace' 'route state reconciled'
assert_contains "$(cat "$tmp/service/20-serverinator-wireguard.sh")" 'ip -4 rule show' 'rules checked before mutation'

# VPS-side reconciliation
export SERVERINATOR_VPS_IP=203.0.113.5
source "$VPS_SCRIPT"; set +e
DEVICE_NAME=phone; PHONE_WG_PUBKEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
setup_wireguard > "$tmp/out" 2>&1; setup_wstunnel_server > "$tmp/out" 2>&1
sed -i 's/RestartSec=5/RestartSec=99/' "$SYSTEMD_DIR/wstunnel-serverinator.service"
setup_wstunnel_server > "$tmp/out" 2>&1
assert_contains "$(cat "$SYSTEMD_DIR/wstunnel-serverinator.service")" 'RestartSec=5' 'unit drift repaired'
assert_file_exists "$SYSTEMD_DIR/wstunnel-serverinator.service.bak" 'unit backup exists'
sed -i 's/MTU = 1280/MTU = 999/' "$WG_CONF"
setup_wireguard > "$tmp/out" 2>&1
assert_contains "$(cat "$WG_CONF")" 'MTU = 1280' 'existing config drift repaired without changing desired MTU'
assert_file_exists "$WG_CONF.bak" 'WG backup exists'

# A temp file left in service.d would run at boot.
echo "Test: reconcile_file stages next to its backups, not in service.d"
mkdir -p "$tmp/sd" "$tmp/bk"
bash -c 'source "$1"; mktemp() { echo "$*" >> "'"$tmp"'/mk"; command mktemp "$@"; }; echo x | reconcile_file "$2/s.sh" 700 "$3"' \
    _ "$REPO_ROOT/core/lib.sh" "$tmp/sd" "$tmp/bk" > /dev/null
assert_contains "$(cat "$tmp/mk")" "$tmp/bk/" 'temp file in the backup folder'
assert_eq 's.sh' "$(ls -A "$tmp/sd")" 'nothing else left in service.d'

exit "$TESTS_FAILED"
