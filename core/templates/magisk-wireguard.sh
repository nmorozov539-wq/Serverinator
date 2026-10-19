#!/system/bin/sh
# ServerInator WireGuard reconciliation; sleep values remain unchanged.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin
export PATH
STATE_DIR='@STATE_DIR@'
CHROOT='@CHROOT@'
umask 077
mkdir -p "$STATE_DIR/logs" "$STATE_DIR/run" || exit 1
exec >> "$STATE_DIR/logs/wireguard.log" 2>&1
printf '%s\n' "$$" > "$STATE_DIR/run/wireguard-supervisor.pid"
trap 'rm -f "$STATE_DIR/run/wireguard-supervisor.pid"; exit' INT TERM
# Wait for wstunnel (up to 120s).
i=0
while [ "$i" -lt 60 ]; do
    if [ -f "$STATE_DIR/run/wstunnel.pid" ]; then
        pid=$(cat "$STATE_DIR/run/wstunnel.pid")
        kill -0 "$pid" 2>/dev/null && break
    fi
    sleep 2; i=$((i+1))
done
while true; do
    chroot "$CHROOT" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root TMPDIR=/tmp /usr/bin/sh -c '
            if ! ip link show wg-si; then wg-quick up /etc/wireguard/wg-si.conf || exit 1; fi
            ip link set wg-si up || exit 1
            # Omitted ListenPort resets the automatic port on every syncconf.
            # Preserve it so reconciliation does not accumulate WSS tunnels.
            listen_port=$(wg show wg-si listen-port) || exit 1
            [ "$listen_port" -gt 0 ] && [ "$listen_port" -le 65535 ] || exit 1
            wg-quick strip /etc/wireguard/wg-si.conf | awk -v port="$listen_port" '\''
                /^ListenPort[[:space:]]*=/ {next}
                {print}
                $0=="[Interface]" {print "ListenPort = "port}
            '\'' > /etc/wireguard/runtime.conf || exit 1
            wg syncconf wg-si /etc/wireguard/runtime.conf || exit 1
            rm -f /etc/wireguard/runtime.conf
            ip address replace @PHONE_WG_IP@/24 dev wg-si || exit 1
            ip link set wg-si mtu 1280 || exit 1
            ip route replace @VPS_WG_NET@.0/24 dev wg-si table main || exit 1
            count=$(ip -4 rule show | awk '\''$1=="100:" && $0 ~ /to @VPS_WG_NET@.0\/24 lookup main/ {n++} END {print n+0}'\'')
            if [ "$count" -ne 1 ]; then
                while [ "$count" -gt 0 ]; do
                    ip rule del to @VPS_WG_NET@.0/24 lookup main priority 100 || exit 1
                    count=$((count - 1))
                done
                ip rule add to @VPS_WG_NET@.0/24 lookup main priority 100 || exit 1
            fi
        '
    if [ -f "$STATE_DIR/logs/wireguard.log" ]; then
        size=$(wc -c < "$STATE_DIR/logs/wireguard.log") || exit 1
        if [ "$size" -ge 1048576 ]; then
            cp "$STATE_DIR/logs/wireguard.log" "$STATE_DIR/logs/wireguard.log.1" && : > "$STATE_DIR/logs/wireguard.log" || exit 1
        fi
    fi
    sleep 30
done
