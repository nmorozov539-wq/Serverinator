#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source "$VPS_SCRIPT"
set +e

echo "Test: JSON string escaping handles authorized_keys control characters"
value=$'ssh-ed25519 AAAACLIENT1ONE windows@host\r\tlabel'
escaped="$(json_escape "$value")"
printf '{"key":"%s"}\n' "$escaped" > "$tmp/value.json"
rc=0
jq -e . "$tmp/value.json" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "escaped key produces valid JSON"
if [[ "$rc" == 0 ]]; then
    actual="$(jq -r .key "$tmp/value.json")"
    assert_eq "$value" "$actual" "JSON round-trip preserves the public key line"
fi

echo "Test: CRLF authorized_keys lines are normalized before back-handoff"
printf 'ssh-ed25519 AAAACLIENT1ONE windows@host\r\n' > "$tmp/authorized_keys"
# setup_vps_ssh_keys strips \r from authorized_keys lines; the key should be accepted
# and stored without CR in the back-handoff.
# We pre-populate the "user home" authorized_keys that setup_vps_ssh_keys reads.
mkdir -p "$tmp/keys" "$tmp/vpsuserhome/.ssh"
cp "$tmp/authorized_keys" "$tmp/vpsuserhome/.ssh/authorized_keys"
out="$(SUDO_USER=vpsuser SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/dev" \
    SERVERINATOR_SSH_KEY_DIR="$tmp/keys" \
    SERVERINATOR_VPS_IP=203.0.113.5 \
    bash -c 'source "$1"
             DEVICE_NAME=rn11p; SSH_ENABLED=1; SSH_USER=root
             PHONE_WG_PUBKEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
             PHONE_WG_IP=${TEST_PHONE_IP}
             VPS_WG_PUBKEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=
             CLIENT_KEYS_MODE=existing
             VPS_IP=203.0.113.5
             # Point getent-based lookup at our stub home
             getent() { printf "vpsuser:x:1000:1000::'"$tmp"'/vpsuserhome:/bin/bash\n"; }
             setup_vps_ssh_keys >/dev/null
             generate_back_handoff >/dev/null' _ "$VPS_SCRIPT" 2>&1)"
rc=$?
assert_eq 0 "$rc" "CRLF key generates a back-handoff"
if [[ "$rc" == 0 ]]; then
    assert_eq 0 "$(jq -r '.ssh_client_key_1 | contains("\r") | if . then 1 else 0 end' "$tmp/dev/back-handoff.json")" \
        "CR terminator removed from client key"
fi

exit "$TESTS_FAILED"
