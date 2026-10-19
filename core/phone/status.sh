# shellcheck shell=bash
# ServerInator Core, phone side: preflight, report and status (si status)
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Preflight and report ──────────────────────

# Facts about this phone, as KEY=VALUE lines (for the preflight and si report).
phone_facts() {
    prop() { getprop "$1" 2>/dev/null || true; }
    echo "model=$(prop ro.product.manufacturer) $(prop ro.product.model) ($(prop ro.product.device))"
    echo "android=$(prop ro.build.version.release)"
    echo "rom=$(prop ro.build.display.id)"
    echo "kernel=$(uname -r)"
    echo "arch=$(uname -m)"
    echo "ram_mb=$(awk '$1=="MemTotal:" {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    echo "magisk=$( { magisk -v 2>/dev/null || echo none; } | head -n 1)"
    echo "uptime_days=$(awk '{printf "%.1f", $1/86400}' /proc/uptime 2>/dev/null)"
}

# Can the kernel make a WireGuard interface? Everything depends on it, and
# the install downloads hundreds of MB before it would find out.
kernel_has_wireguard() {
    local name="si-wgtest"
    ip link del "$name" 2>/dev/null || true
    ip link add "$name" type wireguard 2>/dev/null || return 1
    ip link del "$name" 2>/dev/null || true
}

# Checks what the install needs before it starts; dies with the reason.
phone_preflight() {
    check_root
    check_magisk
    local facts bad=0
    facts="$(phone_facts)"
    _fact() { sed -n "s/^$1=//p" <<< "$facts"; }
    info "Phone: $(_fact model), Android $(_fact android)"
    info "Kernel $(_fact kernel) ($(_fact arch)), $(_fact ram_mb) MB RAM, Magisk $(_fact magisk)"
    detect_arch > /dev/null
    if [[ "$DEV" == 1 ]]; then
        dev "DEV: not testing kernel WireGuard"
    elif kernel_has_wireguard; then
        ok "The kernel supports WireGuard"
    else
        fail "This kernel can't make a WireGuard interface (ip link add ... type wireguard failed)."
        echo "  ServerInator needs WireGuard in the kernel: built in (5.6 and newer), or"
        echo "  backported by the ROM (many custom kernels have it). Userspace WireGuard"
        echo "  isn't supported."
        bad=1
    fi
    check_disk_space
    if (( $(_fact ram_mb) < 2048 )); then
        warn "Less than 2 GB of RAM: Core runs, but Personal's services may not fit"
    fi
    ((bad == 0)) || die "This phone can't run ServerInator (see above)"
}

# One paste-able line about this phone and its install, for bug reports.
phone_report() {
    local facts state="not installed" hs
    facts="$(phone_facts)"
    _fact() { sed -n "s/^$1=//p" <<< "$facts"; }
    if [[ -f "$CHROOT/etc/wireguard/wg-si.conf" ]]; then
        state="installed"
        hs="$(chroot_run wg show wg-si latest-handshakes 2>/dev/null | awk '{print $2; exit}')" || hs=""
        if [[ "$hs" =~ ^[0-9]+$ && "$hs" -gt 0 ]]; then state+=", handshake $(( $(date +%s) - hs ))s ago"
        else state+=", no handshake"; fi
    fi
    printf '%s | Android %s | %s | kernel %s %s | %s MB RAM | Magisk %s | up %s days | ServerInator: %s\n' \
        "$(_fact model)" "$(_fact android)" "$(_fact rom)" "$(_fact kernel)" "$(_fact arch)" \
        "$(_fact ram_mb)" "$(_fact magisk)" "$(_fact uptime_days)" "$state"
}

# ── Phone health (si status) ──────────────────

# Battery, heat and space: a phone that serves for months mostly dies of
# heat or a battery held at 100%. Warnings only; they don't fail si status.
POWER_SUPPLY_DIR="${SERVERINATOR_POWER_SUPPLY_DIR:-/sys/class/power_supply}"
phone_health() {
    local d cap="" status="" temp="" pct line
    for d in "$POWER_SUPPLY_DIR/battery" "$POWER_SUPPLY_DIR/Battery"; do
        # -e, not -r: Android's bash can deny root an access() check.
        [[ -e "$d/capacity" ]] || continue
        read -r cap < "$d/capacity" || cap=""
        [[ -e "$d/status" ]] && { read -r status < "$d/status" || status=""; }
        [[ -e "$d/temp" ]] && { read -r temp < "$d/temp" || temp=""; }
        break
    done
    if [[ "$cap" =~ ^[0-9]+$ ]]; then
        line="Battery ${cap}%${status:+, ${status,,}}"
        [[ "$temp" =~ ^[0-9]+$ ]] && line+=", $((temp / 10)).$((temp % 10))°C"
        info "$line"
        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp >= 420 )); then
            warn "The battery is hot ($((temp / 10))°C): let it cool, or lower the load"
        fi
        if [[ "$cap" == 100 && "${status,,}" =~ ^(full|charging)$ ]]; then
            warn "The battery is held at 100%: a charge limit (ROM setting or a Magisk module) is kinder to it"
        fi
    fi
    pct="$(df -P /data 2>/dev/null | awk 'NR==2 {sub("%", "", $5); print $5}')"
    if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= 90 )); then
        warn "/data is ${pct}% full"
    fi
}

# ── Status (si status) ────────────────────────

# One look at everything the tunnel needs, for debugging without the VPS:
# supervisors, the wstunnel and sshd processes, the WireGuard handshake and a
# ping to the VPS through the tunnel. Exits 1 if anything is wrong.
status_pid_alive() { # PIDFILE
    local pid=""
    [[ -f "$1" ]] && read -r pid < "$1"
    [[ "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]]
}

phone_status() {
    check_root
    local conf="$CHROOT/etc/wireguard/wg-si.conf" bad=0 name hs age vps_ip
    if [[ ! -f "$conf" ]]; then
        fail "Core is not installed on this phone ($conf is missing)"
        return 1
    fi
    local script _ pid
    for name in wstunnel wireguard sshd; do
        read -r script _ <<< "$(service_parts "$name")"
        pid=""; [[ -f "$STATE_DIR/run/$name-supervisor.pid" ]] && read -r pid < "$STATE_DIR/run/$name-supervisor.pid"
        # Alive and really ours: a pid file can outlive its process.
        if status_pid_alive "$STATE_DIR/run/$name-supervisor.pid" \
                && tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fxq -e "$script" -e "${script}.bak"; then
            ok "$name supervisor is running"
        else
            fail "$name supervisor is not running"; bad=1
        fi
    done
    for name in wstunnel sshd; do
        if status_pid_alive "$STATE_DIR/run/$name.pid"; then
            ok "$name is running"
        else
            fail "$name is not running"; bad=1
        fi
    done
    if chroot_run ip link show wg-si >/dev/null 2>&1; then
        ok "wg-si is up"
        hs="$(chroot_run wg show wg-si latest-handshakes 2>/dev/null | awk '{print $2; exit}')" || hs=""
        if [[ "$hs" =~ ^[0-9]+$ && "$hs" -gt 0 ]]; then
            age=$(( $(date +%s) - hs ))
            if (( age <= 180 )); then
                ok "Last handshake with the VPS ${age}s ago"
            else
                fail "Last handshake with the VPS ${age}s ago (over 3 minutes)"; bad=1
            fi
        else
            fail "No handshake with the VPS yet"; bad=1
        fi
    else
        fail "wg-si is missing"; bad=1
    fi
    vps_ip="$(awk -F'[ =/]+' '$1=="AllowedIPs" {print $2; exit}' "$conf")"
    if [[ -n "$vps_ip" ]] && chroot_run ping -c 1 -W 3 "$vps_ip" >/dev/null 2>&1; then
        ok "VPS answers through the tunnel ($vps_ip)"
    else
        fail "No answer from the VPS through the tunnel (${vps_ip:-?})"; bad=1
    fi
    phone_health
    echo ""
    if [[ "$bad" == 0 ]]; then
        echo "  All good. Logs: si logs"
    else
        echo "  Something is wrong. Last lines of each log: si logs"
    fi
    return "$bad"
}
