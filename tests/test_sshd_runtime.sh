#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service" SERVERINATOR_STATE_DIR="$tmp/state"
mkdir -p "$tmp/root/usr/bin" "$tmp/root/usr/sbin" "$tmp/service"
touch "$tmp/root/usr/bin/wg" "$tmp/root/usr/sbin/sshd"
source "$PHONE_SCRIPT"
set +e
calls="$tmp/calls"
chroot_run() {
 printf '%s\n' "$*" >> "$calls"
 case "$1" in
  /usr/bin/dpkg-query) if [[ -f "$tmp/installed" ]]; then printf "install ok installed"; return 0; else return 1; fi;;
  /usr/bin/apt-get) touch "$tmp/installed";;
  /usr/bin/getent) return 2;;
  /usr/sbin/sshd) if [[ "${2:-}" == -T ]]; then printf "port 2222\npasswordauthentication no\n"; fi;;
 esac
 return 0
}
install_chroot_packages
assert_not_contains "$(cat "$calls")" 'AllowUnauthenticated' 'package installation requires authentication'
# A failed repository refresh must stop before installing anything, even when
# the caller invokes the function in a conditional (which disables errexit).
rm -f "$tmp/installed"
chroot_run() {
 printf '%s\n' "$*" >> "$tmp/failed-apt.calls"
 case "$1" in
  /usr/bin/dpkg-query) return 1;;
  /usr/bin/apt-get) [[ "$2" != update ]];;
 esac
}
rc=0
(install_chroot_packages) > "$tmp/failed-apt.out" 2>&1 || rc=$?
assert_eq 1 "$rc" 'failed repository refresh aborts package setup'
assert_not_contains "$(cat "$tmp/failed-apt.calls")" 'install -y' 'no install after failed repository refresh'
# Restore the runtime mock used below.
touch "$tmp/installed"
chroot_run() {
 printf '%s\n' "$*" >> "$calls"
 case "$1" in
  /usr/bin/dpkg-query) printf 'install ok installed';;
  /usr/bin/getent) return 2;;
  /usr/sbin/sshd) if [[ "${2:-}" == -T ]]; then printf "port 2222\npasswordauthentication no\n"; fi;;
 esac
 return 0
}
rc=0; (prepare_sshd_runtime) > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'prepare runtime succeeds with absent account'
assert_contains "$(cat "$calls")" 'apt-get' 'missing package is installed despite binary'
assert_contains "$(cat "$calls")" 'useradd' 'absent privilege-separation user created'
assert_contains "$(cat "$calls")" '/usr/sbin/sshd -t' 'configuration checked before enabling'
write_sshd_autostart
script=$(cat "$tmp/service/30-serverinator-sshd.sh")
assert_contains "$script" 'logs' 'persistent log directory'
assert_contains "$script" '1048576' 'rotation size threshold'
assert_contains "$script" 'PATH=/usr/local/sbin:' 'explicit runtime PATH'
if command -v dash >/dev/null; then dash -n "$tmp/service/30-serverinator-sshd.sh"; assert_eq 0 "$?" 'dash syntax'; fi
exit "$TESTS_FAILED"
