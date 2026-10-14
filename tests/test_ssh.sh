#!/usr/bin/env bash
# Tests the SSH-access feature without touching a real sshd or network:
# handoff/back-handoff fields, authorized_keys append+dedupe, sshd_config
# generation, existing-vs-new client key selection, and the client snippet.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_STATE_DIR="$tmp/state"

# ── Phone: handoff carries SSH info ───────────
mkdir -p "$tmp/p1/etc/wireguard"
echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$tmp/p1/etc/wireguard/client.pub"

SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/p1" SERVERINATOR_SERVICE_D="$tmp/p1svc" \
SERVERINATOR_DEVICE_NAME=rn9p \
    bash -c 'source "$1"; SSH_HOST_FINGERPRINT="SHA256:FP123"; generate_handoff' \
    _ "$PHONE_SCRIPT" >/dev/null 2>&1
h="$tmp/p1/etc/wireguard/handoff.json"

echo "Test: phone handoff includes SSH fields"
assert_file_exists "$h" "handoff written"
assert_contains "$(cat "$h")" '"ssh_enabled": 1' "ssh_enabled=1"
assert_contains "$(cat "$h")" '"ssh_user": "root"' "ssh_user root"
assert_contains "$(cat "$h")" '"ssh_port": 2222' "ssh_port carried"
assert_contains "$(cat "$h")" '"ssh_host_fingerprint": "SHA256:FP123"' "fingerprint carried"

echo "Test: --no-ssh disables SSH in the handoff"
mkdir -p "$tmp/p1b/etc/wireguard"
echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$tmp/p1b/etc/wireguard/client.pub"
SERVERINATOR_DEV=0 SERVERINATOR_NO_SSH=1 SERVERINATOR_CHROOT="$tmp/p1b" \
SERVERINATOR_SERVICE_D="$tmp/p1bsvc" SERVERINATOR_DEVICE_NAME=rn9p \
    bash -c 'source "$1"; generate_handoff' _ "$PHONE_SCRIPT" >/dev/null 2>&1
assert_contains "$(cat "$tmp/p1b/etc/wireguard/handoff.json")" '"ssh_enabled": 0' "ssh_enabled=0"

# ── Phone: apply writes authorized_keys + sshd_config, idempotent ──
if command -v sshd >/dev/null; then
mkdir -p "$tmp/p2/etc/wireguard" "$tmp/p2/usr/sbin" "$tmp/p2svc"
echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$tmp/p2/etc/wireguard/client.key"
cp "$(command -v sshd)" "$tmp/p2/usr/sbin/sshd"
cat > "$tmp/p2/back.json" <<EOF
{
  "version": 1,
  "device_name": "rn9p",
  "vps_ip": "203.0.113.5",
  "vps_wg_pubkey": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=",
  "phone_wg_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  "phone_wg_ip": "${TEST_PHONE_IP}",
  "vps_wg_ip": "10.66.69.1",
  "wg_port": 51822,
  "wstunnel_port": 9443,
  "ssh_enabled": 1,
  "ssh_user": "root",
  "ssh_phone_ip": "${TEST_PHONE_IP}",
  "ssh_vps_host": "203.0.113.5",
  "ssh_vps_user": "vpsuser",
  "ssh_vps_to_phone_pubkey": "ssh-ed25519 VPSPHONEKEY vps@host",
  "ssh_host_fingerprint": "SHA256:PHONE",
  "ssh_client_key_count": 2,
  "ssh_client_key_1": "ssh-ed25519 CLIENTKEY1 client1@host",
  "ssh_client_key_2": "ssh-rsa CLIENTKEY2 client2@host"
}
EOF

apply_p2() {
    SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/p2" SERVERINATOR_SERVICE_D="$tmp/p2svc" \
        bash -c 'source "$1"; parse_args --apply-back-handoff "$2"; prepare_sshd_runtime() { :; }; apply_back_handoff' \
        _ "$PHONE_SCRIPT" "$tmp/p2/back.json" >/dev/null 2>&1
}

echo "Test: apply-back-handoff installs SSH keys and config"
apply_p2
rc=$?
assert_eq 0 "$rc" "apply succeeds"
ak="$tmp/p2/root/.ssh/authorized_keys"
assert_file_exists "$ak" "authorized_keys created"
assert_contains "$(cat "$ak")" "VPSPHONEKEY" "VPS->phone key authorized"
assert_contains "$(cat "$ak")" "CLIENTKEY1" "client key 1 authorized"
assert_contains "$(cat "$ak")" "CLIENTKEY2" "client key 2 authorized"
conf="$tmp/p2/etc/ssh/sshd_config.d/00-serverinator.conf"
assert_file_exists "$conf" "sshd drop-in written"
assert_contains "$(cat "$tmp/p2/etc/ssh/sshd_config")" "Include /etc/ssh/sshd_config.d/*.conf" "main config includes drop-in dir"
assert_contains "$(cat "$conf")" "Port 2222" "sshd on port 2222"
assert_contains "$(cat "$conf")" "ListenAddress ${TEST_PHONE_IP}" "tunnel-only listen address"
assert_contains "$(cat "$conf")" "PermitRootLogin prohibit-password" "root key-only"
assert_contains "$(cat "$conf")" "PasswordAuthentication no" "password auth off"
assert_contains "$(cat "$conf")" "KexAlgorithms curve25519-sha256" "small KEX pinned (no sntrup761)"
assert_contains "$(cat "$conf")" "HostKeyAlgorithms ssh-ed25519" "host key algorithm pinned"
assert_file_exists "$tmp/p2svc/30-serverinator-sshd.sh" "sshd autostart written"

echo "Test: re-applying does not duplicate keys"
before="$(grep -c . "$ak")"
apply_p2
after="$(grep -c . "$ak")"
assert_eq "$before" "$after" "authorized_keys unchanged on re-apply"

else
    echo "SKIP: sshd unavailable; SSH configuration fixture requires real executable"
fi

# ── VPS: key selection ────────────────────────
# Helper: create a mock home dir for SUDO_USER=vpsuser with an authorized_keys
setup_v1_home() {
    mkdir -p "$tmp/v1/vpsuserhome/.ssh"
    cat > "$tmp/v1/vpsuserhome/.ssh/authorized_keys" <<EOF
# a comment
ssh-ed25519 AAAACLIENT1ONE client1@host
ssh-rsa AAAACLIENT2TWO client2@host
EOF
}
setup_v1_home

echo "Test: VPS reads existing client keys when present"
out="$(SUDO_USER=vpsuser SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/v1/dev" \
    SERVERINATOR_SSH_KEY_DIR="$tmp/v1/keys" \
    SERVERINATOR_VPS_IP=203.0.113.5 \
    bash -c 'source "$1"
             getent() { printf "vpsuser:x:1000:1000::'"$tmp"'/v1/vpsuserhome:/bin/sh\n"; }
             DEVICE_NAME=rn9p; SSH_ENABLED=1; CLIENT_KEYS_MODE=existing
             setup_vps_ssh_keys
             printf "COUNT=%s\nNEW=%s\nVPSPUB=%s\nUSER=%s\n" \
               "${#SSH_CLIENT_KEYS[@]}" "$SSH_CLIENT_KEY_IS_NEW" \
               "$SSH_VPS_TO_PHONE_PUBKEY" "$SSH_VPS_USER"' _ "$VPS_SCRIPT" 2>&1)"
assert_contains "$out" "COUNT=2" "two existing keys selected"
assert_contains "$out" "NEW=0" "not marked new"
assert_contains "$out" "VPSPUB=ssh-ed25519 " "VPS->phone key generated"
assert_contains "$out" "USER=vpsuser" "invoking user detected"
assert_file_exists "$tmp/v1/keys/vps_to_phone" "VPS->phone key on disk"
assert_file_exists "$tmp/v1/keys/vps_to_phone.pub" "VPS->phone pubkey on disk"

echo "Test: VPS generates a client key when none exist"
out="$(SUDO_USER=vpsuser SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/v2/dev" \
    SERVERINATOR_SSH_KEY_DIR="$tmp/v2/keys" \
    SERVERINATOR_VPS_IP=203.0.113.5 \
    bash -c 'source "$1"
             getent() { printf "vpsuser:x:1000:1000::'"$tmp"'/v2/vpsuserhome:/bin/sh\n"; }
             DEVICE_NAME=rn9p; SSH_ENABLED=1; CLIENT_KEYS_MODE=new
             PHONE_WG_IP='"${TEST_PHONE_IP}"'; SSH_PHONE_PORT=2222
             setup_vps_ssh_keys
             printf "COUNT=%s\nNEW=%s\nKEY=%s\n" \
               "${#SSH_CLIENT_KEYS[@]}" "$SSH_CLIENT_KEY_IS_NEW" "${SSH_CLIENT_KEYS[0]}"' \
    _ "$VPS_SCRIPT" 2>&1)"
assert_contains "$out" "COUNT=1" "one generated key"
assert_contains "$out" "NEW=1" "marked new"
assert_contains "$out" "KEY=ssh-ed25519 " "generated pubkey is ed25519"
assert_file_exists "$tmp/v2/keys/owner_rn9p" "generated private key stored"
assert_file_exists "$tmp/v2/keys/owner_rn9p.pub" "generated public key stored"

echo "Test: SSH disabled on phone skips VPS key setup"
out="$(SUDO_USER=vpsuser SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/v3/dev" \
    SERVERINATOR_SSH_KEY_DIR="$tmp/v3/keys" \
    bash -c 'source "$1"; SSH_ENABLED=0; setup_vps_ssh_keys; echo DONE' _ "$VPS_SCRIPT" 2>&1)"
assert_contains "$out" "skipping" "skips when disabled"
assert_not_contains "$out" "authorized_keys" "does not read keys file"

# ── VPS: back-handoff carries SSH block ───────
mkdir -p "$tmp/v4/vpsuserhome/.ssh"
echo "ssh-ed25519 AAAACLIENT1ONE client1@host" > "$tmp/v4/vpsuserhome/.ssh/authorized_keys"

echo "Test: back-handoff carries SSH fields"
out="$(SUDO_USER=vpsuser SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/v4/dev" \
    SERVERINATOR_SSH_KEY_DIR="$tmp/v4/keys" \
    SERVERINATOR_VPS_IP=203.0.113.5 \
    bash -c 'source "$1"
             getent() { printf "vpsuser:x:1000:1000::'"$tmp"'/v4/vpsuserhome:/bin/sh\n"; }
             DEVICE_NAME=rn9p; SSH_ENABLED=1; SSH_USER=root; SSH_PHONE_PORT=2222
             PHONE_WG_PUBKEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
             PHONE_WG_IP='"${TEST_PHONE_IP}"'
             VPS_WG_PUBKEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=
             VPS_IP=203.0.113.5
             CLIENT_KEYS_MODE=existing
             setup_vps_ssh_keys >/dev/null
             generate_back_handoff >/dev/null
             cat "$BACK_HANDOFF_PATH"' _ "$VPS_SCRIPT" 2>&1)"
assert_contains "$out" '"ssh_enabled": 1' "ssh_enabled in back-handoff"
assert_contains "$out" '"ssh_port": 2222' "SSH port round-trips in back-handoff"
assert_contains "$out" '"ssh_client_key_count": 1' "client key count"
assert_contains "$out" '"ssh_client_key_1": "ssh-ed25519 AAAACLIENT1ONE' "client key value"
assert_contains "$out" '"ssh_vps_to_phone_pubkey": "ssh-ed25519 ' "VPS->phone pubkey"
assert_contains "$out" '"ssh_host_fingerprint"' "fingerprint field present"

# ── VPS: client setup script (existing vs new) ─
run_snippet() { # $1 = existing|new
    SUDO_USER=vpsuser SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/s/dev" \
    SERVERINATOR_SSH_KEY_DIR="$tmp/s/keys" \
    SERVERINATOR_VPS_IP=203.0.113.5 \
        bash -c 'source "$1"
                 getent() { printf "vpsuser:x:1000:1000::'"$tmp"'/v4/vpsuserhome:/bin/sh\n"; }
                 DEVICE_NAME=rn9p; SSH_ENABLED=1; SSH_USER=root
                 SSH_PHONE_PORT=2222; SSH_ALIAS=serverinated
                 PHONE_WG_IP='"${TEST_PHONE_IP}"'; VPS_IP=203.0.113.5; SSH_VPS_USER=vpsuser
                 SSH_HOST_FINGERPRINT=SHA256:PHONE
                 CLIENT_KEYS_MODE="'"$1"'"
                 setup_vps_ssh_keys >/dev/null
                 generate_client_setup >/dev/null
                 cat "$SSH_KEY_DIR/client-setup-owner-rn9p.sh"' _ "$VPS_SCRIPT" 2>&1
}

echo "Test: client snippet uses default alias and ProxyJump (existing key)"
out="$(run_snippet existing)"
assert_contains "$out" "Host serverinated" "default alias host block"
assert_contains "$out" "HostName ${TEST_PHONE_IP}" "phone tunnel address"
assert_contains "$out" "Port 2222" "phone sshd port"
assert_contains "$out" "User root" "root user"
assert_contains "$out" "ProxyJump vpsuser@203.0.113.5" "proxy jump"
assert_contains "$out" "ServerAliveInterval 60" "ssh keepalive interval"
assert_contains "$out" "ServerAliveCountMax 9999" "ssh keepalive count"
assert_contains "$out" "ssh serverinated" "connect hint"
assert_not_contains "$out" "IdentityFile" "no IdentityFile for existing key"

echo "Test: client snippet provides a private file path without secret output"
rm -rf "$tmp/s"
out="$(run_snippet new)"
assert_contains "$out" "IdentityFile ~/.ssh/si-rn9p" "IdentityFile for new key"
assert_not_contains "$out" "PRIVATE KEY" "private key is never printed"
assert_contains "$out" "$tmp/s/keys/owner_rn9p" "private file path provided"
assert_eq 600 "$(stat -c %a "$tmp/s/keys/owner_rn9p")" "private key permissions"
if ssh-keygen -y -f "$tmp/s/keys/owner_rn9p" >/dev/null; then
 pass "saved private key parses with ssh-keygen"
else failtest "saved key does not parse"; fi
exit "$TESTS_FAILED"
