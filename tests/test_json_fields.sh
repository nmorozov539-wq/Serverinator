#!/usr/bin/env bash
# Verifies JSON helpers tolerate missing/empty fields (return 0, empty) so that
# explicit validation messages are reached instead of a bare `set -e` abort.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export SERVERINATOR_DEV=1
export SERVERINATOR_DEV_ROOT="$tmp/devroot"
# shellcheck disable=SC1090
source "$VPS_SCRIPT"
set +e

cat > "$tmp/a.json" <<'EOF'
{
  "version": 1,
  "device_name": "abc",
  "empty": ""
}
EOF

echo "Test: json_get on present, empty and missing fields"
v="$(json_get "$tmp/a.json" device_name)"; rc=$?
assert_eq 0 "$rc" "present field returns 0"
assert_eq "abc" "$v" "present field value"

v="$(json_get "$tmp/a.json" empty)"; rc=$?
assert_eq 0 "$rc" "empty field returns 0"
assert_eq "" "$v" "empty field value is empty"

v="$(json_get "$tmp/a.json" nope)"; rc=$?
assert_eq 0 "$rc" "missing field returns 0 (not a set -e abort)"
assert_eq "" "$v" "missing field value is empty"

echo "Test: json_get_num on present and missing fields"
v="$(json_get_num "$tmp/a.json" version)"; rc=$?
assert_eq 0 "$rc" "present numeric returns 0"
assert_eq "1" "$v" "present numeric value"

v="$(json_get_num "$tmp/a.json" absent)"; rc=$?
assert_eq 0 "$rc" "missing numeric returns 0"
assert_eq "" "$v" "missing numeric value is empty"

echo "Test: read_handoff reports a meaningful error for a missing field"
cat > "$tmp/bad.json" <<'EOF'
{ "version": 1, "device_name": "abc" }
EOF
rc=0
out="$(HANDOFF_FILE="$tmp/bad.json"; read_handoff 2>&1)" || rc=$?
assert_eq 1 "$rc" "read_handoff fails on missing wg_pubkey"
assert_contains "$out" "wg_pubkey" "reports the missing field"

echo "Test: phone uses chroot jq despite a failed host executable check"
export SERVERINATOR_CHROOT="$tmp/phone" SERVERINATOR_SERVICE_D="$tmp/service"
source "$PHONE_SCRIPT"
set +e
mkdir -p "$CHROOT/usr/bin"
touch "$CHROOT/usr/bin/jq"
chmod 600 "$CHROOT/usr/bin/jq"
host_jq="$(command -v jq)"
command() {
    if [[ "$*" == '-v jq' ]]; then return 1; fi
    builtin command "$@"
}
chroot_run() {
    [[ "$1" == /usr/bin/jq ]] || return 1
    "$host_jq" "${@:2}"
}
rc=0
v="$(json_get "$tmp/a.json" device_name)" || rc=$?
assert_eq 0 "$rc" 'chroot jq execution determines availability'
assert_eq abc "$v" 'chroot fallback parses handoff'
chroot_run() { return 126; }
rc=0
json_get "$tmp/a.json" device_name > /dev/null 2>&1 || rc=$?
assert_eq 126 "$rc" 'real chroot execution failure is propagated'

exit "$TESTS_FAILED"
