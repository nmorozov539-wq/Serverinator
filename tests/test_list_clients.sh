#!/usr/bin/env bash
# core-vps.sh --list-clients: lists the owner key and every --add-client key
# kept on the VPS, with alias, creation date and fingerprint. No tunnel needed.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
devroot="$tmp/vps"; phone_home="$tmp/phone_home"; mkdir -p "$phone_home"
cat > "$tmp/handoff.json" <<JSON
{"version":1,"device_name":"rn9p","wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","wstunnel_port":9443,"wg_port":51822,"ssh_enabled":1,"ssh_user":"root","ssh_port":2222,"ssh_host_fingerprint":"SHA256:TEST"}
JSON
vps() { # ARGS... — run core-vps.sh main in DEV with the phone mocked locally
    SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" bash -c '
        source "$1"; shift
        ssh() { local cmd="${!#}"; HOME="'"$phone_home"'" bash -c "$cmd"; }
        main "$@"' _ "$VPS_SCRIPT" "$@"
}

echo "Test: --list-clients without an install fails cleanly"
rc=0; vps --list-clients > "$tmp/none.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'fails before install'
assert_contains "$(cat "$tmp/none.log")" 'No phone is set up on this VPS' 'explains why'

vps "$tmp/handoff.json" --vps-ip 203.0.113.9 --alias myphone > "$tmp/setup.log" 2>&1
vps --add-client laptop > /dev/null 2>&1
vps --add-client friend > /dev/null 2>&1

echo "Test: lists owner and clients with their aliases"
rc=0; out="$(vps --list-clients 2>&1)" || rc=$?
assert_eq 0 "$rc" 'list succeeds'
assert_contains "$out" 'SSH access to rn9p (via 203.0.113.9)' 'header names device and VPS'
assert_contains "$out" 'owner' 'owner row'
assert_contains "$out" 'myphone-laptop' 'laptop row uses the install alias'
assert_contains "$out" 'myphone-friend' 'friend row'
assert_contains "$out" 'SHA256:' 'fingerprints shown'
assert_contains "$out" '2 extra client(s)' 'client count'

echo "Test: a revoked client disappears from the list"
vps --revoke-client laptop > /dev/null 2>&1
out="$(vps --list-clients 2>&1)"
assert_not_contains "$out" 'myphone-laptop' 'laptop gone after revoke'
assert_contains "$out" '1 extra client(s)' 'count updated'
exit "$TESTS_FAILED"
