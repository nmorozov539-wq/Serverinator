#!/usr/bin/env bash
# The wstunnel autostart must notice the network quickly on Android, where the
# default route lives in per-network tables and the main table has none.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/vps" \
       SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service" \
       SERVERINATOR_STATE_DIR="$tmp/state"
mkdir -p "$tmp/root/etc/wireguard" "$tmp/service" "$tmp/state/backups"
printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= > "$tmp/root/etc/wireguard/client.key"
printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= > "$tmp/root/etc/wireguard/client.pub"
source "$PHONE_SCRIPT"; set +e

make_back() { cat > "$tmp/back.json" <<JSON
{"version":1,"device_name":"phone","vps_ip":"$1","phone_wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","vps_wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","phone_wg_ip":"$TEST_PHONE_IP","vps_wg_ip":"10.66.69.1","ssh_enabled":0}
JSON
}
BACK_HANDOFF_FILE="$tmp/back.json"
script="$tmp/service/10-serverinator-wstunnel.sh"

make_back 203.0.113.9; apply_back_handoff > "$tmp/out" 2>&1
assert_contains "$(cat "$script")" 'ip route get 203.0.113.9' 'probes a route to the VPS'
assert_not_contains "$(cat "$script")" 'ip route show default' 'no longer looks for a main-table default route'

# Pull out just the wait loop and run it with a mocked ip and sleep.
sed -n '/^i=0$/,/^done$/p' "$script" > "$tmp/wait.sh"
run_wait() { # IP_ROUTE_GET_SCRIPT -> prints the number of sleeps
    cat > "$tmp/run.sh" <<RUN
n=0; : > "$tmp/calls"
sleep() { n=\$((n+1)); }
# ip runs inside \$(...), so count calls in a file.
ip() {
    echo x >> "$tmp/calls"; calls=\$(wc -l < "$tmp/calls")
    case "\$*" in
        'route show default') return 0 ;;
        'route get '*) $1 ;;
    esac
}
. "$tmp/wait.sh"
echo "\$n"
RUN
    sh "$tmp/run.sh"
}

android='echo "203.0.113.9 via 192.168.1.1 dev wlan0 table wlan0 src 192.168.1.5 uid 0"'
assert_eq 0 "$(run_wait "$android")" 'Android routing: no waiting at all'
assert_eq 3 "$(run_wait 'if [ $calls -le 3 ]; then echo "RTNETLINK answers: Network is unreachable" >&2; return 2; fi; '"$android")" 'network down at first: waits only until it is up'
assert_eq 60 "$(run_wait 'echo "local 203.0.113.9 dev lo table local src 127.0.0.1"')" 'loopback-only route does not count'
assert_eq 60 "$(run_wait 'echo "203.0.113.9 dev dummy0 table dummy0 src 192.0.0.8"')" 'dummy0 route does not count'
assert_eq 60 "$(run_wait 'echo "unreachable 203.0.113.9 table main"')" 'unreachable route does not count'

# A VPS given by name can't be routed before DNS works; probe a public address.
make_back vps.example.com; apply_back_handoff > "$tmp/out" 2>&1
assert_contains "$(cat "$script")" 'ip route get 1.1.1.1' 'hostname VPS: probes a public address'

exit "$TESTS_FAILED"
