#!/usr/bin/env bash
# Laptop-side, read-only simultaneous E2 captures and E3 counters.
set -euo pipefail
umask 077
DURATION=${DIAG_DURATION:-60}
INTERVAL=${DIAG_INTERVAL:-}
WG_IF=${DIAG_WG_IF:-wg-si}
PHONE_NAME=${DIAG_PHONE_NAME:-phone}
PHONE_IP=${DIAG_PHONE_IP:-10.66.69.$((1 + 1))}
VPS_WG_IP=${DIAG_VPS_WG_IP:-10.66.69.1}
VPS_HOST=${DIAG_VPS_HOST:-203.0.113.5}
VPS_USER=${DIAG_VPS_USER:-admin}
TLS_PORT=${DIAG_TLS_PORT:-9443}
WG_PORT=${DIAG_WG_PORT:-51822}
LOCAL_UDP=${DIAG_LOCAL_UDP:-51823}
SSH_PORT=${DIAG_SSH_PORT:-2222}
CHROOT=${DIAG_CHROOT:-/data/serverinator-root}
ADB_SERIAL=${DIAG_ADB_SERIAL:-}
DRY_RUN=0
INTERACTIVE_SUDO=0
usage() {
 cat <<'HELP'
Usage: collect-tunnel-diag.sh [--duration N] [--interactive-sudo] [--dry-run]
Environment: DIAG_DURATION, DIAG_INTERVAL, DIAG_WG_IF, DIAG_PHONE_NAME, DIAG_PHONE_IP,
DIAG_VPS_WG_IP, DIAG_VPS_HOST, DIAG_VPS_USER, DIAG_TLS_PORT, DIAG_WG_PORT,
DIAG_LOCAL_UDP, DIAG_SSH_PORT, DIAG_CHROOT, DIAG_ADB_SERIAL.
Run from the laptop. The default requires VPS sudo -n. Use --interactive-sudo
when sudo needs a password; its VPS output is also shown so the prompt remains visible.
Collects metadata only; does not restart the client or enable DEBUG logging.
HELP
}
while (($#)); do
 case "$1" in
  --duration) [[ $# -ge 2 ]] || { echo 'Missing duration' >&2; exit 2; }; DURATION=$2; shift 2 ;;
  --interactive-sudo) INTERACTIVE_SUDO=1; shift ;;
  --dry-run) DRY_RUN=1; shift ;;
  --help|-h) usage; exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
 esac
done
[[ "$DURATION" =~ ^[1-9][0-9]{0,4}$ ]] && ((DURATION <= 86400)) || { echo 'Duration must be 1..86400 seconds' >&2; exit 2; }
if [[ -z "$INTERVAL" ]]; then
 INTERVAL=30
 ((INTERVAL <= DURATION)) || INTERVAL=$DURATION
else
 [[ "$INTERVAL" =~ ^[1-9][0-9]{0,4}$ ]] && ((INTERVAL <= DURATION)) || { echo 'DIAG_INTERVAL must be 1..duration seconds' >&2; exit 2; }
fi
for value in "$WG_IF" "$PHONE_NAME" "$VPS_USER"; do
 [[ "$value" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { echo 'Invalid interface, name or user' >&2; exit 2; }
done
for value in "$PHONE_IP" "$VPS_WG_IP" "$VPS_HOST"; do
 [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$ && "$value" != *..* ]] || { echo 'Invalid IP/host' >&2; exit 2; }
done
for value in "$TLS_PORT" "$WG_PORT" "$LOCAL_UDP" "$SSH_PORT"; do
 [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && ((value <= 65535)) || { echo 'Invalid port' >&2; exit 2; }
done
[[ "$CHROOT" =~ ^/[a-zA-Z0-9_/-]+$ && "$CHROOT" != *..* ]] || { echo 'Invalid chroot path' >&2; exit 2; }
[[ -z "$ADB_SERIAL" || "$ADB_SERIAL" =~ ^[a-zA-Z0-9_.:-]+$ ]] || { echo 'Invalid adb serial' >&2; exit 2; }
# POSIX quoting is required: adb/ssh join arguments into a remote shell command.
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
remote_script() {
 local side=$1 udp=$2
 printf 'SIDE=%s\nN=%s\nSTEP=%s\nIFACE=%s\nUDP=%s\nTLS=%s\nSSH_PORT=%s\nPHONE_IP=%s\nVPS_WG_IP=%s\n' \
  "$side" "$DURATION" "$INTERVAL" "$WG_IF" "$udp" "$TLS_PORT" "$SSH_PORT" "$PHONE_IP" "$VPS_WG_IP"
 cat <<'REMOTE'
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077
TMP=$(mktemp -d)
PIDS=''
cleanup() {
 for pid in $PIDS; do
  if kill -0 "$pid"; then
   if kill -TERM "$pid"; then :; else echo "Cannot stop capture PID $pid" >&2; fi
  fi
  if wait "$pid"; then :; else echo "Capture PID $pid ended after stop/failure" >&2; fi
 done
 rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
snapshot() {
 echo "$(stamp) $SIDE counters"
 cat /proc/net/dev /proc/net/snmp
 if command -v wg >/dev/null; then
  for field in transfer endpoints latest-handshakes; do
   echo "$(stamp) wg $field"
   if wg show "$IFACE" "$field"; then :; else echo "wg $field unavailable" >&2; fi
  done
 else echo 'wg unavailable' >&2; fi
 if command -v ss >/dev/null; then
  if ss -tinp; then :; else echo 'ss unavailable at runtime' >&2; fi
 fi
}
if command -v tcpdump >/dev/null; then
 tcpdump -ni "$IFACE" -tttt -vv "icmp or tcp port $SSH_PORT" > "$TMP/wg.log" 2>&1 & PIDS="$PIDS $!"
 tcpdump -ni lo -tttt -vv "udp port $UDP" > "$TMP/lo.log" 2>&1 & PIDS="$PIDS $!"
 tcpdump -ni any -tttt -vv "tcp port $TLS" > "$TMP/outer.log" 2>&1 & PIDS="$PIDS $!"
 echo "$(stamp) capture started ($N seconds)"
else
 echo "$(stamp) tcpdump unavailable: FALLBACK /proc/net/dev + /proc/net/snmp"
fi
i=0
while :; do
 snapshot
 [ "$i" -ge "$N" ] && break
 remaining=$((N - i))
 delay=$STEP
 [ "$remaining" -lt "$delay" ] && delay=$remaining
 sleep "$delay"
 i=$((i + delay))
done
# Stop only the exact tcpdump children, then flush their output before cleanup.
FAILED=0
for pid in $PIDS; do
 if kill -0 "$pid"; then
  if kill -INT "$pid"; then :; else FAILED=1; fi
 else FAILED=1; fi
 if wait "$pid"; then :; else FAILED=1; fi
done
PIDS=''
for file in "$TMP/"*.log; do
 [ -f "$file" ] || continue
 echo "$(stamp) $SIDE $(basename "$file")"
 cat "$file"
done
if [ "$FAILED" -ne 0 ]; then echo 'One or more tcpdump captures failed' >&2; exit 1; fi
REMOTE
}
phone_script=$(remote_script phone "$LOCAL_UDP")
vps_script=$(remote_script vps "$WG_PORT")
phone_inner="chroot $(quote "$CHROOT") /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c $(quote "$phone_script")"
adb_cmd=(adb)
[[ -z "$ADB_SERIAL" ]] || adb_cmd+=(-s "$ADB_SERIAL")
adb_cmd+=(shell su -c "$(quote "$phone_inner")")
if ((INTERACTIVE_SUDO)); then
 ssh_cmd=(ssh -tt -o BatchMode=yes -o ConnectTimeout=15 "$VPS_USER@$VPS_HOST" "sudo sh -c $(quote "$vps_script")")
else
 ssh_cmd=(ssh -T -o BatchMode=yes -o ConnectTimeout=15 "$VPS_USER@$VPS_HOST" "sudo -n sh -c $(quote "$vps_script")")
fi
if ((DRY_RUN)); then
 printf 'Phone (%s):\n' "$PHONE_NAME"; printf '%q ' "${adb_cmd[@]}"; printf '\n'
 printf 'VPS:\n'; printf '%q ' "${ssh_cmd[@]}"; printf '\n'
 exit 0
fi
command -v adb >/dev/null || { echo 'adb is required' >&2; exit 1; }
command -v ssh >/dev/null || { echo 'ssh is required' >&2; exit 1; }
UTC=$(date -u '+%Y%m%dT%H%M%SZ')
DIR="./diag-$UTC"
mkdir "$DIR"
PIDS=()
cleanup_local() {
 for pid in "${PIDS[@]}"; do
  if kill -0 "$pid"; then
   if kill -TERM "$pid"; then :; else echo "Cannot stop transport PID $pid" >&2; fi
  fi
  if wait "$pid"; then :; else echo "Transport PID $pid terminated" >&2; fi
 done
}
trap cleanup_local EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
printf 'UTC start: %s\nDuration: %s\nCounter interval: %s\nDevice: %s\nInterface: %s\nPhone IP: %s\nVPS: %s\nVPS WG IP: %s\nTLS/UDP/local/SSH ports: %s/%s/%s/%s\nInteractive sudo: %s\n' \
 "$UTC" "$DURATION" "$INTERVAL" "$PHONE_NAME" "$WG_IF" "$PHONE_IP" "$VPS_HOST" "$VPS_WG_IP" "$TLS_PORT" "$WG_PORT" "$LOCAL_UDP" "$SSH_PORT" "$INTERACTIVE_SUDO" > "$DIR/manifest-$UTC.txt"
"${adb_cmd[@]}" > "$DIR/phone-$UTC.log" 2>&1 & PIDS+=("$!")
STATUS=0
if ((INTERACTIVE_SUDO)); then
 if "${ssh_cmd[@]}" 2>&1 | tee "$DIR/vps-$UTC.log"; then :; else
  ssh_status=${PIPESTATUS[0]}
  [[ "$ssh_status" == 0 ]] || STATUS=1
 fi
 if wait "${PIDS[0]}"; then :; else STATUS=1; fi
else
 "${ssh_cmd[@]}" > "$DIR/vps-$UTC.log" 2>&1 & PIDS+=("$!")
 for pid in "${PIDS[@]}"; do
  if wait "$pid"; then :; else STATUS=1; fi
 done
fi
PIDS=()
printf 'UTC end: %s\nStatus: %s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$STATUS" >> "$DIR/manifest-$UTC.txt"
tar -czf "$DIR.tar.gz" "$DIR"
printf 'Diagnostics: %s\nArchive: %s\n' "$DIR" "$DIR.tar.gz"
exit "$STATUS"
