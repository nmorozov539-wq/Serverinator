#!/system/bin/sh
# ServerInator — wstunnel supervisor
# Managed by ServerInator, do not edit manually.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin
export PATH
STATE_DIR='@STATE_DIR@'
CHROOT='@CHROOT@'
umask 077
mkdir -p "$STATE_DIR/logs" "$STATE_DIR/run" || exit 1
LOG="$STATE_DIR/logs/wstunnel.log"
printf '%s\n' "$$" > "$STATE_DIR/run/wstunnel-supervisor.pid"
rotate_log() {
    [ -f "$LOG" ] || return 0
    size=$(wc -c < "$LOG") || return 1
    if [ "$size" -ge 1048576 ]; then
        cp "$LOG" "$LOG.1" && : > "$LOG" || return 1
    fi
}
child=''
cleanup() {
    if [ -n "$child" ]; then
        if kill -0 "$child" 2>/dev/null; then kill "$child"; fi
        wait "$child" 2>/dev/null || printf '%s\n' 'wstunnel stopped' >> "$LOG"
    fi
    rm -f "$STATE_DIR/run/wstunnel.pid" "$STATE_DIR/run/wstunnel-supervisor.pid"
}
trap 'cleanup; exit' INT TERM
# The interface the VPS is reached through (wlan0, rmnet_data1, ...), or
# nothing while there is no usable network.
route_dev() {
    route=$(ip route get @PROBE_IP@ 2>/dev/null) || route=''
    case "$route" in
        ''|*' dev lo'*|*' dev dummy'*|*unreachable*|*prohibit*) return 0 ;;
    esac
    printf '%s\n' "$route" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1
}
# True when wstunnel has run 5 minutes and WireGuard still had no handshake
# for 5 minutes (it renews every 2): the connection is dead in a way
# wstunnel doesn't notice, like a network that silently drops it.
STALE_AFTER=300
handshake_stale() {
    now_s=$(date +%s)
    [ $((now_s - started)) -ge "$STALE_AFTER" ] || return 1
    hs=$(chroot "$CHROOT" /usr/bin/env -i PATH=/usr/bin:/bin wg show wg-si latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    case "$hs" in ''|*[!0-9]*) hs=0 ;; esac
    [ $((now_s - hs)) -ge "$STALE_AFTER" ]
}
# Wait until the VPS is routable (network is up), up to 120s. Android keeps
# its default route in per-network tables, not main, so "ip route show
# default" stays empty and used to burn the full 120s on every boot.
i=0
while [ "$i" -lt 60 ]; do
    route=$(ip route get @PROBE_IP@ 2>/dev/null) || route=''
    case "$route" in
        ''|*' dev lo'*|*' dev dummy'*|*unreachable*|*prohibit*) ;;
        *) break ;;
    esac
    sleep 2; i=$((i+1))
done
while true; do
    rotate_log || exit 1
    chroot "$CHROOT" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root TMPDIR=/tmp /usr/local/bin/wstunnel client \
        --log-lvl INFO \
@VERIFY_LINE@@PREFIX_LINE@        -L "udp://@WG_LOCAL_PORT@:127.0.0.1:@WG_VPS_PORT@?timeout_sec=0" \
        wss://@ENDPOINT@:@WSTUNNEL_PORT@ \
        >> "$LOG" 2>&1 &
    child=$!
    printf '%s\n' "$child" > "$STATE_DIR/run/wstunnel.pid"
    # wstunnel keeps its connection on the network it started on. When the
    # phone moves (mobile data at boot, then Wi-Fi), reconnect on the new
    # one: a network that blocks the tunnel would otherwise hold it forever.
    dev=$(route_dev)
    started=$(date +%s); ticks=0
    while kill -0 "$child" 2>/dev/null; do
        rotate_log || exit 1
        sleep 5
        now=$(route_dev)
        [ -n "$now" ] || continue
        if [ -z "$dev" ]; then dev="$now"; continue; fi
        if [ "$now" != "$dev" ]; then
            printf '%s\n' "network changed ($dev -> $now), reconnecting" >> "$LOG"
            kill "$child" 2>/dev/null
            break
        fi
        ticks=$((ticks + 1))
        [ $((ticks % 6)) -eq 0 ] || continue
        if handshake_stale; then
            printf '%s\n' "no handshake for $((now_s - hs))s, reconnecting" >> "$LOG"
            kill "$child" 2>/dev/null
            break
        fi
    done
    wait "$child" 2>/dev/null || printf '%s\n' 'wstunnel exited unsuccessfully' >> "$LOG"
    child=''
    rm -f "$STATE_DIR/run/wstunnel.pid"
    sleep 10
done
