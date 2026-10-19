#!/usr/bin/env bash
# Phone authorized_keys: back-handoff keys live in a managed block that is
# replaced on every apply. Stale ServerInator keys from an older install or
# another VPS are dropped; hand-added and --add-client keys are preserved.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/svc" SERVERINATOR_STATE_DIR="$tmp/state"
source "$PHONE_SCRIPT"; set +e

ak="$tmp/root/root/.ssh/authorized_keys"
mkdir -p "$(dirname "$ak")"
cat > "$ak" <<KEYS
ssh-ed25519 AAAAHANDADDED me@laptop
ssh-ed25519 AAAAOLDVPS serverinator-vps-rn9p
ssh-ed25519 AAAAOLDOWNER serverinator:owner:rn9p
ssh-ed25519 AAAAFRIEND serverinator:client:rn9p:friend
ssh-ed25519 AAAANEWVPS serverinator-vps-rn9p
KEYS

echo "Test: migration from an append-only file"
rc=0; (write_managed_authorized_keys "$ak" "ssh-ed25519 AAAANEWVPS serverinator-vps-rn9p" "ssh-ed25519 AAAANEWOWNER serverinator:owner:rn9p") > /dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'managed block written'
content="$(cat "$ak")"
assert_contains "$content" 'AAAAHANDADDED' 'hand-added key preserved'
assert_contains "$content" 'AAAAFRIEND' '--add-client key preserved'
assert_not_contains "$content" 'AAAAOLDVPS' 'stale VPS->phone key dropped'
assert_not_contains "$content" 'AAAAOLDOWNER' 'stale owner key dropped'
assert_eq 1 "$(grep -c AAAANEWVPS "$ak")" 'current key appears once (moved into the block)'
assert_contains "$content" "$AK_BEGIN" 'block start marker'
assert_eq 600 "$(stat -c %a "$ak")" 'private permissions'

echo "Test: a new back-handoff replaces the block"
(write_managed_authorized_keys "$ak" "ssh-ed25519 AAAAOTHERVPS serverinator-vps-rn9p") > /dev/null 2>&1
content="$(cat "$ak")"
assert_not_contains "$content" 'AAAANEWOWNER' 'previous owner key revoked by re-apply'
assert_not_contains "$content" 'AAAANEWVPS' 'previous VPS key revoked by re-apply'
assert_contains "$content" 'AAAAOTHERVPS' 'new VPS key present'
assert_contains "$content" 'AAAAHANDADDED' 'hand-added key still preserved'
assert_eq 1 "$(grep -cF "$AK_BEGIN" "$ak")" 'exactly one managed block'

echo "Test: re-applying the same keys is a no-op"
before="$(cat "$ak")"
(write_managed_authorized_keys "$ak" "ssh-ed25519 AAAAOTHERVPS serverinator-vps-rn9p") > /dev/null 2>&1
assert_eq "$before" "$(cat "$ak")" 'idempotent'

echo "Test: an unterminated block is refused"
printf '%s\n' "$AK_BEGIN" 'ssh-ed25519 AAAAX x' > "$tmp/broken"
rc=0; (write_managed_authorized_keys "$tmp/broken" "ssh-ed25519 AAAAY y") > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'unterminated block rejected'

echo "Test: multi-line or option-bearing keys are not plain public keys"
rc=0; is_plain_pubkey $'ssh-ed25519 AAAAX x\ncommand="sh" ssh-ed25519 AAAAY' || rc=$?
assert_eq 1 "$rc" 'embedded newline rejected'
rc=0; is_plain_pubkey 'command="sh" ssh-ed25519 AAAAY' || rc=$?
assert_eq 1 "$rc" 'options rejected'

# An admin's file without a final newline got our key glued onto their last key.
echo "Test: appending to authorized_keys without a final newline"
mkdir -p "$tmp/admin/.ssh"; printf 'ssh-ed25519 AAAAOLD admin@laptop' > "$tmp/admin/.ssh/authorized_keys"
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/dev" SERVERINATOR_VPS_ADMIN_HOME="$tmp/admin" \
    bash -c 'source "$1"; _authorize_vps_jump_key "ssh-ed25519 AAAANEW c" 10.66.69.2 2222' _ "$VPS_SCRIPT" > /dev/null 2>&1
assert_eq 'ssh-ed25519 AAAAOLD admin@laptop' "$(head -n 1 "$tmp/admin/.ssh/authorized_keys")" 'admin key line intact'
assert_eq 2 "$(wc -l < "$tmp/admin/.ssh/authorized_keys")" 'jump entry on its own line'
mkdir -p "$tmp/h/.ssh"; printf 'ssh-ed25519 AAAAOLD x' > "$tmp/h/.ssh/authorized_keys"
snippet="$(bash -c 'source "$1"; source "$2"; printf "%s" "$AUTH_INSTALL_SNIPPET"' _ "$REPO_ROOT/core/lib.sh" "$REPO_ROOT/core/vps-auth.sh" 2>/dev/null)"
echo 'ssh-ed25519 AAAANEW y' | HOME="$tmp/h" sh -c "$snippet" > /dev/null
assert_eq $'ssh-ed25519 AAAAOLD x\nssh-ed25519 AAAANEW y' "$(cat "$tmp/h/.ssh/authorized_keys")" 'install snippet keeps keys apart'

exit "$TESTS_FAILED"
