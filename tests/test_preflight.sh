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

# A VPS set up with another wstunnel port is checked on that port.
echo "Test: orchestrator preflight uses the back-handoff's wstunnel port"
printf '{\n  "version": 1,\n  "wstunnel_port": 8443\n}\n' > "$tmp/back.json"
got="$(bash -c 'source "$1"; BACK_HANDOFF_LOCAL="$2"; back_handoff_wstunnel_port' _ "$REPO_ROOT/serverinator.sh" "$tmp/back.json")"
assert_eq 8443 "$got" 'port read from back-handoff'
got="$(bash -c 'source "$1"; BACK_HANDOFF_LOCAL=""; back_handoff_wstunnel_port' _ "$REPO_ROOT/serverinator.sh")"
assert_eq 9443 "$got" 'falls back to the default'

# A server that never answers once passed as a working TLS handshake.
echo "Test: a silent server is not 'handshake completed'"
mkdir -p "$tmp/wss-bin"
cat > "$tmp/wss-bin/curl" <<'C'
#!/bin/bash
echo "* TLS handshake, Client hello (1):" >&2
echo "curl: (28) Connection timed out after 15001 milliseconds" >&2
exit 28
C
chmod +x "$tmp/wss-bin/curl"
rc=0; out="$(PATH="$tmp/wss-bin:$PATH" bash -c 'source "$1"; VPS_HOST=203.0.113.9; step_wss_preflight' _ "$REPO_ROOT/serverinator.sh" 2>&1)" || rc=$?
assert_eq 1 "$rc" 'hang reported as failure'
assert_contains "$out" 'hung' 'and called a hang'
assert_not_contains "$out" 'all good' 'never "all good"'
printf '#!/bin/bash\necho "* SSL certificate problem: self-signed certificate" >&2\nexit 60\n' > "$tmp/wss-bin/curl"
rc=0; out="$(PATH="$tmp/wss-bin:$PATH" bash -c 'source "$1"; VPS_HOST=203.0.113.9; step_wss_preflight' _ "$REPO_ROOT/serverinator.sh" 2>&1)" || rc=$?
assert_eq 0 "$rc" 'self-signed answer is fine'
assert_contains "$out" 'expected certificate error' 'and said so'

exit "$TESTS_FAILED"
