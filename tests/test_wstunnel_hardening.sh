#!/usr/bin/env bash
# Review #12: the VPS's wstunnel runs as a sandboxed throwaway user and only
# answers a secret per-install path, which phones get in the back-handoff.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

devroot="$tmp/vps"
cat > "$tmp/handoff.json" <<JSON
{ "version": 1, "device_name": "testphone", "wg_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "wstunnel_port": 9443, "wg_port": 51822 }
JSON
vps_setup() {
    (SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" SERVERINATOR_VPS_IP=203.0.113.5 \
     bash -c 'source "$1"; HANDOFF_FILE="$2"; read_handoff; setup_wireguard; setup_wstunnel_server; generate_back_handoff' \
     _ "$VPS_SCRIPT" "$tmp/handoff.json") > "$tmp/vps.out" 2>&1
}
rc=0; vps_setup || rc=$?
assert_eq 0 "$rc" 'VPS setup succeeds'
unit="$(cat "$devroot/etc/systemd/system/wstunnel-serverinator.service")"
envf="$devroot/etc/wireguard/serverinator/wstunnel.env"
prefix="$(head -n 1 "$devroot/etc/wireguard/serverinator/wstunnel-path-prefix")"
echo "Test: sandboxed service"
for opt in DynamicUser=yes NoNewPrivileges=yes ProtectSystem=strict ProtectHome=yes 'CapabilityBoundingSet=' \
           'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX' SystemCallFilter=@system-service; do
    assert_contains "$unit" "$opt" "unit has $opt"
done
assert_contains "$unit" "EnvironmentFile=$devroot/etc/wireguard/serverinator/wstunnel.env" 'prefix comes from the env file'
echo "Test: secret path prefix"
[[ "$prefix" =~ ^[A-Za-z0-9]{24}$ ]]; assert_eq 0 "$?" 'prefix is 24 random letters and digits'
assert_not_contains "$unit" "$prefix" 'prefix is not in the world-readable unit'
assert_eq "WSTUNNEL_RESTRICT_HTTP_UPGRADE_PATH_PREFIX=$prefix" "$(cat "$envf")" 'env file restricts the path'
assert_eq 600 "$(stat -c %a "$envf")" 'env file is root-only'
assert_contains "$(cat "$devroot/back-handoff.json")" "\"wstunnel_path_prefix\": \"$prefix\"" 'back-handoff carries the prefix'
vps_setup
assert_eq "$prefix" "$(head -n 1 "$devroot/etc/wireguard/serverinator/wstunnel-path-prefix")" 'a re-install keeps the prefix'

echo "Test: the phone uses it"
mkdir -p "$tmp/chroot/etc/wireguard" "$tmp/service.d"
for f in client.key client.pub; do echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$tmp/chroot/etc/wireguard/$f"; done
phone_apply() {
    SERVERINATOR_DEV=0 SERVERINATOR_STATE_DIR="$tmp/state" SERVERINATOR_CHROOT="$tmp/chroot" SERVERINATOR_SERVICE_D="$tmp/service.d" \
        bash -c 'source "$1"; parse_args --apply-back-handoff "$2"; prepare_sshd_runtime() { :; }; apply_back_handoff' \
        _ "$PHONE_SCRIPT" "$1" > "$tmp/phone.out" 2>&1; local r=$?; [ $r = 0 ] || cat "$tmp/phone.out" >&2; return $r
}
jq '. + {ssh_enabled: 0, vps_ip: "203.0.113.5"}' "$devroot/back-handoff.json" > "$tmp/back.json"
rc=0; phone_apply "$tmp/back.json" || rc=$?
assert_eq 0 "$rc" 'phone applies the back-handoff'
sup="$tmp/service.d/10-serverinator-wstunnel.sh"
assert_contains "$(cat "$sup")" "--http-upgrade-path-prefix $prefix" 'phone wstunnel sends the prefix'
sh -n "$sup"; assert_eq 0 "$?" 'supervisor is valid sh'
jq 'del(.wstunnel_path_prefix)' "$tmp/back.json" > "$tmp/old.json"
phone_apply "$tmp/old.json"
assert_not_contains "$(cat "$sup")" 'http-upgrade-path-prefix' 'older VPS without a prefix: none sent'
jq '. + {wstunnel_path_prefix: "x; rm -rf /"}' "$tmp/back.json" > "$tmp/bad.json"
rc=0; phone_apply "$tmp/bad.json" || rc=$?
assert_eq 1 "$rc" 'odd prefix refused'
exit "$TESTS_FAILED"
