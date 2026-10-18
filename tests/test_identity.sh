#!/usr/bin/env bash
# Identity backup/restore: the WireGuard key survives a chroot rebuild, and
# --export-identity / --import-identity move a phone's identity (WireGuard
# key, SSH host keys, VPS login key, extra authorized keys) to a new phone.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

KEY_A="$(printf 'B%.0s' {1..42})A="
PUB_A="$(printf 'C%.0s' {1..42})A="
KEY_B="$(printf 'D%.0s' {1..42})A="

# phone_env DIR: point every phone path at DIR (run in a subshell).
phone_env() {
    export SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$1/root" SERVERINATOR_SERVICE_D="$1/service" \
        SERVERINATOR_STATE_DIR="$1/state" SERVERINATOR_SSH_HOSTKEY_DIR="$1/hostkeys" \
        SERVERINATOR_IDENTITY_DIR="$1/state/identity" SERVERINATOR_ORCHESTRATOR_SSH_DIR="$1/orchestrator"
    mkdir -p "$1/service"
}
phone() { # DIR ARGS...: run core-phone.sh as that phone
    local d="$1"; shift
    ( phone_env "$d"; bash "$PHONE_SCRIPT" "$@" )
}
in_phone() { # DIR CODE: source core-phone.sh as that phone and run CODE
    ( phone_env "$1"; source "$PHONE_SCRIPT"; set +e; eval "$2" )
}

old="$tmp/old"
mkdir -p "$old/root/etc/wireguard" "$old/root/root/.ssh" "$old/hostkeys" "$old/orchestrator"
printf '%s\n' "$KEY_A" > "$old/root/etc/wireguard/client.key"
printf '%s\n' "$PUB_A" > "$old/root/etc/wireguard/client.pub"
ssh-keygen -q -t ed25519 -N '' -C host -f "$old/hostkeys/ssh_host_ed25519_key"
ssh-keygen -q -t ed25519 -N '' -C orch -f "$old/orchestrator/id_ed25519"
cat > "$old/root/root/.ssh/authorized_keys" <<'KEYS'
ssh-ed25519 AAAAHAND me@laptop
# >>> ServerInator managed keys (replaced on every apply) >>>
ssh-ed25519 AAAAMANAGED serverinator-vps-rn9p
# <<< ServerInator managed keys <<<
ssh-ed25519 AAAAFRIEND serverinator:client:rn9p:friend
ssh-ed25519 AAAAOLDVPS serverinator-vps-rn9p
KEYS

echo "Test: the WireGuard key is kept outside the chroot"
in_phone "$old" 'generate_wg_keys' > /dev/null 2>&1
assert_eq "$KEY_A" "$(cat "$old/state/identity/wireguard/client.key" 2>/dev/null)" 'key copied to the identity store'
assert_eq 600 "$(stat -c %a "$old/state/identity/wireguard/client.key" 2>/dev/null)" 'stored key is private'
rm -f "$old/root/etc/wireguard/client.key" "$old/root/etc/wireguard/client.pub"
in_phone "$old" 'generate_wg_keys' > "$tmp/out" 2>&1
assert_eq "$KEY_A" "$(cat "$old/root/etc/wireguard/client.key" 2>/dev/null)" 'rebuilt chroot gets the same key back'
assert_contains "$(cat "$tmp/out")" 'Restored the saved WireGuard key' 'says so'

echo "Test: export"
out="$tmp/id.tar"
rc=0; phone "$old" --export-identity "$out" --device-name rn9p > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'export succeeds'
assert_eq 600 "$(stat -c %a "$out")" 'backup file is private'
list="$(tar -tf "$out")"
for p in manifest extra-keys wireguard/client.key wireguard/client.pub ssh/ssh_host_ed25519_key ssh/ssh_host_ed25519_key.pub orchestrator/id_ed25519 orchestrator/id_ed25519.pub; do
    assert_contains "$list" "serverinator-identity/$p" "contains $p"
done
tar -xf "$out" -C "$tmp" serverinator-identity/extra-keys serverinator-identity/manifest
extra="$(cat "$tmp/serverinator-identity/extra-keys")"
assert_contains "$extra" 'AAAAHAND' 'hand-added key kept'
assert_contains "$extra" 'AAAAFRIEND' 'client key kept'
assert_not_contains "$extra" 'AAAAMANAGED' 'managed block left out (the VPS re-sends it)'
assert_not_contains "$extra" 'AAAAOLDVPS' 'stale VPS key left out'
assert_contains "$(cat "$tmp/serverinator-identity/manifest")" 'device_name=rn9p' 'device name recorded'
assert_contains "$(cat "$tmp/out")" 'private keys' 'warns that the file is sensitive'
rc=0; phone "$old" --export-identity "$out" > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'does not overwrite an existing file'

echo "Test: import on a fresh phone (before install)"
new="$tmp/new"
rc=0; phone "$new" --import-identity "$out" > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'import succeeds'
assert_eq "$KEY_A" "$(cat "$new/state/identity/wireguard/client.key" 2>/dev/null)" 'WireGuard key in place'
assert_eq rn9p "$(cat "$new/state/identity/device-name" 2>/dev/null)" 'device name saved for the installer'
cmp -s "$old/hostkeys/ssh_host_ed25519_key" "$new/hostkeys/ssh_host_ed25519_key"
assert_eq 0 "$?" 'SSH host key in place'
cmp -s "$old/orchestrator/id_ed25519" "$new/orchestrator/id_ed25519"
assert_eq 0 "$?" 'VPS login key in place'
assert_contains "$(cat "$new/state/identity/pending-extra-keys" 2>/dev/null)" 'AAAAFRIEND' 'extra keys wait for the install'
assert_contains "$(cat "$tmp/out")" "device name 'rn9p'" 'tells you what to run next'
in_phone "$new" 'generate_wg_keys' > /dev/null 2>&1
assert_eq "$KEY_A" "$(cat "$new/root/etc/wireguard/client.key" 2>/dev/null)" 'install uses the imported key'

echo "Test: extra keys are merged once the install writes authorized_keys"
in_phone "$new" 'ak="$CHROOT/root/.ssh/authorized_keys"; write_managed_authorized_keys "$ak" "ssh-ed25519 AAAANEWVPS serverinator-vps-rn9p"; merge_extra_keys "$ak" "$IDENTITY_DIR/pending-extra-keys"' > /dev/null 2>&1
ak="$(cat "$new/root/root/.ssh/authorized_keys")"
assert_contains "$ak" 'AAAAFRIEND' 'client key restored'
assert_contains "$ak" 'AAAAHAND' 'hand-added key restored'
in_phone "$new" 'merge_extra_keys "$CHROOT/root/.ssh/authorized_keys" "$IDENTITY_DIR/pending-extra-keys"' > /dev/null 2>&1
assert_eq 1 "$(grep -c AAAAFRIEND "$new/root/root/.ssh/authorized_keys")" 'merging twice adds nothing'
assert_contains "$(sed -n '/apply_ssh_config()/,/^}/p' "$PHONE_SCRIPT")" 'pending-extra-keys' 'apply_ssh_config merges pending keys'

echo "Test: importing the same identity again is harmless"
rc=0; phone "$new" --import-identity "$out" > /dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 're-import succeeds'

echo "Test: a phone with a different identity is not overwritten"
other="$tmp/other"
mkdir -p "$other/root/etc/wireguard"
printf '%s\n' "$KEY_B" > "$other/root/etc/wireguard/client.key"
printf '%s\n' "$PUB_A" > "$other/root/etc/wireguard/client.pub"
rc=0; phone "$other" --import-identity "$out" > "$tmp/out" 2>&1 || rc=$?
assert_eq 1 "$rc" 'different WireGuard key: refused'
assert_contains "$(cat "$tmp/out")" '--uninstall --purge' 'explains how to replace it on purpose'
assert_eq "$KEY_B" "$(cat "$other/root/etc/wireguard/client.key")" 'existing key untouched'
assert_file_missing "$other/hostkeys" 'nothing else written'
other2="$tmp/other2"
mkdir -p "$other2/hostkeys"
ssh-keygen -q -t ed25519 -N '' -f "$other2/hostkeys/ssh_host_ed25519_key"
rc=0; phone "$other2" --import-identity "$out" > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'different SSH host key: refused'
assert_file_missing "$other2/state/identity/wireguard/client.key" 'nothing written'

echo "Test: the old VPS login key is set aside, not lost"
o3="$tmp/o3"
mkdir -p "$o3/orchestrator"
ssh-keygen -q -t ed25519 -N '' -f "$o3/orchestrator/id_ed25519"
cp "$o3/orchestrator/id_ed25519" "$tmp/o3-orig"
phone "$o3" --import-identity "$out" > "$tmp/out" 2>&1
cmp -s "$tmp/o3-orig" "$o3/orchestrator/id_ed25519.before-import"
assert_eq 0 "$?" 'previous key kept as .before-import'
assert_contains "$(cat "$tmp/out")" 'before-import' 'and it says so'

echo "Test: odd archives are refused"
bad() { # NAME: build $tmp/bad/NAME.tar from $tmp/bad/NAME/
    tar -cf "$tmp/bad/$1.tar" -C "$tmp/bad/$1" serverinator-identity
}
mkdir -p "$tmp/bad"
mk() { rm -rf "$tmp/bad/$1"; mkdir -p "$tmp/bad/$1"; tar -xf "$out" -C "$tmp/bad/$1"; }
mk link; ln -s /etc/passwd "$tmp/bad/link/serverinator-identity/ssh/ssh_host_rsa_key"; bad link
mk extra; echo x > "$tmp/bad/extra/serverinator-identity/evil.sh"; bad extra
mk fmt; sed -i 's/format=1/format=9/' "$tmp/bad/fmt/serverinator-identity/manifest"; bad fmt
mk wg; echo 'not-a-key' > "$tmp/bad/wg/serverinator-identity/wireguard/client.key"; bad wg
mk ak; echo 'command="evil" ssh-ed25519 AAAA x' >> "$tmp/bad/ak/serverinator-identity/extra-keys"; bad ak
for n in link extra fmt wg ak; do
    d="$tmp/fresh-$n"
    rc=0; phone "$d" --import-identity "$tmp/bad/$n.tar" > "$tmp/out" 2>&1 || rc=$?
    assert_eq 1 "$rc" "refused: $n"
    assert_file_missing "$d/state/identity/wireguard" "nothing written: $n"
done
tar -cf "$tmp/bad/dotdot.tar" -C "$tmp" serverinator-identity/manifest --transform 's,^,../,' 2>/dev/null
rc=0; phone "$tmp/fresh-dd" --import-identity "$tmp/bad/dotdot.tar" > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'refused: path outside the archive'

echo "Test: uninstall keeps the identity; --purge removes it"
phone "$new" --uninstall --yes > /dev/null 2>&1
assert_file_exists "$new/state/identity/wireguard/client.key" 'kept by a plain uninstall'
phone "$new" --uninstall --purge --yes > /dev/null 2>&1
assert_file_missing "$new/state/identity" 'removed by --purge'

echo "Test: the installer offers the saved device name"
saved_q="$(printf '\n' | SERVERINATOR_IDENTITY_DIR="$tmp/sq" bash -c '
    mkdir -p "$SERVERINATOR_IDENTITY_DIR"; echo rn9p > "$SERVERINATOR_IDENTITY_DIR/device-name"
    source <(sed -n "/^ask_questions()/,/^}/p" "$1"); source "$2"
    IDENTITY_DIR="$SERVERINATOR_IDENTITY_DIR"; VPS_TARGET=x; SSH_ALIAS=a; DEVICE_NAME=""
    split_vps_target() { :; }; validate_ssh_alias() { :; }; ask_chroot_tmp() { :; }; ask_domain() { :; }
    ask_questions > /dev/null; echo "$DEVICE_NAME"' _ "$REPO_ROOT/serverinator.sh" "$REPO_ROOT/core/lib.sh" 2>&1)"
assert_eq rn9p "$saved_q" 'pressing Enter keeps the saved device name'

exit "$TESTS_FAILED"
