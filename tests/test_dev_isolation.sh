#!/usr/bin/env bash
# Verifies DEV mode stays inside temporary paths and never reaches real system
# commands/services.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

had_data=0
[[ -e /data/adb/service.d ]] && had_data=1

echo "Test: phone DEV mode requires SERVERINATOR_SERVICE_D"
rc=0
out="$(SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/pc" \
    bash -c 'source "$1"' _ "$PHONE_SCRIPT" 2>&1)" || rc=$?
if [[ "$rc" -ne 0 && "$out" == *"SERVERINATOR_SERVICE_D"* ]]; then
    pass "phone DEV aborts without SERVERINATOR_SERVICE_D"
else
    failtest "phone DEV did not require SERVERINATOR_SERVICE_D (rc=$rc)"
fi

echo "Test: phone DEV setup writes only under the temp chroot/service dir"
# Seed key material and wstunnel so the DEV run needs no network.
mkdir -p "$tmp/pc/root/etc/wireguard" "$tmp/pc/root/usr/local/bin"
echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$tmp/pc/root/etc/wireguard/client.key"
echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > "$tmp/pc/root/etc/wireguard/client.pub"
printf '#!/bin/sh\necho stub\n' > "$tmp/pc/root/usr/local/bin/wstunnel"

SERVERINATOR_DEV=1 \
SERVERINATOR_CHROOT="$tmp/pc/root" \
SERVERINATOR_SERVICE_D="$tmp/pc/service" \
SERVERINATOR_ARCH_OVERRIDE=aarch64 \
SERVERINATOR_DEVICE_NAME=dev-phone \
    bash "$PHONE_SCRIPT" >"$tmp/pc.out" 2>&1
rc=$?
assert_eq 0 "$rc" "phone DEV setup succeeds"
assert_file_exists "$tmp/pc/root/etc/wireguard/handoff.json" "handoff under temp chroot"
assert_file_exists "$tmp/pc/service/00-serverinator-mount.sh" "mount script under temp service dir"
# wstunnel autostart is written by apply_back_handoff (after VPS IP is known), not during setup
if [[ "$had_data" -eq 0 ]]; then
    assert_file_missing "/data/adb/service.d/00-serverinator-mount.sh" "real /data/adb/service.d untouched"
fi

echo "Test: VPS DEV default paths are under the temp DEV root"
exp_default="${TMPDIR:-/tmp}/serverinator-dev/etc/wireguard"
got_default="$(SERVERINATOR_DEV=1 bash -c 'source "$1"; printf "%s" "$WG_DIR"' _ "$VPS_SCRIPT")"
assert_eq "$exp_default" "$got_default" "default WG_DIR is temp-scoped"

res="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/defaultroot" \
    bash -c 'source "$1"; printf "%s\n%s\n%s\n%s" "$WG_DIR" "$SYSTEMD_DIR" "$WSTUNNEL_BIN" "$BACK_HANDOFF_PATH"' \
    _ "$VPS_SCRIPT")"
assert_contains "$res" "$tmp/defaultroot/etc/wireguard" "WG dir under DEV root"
assert_contains "$res" "$tmp/defaultroot/etc/systemd/system" "systemd dir under DEV root"
assert_contains "$res" "$tmp/defaultroot/usr/local/bin/wstunnel" "wstunnel bin under DEV root"
assert_contains "$res" "$tmp/defaultroot/back-handoff.json" "back-handoff under DEV root"

echo "Test: VPS full DEV setup runs without touching real system commands"
mkdir -p "$tmp/bin"
marker="$tmp/forbidden_calls"
# The download (curl) and key generation (wg) still run, against the fakes in
# tests/fakes; these would change the real system.
for c in systemctl apt-get apt wg-quick ip; do
    cat > "$tmp/bin/$c" <<EOF
#!/usr/bin/env bash
echo "$c \$*" >> "$marker"
exit 1
EOF
    chmod +x "$tmp/bin/$c"
done

cat > "$tmp/handoff.json" <<'EOF'
{ "version": 1, "device_name": "testphone", "wg_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "wstunnel_port": 9443, "wg_port": 51822 }
EOF

devroot="$tmp/vpsdev"
rc=0
out="$(PATH="$tmp/bin:$PATH" \
    SERVERINATOR_DEV=1 \
    SERVERINATOR_DEV_ROOT="$devroot" \
    SERVERINATOR_VPS_IP=203.0.113.5 \
    bash "$VPS_SCRIPT" "$tmp/handoff.json" 2>&1)" || rc=$?
assert_eq 0 "$rc" "VPS DEV setup succeeds"
assert_not_contains "$out" "[ERROR]" "no errors during VPS DEV setup"
assert_file_missing "$marker" "no real system commands invoked in DEV"
assert_file_exists "$devroot/etc/wireguard/wg-si.conf" "WG config under DEV root"
assert_file_exists "$devroot/etc/systemd/system/wstunnel-serverinator.service" "unit under DEV root"
assert_file_exists "$devroot/usr/local/bin/wstunnel" "wstunnel under DEV root"
assert_file_exists "$devroot/back-handoff.json" "back-handoff under DEV root"

exit "$TESTS_FAILED"
