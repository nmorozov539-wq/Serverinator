# shellcheck shell=bash
# ServerInator Core, phone side: --uninstall
# Sourced by core-phone.sh, which holds the settings and globals used here.

stop_exact_pid() {
    local pid="$1" expected="$2" kind="$3" root _
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "$$" ]] || die "Invalid managed PID"
    [[ -d "/proc/$pid" ]] || return 0
    if [[ "$kind" == supervisor ]]; then
        tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | grep -Fx -e "$expected" -e "${expected}.bak" > /dev/null \
            || { [[ -d "/proc/$pid" ]] || return 0; die "PID file points to an unrelated supervisor; refusing kill"; }
    else
        root="$(readlink "/proc/$pid/root")" || { [[ -d "/proc/$pid" ]] || return 0; die "Cannot inspect process root"; }
        [[ "$root" == "$CHROOT" ]] || die "PID file points outside managed chroot"
    fi
    kill -TERM "$pid" 2>/dev/null || [[ ! -d "/proc/$pid" ]] || die "Cannot stop managed process"
    for _ in 1 2 3 4 5; do
        [[ -d "/proc/$pid" ]] || return 0
        sleep 1
    done
    # Revalidate identity before escalation to avoid a reused PID. A shell
    # supervisor runs its TERM trap only after its current sleep, so it often
    # exits right here: gone at any point counts as stopped.
    if [[ "$kind" == supervisor ]]; then
        tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | grep -Fx -e "$expected" -e "${expected}.bak" > /dev/null \
            || { [[ -d "/proc/$pid" ]] || return 0; die "PID identity changed before kill escalation"; }
    else
        root="$(readlink "/proc/$pid/root")" || { [[ -d "/proc/$pid" ]] || return 0; die "Cannot inspect process root"; }
        [[ "$root" == "$CHROOT" ]] || die "PID root changed before escalation"
    fi
    kill -KILL "$pid" 2>/dev/null || [[ ! -d "/proc/$pid" ]] || die "Cannot kill remaining managed process"
}

# What --uninstall is about to delete, so the question means something.
uninstall_summary() {
    local size="" f
    echo ""
    echo "  This removes ServerInator Core from this phone:"
    if [[ -d "$CHROOT" ]]; then
        size="$(du -sxh "$CHROOT" 2>/dev/null | awk '{print $1}')" || size=""
        echo "    - the Linux system in $CHROOT${size:+ ($size)}, with everything in it:"
        echo "      your files in /root, shared folders and add-on data in /srv"
    fi
    for f in "$MAGISK_SERVICE_D"/[0-9][0-9]-serverinator-*.sh; do
        [[ -e "$f" ]] && { echo "    - the boot scripts in $MAGISK_SERVICE_D and the si command"; break; }
    done
    local addons
    addons="$(addon_boot_scripts | sed 's|.*/[0-9][0-9]-||; s|\.sh$||' | tr '\n' ' ')"
    [[ -z "$addons" ]] || echo "    - add-on services that run in it, and their boot scripts: ${addons% }"
    if [[ "$PURGE" == 1 ]]; then
        echo "    - this phone's identity (WireGuard key, SSH host keys): the VPS and"
        echo "      every client will see a new phone after a reinstall"
    else
        echo "  Kept: this phone's WireGuard key and SSH host keys (--purge deletes them)."
    fi
    echo ""
}

# Boot scripts of add-ons built on Core: a module serverinator-ADDON runs
# NN-ADDON-*.sh in service.d (Personal: 50-personal-NAME.sh). They run
# inside the chroot, so they go with it.
addon_boot_scripts() {
    local module addon f
    [[ -n "$MAGISK_MODULES_DIR" ]] || return 0
    for module in "$MAGISK_MODULES_DIR"/serverinator-*; do
        [[ -d "$module" ]] || continue
        addon="${module##*/serverinator-}"
        [[ "$addon" =~ ^[a-z][a-z0-9_]*$ ]] || continue
        for f in "$MAGISK_SERVICE_D"/[0-9][0-9]-"$addon"-*.sh; do
            [[ -f "$f" ]] && printf '%s\n' "$f"
        done
    done
    return 0
}

uninstall_phone() {
    check_root
    safe_remove_path "$CHROOT"
    uninstall_summary
    confirm_destructive "Remove it?"
    safe_remove_path "$SSH_HOSTKEY_DIR"
    safe_remove_path "$IDENTITY_DIR"
    local name file pid proc script addon_scripts=()
    mapfile -t addon_scripts < <(addon_boot_scripts)
    if [[ "$DEV" != 1 ]]; then
        # Add-on supervisors first, or they restart their services in the
        # chroot while it is being taken apart.
        for script in ${addon_scripts[@]+"${addon_scripts[@]}"}; do
            for proc in /proc/[0-9]*; do
                [[ -e "$proc/cmdline" ]] || continue
                if tr '\0' '\n' 2>/dev/null < "$proc/cmdline" | grep -Fx -e "$script" > /dev/null; then
                    stop_exact_pid "${proc##*/}" "$script" supervisor
                fi
            done
        done
        # Stop only supervisors named by exact script argv and children in this root.
        for name in wstunnel sshd wireguard tmpclean; do
            case "$name" in
                wstunnel) script="$MAGISK_SERVICE_D/10-serverinator-wstunnel.sh";;
                sshd) script="$MAGISK_SERVICE_D/30-serverinator-sshd.sh";;
                wireguard) script="$MAGISK_SERVICE_D/20-serverinator-wireguard.sh";;
                tmpclean) script="$MAGISK_SERVICE_D/40-serverinator-tmpclean.sh";;
            esac
            file="$STATE_DIR/run/$name-supervisor.pid"
            # An empty pid file must not abort the uninstall under set -e.
            if [[ -f "$file" ]] && read -r pid < "$file"; then stop_exact_pid "$pid" "$script" supervisor; fi
            # Covers legacy boot scripts without PID files; no name-wide pkill.
            for proc in /proc/[0-9]*; do
                # Android host access(R_OK) may report false even when root can
                # read the file. Check existence, then inspect the actual argv.
                [[ -e "$proc/cmdline" ]] || continue
                if tr '\0' '\n' 2>/dev/null < "$proc/cmdline" | grep -Fx -e "$script" -e "${script}.bak" > /dev/null; then
                    stop_exact_pid "${proc##*/}" "$script" supervisor
                fi
            done
        done
        for proc in /proc/[0-9]*; do
            [[ -e "$proc/root" ]] || continue
            if root="$(readlink "$proc/root")"; then
                if [[ "$root" == "$CHROOT" ]]; then stop_exact_pid "${proc##*/}" "$CHROOT" child; fi
            else
                warn "Process disappeared or root inspection failed: ${proc##*/}"
            fi
        done
        if [[ -d "$CHROOT" ]]; then
            local links
            links="$(chroot_run /sbin/ip -o link show)" || die "Cannot inspect interfaces before uninstall"
            if printf '%s\n' "$links" | grep -E '^[0-9]+: wg-si:' > /dev/null; then chroot_run /sbin/ip link del wg-si; fi
        fi
        # Remove only rules owned by this installation's managed config.
        local address subnet
        if [[ -f "$CHROOT/etc/wireguard/wg-si.conf" ]]; then
            address="$(awk '$1=="Address" {split($3,a,"/"); print a[1]}' "$CHROOT/etc/wireguard/wg-si.conf")"
            validate_ipv4 "$address" || die "Cannot identify owned policy rule"
            subnet="${address%.*}.0/24"
            local rules
            while :; do
                rules="$(chroot_run /sbin/ip -4 rule show)" || die "Cannot inspect policy rules before uninstall"
                if printf '%s\n' "$rules" | grep -E "^100:.*to ${subnet//./\.} lookup main" > /dev/null; then
                    chroot_run /sbin/ip rule del to "$subnet" lookup main priority 100
                else
                    break
                fi
            done
        fi
    fi
    unmount_chroot || die "Unmount failed; refusing rootfs deletion"
    [[ -z "$(phone_mounts)" ]] || die "Mounted paths remain; refusing rootfs deletion"
    for name in 00-serverinator-mount 10-serverinator-wstunnel 20-serverinator-wireguard 30-serverinator-sshd 40-serverinator-tmpclean; do
        rm -f "$MAGISK_SERVICE_D/$name.sh" "$MAGISK_SERVICE_D/$name.sh.bak"
    done
    for script in ${addon_scripts[@]+"${addon_scripts[@]}"}; do
        rm -f "$script" "$script.bak"
    done
    rm -rf "$CHROOT"
    if [[ "$PURGE" == 1 ]]; then rm -rf "$SSH_HOSTKEY_DIR" "$IDENTITY_DIR" "$STATE_DIR/vps-target"; fi
    # The si command and the scripts it runs (serverinator.sh keeps them in
    # STATE_DIR/bin), plus any module built on top of Core (serverinator-*).
    # Bash keeps this file open, so removing it doesn't stop the run.
    local module
    if [[ -n "$MAGISK_MODULES_DIR" ]]; then
        for module in "$MAGISK_MODULES_DIR/serverinator" "$MAGISK_MODULES_DIR"/serverinator-*; do
            [[ -d "$module" ]] && rm -rf "$module"
        done
    fi
    rm -rf "${STATE_DIR:?}/bin"
    # Logs and .bak backups are pure operational debris, not identity state —
    # always clear them, regardless of --purge.
    rm -rf "$STATE_DIR/run" "$STATE_DIR/logs" "$STATE_DIR/backups"
    if [[ "$PURGE" == 1 ]]; then
        info "Phone uninstall complete; WireGuard and SSH host keys removed too (--purge)"
    else
        info "Phone uninstall complete; WireGuard and SSH host keys kept (--purge removes them)"
    fi
}
