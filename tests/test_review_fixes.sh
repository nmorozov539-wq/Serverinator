#!/usr/bin/env bash
# Small fixes from the 2026-10-14 review: VPS wstunnel architecture, the
# install alias reused by --add-client, jump-key revocation that empties the
# file, and the orchestrator's preflight port.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "Test: VPS wstunnel architecture mapping"
for pair in x86_64:amd64 aarch64:arm64 arm64:arm64 armv7l:armv7; do
    got="$(SERVERINATOR_VPS_ARCH="${pair%%:*}" bash -c 'source "$1"; wstunnel_vps_suffix' _ "$VPS_SCRIPT" 2>/dev/null)"
    assert_eq "${pair##*:}" "$got" "uname ${pair%%:*} -> ${pair##*:}"
done
rc=0; SERVERINATOR_VPS_ARCH=mips bash -c 'source "$1"; wstunnel_vps_suffix' _ "$VPS_SCRIPT" > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'unknown architecture refused'

echo "Test: --add-client reuses the alias chosen at install"
mkdir -p "$tmp/keys" "$tmp/devices"
cat > "$tmp/devices/rn9p.json" <<JSON
{"device_name":"rn9p","vps_ip":"203.0.113.9","ssh_phone_ip":"$TEST_PHONE_IP","ssh_user":"root","ssh_port":2222,"ssh_vps_user":"root","ssh_enabled":1,"ssh_alias":"myphone"}
JSON
got="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/dev" SERVERINATOR_SSH_KEY_DIR="$tmp/keys" SERVERINATOR_DEVICES_DIR="$tmp/devices" \
    bash -c 'source "$1"; _load_phone_state; echo "$SSH_ALIAS"' _ "$VPS_SCRIPT" 2>/dev/null)"
assert_eq myphone "$got" 'alias loaded from the device record'
got="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/dev" SERVERINATOR_SSH_KEY_DIR="$tmp/keys" SERVERINATOR_DEVICES_DIR="$tmp/devices" \
    bash -c 'source "$1"; SSH_ALIAS=explicit; _load_phone_state; echo "$SSH_ALIAS"' _ "$VPS_SCRIPT" 2>/dev/null)"
assert_eq explicit "$got" 'explicit --alias wins'

echo "Test: revoking the only jump entry leaves an empty file"
mkdir -p "$tmp/admin/.ssh"
rc=0
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/dev" SERVERINATOR_VPS_ADMIN_HOME="$tmp/admin" \
    bash -c 'source "$1"
        _authorize_vps_jump_key "ssh-ed25519 AAAAONLY x" 10.66.69.2 2222
        _revoke_vps_jump_key "ssh-ed25519 AAAAONLY x" 10.66.69.2 2222' _ "$VPS_SCRIPT" > "$tmp/revoke.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'revocation succeeds when no lines remain'
assert_eq 0 "$(stat -c %s "$tmp/admin/.ssh/authorized_keys")" 'file emptied'
assert_eq "" "$(find "$tmp/admin/.ssh" -name 'authorized_keys.*')" 'no temp files left behind'

echo "Test: orchestrator preflight uses the back-handoff's wstunnel port"
printf '{\n  "version": 1,\n  "wstunnel_port": 8443\n}\n' > "$tmp/back.json"
got="$(bash -c 'source "$1"; BACK_HANDOFF_LOCAL="$2"; back_handoff_wstunnel_port' _ "$REPO_ROOT/serverinator.sh" "$tmp/back.json")"
assert_eq 8443 "$got" 'port read from back-handoff'
got="$(bash -c 'source "$1"; BACK_HANDOFF_LOCAL=""; back_handoff_wstunnel_port' _ "$REPO_ROOT/serverinator.sh")"
assert_eq 9443 "$got" 'falls back to the default'
exit "$TESTS_FAILED"
