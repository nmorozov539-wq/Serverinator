# ServerInator login summary.
# Managed by ServerInator, do not edit manually.
# Kept deliberately cheap: bash builtins reading /proc and /sys, plus a single
# df call. Never add a subprocess per check; every fork costs extra on
# chroot-on-Android. Silence it with ~/.hushlogin or SI_MOTD=0.
__si_motd() {
    local device="$1" k v c d fs size used mnt up mt=0 ma=0 load1 load5 load15
    local cap="" status="" temp="" ws=0 sshd=0 wg=0 df_out="" disk="?" tmp="?"
    local b="" r="" g="" y=""
    [[ -e "${HOME:-/root}/.hushlogin" || "${SI_MOTD:-1}" == 0 ]] && return 0
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
        b=$'\e[1m' r=$'\e[0m' g=$'\e[32m' y=$'\e[33m'
    fi

    read -r up _ < /proc/uptime || up=0
    up=${up%.*}
    read -r load1 load5 load15 _ < /proc/loadavg
    while read -r k v _; do
        case $k in MemTotal:) mt=$v ;; MemAvailable:) ma=$v; break ;; esac
    done < /proc/meminfo
    for d in /sys/class/power_supply/battery /sys/class/power_supply/Battery; do
        [[ -r $d/capacity ]] || continue
        read -r cap < "$d/capacity"
        [[ -r $d/status ]] && read -r status < "$d/status"
        [[ -r $d/temp ]] && read -r temp < "$d/temp"
        break
    done
    for c in /proc/[0-9]*/comm; do
        read -r k < "$c" 2>/dev/null || continue
        case $k in wstunnel) ws=1 ;; sshd) sshd=1 ;; esac
    done
    [[ -d /sys/class/net/wg-si ]] && wg=1

    df_out="$(df -Pk / /tmp 2>/dev/null)"   # the only fork
    while read -r fs size used _ _ mnt; do
        [[ $size =~ ^[0-9]+$ ]] || continue
        case $mnt in
            /)    disk="$((used / 1048576))/$((size / 1048576)) GB" ;;
            /tmp) if [[ $fs == tmpfs ]]; then tmp="$((used / 1024))/$((size / 1024)) MB tmpfs"; fi ;;
        esac
    done <<< "$df_out"
    [[ $tmp == "?" ]] && tmp="on disk"

    local ok="${g}ok${r}" bad="${y}DOWN${r}" m_wg m_ws m_sshd
    m_wg=$bad m_ws=$bad m_sshd=$bad
    ((wg)) && m_wg=$ok
    ((ws)) && m_ws=$ok
    ((sshd)) && m_sshd=$ok
    printf '\n%s%s%s · up %dd %dh %dm · load %s %s %s\n' \
        "$b" "$device" "$r" $((up / 86400)) $((up % 86400 / 3600)) $((up % 3600 / 60)) "$load1" "$load5" "$load15"
    printf 'mem  %d/%d MB used · disk %s\n' $(((mt - ma) / 1024)) $((mt / 1024)) "$disk"
    printf 'tmp  %s\n' "$tmp"
    if [[ -n $cap ]]; then
        printf 'batt %s%%%s%s\n' "$cap" "${status:+ ${status,,}}" \
            "${temp:+ · $((temp / 10)).$((temp % 10))°C}"
    fi
    printf 'tunnel %s · wstunnel %s · sshd %s\n\n' "$m_wg" "$m_ws" "$m_sshd"
}
