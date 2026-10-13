#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/vps"
source "$VPS_SCRIPT"
set +e
keys=(AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA= CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA= DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDA=)
ips=()
for n in 0 1 2; do
 DEVICE_NAME="phone$n"; PHONE_WG_PUBKEY=${keys[$n]}
 setup_wireguard > "$tmp/out" 2>&1
 ips+=("$PHONE_WG_IP")
done
assert_eq 3 "$(printf '%s\n' "${ips[@]}" | sort -u | wc -l | tr -d ' ')" 'three distinct device addresses'
DEVICE_NAME=phone0; PHONE_WG_PUBKEY=${keys[0]}; setup_wireguard > "$tmp/out" 2>&1
assert_eq "${ips[0]}" "$PHONE_WG_IP" 'repeat preserves address'
PHONE_WG_PUBKEY=${keys[3]}; setup_wireguard > "$tmp/out" 2>&1
assert_eq "${ips[0]}" "$PHONE_WG_IP" 'replacement preserves device address'
assert_not_contains "$(cat "$WG_CONF")" "${keys[0]}" 'replacement removes old key'
printf '\n[Peer]\nPublicKey = FOREIGN\nAllowedIPs = %s/32\n' "${ips[1]}" >> "$WG_CONF"
rc=0
(DEVICE_NAME=phone3; PHONE_WG_PUBKEY=${keys[0]}; setup_wireguard) > "$tmp/out" 2>&1 || rc=$?
assert_eq 1 "$rc" 'overlapping AllowedIPs rejected'
exit "$TESTS_FAILED"
