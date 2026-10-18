#!/usr/bin/env bash
# Regressions from the outside review of 2026-10-18 (docs/ServerInator code
# review (commit bd8e6cf).md): B1, B2, B4, B5, B6, B9 and the smaller items.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

echo "Test: B1 a silent server is not 'handshake completed'"
cat > "$tmp/bin/curl" <<'C'
#!/bin/bash
echo "* TLS handshake, Client hello (1):" >&2
echo "curl: (28) Connection timed out after 15001 milliseconds" >&2
exit 28
C
chmod +x "$tmp/bin/curl"
rc=0; out="$(PATH="$tmp/bin:$PATH" bash -c 'source "$1"; VPS_HOST=203.0.113.9; step_wss_preflight' _ "$REPO_ROOT/serverinator.sh" 2>&1)" || rc=$?
assert_eq 1 "$rc" 'hang reported as failure'
assert_contains "$out" 'hung' 'and called a hang'
assert_not_contains "$out" 'all good' 'never "all good"'
printf '#!/bin/bash\necho "* SSL certificate problem: self-signed certificate" >&2\nexit 60\n' > "$tmp/bin/curl"
rc=0; out="$(PATH="$tmp/bin:$PATH" bash -c 'source "$1"; VPS_HOST=203.0.113.9; step_wss_preflight' _ "$REPO_ROOT/serverinator.sh" 2>&1)" || rc=$?
assert_eq 0 "$rc" 'self-signed answer is fine'
assert_contains "$out" 'expected certificate error' 'and said so'

echo "Test: B2 a device name that prefixes another is counted apart"
printf '# ServerInator peer: rn9p\n[Peer]\n# ServerInator peer: rn9\n[Peer]\n' > "$tmp/wg.conf"
assert_eq 1 "$(bash -c 'source "$1"; peer_block_count "$2" rn9' _ "$VPS_SCRIPT" "$tmp/wg.conf" 2>/dev/null)" 'rn9 counted once'
assert_eq 0 "$(bash -c 'source "$1"; peer_block_count "$2" phone' _ "$VPS_SCRIPT" "$tmp/wg.conf" 2>/dev/null)" 'unknown device counts zero'

echo "Test: B4 appending to authorized_keys without a final newline"
mkdir -p "$tmp/admin/.ssh"; printf 'ssh-ed25519 AAAAOLD admin@laptop' > "$tmp/admin/.ssh/authorized_keys"
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/dev" SERVERINATOR_VPS_ADMIN_HOME="$tmp/admin" \
    bash -c 'source "$1"; _authorize_vps_jump_key "ssh-ed25519 AAAANEW c" 10.66.69.2 2222' _ "$VPS_SCRIPT" > /dev/null 2>&1
assert_eq 'ssh-ed25519 AAAAOLD admin@laptop' "$(head -n 1 "$tmp/admin/.ssh/authorized_keys")" 'admin key line intact'
assert_eq 2 "$(wc -l < "$tmp/admin/.ssh/authorized_keys")" 'jump entry on its own line'
mkdir -p "$tmp/h/.ssh"; printf 'ssh-ed25519 AAAAOLD x' > "$tmp/h/.ssh/authorized_keys"
snippet="$(bash -c 'source "$1"; source "$2"; printf "%s" "$AUTH_INSTALL_SNIPPET"' _ "$REPO_ROOT/core/lib.sh" "$REPO_ROOT/core/vps-auth.sh" 2>/dev/null)"
echo 'ssh-ed25519 AAAANEW y' | HOME="$tmp/h" sh -c "$snippet" > /dev/null
assert_eq $'ssh-ed25519 AAAAOLD x\nssh-ed25519 AAAANEW y' "$(cat "$tmp/h/.ssh/authorized_keys")" 'install snippet keeps keys apart'

echo "Test: B5 a client can be revoked while the phone is offline"
devroot="$tmp/vps"; phone_home="$tmp/phone"; mkdir -p "$phone_home"
cat > "$tmp/handoff.json" <<JSON
{"version":1,"device_name":"rn9p","wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","wstunnel_port":9443,"wg_port":51822,
 "ssh_enabled":1,"ssh_user":"root","ssh_port":2222,"ssh_host_fingerprint":"SHA256:TEST"}
JSON
vps() { SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" SERVERINATOR_VPS_IP=203.0.113.9 bash -c '
    source "$1"; shift
    ssh() { [ -f "'"$tmp"'/offline" ] && return 255; local cmd="${!#}"; HOME="'"$phone_home"'" bash -c "$cmd"; }
    main "$@"' _ "$VPS_SCRIPT" "$@"; }
vps "$tmp/handoff.json" --vps-ip 203.0.113.9 > /dev/null 2>&1
vps --add-client lost --generate-key > /dev/null 2>&1
pub="$(cat "$devroot/etc/wireguard/serverinator/ssh/owner_rn9p_lost.pub")"
touch "$tmp/offline"
rc=0; out="$(vps --revoke-client lost 2>&1)" || rc=$?
assert_eq 1 "$rc" 'reports the phone part as not done'
assert_not_contains "$(cat "$devroot/root/.ssh/authorized_keys")" "$pub" 'but the VPS hop is cut'
assert_contains "$out" 'again once the tunnel is up' 'and says what to do'
rm "$tmp/offline"
rc=0; vps --revoke-client lost > /dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'second run with the phone back finishes'
assert_not_contains "$(cat "$phone_home/.ssh/authorized_keys")" "$pub" 'phone cleaned'
rc=0; vps --list-clients stray > "$tmp/stray.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'a stray argument is refused outside setup'

echo "Test: B6 core-phone.sh refuses a stray word instead of looping"
rc=0; out="$(timeout 10 bash "$PHONE_SCRIPT" foo 2>&1)" || rc=$?
assert_eq 1 "$rc" 'exits with an error (not a hang: 124)'
assert_contains "$out" 'Unknown argument: foo' 'names it'

echo "Test: B9 key folders can't be shared with guests"
for p in /root/.ssh /home/x/.ssh/keys /root/.gnupg /srv/files/.ssh; do
    rc=0; bash -c 'source "$1" >/dev/null 2>&1; folder_path_ok "$2"' _ "$REPO_ROOT/core/guest-helper.sh" "$p" || rc=$?
    assert_eq 1 "$rc" "$p refused"
done
rc=0; bash -c 'source "$1" >/dev/null 2>&1; folder_path_ok /srv/files/photos' _ "$REPO_ROOT/core/guest-helper.sh" || rc=$?
assert_eq 0 "$rc" 'a normal folder still works'

echo "Test: reconcile_file stages next to its backups, not in service.d"
mkdir -p "$tmp/sd" "$tmp/bk"
bash -c 'source "$1"; mktemp() { echo "$*" >> "'"$tmp"'/mk"; command mktemp "$@"; }; echo x | reconcile_file "$2/s.sh" 700 "$3"' \
    _ "$REPO_ROOT/core/lib.sh" "$tmp/sd" "$tmp/bk" > /dev/null
assert_contains "$(cat "$tmp/mk")" "$tmp/bk/" 'temp file in the backup folder'
assert_eq 's.sh' "$(ls -A "$tmp/sd")" 'nothing else left in service.d'
exit "$TESTS_FAILED"
