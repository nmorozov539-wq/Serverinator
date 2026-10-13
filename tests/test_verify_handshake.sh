#!/usr/bin/env bash
# Exercises the --verify handshake logic with mocked wg/systemctl/ping/ip.
# Covers: multi-peer output, missing peer, timestamp 0, duplicate entries for
# the phone key, missing JSON fields, and missing tools.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export SERVERINATOR_DEV=0
# shellcheck disable=SC1090
source "$VPS_SCRIPT"
set +e

# ── Mocks ─────────────────────────────────────
interface_is_up() { return 0; }
have_cmd() { return 0; }
systemctl() { return 0; }
ping() { return 0; }
WG_OUTPUT=""
wg() { printf '%s\n' "$WG_OUTPUT"; }

back="$tmp/back.json"
write_back() { # $1 = phone_wg_pubkey (may be empty string to omit)
    if [[ "$1" == "__OMIT__" ]]; then
        cat > "$back" <<EOF
{ "version": 1, "device_name": "testphone", "phone_wg_ip": "${TEST_PHONE_IP}" }
EOF
    else
        cat > "$back" <<EOF
{
  "version": 1,
  "device_name": "testphone",
  "vps_ip": "203.0.113.5",
  "vps_wg_pubkey": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=",
  "phone_wg_pubkey": "$1",
  "phone_wg_ip": "${TEST_PHONE_IP}",
  "vps_wg_ip": "10.66.69.1",
  "wg_port": 51822,
  "wstunnel_port": 9443
}
EOF
    fi
    BACK_HANDOFF_FILE="$back"
}

run_verify() { # sets OUT and RC
    RC=0
    OUT="$(verify 2>&1)" || RC=$?
}

now="$(date +%s)"

echo "Test: passes with one recent handshake among several peers"
WG_OUTPUT="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= $now
OTHERKEY= 0
THIRDKEY= 12345"
write_back "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
run_verify
assert_eq 0 "$RC" "verify passes"
assert_contains "$OUT" "all checks passed" "success message shown"

echo "Test: peer absent fails"
WG_OUTPUT="OTHERKEY= 0"
write_back "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
run_verify
assert_eq 1 "$RC" "verify fails when peer absent"
assert_contains "$OUT" "not found" "reports absent peer"

echo "Test: timestamp 0 fails"
WG_OUTPUT="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= 0
OTHERKEY= 123"
write_back "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
run_verify
assert_eq 1 "$RC" "verify fails on timestamp 0"
assert_contains "$OUT" "timestamp 0" "reports zero handshake"

echo "Test: duplicate entries for the phone key fail without arithmetic errors"
WG_OUTPUT="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= 111
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= 222"
write_back "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
run_verify
assert_eq 1 "$RC" "verify fails on duplicate handshakes"
assert_contains "$OUT" "Multiple handshake entries" "reports duplicates"
assert_not_contains "$OUT" "syntax error" "no arithmetic syntax error"

echo "Test: stale handshake fails"
WG_OUTPUT="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= 1000000000"
write_back "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
run_verify
assert_eq 1 "$RC" "verify fails on stale handshake"
assert_contains "$OUT" "is stale" "reports stale handshake"

echo "Test: missing phone_wg_pubkey yields a meaningful error"
WG_OUTPUT="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= $now"
write_back "__OMIT__"
run_verify
assert_eq 1 "$RC" "verify fails when phone_wg_pubkey missing"
assert_contains "$OUT" "phone_wg_pubkey" "reports missing pubkey"

echo "Test: missing phone_wg_ip yields a meaningful error"
cat > "$back" <<EOF
{ "version": 1, "device_name": "testphone", "phone_wg_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" }
EOF
BACK_HANDOFF_FILE="$back"
run_verify
assert_eq 1 "$RC" "verify fails when phone_wg_ip missing"
assert_contains "$OUT" "phone_wg_ip" "reports missing ip"

echo "Test: missing ping is reported actionably"
have_cmd() { [[ "$1" != "ping" ]]; }
WG_OUTPUT="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= $now"
write_back "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
run_verify
assert_eq 1 "$RC" "verify fails when ping missing"
assert_contains "$OUT" "ping not found" "reports missing ping"

exit "$TESTS_FAILED"
