#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service"
mkdir -p "$SERVERINATOR_CHROOT/etc/ssh"
printf '# Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication yes\n' > "$SERVERINATOR_CHROOT/etc/ssh/sshd_config"
source "${TEST_PHONE_SCRIPT:-$PHONE_SCRIPT}"; set +e
ensure_sshd_include
assert_eq 1 "$(grep -c '^Include /etc/ssh/sshd_config.d/\*.conf$' "$CHROOT/etc/ssh/sshd_config")" 'commented Include repaired'
output="port 2222
passwordauthentication no
listenaddress ${TEST_PHONE_IP}:2222"
chroot_run() { printf '%s\n' "$output"; }
rc=0; (validate_effective_sshd "$TEST_PHONE_IP") > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'expected effective configuration accepted'
for bad in 'port 22' 'passwordauthentication yes' 'listenaddress 0.0.0.0:2222'; do
 case "$bad" in port*) output="port 22
passwordauthentication no
listenaddress ${TEST_PHONE_IP}:2222";; password*) output="port 2222
passwordauthentication yes
listenaddress ${TEST_PHONE_IP}:2222";; *) output="port 2222
passwordauthentication no
$bad";; esac
 rc=0; (validate_effective_sshd "$TEST_PHONE_IP") > "$tmp/out" 2>&1 || rc=$?
 assert_eq 1 "$rc" "effective drift rejected: $bad"
done
exit "$TESTS_FAILED"
