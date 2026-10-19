#!/usr/bin/env bash
# Verifies the port arrangement is consistent across generated phone/VPS files.
#   phone wstunnel local UDP : 51823
#   wstunnel forward target  : 127.0.0.1:51822 (VPS WG ListenPort)
#   phone WG Endpoint        : 127.0.0.1:51823
#   wstunnel server TLS      : 9443
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_STATE_DIR="$tmp/state"

# ── Phone side ────────────────────────────────
mkdir -p "$tmp/chroot/etc/wireguard" "$tmp/service.d"
echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$tmp/chroot/etc/wireguard/client.key"
echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$tmp/chroot/etc/wireguard/client.pub"

SERVERINATOR_DEV=0 \
SERVERINATOR_CHROOT="$tmp/chroot" \
SERVERINATOR_SERVICE_D="$tmp/service.d" \
SERVERINATOR_DEVICE_NAME=testphone \
    bash -c 'source "$1"; generate_handoff' _ "$PHONE_SCRIPT" >/dev/null 2>&1

# wstunnel autostart is only ever written by apply_back_handoff (it needs the
# VPS IP) — covered below, once a back-handoff is available.
autostart="$tmp/service.d/10-serverinator-wstunnel.sh"
handoff="$tmp/chroot/etc/wireguard/handoff.json"

echo "Test: phone handoff ports"
assert_file_exists "$handoff" "handoff exists"
assert_contains "$(cat "$handoff")" '"wstunnel_port": 9443' "handoff wstunnel_port"
assert_contains "$(cat "$handoff")" '"wg_port": 51822' "handoff wg_port"

echo "Test: apply back-handoff writes matching WG endpoint"
cat > "$tmp/back.json" <<EOF
{
  "version": 1,
  "device_name": "testphone",
  "vps_ip": "203.0.113.5",
  "vps_wg_pubkey": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=",
  "phone_wg_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  "phone_wg_ip": "${TEST_PHONE_IP}",
  "vps_wg_ip": "10.66.69.1",
  "wg_port": 51822,
  "wstunnel_port": 9443
}
EOF

SERVERINATOR_DEV=0 \
SERVERINATOR_CHROOT="$tmp/chroot" \
SERVERINATOR_SERVICE_D="$tmp/service.d" \
    bash -c 'source "$1"; parse_args --apply-back-handoff "$2"; prepare_sshd_runtime() { :; }; apply_back_handoff' \
    _ "$PHONE_SCRIPT" "$tmp/back.json" >/dev/null 2>&1

wgconf="$tmp/chroot/etc/wireguard/wg-si.conf"
assert_file_exists "$wgconf" "WG client config exists"
assert_contains "$(cat "$wgconf")" 'Endpoint = 127.0.0.1:51823' "WG endpoint uses local port 51823"
assert_contains "$(cat "$wgconf")" 'AllowedIPs = 10.66.69.1/32' "WG AllowedIPs is the VPS WG IP"
assert_contains "$(cat "$autostart")" 'wss://203.0.113.5:9443' "VPS IP patched into autostart"
assert_file_exists "$tmp/service.d/20-serverinator-wireguard.sh" "WG autostart exists"

# ── VPS side (DEV, isolated) ──────────────────
devroot="$tmp/vpsdev"
cat > "$tmp/handoff.json" <<EOF
{ "version": 1, "device_name": "testphone", "wg_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "wstunnel_port": 9443, "wg_port": 51822 }
EOF

export SERVERINATOR_DEV=1
export SERVERINATOR_DEV_ROOT="$devroot"
export SERVERINATOR_VPS_IP=203.0.113.5

echo "Test: VPS generated config/service ports and restriction"
# Run the sequence in one child process: `die` cannot escape and the parent
# inspects the resulting files by known DEV paths.
rc=0
(SERVERINATOR_DEV=1 \
 SERVERINATOR_DEV_ROOT="$devroot" \
 SERVERINATOR_VPS_IP=203.0.113.5 \
 bash -c 'source "$1"; HANDOFF_FILE="$2"; read_handoff; setup_wireguard; generate_back_handoff; setup_wstunnel_server' \
 _ "$VPS_SCRIPT" "$tmp/handoff.json") >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "VPS DEV setup sequence succeeds"

vpsconf="$devroot/etc/wireguard/wg-si.conf"
svc="$devroot/etc/systemd/system/wstunnel-serverinator.service"
backout="$devroot/back-handoff.json"

assert_file_exists "$vpsconf" "VPS WG config exists"
assert_contains "$(cat "$vpsconf")" "ListenPort = 51822" "VPS WG listens on 51822"
assert_contains "$(cat "$vpsconf")" "MTU = 1280" "VPS WG MTU matches phone"
assert_contains "$(cat "$vpsconf")" "PersistentKeepalive = 25" "VPS sends keepalives (keeps wstunnel tunnel alive)"
assert_file_exists "$svc" "wstunnel service unit exists"
assert_contains "$(cat "$svc")" "wss://0.0.0.0:9443" "wstunnel server TLS port 9443"
assert_contains "$(cat "$svc")" "--restrict-to 127.0.0.1:51822" "server restricted to WG listener"
assert_file_exists "$backout" "back-handoff exists"
assert_contains "$(cat "$backout")" '"phone_wg_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' "back-handoff carries phone key"
assert_contains "$(cat "$backout")" '"wg_port": 51822' "back-handoff wg_port"
assert_contains "$(cat "$backout")" '"wstunnel_port": 9443' "back-handoff wstunnel_port"

echo 'Test: custom VPS ports round-trip to phone'
customroot="$tmp/custom-vps"
rc=0
SERVERINATOR_DEV_ROOT="$customroot" SERVERINATOR_WG_PORT=51824 SERVERINATOR_WSTUNNEL_PORT=9444 \
    bash -c 'source "$1"; HANDOFF_FILE="$2"; read_handoff; setup_wireguard; generate_back_handoff; setup_wstunnel_server' \
    _ "$VPS_SCRIPT" "$tmp/handoff.json" > "$tmp/custom.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'custom VPS setup succeeds'
assert_contains "$(cat "$customroot/etc/wireguard/wg-si.conf")" 'ListenPort = 51824' 'custom WG ListenPort'
assert_contains "$(cat "$customroot/etc/systemd/system/wstunnel-serverinator.service")" 'wss://0.0.0.0:9444' 'custom TLS unit port'
assert_contains "$(cat "$customroot/etc/systemd/system/wstunnel-serverinator.service")" '--restrict-to 127.0.0.1:51824' 'custom restrict target'
assert_eq 51824 "$(jq -r .wg_port "$customroot/back-handoff.json")" 'custom back-handoff WG port'
assert_eq 9444 "$(jq -r .wstunnel_port "$customroot/back-handoff.json")" 'custom back-handoff TLS port'
# Feed an independently constructed return file: failures on VPS must not hide
# phone regressions. Local UDP endpoint intentionally remains 51823.
jq '.wg_port=51824 | .wstunnel_port=9444' "$tmp/back.json" > "$tmp/custom-back.json"
rc=0
SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/chroot" SERVERINATOR_SERVICE_D="$tmp/service.d" \
SERVERINATOR_DEVICE_NAME=testphone \
    bash -c 'source "$1"; BACK_HANDOFF_FILE="$2"; apply_back_handoff; generate_handoff' \
    _ "$PHONE_SCRIPT" "$tmp/custom-back.json" > "$tmp/custom-phone.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'custom phone apply succeeds'
assert_contains "$(cat "$autostart")" 'udp://51823:127.0.0.1:51824' 'custom forwarding port in phone startup'
assert_contains "$(cat "$autostart")" 'wss://203.0.113.5:9444' 'custom endpoint survives startup regeneration'
assert_contains "$(cat "$wgconf")" 'Endpoint = 127.0.0.1:51823' 'WG endpoint still matches local UDP listener'
assert_eq 51824 "$(jq -r .wg_port "$handoff")" 'custom outgoing phone WG port'
assert_eq 9444 "$(jq -r .wstunnel_port "$handoff")" 'custom outgoing phone TLS port'
# NOTE: there is no standalone "regenerate autostart" entry point anymore —
# write_wstunnel_autostart requires the VPS IP and is only ever called from
# apply_back_handoff (Stage 2 dropped the VPS_IP_PLACEHOLDER+sed mechanism).
# A phone-only rerun without a back-handoff cannot "preserve" custom ports
# because nothing persists them between separate script invocations.
echo 'Test: invalid back-handoff tunnel ports do not change files'
for pair in '1023 9444' '51824 1023' '65536 9444' '51824 65536'; do
    read -r wp tp <<< "$pair"
    jq --argjson wp "$wp" --argjson tp "$tp" '.wg_port=$wp | .wstunnel_port=$tp' \
        "$tmp/custom-back.json" > "$tmp/invalid-phone.json"
    cp "$autostart" "$tmp/startup-before"
    cp "$wgconf" "$tmp/wg-before"
    rc=0
    SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/chroot" SERVERINATOR_SERVICE_D="$tmp/service.d" \
        bash -c 'source "$1"; BACK_HANDOFF_FILE="$2"; apply_back_handoff' \
        _ "$PHONE_SCRIPT" "$tmp/invalid-phone.json" > "$tmp/invalid-phone.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "phone rejects invalid tunnel ports $pair"
    rc=0; cmp -s "$autostart" "$tmp/startup-before" && cmp -s "$wgconf" "$tmp/wg-before" || rc=$?
    assert_eq 0 "$rc" 'invalid phone ports leave generated files unchanged'
done
for script in "$tmp/service.d"/*serverinator*.sh; do
    rc=0
    if [[ -n "${SERVERINATOR_TEST_BUSYBOX:-}" ]]; then
        "$SERVERINATOR_TEST_BUSYBOX" ash -n "$script" || rc=$?
    elif command -v dash > /dev/null; then
        dash -n "$script" || rc=$?
    else
        echo 'SKIP: custom generated shell syntax (BusyBox ash/dash unavailable)'
        continue
    fi
    assert_eq 0 "$rc" 'custom generated script parses under ash/dash'
done

echo 'Test: invalid VPS port overrides fail before writes'
for pair in '1023 9443' '65536 9443' 'abc 9443' '51822 0' '51822 65536' '51822 51822' '051824 9444' '51824 9444;echo'; do
    read -r wp tp <<< "$pair"
    rc=0
    SERVERINATOR_WG_PORT="$wp" SERVERINATOR_WSTUNNEL_PORT="$tp" \
        bash -c 'source "$1"' _ "$VPS_SCRIPT" > "$tmp/invalid.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "reject invalid override $pair"
done
rc=0
SERVERINATOR_WG_PORT='' bash -c 'source "$1"' _ "$VPS_SCRIPT" > "$tmp/empty.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'reject explicitly empty override'
for pair in '1024 65535' '65535 1024'; do
    read -r wp tp <<< "$pair"
    rc=0
    SERVERINATOR_WG_PORT="$wp" SERVERINATOR_WSTUNNEL_PORT="$tp" \
        bash -c 'source "$1"' _ "$VPS_SCRIPT" > "$tmp/boundary.log" 2>&1 || rc=$?
    assert_eq 0 "$rc" "accept port boundaries $pair"
done

echo 'Test: MSS ownership with isolated firewall mocks'
# All host interactions below are functions; no real firewall or service runs.
rc=0
SERVERINATOR_DEV_ROOT="$tmp/mss-vps" SERVERINATOR_IPTABLES_RULES_PATH="$tmp/rules.v4" \
    bash -s -- "$VPS_SCRIPT" "$tmp" > "$tmp/mss.log" 2>&1 <<'MOCK' || rc=$?
source "$1"
DEV=0
root="$2"
iptables() {
    printf '%s\n' "$*" >> "$root/iptables.calls"
    case " $* " in
        *' -C '*) grep -Fxq -- "${*:5}" "$root/runtime.rules" ;;
        *' -A '*) printf '%s\n' "${*:5}" >> "$root/runtime.rules" ;;
        *' -D '*) grep -Fxv -- "${*:5}" "$root/runtime.rules" > "$root/runtime.next"; mv "$root/runtime.next" "$root/runtime.rules" ;;
    esac
}
iptables-save() {
    echo save >> "$root/save.calls"
    awk '{sub(/^-p tcp /,"-A OUTPUT -p tcp -m tcp "); print}' "$root/runtime.rules"
}
have_cmd() { case "$1" in iptables) return 0;; iptables-save) [[ "${IPTABLES_RULES_PATH:-}" == "$root/rules.v4" ]];; *) return 1;; esac; }
systemctl() { return 0; }
id() { echo 0; }
touch "$root/runtime.rules" "$IPTABLES_RULES_PATH"
WSTUNNEL_PORT=9444
unset SERVERINATOR_SKIP_MSS
fix_pmtu_clamp
[[ ! -e "$root/iptables.calls" && ! -e "$root/save.calls" ]] || exit 39
SERVERINATOR_SKIP_MSS=1
fix_pmtu_clamp
[[ ! -e "$root/iptables.calls" && ! -e "$root/save.calls" ]] || exit 31
SERVERINATOR_SKIP_MSS=0
fix_pmtu_clamp
[[ -s "$root/runtime.rules" && -s "$root/save.calls" ]] || exit 32
before=$(wc -l < "$root/runtime.rules")
fix_pmtu_clamp
[[ $(wc -l < "$root/runtime.rules") == "$before" ]] || exit 33
WSTUNNEL_PORT=9445
fix_pmtu_clamp
# Same port/MSS, but foreign rule has no ownership tag.
foreign='-p tcp --sport 9443 --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500'
printf '%s\n' "$foreign" >> "$root/runtime.rules"
printf '%s\n' '-A OUTPUT -p tcp -m tcp --sport 9443 --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500' >> "$IPTABLES_RULES_PATH"
# Uninstall must use recorded ports, not today's override, even with SKIP set.
WSTUNNEL_PORT=9443 SERVERINATOR_SKIP_MSS=1
ASSUME_YES=1 uninstall_vps
[[ $(cat "$root/runtime.rules") == "$foreign" ]] || exit 34
[[ $(cat "$SERVERINATOR_IPTABLES_RULES_PATH") != *serverinator-mss* ]] || exit 35
grep -Fxq -- '-A OUTPUT -p tcp -m tcp --sport 9443 --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500' "$IPTABLES_RULES_PATH" || exit 38
# An installation which only reused a foreign rule owns nothing.
WSTUNNEL_PORT=9443 SERVERINATOR_SKIP_MSS=0
fix_pmtu_clamp
[[ $(cat "$root/runtime.rules") == "$foreign" ]] || exit 36
before=$(wc -l < "$root/iptables.calls")
ASSUME_YES=1 uninstall_vps
[[ $(wc -l < "$root/iptables.calls") == "$before" ]] || exit 37
MOCK
assert_eq 0 "$rc" 'default/explicit skip makes no firewall calls; uninstall removes only recorded owned rule'
if [[ "$rc" != 0 ]]; then cat "$tmp/mss.log"; fi

# An active firewall that blocks the wstunnel port is the usual reason a fresh install can't connect.
echo "Test: firewall warning"
fw() { # SCENARIO
    SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/f" bash -c 'source "$1"; WSTUNNEL_PORT=9443; scenario="$2"
        have_cmd() { case "$1" in ufw) [[ $scenario == ufw* ]];; iptables) [[ $scenario == ipt* ]];; *) return 1;; esac; }
        ufw() { echo "Status: active"; echo; [[ $scenario == ufw-open ]] && echo "9443/tcp                   ALLOW       Anywhere"; echo "22/tcp ALLOW Anywhere"; }
        iptables() { echo "-P INPUT DROP"; [[ $scenario == ipt-open ]] && echo "-A INPUT -p tcp -m tcp --dport 9443 -j ACCEPT"; true; }
        check_firewall' _ "$VPS_SCRIPT" "$1" 2>&1
}
assert_contains "$(fw ufw-closed)" 'ufw allow 9443/tcp' 'active ufw without the port: warns with the command'
assert_eq '' "$(fw ufw-open)" 'ufw with the port open: silent'
assert_contains "$(fw ipt-closed)" 'iptables -I INPUT -p tcp --dport 9443' 'default-drop iptables: warns'
assert_eq '' "$(fw ipt-open)" 'iptables with an ACCEPT rule: silent'
assert_eq '' "$(fw none)" 'no firewall: silent'

exit "$TESTS_FAILED"
