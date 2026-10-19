# shellcheck shell=bash
# ServerInator Core, phone side: step 2, the chroot: rootfs, mounts, /tmp, DNS
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Step 2: Bootstrap chroot ──────────────────

# Written last, once the rootfs is known to be usable. A chroot without it
# is an interrupted install and gets extracted again instead of skipped.
ROOTFS_MARKER_NAME=".serverinator-rootfs-complete"

rootfs_marker() { printf '%s/%s\n' "$CHROOT" "$ROOTFS_MARKER_NAME"; }

# Installs from before the marker existed: accept them if the key files are there.
rootfs_looks_complete() {
    local file
    for file in bin/sh usr/bin/env usr/bin/dpkg etc/os-release; do
        [[ -e "$CHROOT/$file" || -L "$CHROOT/$file" ]] || return 1
    done
}

mark_rootfs_complete() { date -u +%Y-%m-%dT%H:%M:%SZ > "$(rootfs_marker)"; }

extract_rootfs() {
    local archive="$1" scratch rc=0 file
    scratch="$(mktemp -d)" || die "Cannot prepare extraction diagnostics"
    if LC_ALL=C tar -xf "$archive" -C "$CHROOT" > "$scratch/stdout" 2> "$scratch/stderr"; then
        :
    else
        rc=$?
    fi
    if [[ "$rc" != 0 ]]; then
        cat "$scratch/stderr" >&2
        rm -rf "$scratch"
        die "Rootfs extraction failed (tar exit $rc); refusing partial rootfs"
    fi
    if [[ -s "$scratch/stderr" ]]; then
        # GNU tar leading-slash warnings do not imply incomplete extraction.
        # Other successful warnings remain visible and are not silently discarded.
        while IFS= read -r line; do
            case "$line" in
                "tar: Removing leading '/' from member names"|"tar: Removing leading '/' from hard link targets")
                    warn "Rootfs archive paths normalized by tar" ;;
                *) warn "tar warning: $line" ;;
            esac
        done < "$scratch/stderr"
    fi
    rm -rf "$scratch"
    for file in bin/sh usr/bin/env usr/bin/dpkg etc/os-release; do
        [[ -e "$CHROOT/$file" || -L "$CHROOT/$file" ]] || die "Incomplete rootfs: missing $file"
    done
    # Resolve absolute symlinks inside the chroot, not against the Android root.
    chroot_run /bin/sh -c 'test -x /bin/sh && test -x /usr/bin/env && test -x /usr/bin/dpkg && test -r /etc/os-release'         || die "Rootfs key files cannot be used inside chroot"
}

bootstrap_chroot() (
    if [[ -d "$CHROOT/bin" && ! -f "$(rootfs_marker)" ]]; then
        if rootfs_looks_complete; then
            mark_rootfs_complete
        else
            warn "The chroot at $CHROOT is incomplete (an earlier install was interrupted) — installing the rootfs again over it"
        fi
    fi
    if [[ -d "$CHROOT/bin" && -f "$(rootfs_marker)" ]]; then
        warn "Chroot already exists at $CHROOT"
        if [[ "${SERVERINATOR_YES:-0}" == "1" ]]; then
            info "Skipping bootstrap"
            return
        fi
        # When running in a pipeline (e.g. … | tee log), stdin is not a tty
        # and read returns immediately with exit code 1, which set -e would
        # turn into an abort.  Default to skip (Y) when non-interactive.
        if [[ -t 0 ]]; then
            read -r -p "Skip bootstrap? [Y/n] " answer
        else
            answer=""
            warn "Non-interactive: defaulting to skip existing chroot"
        fi
        answer="${answer:-Y}"
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            info "Skipping bootstrap"
            return
        fi
    fi

    if command -v debootstrap &>/dev/null; then
        info "Running debootstrap..."
        debootstrap --arch="$(debian_arch)" stable "$CHROOT" http://deb.debian.org/debian
        rootfs_looks_complete || die "debootstrap finished but the rootfs is incomplete"
        mark_rootfs_complete
    else
        warn "debootstrap not found, falling back to pre-built rootfs"
        local rootfs_name
        rootfs_name="ubuntu-base-24.04.4-base-$(debian_arch).tar.gz"
        info "Downloading Ubuntu 24.04 base rootfs for ${ARCH}..."
        local scratch
        scratch="$(mktemp -d)"
        trap 'rm -rf "$scratch"' EXIT
        curl -fsSL "https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/$rootfs_name" -o "$scratch/rootfs.tar.gz"
        verify_download "$scratch/rootfs.tar.gz" "$rootfs_name"
        mkdir -p "$CHROOT"
        extract_rootfs "$scratch/rootfs.tar.gz"
        rm -f "$scratch/rootfs.tar.gz"
        mark_rootfs_complete
        info "Rootfs extracted to $CHROOT"
    fi
)

# Settles CHROOT_TMP_MODE: explicit choice, else the previous one, else by RAM.
resolve_chroot_tmp_mode() {
    local saved="$STATE_DIR/chroot-tmp-mode"
    if [[ -z "$CHROOT_TMP_MODE" && -f "$saved" ]]; then
        CHROOT_TMP_MODE="$(cat "$saved")"
    fi
    CHROOT_TMP_MODE="${CHROOT_TMP_MODE:-$(default_chroot_tmp_mode)}"
    [[ "$CHROOT_TMP_MODE" == tmpfs || "$CHROOT_TMP_MODE" == disk ]] \
        || die "Invalid chroot /tmp mode '$CHROOT_TMP_MODE' (expected tmpfs or disk)"
    [[ "$CHROOT_TMP_SIZE" =~ ^[1-9][0-9]{0,5}[MG]$ ]] \
        || die "Invalid SERVERINATOR_CHROOT_TMP_SIZE '$CHROOT_TMP_SIZE' (e.g. 256M or 1G)"
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$CHROOT_TMP_MODE" > "$saved"
    info "Chroot /tmp: $CHROOT_TMP_MODE$([[ "$CHROOT_TMP_MODE" == tmpfs ]] && echo " (${CHROOT_TMP_SIZE})")"
}

write_mount_script() {
    local script_path="$MAGISK_SERVICE_D/00-serverinator-mount.sh"

    mkdir -p "$MAGISK_SERVICE_D"
    local desired
    desired="$(mktemp "$MAGISK_SERVICE_D/script.XXXXXX")"
    render_template "$CORE_DIR/templates/magisk-mount.sh" "CHROOT=$CHROOT" \
        "CHROOT_TMP_MOUNT_LINES=$(chroot_tmp_mount_lines)" > "$desired"
    reconcile_file "$script_path" 700 "$STATE_DIR/backups" < "$desired"
    rm -f "$desired"
    info "Mount script written to $script_path"
    if [[ "$DEV" == "1" ]]; then
        dev "DEV mode: mount script created but not executed"
    fi
}

# Lines appended to the boot mount script for the chosen /tmp mode.
chroot_tmp_mount_lines() {
    if [[ "$CHROOT_TMP_MODE" == tmpfs ]]; then
        printf '%s\n' \
            '# /tmp: tmpfs (cleared on every boot)' \
            "mkdir -p \"\${CHROOT}/tmp\"" \
            "mountpoint -q \"\${CHROOT}/tmp\" || mount -t tmpfs -o size=${CHROOT_TMP_SIZE},mode=1777,nosuid,nodev tmpfs \"\${CHROOT}/tmp\""
    else
        printf '%s\n' '# /tmp: on disk; 40-serverinator-tmpclean.sh removes old files'
    fi
}

# Disk mode: a supervisor that prunes /tmp every 6 hours. Only regular files
# and symlinks untouched (mtime and atime) for CHROOT_TMP_MAX_AGE_DAYS days
# are removed, then empty directories of the same age; sockets and anything
# in use recently are left alone. tmpfs mode removes the script instead.
write_tmpclean_autostart() {
    local script_path="$MAGISK_SERVICE_D/40-serverinator-tmpclean.sh"
    if [[ "$CHROOT_TMP_MODE" != disk ]]; then
        if [[ -f "$script_path" ]]; then
            rm -f "$script_path"
            info "Removed $script_path (chroot /tmp is tmpfs)"
        fi
        return 0
    fi
    mkdir -p "$MAGISK_SERVICE_D"
    render_template "$CORE_DIR/templates/magisk-tmpclean.sh" "STATE_DIR=$STATE_DIR" "CHROOT=$CHROOT" \
        "CHROOT_TMP_MAX_AGE_DAYS=$CHROOT_TMP_MAX_AGE_DAYS" \
        | reconcile_file "$script_path" 700 "$STATE_DIR/backups"
    info "tmp cleaner autostart written: $script_path"
}

# ── Step 2: Chroot environment (mounts, DNS) ───

setup_chroot_env() {
    # Make the chroot usable for package installation and DNS.
    # Idempotent: filesystems that are already mounted are left untouched, so
    # repeated runs never remount or stack mounts.
    local fs target

    for fs in proc sys dev; do
        target="$CHROOT/$fs"
        if [[ ! -d "$target" ]]; then
            mkdir -p "$target" || die "Unable to create $target"
        fi
        if mountpoint -q "$target" 2>/dev/null; then
            info "Already mounted: $target"
            continue
        fi
        if mount --bind "/$fs" "$target"; then
            info "Mounted /$fs -> $target"
        else
            # apt and key generation need these; failing loudly avoids leaving
            # the caller with a half-configured chroot it cannot install into.
            die "Failed to bind-mount /$fs into $target (required for chroot package installation)"
        fi
    done

    # /dev/pts is normally already mounted through the /dev bind mount above.
    # Only set it up if it is genuinely missing.
    target="$CHROOT/dev/pts"
    if [[ ! -d "$target" ]]; then
        mkdir -p "$target" || die "Unable to create $target"
    fi
    if ! mountpoint -q "$target" 2>/dev/null; then
        if mount -t devpts devpts "$target"; then
            info "Mounted devpts -> $target"
        else
            warn "Could not mount devpts at $target (continuing)"
        fi
    fi

    if [[ "$CHROOT_TMP_MODE" == tmpfs ]] && ! mountpoint -q "$CHROOT/tmp" 2>/dev/null; then
        mkdir -p "$CHROOT/tmp"
        mount -t tmpfs -o "size=${CHROOT_TMP_SIZE},mode=1777,nosuid,nodev" tmpfs "$CHROOT/tmp" \
            || die "Failed to mount tmpfs on $CHROOT/tmp"
        info "Mounted tmpfs (${CHROOT_TMP_SIZE}) -> $CHROOT/tmp"
    fi

    # DNS for apt inside the chroot.
    mkdir -p "$CHROOT/etc" "$CHROOT/tmp" || die "Unable to prepare chroot directories"
    if ! chroot_resolv_conf > "$CHROOT/etc/resolv.conf"; then
        die "Failed to write $CHROOT/etc/resolv.conf"
    fi

    info "Chroot environment configured (mounts + DNS)"
}

# resolv.conf for the chroot. SERVERINATOR_DNS="9.9.9.9 1.0.0.1" replaces
# the defaults, for networks that block Google or Cloudflare DNS.
chroot_resolv_conf() {
    local servers="${SERVERINATOR_DNS:-8.8.8.8 1.1.1.1}" ip
    printf '# Written by ServerInator. Set SERVERINATOR_DNS="IP IP" and re-run setup to change.\n'
    for ip in $servers; do
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* ]] \
            || die "SERVERINATOR_DNS: '$ip' is not an IP address"
        printf 'nameserver %s\n' "$ip"
    done
}

phone_mounts() {
    # /proc/mounts is authoritative; decode mount escaping after prefix matching.
    awk -v root="$CHROOT" '
      $2==root || index($2,root"/")==1 {
        path=$2; gsub(/\\040/," ",path); gsub(/\\011/,"\t",path); print length(path) " " path
      }' /proc/mounts | sort -rn | cut -d' ' -f2-
}

unmount_chroot() {
    local mounts target attempts=0
    while :; do
        mounts="$(phone_mounts)" || return 1
        [[ -n "$mounts" ]] || return 0
        while IFS= read -r target; do
            umount "$target" || { error "Cannot unmount $target; rootfs preserved"; return 1; }
        done <<< "$mounts"
        attempts=$((attempts+1))
        [[ "$attempts" -lt 4096 ]] || { error "Mounts remain after repeated unmount"; return 1; }
    done
}
