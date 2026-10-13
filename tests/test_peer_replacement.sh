#!/usr/bin/env bash
# Exercises core-vps.sh peer-block parsing/replacement in isolated DEV mode.
# Covers: first run, idempotency, key change, unrelated-peer preservation,
# ambiguous duplicate markers, and malformed blocks.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export SERVERINATOR_DEV=1
export SERVERINATOR_DEV_ROOT="$tmp/devroot"
export SERVERINATOR_VPS_IP=127.0.0.1
# shellcheck disable=SC1090
source "$VPS_SCRIPT"
set +e

conf="$WG_CONF"
KEY_A="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
KEY_B="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA="
KEY_C="CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA="
KEY_D="DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDA="
UNRELATED="UUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUA="

DEVICE_NAME="testphone"
PHONE_WG_PUBKEY="$KEY_A"

echo "Test: first setup creates a single peer"
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
assert_eq 0 "$rc" "first setup succeeds"
assert_file_exists "$conf" "config created"
assert_eq 1 "$(peer_block_count "$conf" "testphone")" "exactly one phone block"
assert_eq "$KEY_A" "$(peer_pubkey_for_device "$conf" "testphone")" "phone key written"
assert_contains "$(cat "$conf")" "ListenPort = 51822" "WG listen port present"
assert_contains "$(cat "$conf")" "PersistentKeepalive = 25" "peer keepalive set"

echo "Test: repeated setup with the same key is idempotent"
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
assert_eq 0 "$rc" "second setup succeeds"
assert_eq 1 "$(peer_block_count "$conf" "testphone")" "still exactly one phone block"
assert_eq "$KEY_A" "$(peer_pubkey_for_device "$conf" "testphone")" "key unchanged"

echo "Test: key change replaces only the phone peer and preserves others"
printf '\n# ServerInator peer: otherdevice\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.66.69.9/32\n' \
    "$UNRELATED" >> "$conf"
PHONE_WG_PUBKEY="$KEY_B"
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
assert_eq 0 "$rc" "replacement setup succeeds"
assert_eq 1 "$(peer_block_count "$conf" "testphone")" "one phone block after key change"
assert_eq "$KEY_B" "$(peer_pubkey_for_device "$conf" "testphone")" "new phone key present"
assert_not_contains "$(cat "$conf")" "$KEY_A" "old phone key removed"
assert_contains "$(cat "$conf")" "PersistentKeepalive = 25" "replaced peer keeps keepalive"
assert_contains "$(cat "$conf")" "$UNRELATED" "unrelated peer preserved"
assert_contains "$(cat "$conf")" "AllowedIPs = 10.66.69.9/32" "unrelated AllowedIPs preserved"
assert_eq 1 "$(grep -c 'otherdevice' "$conf")" "unrelated block not duplicated"

echo "Test: repeated replacement does not accumulate blank/duplicate blocks"
PHONE_WG_PUBKEY="$KEY_C"
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
assert_eq 0 "$rc" "second replacement succeeds"
assert_eq 1 "$(peer_block_count "$conf" "testphone")" "still one phone block"
assert_eq 1 "$(grep -c 'otherdevice' "$conf")" "unrelated block still single"

echo "Test: ambiguous duplicate marker is refused and file left intact"
printf '\n# ServerInator peer: testphone\n[Peer]\nPublicKey = %s\nAllowedIPs = 10.66.69.3/32\n' \
    "$KEY_D" >> "$conf"
sum_before="$(cksum < "$conf")"
PHONE_WG_PUBKEY="$KEY_A"   # not present in file, so we reach the ambiguity check
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
assert_eq 1 "$rc" "ambiguous config is rejected"
assert_eq "$sum_before" "$(cksum < "$conf")" "config unchanged after refusal"

echo "Test: marker without a readable PublicKey is refused and file left intact"
rm -rf "$SERVERINATOR_DEV_ROOT"
mkdir -p "$(dirname "$conf")"
cat > "$conf" <<EOF
[Interface]
PrivateKey = stub
Address = 10.66.69.1/24
ListenPort = 51822

# ServerInator peer: testphone
[Peer]
AllowedIPs = ${TEST_PHONE_IP}/32
EOF
sum_before="$(cksum < "$conf")"
PHONE_WG_PUBKEY="$KEY_A"
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
assert_eq 1 "$rc" "malformed block is rejected"
assert_eq "$sum_before" "$(cksum < "$conf")" "config unchanged after refusal"

echo "Test: two distinct devices coexist"
rm -rf "$SERVERINATOR_DEV_ROOT"
DEVICE_NAME="phoneone"; PHONE_WG_PUBKEY="$KEY_A"
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
DEVICE_NAME="phonetwo"; PHONE_WG_PUBKEY="$KEY_B"
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
assert_eq 1 "$(peer_block_count "$conf" "phoneone")" "phoneone block present"
assert_eq 1 "$(peer_block_count "$conf" "phonetwo")" "phonetwo block present"
PHONE_WG_PUBKEY="$KEY_C"
DEVICE_NAME="phoneone"
rc=0; ( setup_wireguard >/dev/null 2>&1 ) || rc=$?
assert_eq "$KEY_C" "$(peer_pubkey_for_device "$conf" "phoneone")" "phoneone replaced"
assert_eq "$KEY_B" "$(peer_pubkey_for_device "$conf" "phonetwo")" "phonetwo untouched"

exit "$TESTS_FAILED"
