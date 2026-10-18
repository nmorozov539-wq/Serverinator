#!/usr/bin/env bash
# core-phone.sh --preflight (before the install) and --report (si report).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/getprop" <<'S'
#!/bin/sh
case "$1" in
  ro.product.manufacturer) echo Xiaomi ;; ro.product.model) echo "Redmi Note 9 Pro" ;;
  ro.product.device) echo miatoll ;; ro.build.version.release) echo 15 ;;
  ro.build.display.id) echo lineage-22 ;;
esac
S
printf '#!/bin/sh\necho 30.7:MAGISK:R\n' > "$tmp/bin/magisk"
# ip: "type wireguard" works unless NOWG is set.
printf '#!/bin/sh\n[ -n "$NOWG" ] && [ "$2" = add ] && exit 2\nexit 0\n' > "$tmp/bin/ip"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" SERVERINATOR_SERVICE_D="$tmp/service" SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_STATE_DIR="$tmp/state" SERVERINATOR_COLOR=never

echo "Test: si report is one paste-able line"
out="$(SERVERINATOR_DEV=1 bash "$PHONE_SCRIPT" --report 2>&1)"
assert_eq 1 "$(wc -l <<< "$out")" 'one line'
assert_contains "$out" 'Xiaomi Redmi Note 9 Pro (miatoll) | Android 15 | lineage-22' 'model, Android, ROM'
assert_contains "$out" 'Magisk 30.7:MAGISK:R' 'Magisk version'
assert_contains "$out" 'ServerInator: not installed' 'install state'

echo "Test: the preflight"
pre() { bash -c 'source "$1"; check_root() { :; }; check_magisk() { :; }; set +e; phone_preflight' _ "$PHONE_SCRIPT" 2>&1; }
rc=0; out="$(SERVERINATOR_DEV=0 pre)" || rc=$?
assert_eq 0 "$rc" 'passes with kernel WireGuard'
assert_contains "$out" 'The kernel supports WireGuard' 'says so'
assert_contains "$out" 'Phone: Xiaomi Redmi Note 9 Pro' 'shows the phone'
rc=0; out="$(NOWG=1 SERVERINATOR_DEV=0 pre)" || rc=$?
assert_eq 1 "$rc" 'stops without kernel WireGuard'
assert_contains "$out" "can't make a WireGuard interface" 'and explains why'
exit "$TESTS_FAILED"
