#!/usr/bin/env bash
# Windows client setup: a .ps1 is written next to every client-setup .sh,
# with the same key, ssh config and pinned host keys. If PowerShell (pwsh)
# is installed, the script is also run against a scratch profile.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

devroot="$tmp/vps"
phone_home="$tmp/phone_home"; mkdir -p "$phone_home"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/hostkey"
host_pub="$(cut -d' ' -f1,2 "$tmp/hostkey.pub")"
host_fp="$(ssh-keygen -lf "$tmp/hostkey.pub" | awk '{print $2}')"
cat > "$tmp/handoff.json" <<JSON
{"version":1,"device_name":"rn9p","wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","wstunnel_port":9443,"wg_port":51822,
 "ssh_enabled":1,"ssh_user":"root","ssh_port":2222,"ssh_host_fingerprint":"$host_fp","ssh_host_pubkey":"$host_pub"}
JSON
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" SERVERINATOR_VPS_IP=203.0.113.9 \
    bash -c 'source "$1"; main "$2" --vps-ip 203.0.113.9 --alias rn9p' _ "$VPS_SCRIPT" "$tmp/handoff.json" > "$tmp/setup.log" 2>&1
key_dir="$devroot/etc/wireguard/serverinator/ssh"
u="${SUDO_USER:-$(id -un)}"   # the VPS login the client scripts jump as
ps1="$key_dir/client-setup-owner-rn9p.ps1"

echo "Test: the owner gets a .ps1 next to the .sh"
assert_file_exists "$ps1" 'owner .ps1 written'
assert_eq 600 "$(stat -c %a "$ps1" 2>/dev/null)" 'private permissions (it holds a key)'
body="$(cat "$ps1")"
assert_eq 0 "$(LC_ALL=C grep -c '[^[:print:][:space:]]' "$ps1")" 'plain ASCII (PowerShell 5 reads BOM-less files as ANSI)'
assert_contains "$body" "'    ProxyJump rn9p-jump'" 'jump through the VPS'
assert_contains "$body" "'Host rn9p-jump', '    HostName 203.0.113.9', '    User $u'" 'in a jump block of its own'
assert_contains "$body" "'    HostKeyAlias rn9p'" 'phone key pinned under the alias'
assert_contains "$body" "rn9p $host_pub" 'phone host key pinned'
assert_contains "$body" 'icacls' 'key locked down to the owner (OpenSSH for Windows insists)'
assert_contains "$(cat "$tmp/setup.log")" 'powershell -ExecutionPolicy Bypass -File .\client-setup-owner-rn9p.ps1' 'install prints the Windows command'

echo "Test: --add-client and --revoke-client handle the .ps1 too"
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" bash -c '
    source "$1"; ssh() { local cmd="${!#}"; HOME="'"$phone_home"'" bash -c "$cmd"; }
    main --add-client laptop --generate-key' _ "$VPS_SCRIPT" > "$tmp/add.log" 2>&1
assert_file_exists "$key_dir/client-setup-laptop-rn9p.ps1" 'client .ps1 written'
assert_contains "$(cat "$key_dir/client-setup-laptop-rn9p.ps1")" "'Host rn9p-laptop-jump'" 'jump block for the new key'
assert_contains "$(cat "$tmp/add.log")" 'Windows: ssh' 'add-client prints the Windows command'
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" bash -c '
    source "$1"; ssh() { local cmd="${!#}"; HOME="'"$phone_home"'" bash -c "$cmd"; }
    main --revoke-client laptop' _ "$VPS_SCRIPT" > /dev/null 2>&1
assert_file_missing "$key_dir/client-setup-laptop-rn9p.ps1" 'revoke removes the .ps1'

if ! command -v pwsh > /dev/null; then
    printf '%s\n' 'SKIP: pwsh not installed; the .ps1 was not executed'
    exit "$TESTS_FAILED"
fi

echo "Test: running the .ps1 (pwsh, scratch profile)"
prof="$tmp/profile"; mkdir -p "$prof/.ssh" "$tmp/bin"
printf 'Host other\n    HostName example.org' > "$prof/.ssh/config"   # no trailing newline
run_ps1() { USERPROFILE="$prof" PATH="$tmp/bin:$PATH" pwsh -NoLogo -NoProfile -NonInteractive -File "$1" 2>&1; }
rc=0; out="$(run_ps1 "$ps1")" || rc=$?
assert_eq 0 "$rc" 'runs without errors'; [[ "$rc" == 0 ]] || printf "%s\n" "$out"
cmp -s "$key_dir/owner_rn9p" "$prof/.ssh/si-rn9p"
assert_eq 0 "$?" 'private key installed byte for byte'
# (On Windows the script uses icacls instead; that branch can't run here.)
assert_eq 600 "$(stat -c %a "$prof/.ssh/si-rn9p" 2>/dev/null)" 'key permissions tightened'
cfg="$(cat "$prof/.ssh/config")"
assert_contains "$cfg" $'HostName example.org\n\nHost rn9p' 'existing config kept, new block on a fresh line'
assert_contains "$cfg" $'Host rn9p\n    HostName 10.66.69.2\n    Port 2222\n    User root\n    IdentityFile '"$prof"$'/.ssh/si-rn9p\n    IdentitiesOnly yes\n    ProxyJump rn9p-jump\n    HostKeyAlias rn9p' 'alias block'
assert_contains "$cfg" $'Host rn9p-jump\n    HostName 203.0.113.9\n    User '"$u"$'\n    IdentityFile '"$prof"$'/.ssh/si-rn9p' 'jump block'
assert_eq 0 "$(grep -c $'\r' "$prof/.ssh/config")" 'LF line endings'
assert_eq "$(head -c 3 "$prof/.ssh/config" | od -An -tx1 | tr -d ' ')" "$(printf 'Hos' | od -An -tx1 | tr -d ' ')" 'no BOM'
assert_contains "$(cat "$prof/.ssh/known_hosts")" "rn9p $host_pub" 'phone host key pinned'
g="$(ssh -F "$prof/.ssh/config" -G rn9p 2>&1)"
assert_contains "$g" 'hostname 10.66.69.2' 'OpenSSH parses the config: tunnel address'
assert_contains "$g" 'proxyjump rn9p-jump' 'OpenSSH parses the config: jump'
before="$(cat "$prof/.ssh/config" "$prof/.ssh/known_hosts")"
rc=0; out="$(run_ps1 "$ps1")" || rc=$?
assert_eq 0 "$rc" 'second run succeeds'
assert_eq "$before" "$(cat "$prof/.ssh/config" "$prof/.ssh/known_hosts")" 'second run changes nothing'
assert_contains "$out" 'already' 'and says so'

exit "$TESTS_FAILED"
