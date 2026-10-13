#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/vps"
source "$VPS_SCRIPT"; set +e
for bad in '../escape' 'UpperCase' 'name;touch-x'; do
 printf '{"version":1,"device_name":"%s","wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}\n' "$bad" > "$tmp/in.json"
 rc=0; (HANDOFF_FILE="$tmp/in.json"; read_handoff) > "$tmp/out" 2>&1 || rc=$?
 assert_eq 1 "$rc" 'unsafe device name rejected'
done
for bad in BADKEY AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB=; do
 printf '{"version":1,"device_name":"phone","wg_pubkey":"%s"}\n' "$bad" > "$tmp/in.json"
 rc=0; (HANDOFF_FILE="$tmp/in.json"; read_handoff) > "$tmp/out" 2>&1 || rc=$?
 assert_eq 1 "$rc" 'invalid WG key rejected'
done
for port in '"9443"' -1 65536; do
 printf '{"version":1,"device_name":"phone","wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","wstunnel_port":%s}\n' "$port" > "$tmp/in.json"
 rc=0; (HANDOFF_FILE="$tmp/in.json"; read_handoff) > "$tmp/out" 2>&1 || rc=$?
 assert_eq 1 "$rc" 'invalid numeric port rejected'
done
for host in '999.1.1.1' 'vps;id' '-bad.example' 'good.example'; do
 rc=0; (validate_host "$host") > "$tmp/out" 2>&1 || rc=$?
 if [[ "$host" == good.example ]]; then expected=0; else expected=1; fi
 assert_eq "$expected" "$rc" 'hostname/IPv4 validation'
done
DEVICE_NAME=phone; PHONE_WG_PUBKEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
setup_wireguard > "$tmp/out" 2>&1
VPS_IP=203.0.113.5 generate_back_handoff > "$tmp/out" 2>&1
assert_eq 600 "$(stat -c %a "$BACK_HANDOFF_PATH")" 'back handoff private permissions'
SSH_ENABLED=1; SSH_VPS_USER=uber; VPS_IP=203.0.113.5; SSH_ALIAS=serverinated
CLIENT_KEYS_MODE=new setup_vps_ssh_keys > "$tmp/out" 2>&1
generate_client_setup > "$tmp/out2" 2>&1
assert_not_contains "$(cat "$SSH_KEY_DIR/client-setup-owner-phone.sh")" 'PRIVATE KEY' 'private key never printed'
assert_contains "$(cat "$SSH_KEY_DIR/client-setup-owner-phone.sh")" 'si-phone' 'client key install path in script'
exit "$TESTS_FAILED"
