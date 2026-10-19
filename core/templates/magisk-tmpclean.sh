#!/system/bin/sh
# ServerInator — chroot /tmp cleaner (disk mode)
# Managed by ServerInator, do not edit manually.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin
export PATH
STATE_DIR='@STATE_DIR@'
CHROOT='@CHROOT@'
umask 077
mkdir -p "$STATE_DIR/logs" "$STATE_DIR/run" || exit 1
LOG="$STATE_DIR/logs/tmpclean.log"
printf '%s\n' "$$" > "$STATE_DIR/run/tmpclean-supervisor.pid"
trap 'rm -f "$STATE_DIR/run/tmpclean-supervisor.pid"; exit' INT TERM
sleep 300
while true; do
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -ge 1048576 ]; then
        cp "$LOG" "$LOG.1" && : > "$LOG"
    fi
    chroot "$CHROOT" /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/find /tmp -xdev -mindepth 1 \
        \( -type f -o -type l \) -mtime +@CHROOT_TMP_MAX_AGE_DAYS@ -atime +@CHROOT_TMP_MAX_AGE_DAYS@ -print -delete >> "$LOG" 2>&1
    chroot "$CHROOT" /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/find /tmp -xdev -mindepth 1 -depth \
        -type d -empty -mtime +@CHROOT_TMP_MAX_AGE_DAYS@ -print -delete >> "$LOG" 2>&1
    sleep 21600
done
