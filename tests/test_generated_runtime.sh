#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if rg -n ': > .*usr/sbin/sshd' "$REPO_ROOT/tests/test_ssh.sh" > "$tmp/fixture"; then
 failtest 'empty sshd fixture must be replaced with executable or explicit SKIP'
else pass 'no empty sshd fixture'; fi
export SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service" SERVERINATOR_STATE_DIR="$tmp/state"
mkdir -p "$tmp/root/etc/wireguard" "$tmp/service" "$tmp/root/usr/sbin"
printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= > "$tmp/root/etc/wireguard/client.key"
cat > "$tmp/back.json" <<JSON
{"version":1,"device_name":"phone","vps_ip":"203.0.113.5","vps_wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","phone_wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","phone_wg_ip":"$TEST_PHONE_IP","vps_wg_ip":"10.66.69.1","ssh_enabled":0}
JSON
source "$PHONE_SCRIPT"; set +e
write_mount_script; write_sshd_autostart
# wstunnel autostart is written by apply_back_handoff (needs VPS IP from back-handoff)
BACK_HANDOFF_FILE="$tmp/back.json"; apply_back_handoff > "$tmp/out" 2>&1
shell=()
if [[ -n "${SERVERINATOR_TEST_BUSYBOX:-}" ]]; then shell=("$SERVERINATOR_TEST_BUSYBOX" ash)
elif command -v busybox >/dev/null; then shell=(busybox ash)
elif command -v dash >/dev/null; then shell=(dash)
fi
if [[ ${#shell[@]} == 0 ]]; then
 printf '%s\n' 'SKIP: BusyBox ash/dash unavailable; generated-shell syntax unverified'
else
 for script in "$tmp/service/"*.sh; do
  "${shell[@]}" -n "$script"; assert_eq 0 "$?" "POSIX shell syntax: $(basename "$script")"
 done
fi
# Execute the generated chroot command twice with a WireGuard mock which, like
# setconf/syncconf, allocates a new port when ListenPort is omitted.
rc=0
(
 chroot() { printf '%s\n' "${@: -1}" > "$tmp/wg-command"; }
 sleep() { :; }
 sed 's/sleep 30$/exit 0/' "$tmp/service/20-serverinator-wireguard.sh" > "$tmp/runner"
 (source "$tmp/runner")
 sed "s|/etc/wireguard/|$tmp/root/etc/wireguard/|g" "$tmp/wg-command" > "$tmp/wg-command-local"
 listen_port=48477
 wg() {
  case "$1" in
   show) printf '%s\n' "$listen_port";;
   syncconf)
    cp "$3" "$tmp/synced"
    value=$(awk '$1=="ListenPort" {print $3}' "$3")
    listen_port="${value:-48478}";;
  esac
 }
 wg-quick() { cat "$2"; }
 ip() { if [[ "$*" == '-4 rule show' ]]; then echo '100: to 10.66.69.0/24 lookup main'; fi; }
 source "$tmp/wg-command-local"
 source "$tmp/wg-command-local"
 [[ "$listen_port" == 48477 ]] || exit 41
 [[ $(grep -c '^ListenPort = 48477$' "$tmp/synced") == 1 ]] || exit 42
) > "$tmp/wg-test.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'generated reconciliation preserves automatic WG port across cycles'
if [[ "$rc" != 0 ]]; then cat "$tmp/wg-test.log"; fi
if ! command -v sshd >/dev/null; then
 printf '%s\n' 'SKIP: real sshd unavailable'
else
 ssh-keygen -q -t ed25519 -N '' -f "$tmp/hostkey"
 sshd_bin=$(command -v sshd)
 # Real generated drop-in; rewrite only host-specific Include for local parsing.
 mkdir -p "$tmp/root/etc/ssh/sshd_config.d"
 cat > "$tmp/ssh-back.json" <<JSON
{"ssh_enabled":1,"ssh_phone_ip":"$TEST_PHONE_IP","phone_wg_ip":"$TEST_PHONE_IP","ssh_user":"root","ssh_client_key_count":0}
JSON
 cp "$sshd_bin" "$tmp/root/usr/sbin/sshd"
 BACK_HANDOFF_FILE="$tmp/ssh-back.json"
 apply_ssh_config > "$tmp/out" 2>&1
 cat > "$tmp/sshd_config" <<CONFIG
Include $tmp/root/etc/ssh/sshd_config.d/*.conf
HostKey $tmp/hostkey
CONFIG
 if "$sshd_bin" -t -f "$tmp/sshd_config" > "$tmp/check" 2>&1; then
  pass 'real sshd parses generated configuration'
  "$sshd_bin" -T -f "$tmp/sshd_config" > "$tmp/effective" 2> "$tmp/check"
  assert_eq 0 "$?" 'real sshd effective config succeeds'
  assert_contains "$(awk '{$1=tolower($1); print}' "$tmp/effective")" "listenaddress $TEST_PHONE_IP:2222" 'real effective tunnel listener'
  assert_contains "$(awk '{$1=tolower($1); print}' "$tmp/effective")" 'passwordauthentication no' 'real password policy'
 else
  if grep -q 'Missing privilege separation directory' "$tmp/check"; then
   printf '%s\n' 'SKIP: real sshd requires unavailable host privilege-separation directory'
  else cat "$tmp/check"; failtest 'real sshd rejected generated config'; fi
 fi
fi
exit "$TESTS_FAILED"
