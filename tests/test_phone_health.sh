#!/usr/bin/env bash
# Battery, heat and disk warnings: in si status (phone_health) and in the
# login summary.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/ps/battery"
batt() { echo "$1" > "$tmp/ps/battery/capacity"; echo "$2" > "$tmp/ps/battery/status"; echo "$3" > "$tmp/ps/battery/temp"; }
export SERVERINATOR_DEV=1 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/svc" \
    SERVERINATOR_STATE_DIR="$tmp/state" SERVERINATOR_POWER_SUPPLY_DIR="$tmp/ps" SERVERINATOR_COLOR=never
health() { bash -c 'source "$1"; set +e; phone_health' _ "$PHONE_SCRIPT" 2>&1; }
motd() { SI_POWER_SUPPLY_DIR="$tmp/ps" HOME="$tmp" bash -c "source '$REPO_ROOT/core/motd.bash'; __si_motd rn9p" 2>&1; }

echo "Test: si status"
batt 64 Discharging 312
out="$(health)"
assert_contains "$out" 'Battery 64%, discharging, 31.2°C' 'battery line'
assert_not_contains "$out" 'WARN' 'nothing to warn about'
batt 100 Full 455
out="$(health)"
assert_contains "$out" 'hot (45°C)' 'heat warned'
assert_contains "$out" 'held at 100%' '100% while plugged warned'

echo "Test: login summary"
batt 64 Discharging 312
assert_not_contains "$(motd)" 'note' 'no note when all is well'
batt 100 Charging 430
out="$(motd)"
assert_contains "$out" 'battery hot (43°C)' 'heat noted'
assert_contains "$out" 'held at 100%' '100% noted'
rm -rf "$tmp/ps/battery"
assert_not_contains "$(motd)" 'batt ' 'no battery, no battery line'
exit "$TESTS_FAILED"
