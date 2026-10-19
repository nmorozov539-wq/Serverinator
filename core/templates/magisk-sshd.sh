#!/system/bin/sh
# ServerInator managed sshd supervisor. All diagnostics stay in a root-only log.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin
export PATH
STATE_DIR='@STATE_DIR@'
CHROOT='@CHROOT@'
umask 077
mkdir -p "$STATE_DIR/logs" "$STATE_DIR/run" || exit 1
LOG="$STATE_DIR/logs/sshd.log"
printf '%s\n' "$$" > "$STATE_DIR/run/sshd-supervisor.pid"
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
        if kill -0 "$child"; then kill "$child"; fi
        if wait "$child"; then :; else printf '%s\n' 'sshd stopped' >> "$LOG"; fi
    fi
    rm -f "$STATE_DIR/run/sshd.pid" "$STATE_DIR/run/sshd-supervisor.pid"
}
trap 'cleanup; exit' INT TERM
# Wait for the wg-si interface (up to 120s).
i=0
while [ "$i" -lt 60 ]; do
    ip link show wg-si >/dev/null 2>&1 && break
    sleep 2; i=$((i+1))
done
while true; do
    rotate_log || exit 1
    chroot "$CHROOT" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root TMPDIR=/tmp /usr/bin/sh -c \
        'mkdir -p /run/sshd && chmod 0755 /run/sshd && if [ -x /usr/local/sbin/serverinator-guests ]; then /usr/local/sbin/serverinator-guests mount-all || :; fi; /usr/sbin/sshd -t && exec /usr/sbin/sshd -D -e' \
        >> "$LOG" 2>&1 &
    child=$!
    printf '%s\n' "$child" > "$STATE_DIR/run/sshd.pid"
    while kill -0 "$child"; do rotate_log || exit 1; sleep 5; done
    if wait "$child"; then :; else printf '%s\n' 'sshd exited unsuccessfully' >> "$LOG"; fi
    child=''
    rm -f "$STATE_DIR/run/sshd.pid"
    sleep 10
done
