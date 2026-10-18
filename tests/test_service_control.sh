#!/usr/bin/env bash
# core-phone.sh --start/--stop/--restart (si start|stop|restart): the boot
# scripts started and stopped without a reboot, by pid file and exact argv.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d)
cleanup() { pkill -f "$tmp/service/" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
export SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service" \
    SERVERINATOR_STATE_DIR="$tmp/state" SERVERINATOR_COLOR=never
mkdir -p "$tmp/root/etc/wireguard" "$tmp/service" "$tmp/state/run"
touch "$tmp/root/etc/wireguard/wg-si.conf"
printf '#!/system/bin/sh\necho mounted >> "%s/mounts"\n' "$tmp" > "$tmp/service/00-serverinator-mount.sh"
for s in 10-serverinator-wstunnel:wstunnel 20-serverinator-wireguard:wireguard 30-serverinator-sshd:sshd; do
    f="${s%%:*}"; n="${s##*:}"
    printf '#!/system/bin/sh\necho $$ > "%s/state/run/%s-supervisor.pid"\nwhile :; do sleep 1; done\n' "$tmp" "$n" > "$tmp/service/$f.sh"
done
ctl() { bash "$PHONE_SCRIPT" "$@" 2>&1; }
alive() { local p; read -r p < "$tmp/state/run/$1-supervisor.pid" 2>/dev/null && [[ -d /proc/$p ]]; }
wait_alive() { for _ in $(seq 1 25); do alive "$1" && return 0; sleep 0.2; done; return 1; }

echo "Test: start launches every installed boot script"
out="$(ctl --start)"
assert_contains "$out" 'wstunnel started' 'wstunnel started'
assert_contains "$out" 'sshd started' 'sshd started'
assert_not_contains "$out" 'tmpclean' 'a script that is not there is skipped quietly'
assert_file_exists "$tmp/mounts" 'the mount script ran first'
for n in wstunnel wireguard sshd; do wait_alive "$n"; assert_eq 0 "$?" "$n running"; done
assert_contains "$(ctl --start wstunnel)" 'already running' 'starting a running one says so'

echo "Test: stop one, then restart all"
read -r old < "$tmp/state/run/sshd-supervisor.pid"
out="$(ctl --stop sshd)"
assert_contains "$out" 'sshd stopped' 'sshd stopped'
[[ ! -d /proc/$old ]]; assert_eq 0 "$?" 'its process is gone'
alive wstunnel; assert_eq 0 "$?" 'the others keep running'
read -r old < "$tmp/state/run/wstunnel-supervisor.pid"
out="$(ctl --restart)"
assert_contains "$out" 'wstunnel stopped' 'restart stops'
assert_contains "$out" 'sshd started' 'and starts'
wait_alive wstunnel
read -r new < "$tmp/state/run/wstunnel-supervisor.pid"
[[ "$new" != "$old" && ! -d /proc/$old ]]; assert_eq 0 "$?" 'wstunnel is a new process'

echo "Test: refusals"
rc=0; out="$(ctl --start frobd)" || rc=$?
assert_eq 1 "$rc" 'unknown service refused'
assert_contains "$out" 'one of: wstunnel wireguard sshd' 'and the valid ones listed'
echo 99999999 > "$tmp/state/run/wireguard-supervisor.pid"
rc=0; ctl --stop wireguard > /dev/null || rc=$?
assert_eq 0 "$rc" 'a stale pid file is no problem'
sleep 300 & other=$!
echo "$other" > "$tmp/state/run/sshd-supervisor.pid"
rc=0; out="$(ctl --restart sshd)" || rc=$?
assert_eq 0 "$rc" 'a pid file pointing at something else (a reused pid) is treated as stale'
assert_contains "$out" 'stale' 'and said so'
[[ -d /proc/$other ]]; assert_eq 0 "$?" 'that process is left alone'
assert_contains "$out" 'sshd started' 'and the restart still starts sshd'
wait_alive sshd; assert_eq 0 "$?" 'sshd running again'
kill "$other"
rm "$tmp/root/etc/wireguard/wg-si.conf"
rc=0; out="$(ctl --start)" || rc=$?
assert_eq 1 "$rc" 'no install, no start'
exit "$TESTS_FAILED"
