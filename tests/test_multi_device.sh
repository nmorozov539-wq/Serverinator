#!/usr/bin/env bash
# Several phones on one VPS: one record per phone under devices/, --device
# selection, --list-devices, --remove-device, legacy state.json migration and
# the device-name ambiguity guard.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
devroot="$tmp/vps"; phone_home="$tmp/phone_home"; mkdir -p "$phone_home"
state_dir="$devroot/etc/wireguard/serverinator"
key_dir="$state_dir/ssh"; dev_dir="$state_dir/devices"; wg_conf="$devroot/etc/wireguard/wg-si.conf"

handoff() { # NAME PUBKEY
    cat > "$tmp/$1.json" <<JSON
{"version":1,"device_name":"$1","wg_pubkey":"$2","wstunnel_port":9443,"wg_port":51822,"ssh_enabled":1,"ssh_user":"root","ssh_port":2222,"ssh_host_fingerprint":"SHA256:TEST"}
JSON
}
vps() {
    SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" bash -c '
        source "$1"; shift
        ssh() { local cmd="${!#}"; HOME="'"$phone_home"'" bash -c "$cmd"; }
        main "$@"' _ "$VPS_SCRIPT" "$@"
}
handoff rn9p  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
handoff rn11p BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=
handoff rn9p_x CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=

echo "Test: each phone gets its own record"
vps "$tmp/rn9p.json" --vps-ip 203.0.113.9 > "$tmp/i1.log" 2>&1; assert_eq 0 "$?" 'first phone installs'
vps "$tmp/rn11p.json" --vps-ip 203.0.113.9 > "$tmp/i2.log" 2>&1; assert_eq 0 "$?" 'second phone installs'
assert_file_exists "$dev_dir/rn9p.json" 'record for rn9p'
assert_file_exists "$dev_dir/rn11p.json" 'record for rn11p'
assert_eq 10.66.69.2 "$(jq -r .phone_wg_ip "$dev_dir/rn9p.json")" 'rn9p keeps its address'
assert_eq 10.66.69.3 "$(jq -r .phone_wg_ip "$dev_dir/rn11p.json")" 'rn11p gets the next address'
assert_eq 700 "$(stat -c %a "$dev_dir")" 'records directory is private'
assert_file_missing "$key_dir/state.json" 'no single shared state file'

echo "Test: --list-devices"
out="$(vps --list-devices 2>&1)"
assert_contains "$out" 'rn9p ' 'lists rn9p'
assert_contains "$out" 'rn11p' 'lists rn11p'
assert_contains "$out" '10.66.69.3' 'shows tunnel addresses'

echo "Test: with two phones, commands ask which one"
rc=0; out="$(vps --add-client laptop 2>&1)" || rc=$?
assert_eq 1 "$rc" 'add-client without --device refused'
assert_contains "$out" 'Several phones use this VPS: rn11p rn9p' 'names the phones'
rc=0; vps --add-client laptop --device rn9p > "$tmp/add.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'add-client --device rn9p works'
assert_contains "$(cat "$tmp/add.log")" 'client-setup-laptop-rn9p.sh' 'client issued for rn9p'
out="$(vps --list-clients --device rn11p 2>&1)"
assert_contains "$out" '0 extra client(s)' 'rn11p has no extra clients'
rc=0; vps --verify --device rn11p > "$tmp/verify.log" 2>&1 || rc=$?
assert_eq 0 "$rc" '--verify uses the record when no file is given'
assert_contains "$(cat "$tmp/verify.log")" 'device: rn11p' 'verifies the chosen phone'
rc=0; vps --list-clients --device nosuch > "$tmp/nosuch.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'unknown --device refused'
assert_contains "$(cat "$tmp/nosuch.log")" 'known: rn11p rn9p' 'lists known phones'

echo "Test: names that would make key files ambiguous are refused"
rc=0; vps "$tmp/rn9p_x.json" --vps-ip 203.0.113.9 > "$tmp/amb.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'rn9p_x refused while rn9p exists'
assert_contains "$(cat "$tmp/amb.log")" "clashes with existing phone 'rn9p'" 'explains the clash'

echo "Test: --remove-device removes one phone only"
laptop_pub="$(cat "$key_dir/owner_rn9p_laptop.pub")"
rn11p_owner="$(cat "$key_dir/owner_rn11p.pub")"
echo 'pinned' > "$key_dir/known_hosts_rn9p"; echo 'pinned' > "$key_dir/known_hosts_rn11p"
rc=0; vps --remove-device rn9p > "$tmp/rm.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'remove succeeds'
assert_file_missing "$dev_dir/rn9p.json" 'record removed'
assert_file_missing "$key_dir/owner_rn9p" 'owner key removed'
assert_file_missing "$key_dir/owner_rn9p_laptop.pub" 'client key removed'
assert_file_missing "$key_dir/client-setup-laptop-rn9p.sh" 'client setup script removed'
assert_not_contains "$(cat "$wg_conf")" '# ServerInator peer: rn9p' 'rn9p peer removed'
assert_not_contains "$(cat "$wg_conf")" 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' 'rn9p public key gone from WG config'
assert_contains "$(cat "$wg_conf")" '# ServerInator peer: rn11p' 'rn11p peer kept'
assert_not_contains "$(cat "$devroot/root/.ssh/authorized_keys")" "$laptop_pub" 'rn9p jump entries removed'
assert_contains "$(cat "$devroot/root/.ssh/authorized_keys")" "$rn11p_owner" 'rn11p jump entry kept'
assert_file_exists "$dev_dir/rn11p.json" 'rn11p record kept'
assert_file_missing "$key_dir/known_hosts_rn9p" 'pinned host key removed'
assert_file_exists "$key_dir/known_hosts_rn11p" 'other phone keeps its pinned host key'
rc=0; vps --add-client tablet > /dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'with one phone left, --device is optional again'

echo "Test: legacy ssh/state.json is moved into devices/"
legacy_root="$tmp/legacy"; mkdir -p "$legacy_root/etc/wireguard/serverinator/ssh"
cp "$dev_dir/rn11p.json" "$legacy_root/etc/wireguard/serverinator/ssh/state.json"
out="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$legacy_root" bash "$VPS_SCRIPT" --list-devices 2>&1)"
assert_contains "$out" 'Moved' 'migration reported'
assert_contains "$out" 'rn11p' 'migrated phone listed'
assert_file_exists "$legacy_root/etc/wireguard/serverinator/devices/rn11p.json" 'record created from state.json'
assert_file_missing "$legacy_root/etc/wireguard/serverinator/ssh/state.json" 'legacy file gone'

echo "Test: client keys of a phone named <dev>_x are not counted as <dev>'s clients"
amb="$tmp/amb"; mkdir -p "$amb/ssh" "$amb/devices"
touch "$amb/devices/a.json" "$amb/devices/a_b.json" "$amb/ssh/owner_a_phone.pub" "$amb/ssh/owner_a_b.pub" "$amb/ssh/owner_a_b_tab.pub"
got="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/x" SERVERINATOR_SSH_KEY_DIR="$amb/ssh" SERVERINATOR_DEVICES_DIR="$amb/devices" \
    bash -c 'source "$1"; device_client_pubs a' _ "$VPS_SCRIPT" | xargs -n1 basename | tr '\n' ' ')"
assert_eq 'owner_a_phone.pub ' "$got" 'only a_phone belongs to device a'

echo "Test: orchestrator download hints"
out="$(bash -c 'source "$1"; VPS_TARGET=root@203.0.113.9; VPS_NEEDS_SUDO=0; fetch_hint /etc/wireguard/serverinator/ssh/x.sh' _ "$REPO_ROOT/serverinator.sh")"
assert_eq 'scp root@203.0.113.9:/etc/wireguard/serverinator/ssh/x.sh . && bash x.sh' "$out" 'root uses scp'
out="$(bash -c 'source "$1"; VPS_TARGET=deploy@203.0.113.9; VPS_NEEDS_SUDO=1; fetch_hint /etc/wireguard/serverinator/ssh/x.sh' _ "$REPO_ROOT/serverinator.sh")"
assert_eq "ssh deploy@203.0.113.9 'sudo cat /etc/wireguard/serverinator/ssh/x.sh' > x.sh && bash x.sh" "$out" 'sudo user reads through sudo'
exit "$TESTS_FAILED"
