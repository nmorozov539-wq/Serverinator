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

# The network the VPS is reached through, for reconnecting after a switch.
sed -n '/^route_dev() {$/,/^}$/p' "$script" > "$tmp/dev.sh"
dev_of() { # IP_ROUTE_GET_OUTPUT
    printf 'ip() { echo "%s"; }\n. "%s"\nroute_dev\n' "$1" "$tmp/dev.sh" > "$tmp/devrun.sh"
    sh "$tmp/devrun.sh"
}
assert_eq wlan0 "$(dev_of '203.0.113.9 via 192.168.1.1 dev wlan0 table wlan0 src 192.168.1.5 uid 0')" 'route_dev: Wi-Fi'
assert_eq rmnet_data1 "$(dev_of '203.0.113.9 via 100.1.1.1 dev rmnet_data1 table rmnet_data1 src 100.1.1.2 uid 0')" 'route_dev: mobile data'
assert_eq '' "$(dev_of 'local 203.0.113.9 dev lo table local src 127.0.0.1')" 'route_dev: loopback is no network'
assert_eq '' "$(dev_of 'unreachable 203.0.113.9 table main')" 'route_dev: unreachable is no network'
content="$(cat "$script")"
assert_contains "$content" 'network changed (' 'supervisor logs a network switch'
sh -n "$script"; assert_eq 0 "$?" 'generated supervisor is valid sh'

# The watch loop: started on mobile data, the phone moves to Wi-Fi; wstunnel
# is stopped so the outer loop starts it again on Wi-Fi.
sed -n '/^    dev=\$(route_dev)$/,/^    done$/p' "$script" > "$tmp/watch.sh"
cat > "$tmp/watchrun.sh" <<RUN
LOG="$tmp/watch.log"; : > "\$LOG"; n=0
rotate_log() { :; }
sleep() { n=\$((n+1)); [ \$n -lt 20 ] || exit 3; }
route_dev() { if [ -f "$tmp/onwifi" ]; then echo wlan0; else echo rmnet_data1; fi; }
kill() { if [ "\$1" = -0 ]; then [ ! -f "$tmp/killed" ]; else touch "$tmp/killed"; fi; }
child=123
(sleep 0)
. "$tmp/watch.sh"
echo "sleeps=\$n"
RUN
rm -f "$tmp/onwifi" "$tmp/killed"
# Switch to Wi-Fi after the first check.
sed -i 's|^route_dev() {|route_dev() { [ "\$n" -ge 2 ] \&\& touch "'"$tmp"'/onwifi";|' "$tmp/watchrun.sh"
out="$(sh "$tmp/watchrun.sh" 2>&1)"; rc=$?
assert_eq 0 "$rc" 'watch loop ends instead of waiting forever'
assert_file_exists "$tmp/killed" 'wstunnel stopped after the switch'
assert_contains "$(cat "$tmp/watch.log")" 'network changed (rmnet_data1 -> wlan0)' 'switch is logged'
rm -f "$tmp/onwifi" "$tmp/killed"
sed -i 's|\[ "\$n" -ge 2 \] \&\& touch|[ "\$n" -ge 99 ] \&\& touch|' "$tmp/watchrun.sh"
out="$(sh "$tmp/watchrun.sh" 2>&1)"; rc=$?
assert_eq 3 "$rc" 'same network: wstunnel keeps running'
assert_file_missing "$tmp/killed" 'same network: nothing stopped'

# A VPS given by name can't be routed before DNS works; probe a public address.
make_back vps.example.com; apply_back_handoff > "$tmp/out" 2>&1
assert_contains "$(cat "$script")" 'ip route get 1.1.1.1' 'hostname VPS: probes a public address'

exit "$TESTS_FAILED"
