#!/usr/bin/env bash
# Client keys, one per device: pairing scripts that
# carry no secret, --pubkey, VPS-made keys handed out once by --client-script,
# --expires, and the last login per key in --list-clients.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

devroot="$tmp/vps"; phone_home="$tmp/phone_home"; mkdir -p "$phone_home"
cat > "$tmp/handoff.json" <<JSON
{"version":1,"device_name":"rn9p","wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","wstunnel_port":9443,"wg_port":51822,
 "ssh_enabled":1,"ssh_user":"root","ssh_port":2222,"ssh_host_fingerprint":"SHA256:TEST"}
JSON
vps() { # ARGS... — core-vps.sh main in DEV, the phone mocked as a local HOME
    SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" SERVERINATOR_VPS_IP=203.0.113.9 \
    SERVERINATOR_AUTH_LOG="$tmp/auth.log" bash -c '
        source "$1"; shift
        ssh() { local cmd="${!#}"; HOME="'"$phone_home"'" bash -c "$cmd"; }
        main "$@"' _ "$VPS_SCRIPT" "$@"
}
vps "$tmp/handoff.json" --vps-ip 203.0.113.9 --alias rn9p > "$tmp/setup.log" 2>&1
key_dir="$devroot/etc/wireguard/serverinator/ssh"
admin_ak="$devroot/root/.ssh/authorized_keys"
phone_ak="$phone_home/.ssh/authorized_keys"
# A client device: its own HOME with an ssh-keygen that works offline.
device() { # NAME SCRIPT
    mkdir -p "$tmp/dev-$1"
    HOME="$tmp/dev-$1" bash "$2" 2>&1
}

echo "Test: add-client with no key writes a pairing script"
rc=0; out="$(vps --add-client laptop 2>&1)" || rc=$?
assert_eq 0 "$rc" 'pairing succeeds'
script="$key_dir/client-setup-laptop-rn9p.sh"
assert_file_exists "$script" 'pairing script written'
assert_file_missing "$key_dir/owner_rn9p_laptop.pub" 'nothing registered yet'
assert_contains "$(cat "$script")" "SI_KEY_B64=''" 'the script holds no key'
assert_contains "$out" 'si client-script laptop --device rn9p' 'says how to fetch it'
assert_contains "$(vps --list-clients 2>&1)" 'Waiting for approval: laptop' 'listed as waiting'

echo "Test: the device makes its own key and is told how to approve it"
out="$(device laptop "$script")"
assert_file_exists "$tmp/dev-laptop/.ssh/si-rn9p-laptop" 'key made on the device'
assert_contains "$out" "si add-client laptop --device rn9p --pubkey 'ssh-ed25519 " 'prints the approve command'
cfg="$(cat "$tmp/dev-laptop/.ssh/config")"
assert_contains "$cfg" $'Host rn9p-laptop\n' 'alias block'
assert_contains "$cfg" "IdentityFile $tmp/dev-laptop/.ssh/si-rn9p-laptop" 'uses its own key'
assert_contains "$cfg" 'ProxyJump rn9p-laptop-jump' 'jumps through its own block'
assert_contains "$cfg" $'Host rn9p-laptop-jump\n    HostName 203.0.113.9' 'jump block to the VPS'
g="$(ssh -F "$tmp/dev-laptop/.ssh/config" -G rn9p-laptop 2>&1)"
assert_contains "$g" 'proxyjump rn9p-laptop-jump' 'OpenSSH parses it'

echo "Test: approving the device's key"
pub="$(cut -d' ' -f1,2 "$tmp/dev-laptop/.ssh/si-rn9p-laptop.pub")"
rc=0; out="$(vps --add-client laptop --pubkey "$pub" 2>&1)" || rc=$?
assert_eq 0 "$rc" 'approval succeeds'
assert_contains "$(cat "$phone_ak")" "$pub" 'key on the phone'
assert_contains "$(cat "$admin_ak")" "permitopen=\"${TEST_PHONE_IP}:2222\" $pub" 'restricted jump entry on the VPS'
assert_file_missing "$key_dir/owner_rn9p_laptop" 'no private key on the VPS'
assert_contains "$(cat "$script")" "SI_KEY_B64=''" 'the new script holds no key either'
assert_contains "$(cat "$script")" "EXPECTED='$pub'" 'it is tied to that key'
rc=0; vps --add-client tablet --pubkey "$pub" > "$tmp/dup.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'the same key for a second label is refused'
assert_contains "$(cat "$tmp/dup.log")" 'one key per device' 'and says why'

echo "Test: a copied script is useless elsewhere"
out="$(device laptop "$script")"; rc=$?
assert_eq 0 "$rc" 'runs on the device that has the key'
rc=0; out="$(device stranger "$script")" || rc=$?
assert_eq 1 "$rc" 'refused on another device'
assert_contains "$out" "isn't in ~/.ssh" 'says the key is not there'
assert_file_missing "$tmp/dev-stranger/.ssh/config" 'and changes nothing there'
# The key can live under another name too.
mkdir -p "$tmp/dev-moved/.ssh"; cp "$tmp/dev-laptop/.ssh/si-rn9p-laptop" "$tmp/dev-moved/.ssh/id_ed25519"
out="$(device moved "$script")"; rc=$?
assert_eq 0 "$rc" 'finds the key under another file name'
assert_contains "$(cat "$tmp/dev-moved/.ssh/config")" "IdentityFile $tmp/dev-moved/.ssh/id_ed25519" 'and uses that file'

echo "Test: a VPS-made key is handed out once"
rc=0; vps --add-client friend --generate-key > "$tmp/gen.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'generate-key succeeds'
assert_file_exists "$key_dir/owner_rn9p_friend" 'private key made on the VPS'
vps --client-script friend > "$tmp/friend.sh" 2> "$tmp/friend.err"
assert_contains "$(cat "$tmp/friend.sh")" 'base64 -d' 'first fetch carries the key'
assert_file_missing "$key_dir/owner_rn9p_friend" 'private key deleted after the fetch'
assert_contains "$(cat "$tmp/friend.err")" 'only copy' 'and says so'
out="$(device friend "$tmp/friend.sh")"
assert_file_exists "$tmp/dev-friend/.ssh/si-rn9p-friend.pub" 'public half installed too'
vps --client-script friend > "$tmp/friend2.sh" 2>/dev/null
assert_contains "$(cat "$tmp/friend2.sh")" "SI_KEY_B64=''" 'second fetch has no key'
out="$(device friend "$tmp/friend2.sh")"; rc=$?
assert_eq 0 "$rc" 'second script still works on that device'

echo "Test: the owner key"
vps --client-script owner > "$tmp/owner.sh" 2>/dev/null
assert_contains "$(cat "$tmp/owner.sh")" 'base64 -d' 'owner script carries the install key once'
assert_file_missing "$key_dir/owner_rn9p" 'then only the public key stays'
owner_pub="$(cat "$key_dir/owner_rn9p.pub")"
vps "$tmp/handoff.json" --vps-ip 203.0.113.9 --alias rn9p > /dev/null 2>&1
assert_eq "$owner_pub" "$(cat "$key_dir/owner_rn9p.pub")" 'a re-install keeps the owner key (no new one)'
assert_file_missing "$key_dir/owner_rn9p" 'and does not bring the private key back'
rc=0; vps --add-client owner --pubkey "$pub" > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'owner is not a client label'

echo "Test: --expires"
pub2="$(ssh-keygen -q -t ed25519 -N '' -f "$tmp/k2" && cut -d' ' -f1,2 "$tmp/k2.pub")"
day="$(date -u -d '+30 days' +%Y%m%d)"
rc=0; vps --add-client guest --pubkey "$pub2" --expires 30d > /dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'expiring client added'
assert_contains "$(cat "$phone_ak")" "expiry-time=\"$day\" $pub2" 'expiry on the phone'
assert_contains "$(cat "$admin_ak")" "expiry-time=\"$day\" $pub2" 'and on the VPS jump entry'
assert_contains "$(vps --list-clients 2>&1)" "${day:0:4}-${day:4:2}-${day:6:2}" 'listed with its date'
for bad in 2001-01-01 tomorrow 2026-13-40; do
    rc=0; vps --add-client x --pubkey "$pub2" --expires "$bad" > /dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "--expires $bad refused"
done
rc=0; vps --revoke-client guest > /dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'expiring client revoked'
assert_not_contains "$(cat "$phone_ak")" "$pub2" 'gone from the phone'
assert_not_contains "$(cat "$admin_ak")" "$pub2" 'gone from the VPS'

echo "Test: last login per key"
fp="$(ssh-keygen -lf "$tmp/dev-laptop/.ssh/si-rn9p-laptop.pub" | awk '{print $2}')"
cat > "$tmp/auth.log" <<LOG
2026-10-01T10:00:00+0000 vps sshd[1]: Accepted publickey for root from 198.51.100.1 port 5 ssh2: ED25519 $fp
2026-10-16T21:07:33+0000 vps sshd[2]: Accepted publickey for root from 198.51.100.7 port 6 ssh2: ED25519 $fp
2026-10-16T22:00:00+0000 vps sshd[3]: Accepted publickey for root from 192.0.2.9 port 7 ssh2: ED25519 SHA256:someoneelse
LOG
out="$(vps --list-clients 2>&1)"
assert_contains "$out" 'LAST-LOGIN' 'column header'
assert_contains "$(grep ' laptop ' <<< "$out")" '2026-10-16_21:07 198.51.100.7' 'latest login and address'
assert_not_contains "$(grep ' friend ' <<< "$out")" '198.51.100' 'other keys show none'

echo "Test: pairing nobody approved can be cancelled"
vps --add-client pending > /dev/null 2>&1
rc=0; vps --revoke-client pending > "$tmp/cancel.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'cancel succeeds'
assert_file_missing "$key_dir/client-setup-pending-rn9p.sh" 'pairing script removed'

echo "Test: expiring keys survive an identity export"
(source "$REPO_ROOT/core/lib.sh"; is_client_key_line "expiry-time=\"$day\" $pub2") ; assert_eq 0 "$?" 'expiring line accepted'
(source "$REPO_ROOT/core/lib.sh"; is_client_key_line "command=\"x\" $pub2") ; assert_eq 1 "$?" 'other options refused'
exit "$TESTS_FAILED"
