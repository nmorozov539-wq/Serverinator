#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# ServerInator Core — phone-side setup script
# ─────────────────────────────────────────────

DEV="${SERVERINATOR_DEV:-0}"
ARCH_OVERRIDE="${SERVERINATOR_ARCH_OVERRIDE:-}"
CHROOT="${SERVERINATOR_CHROOT:-/data/serverinator-root}"

if [[ "$DEV" == "1" ]]; then
    MAGISK_SERVICE_D="${SERVERINATOR_SERVICE_D:?DEV mode requires SERVERINATOR_SERVICE_D to be set}"
else
    # Honor an explicit override so tests (and unusual setups) can redirect the
    # Magisk service directory without modifying the script.
    MAGISK_SERVICE_D="${SERVERINATOR_SERVICE_D:-/data/adb/service.d}"
fi

# v11.0.0 fixes reverse-tunnel idle reconnect, TCP_NODELAY stalls and dispatch
# speed (see upstream changelog). The working reference setup used 11.0.0.
WSTUNNEL_VERSION="11.0.0"
BACK_HANDOFF_FILE=""
DEVICE_NAME="${SERVERINATOR_DEVICE_NAME:-}"
MODE="setup"
PURGE=0

# /tmp inside the chroot: "tmpfs" (RAM, cleared on reboot) or "disk"
# (persistent storage, old files removed by a periodic cleaner). Empty means
# keep the previous choice, or pick by RAM on a first install.
CHROOT_TMP_MODE="${SERVERINATOR_CHROOT_TMP:-}"
CHROOT_TMP_SIZE="${SERVERINATOR_CHROOT_TMP_SIZE:-256M}"
CHROOT_TMP_MAX_AGE_DAYS=7

# Port arrangement (must stay consistent with the VPS script and the
# autostart/wg config generated below):
#   WG_LOCAL_PORT : local UDP port the phone's wstunnel client binds, and the
#                   port the phone's WireGuard client uses as its Endpoint.
#   WG_VPS_PORT   : the VPS WireGuard ListenPort, i.e. the wstunnel forwarding
#                   target (127.0.0.1:WG_VPS_PORT on the VPS).
#   WSTUNNEL_PORT : the VPS wstunnel server TLS port.
WG_LOCAL_PORT=51823
WG_VPS_PORT=51822
WSTUNNEL_PORT=9443

# SSH access (tunnel-only, root, public-key auth)
SSH_USER="root"
SSH_PORT=2222
ENABLE_SSH=1
SSH_HOST_FINGERPRINT=""
SSH_HOST_PUBKEY=""
SSHD_LISTEN_IP=""
STATE_DIR="${SERVERINATOR_STATE_DIR:-/data/adb/serverinator}"
if [[ "$DEV" == "1" ]]; then STATE_DIR="${SERVERINATOR_STATE_DIR:-${CHROOT%/}-state}"; fi
if [[ "${SERVERINATOR_NO_SSH:-0}" == "1" ]]; then
    ENABLE_SSH=0
fi
if [[ "$DEV" == "1" ]]; then
    SSH_HOSTKEY_DIR="${SERVERINATOR_SSH_HOSTKEY_DIR:-${CHROOT%/}-ssh-hostkeys}"
else
    SSH_HOSTKEY_DIR="${SERVERINATOR_SSH_HOSTKEY_DIR:-/data/adb/serverinator/ssh}"
fi

# Identity kept outside the chroot so a chroot rebuild, an uninstall without
# --purge, or a move to another phone (--export/--import-identity) keeps the
# WireGuard key the VPS knows. SSH host keys live in SSH_HOSTKEY_DIR.
IDENTITY_DIR="${SERVERINATOR_IDENTITY_DIR:-$STATE_DIR/identity}"
# serverinator.sh's key for logging into the VPS (same default as there).
ORCHESTRATOR_SSH_DIR="${SERVERINATOR_ORCHESTRATOR_SSH_DIR:-/data/adb/serverinator/orchestrator}"
IDENTITY_FILE=""
# Magisk modules: serverinator.sh's `si` command lives in one. DEV never
# touches the real folder.
if [[ "$DEV" == "1" ]]; then
    MAGISK_MODULES_DIR="${SERVERINATOR_MODULES_DIR:-}"
else
    MAGISK_MODULES_DIR="${SERVERINATOR_MODULES_DIR:-/data/adb/modules}"
fi

# ── Shared library ────────────────────────────
# Resolved once at the top level: inside a function, the phone's bash gave
# BASH_SOURCE without its directory (hardware run 2026-10-14).
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CORE_DIR/lib.sh"

# ── Argument parsing ──────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device-name)
                shift
                [[ $# -gt 0 ]] || die "--device-name requires a value"
                DEVICE_NAME="$1"; shift
                ;;
            --apply-back-handoff|--back-handoff)
                MODE="apply-back-handoff"; shift
                [[ $# -gt 0 ]] || die "--back-handoff requires a file path"
                BACK_HANDOFF_FILE="$1"; shift
                ;;
            --uninstall) MODE="uninstall"; shift ;;
            --status)    MODE="status"; shift ;;
            --export-identity|--import-identity)
                [[ "$1" == --export-identity ]] && MODE="export-identity" || MODE="import-identity"
                shift
                [[ $# -gt 0 ]] || die "${MODE/-identity/} needs a FILE"
                IDENTITY_FILE="$1"; shift
                ;;
            --purge)     PURGE=1; shift ;;
            --no-ssh)    ENABLE_SSH=0; shift ;;
            --chroot-tmp)
                shift
                [[ $# -gt 0 ]] || die "--chroot-tmp requires tmpfs or disk"
                CHROOT_TMP_MODE="$1"; shift
                ;;
            -*) die "Unknown argument: $1" ;;
        esac
    done
}

# ── Chroot helper ─────────────────────────────

# Run a command inside the chroot with a sanitized environment. Android
# exports TMPDIR=/data/local/tmp (plus other variables) which do not exist
# inside the chroot; package maintainer scripts use mktemp and fail otherwise.
chroot_run() {
    chroot "$CHROOT" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root \
        TMPDIR=/tmp \
        DEBIAN_FRONTEND=noninteractive \
        "$@"
}

# ── Step 1: Environment checks ────────────────

check_root() {
    if [[ "$DEV" == "1" ]]; then
        dev "Skipping root check"
        return
    fi
    [[ "$(id -u)" == "0" ]] || die "This script must be run as root"
}

check_magisk() {
    if [[ "$DEV" == "1" ]]; then
        dev "Skipping Magisk check"
        return
    fi
    [[ -d "/data/adb/magisk" ]] || die "Magisk not found at /data/adb/magisk. Is Magisk installed?"
}

check_disk_space() {
    local required_kb=512000
    local check_path="$CHROOT"
    while [[ ! -e "$check_path" ]]; do
        check_path="$(dirname "$check_path")"
        if [[ "$check_path" == "/" ]]; then
            break
        fi
    done
    local available_kb
    available_kb="$(df "$check_path" | awk 'NR==2{print $4}')"
    if [[ "$available_kb" -lt "$required_kb" ]]; then
        die "Not enough disk space. Required: 500 MB, available: $(( available_kb / 1024 )) MB"
    fi
    info "Disk space OK ($(( available_kb / 1024 )) MB available)"
}

detect_arch() {
    if [[ -n "$ARCH_OVERRIDE" ]]; then
        echo "$ARCH_OVERRIDE"
        return
    fi
    local raw
    raw="$(uname -m)"
    case "$raw" in
        aarch64)        echo "aarch64" ;;
        armv7l|armv8l) echo "armv7" ;;
        x86_64)         echo "x86_64" ;;
        *)              die "Unsupported architecture: $raw" ;;
    esac
}

# Debian/Ubuntu name for ARCH (debootstrap and ubuntu-base use these).
debian_arch() {
    case "$ARCH" in
        aarch64) echo arm64 ;;
        armv7)   echo armhf ;;
        x86_64)  echo amd64 ;;
        *)       die "No Debian architecture for: $ARCH" ;;
    esac
}

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
        if [[ "$DEV" != "1" ]] && rootfs_looks_complete; then
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

    if [[ "$DEV" == "1" ]]; then
        dev "DEV mode: creating stub chroot at $CHROOT"
        mkdir -p "$CHROOT"/{bin,etc,proc,sys,dev,dev/pts,usr/local/bin}
        mark_rootfs_complete
        info "Stub chroot created at $CHROOT"
        return
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

# Total RAM in MiB (0 if unknown).
total_ram_mb() {
    awk '$1=="MemTotal:" {print int($2/1024); found=1} END {if(!found) print 0}' /proc/meminfo 2>/dev/null || echo 0
}

# Default for a first install: tmpfs only when RAM is comfortably large.
default_chroot_tmp_mode() {
    if (( $(total_ram_mb) >= 3072 )); then echo tmpfs; else echo disk; fi
}

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
    cat > "$desired" << EOF
#!/system/bin/sh
# ServerInator — mount filesystems into chroot
# Managed by ServerInator Core, do not edit manually

CHROOT="${CHROOT}"

for fs in proc sys dev dev/pts; do
    mountpoint -q "\${CHROOT}/\${fs}" || mount --bind "/\${fs}" "\${CHROOT}/\${fs}"
done
$(chroot_tmp_mount_lines)
EOF
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
    reconcile_file "$script_path" 700 "$STATE_DIR/backups" << EOF
#!/system/bin/sh
# ServerInator — chroot /tmp cleaner (disk mode)
# Managed by ServerInator, do not edit manually.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin
export PATH
STATE_DIR='${STATE_DIR}'
CHROOT='${CHROOT}'
umask 077
mkdir -p "\$STATE_DIR/logs" "\$STATE_DIR/run" || exit 1
LOG="\$STATE_DIR/logs/tmpclean.log"
printf '%s\\n' "\$\$" > "\$STATE_DIR/run/tmpclean-supervisor.pid"
trap 'rm -f "\$STATE_DIR/run/tmpclean-supervisor.pid"; exit' INT TERM
sleep 300
while true; do
    if [ -f "\$LOG" ] && [ "\$(wc -c < "\$LOG")" -ge 1048576 ]; then
        cp "\$LOG" "\$LOG.1" && : > "\$LOG"
    fi
    chroot "\$CHROOT" /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/find /tmp -xdev -mindepth 1 \\
        \\( -type f -o -type l \\) -mtime +${CHROOT_TMP_MAX_AGE_DAYS} -atime +${CHROOT_TMP_MAX_AGE_DAYS} -print -delete >> "\$LOG" 2>&1
    chroot "\$CHROOT" /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/find /tmp -xdev -mindepth 1 -depth \\
        -type d -empty -mtime +${CHROOT_TMP_MAX_AGE_DAYS} -print -delete >> "\$LOG" 2>&1
    sleep 21600
done
EOF
    info "tmp cleaner autostart written: $script_path"
}

# ── Step 3: Install packages into chroot ──────

install_chroot_packages() {
    if [[ "$DEV" == "1" ]]; then
        dev "DEV mode: skipping package install"
        return
    fi

    local packages=(wireguard-tools iproute2 iputils-ping curl jq)
    if [[ "$ENABLE_SSH" == "1" ]]; then
        packages+=(openssh-server)
    fi

    local pkg status all_installed=1
    for pkg in "${packages[@]}"; do
        if status="$(chroot_run /usr/bin/dpkg-query -W -f='${Status}' "$pkg")"; then
            [[ "$status" == "install ok installed" ]] || all_installed=0
        else
            all_installed=0
        fi
    done
    if [[ "$all_installed" == 1 ]]; then
        chroot_run /usr/bin/dpkg --configure -a || die "dpkg configuration failed"
        return 0
    fi

    info "Installing packages into chroot (${packages[*]})..."
    chroot_run /usr/bin/apt-get update -qq \
        || die "APT update failed; check chroot time, repository configuration and signing keys"

    chroot_run /usr/bin/apt-get install -y "${packages[@]}" \
        || die "APT package installation failed; repository authentication remains required"

    chroot_run /usr/bin/dpkg --configure -a || die "dpkg --configure -a failed inside chroot"
    info "Packages installed"
}

# ── Step 3: Transport plugin — client side ────

wstunnel_arch_suffix() {
    case "$ARCH" in
        aarch64) echo "arm64" ;;
        armv7)   echo "armv7" ;;
        x86_64)  echo "amd64" ;;
        *)       die "No wstunnel binary for architecture: $ARCH" ;;
    esac
}

install_wstunnel() (
    local dest="$CHROOT/usr/local/bin/wstunnel"

    # In DEV mode, create a stub that answers the version check correctly.
    if [[ "$DEV" == "1" ]]; then
        if [[ -x "$dest" ]]; then
            local current
            current="$(chroot_run /usr/local/bin/wstunnel --version 2>&1 \
                | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
            if [[ "$current" == "$WSTUNNEL_VERSION" ]]; then
                info "wstunnel v${WSTUNNEL_VERSION} (DEV stub) already present — skipping"
                return 0
            fi
        fi
        dev "DEV: creating wstunnel stub at $dest"
        mkdir -p "$(dirname "$dest")"
        cat > "$dest" << STUB
#!/usr/bin/env bash
case "\${1:-}" in --version) echo "wstunnel v${WSTUNNEL_VERSION}";; esac
echo "wstunnel STUB (DEV): \$*"
STUB
        chmod +x "$dest"
        return 0
    fi

    # Check both presence AND version — a mismatched version gets upgraded.
    # -f, not -x: Android's bash can deny root an access() check, which made
    # every run download wstunnel again (seen 2026-10-17).
    if [[ -f "$dest" ]]; then
        local current
        current="$(chroot_run /usr/local/bin/wstunnel --version 2>&1 \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        if [[ "$current" == "$WSTUNNEL_VERSION" ]]; then
            info "wstunnel v${WSTUNNEL_VERSION} already installed — skipping"
            # Older installs kept the archive's owner; see below.
            [[ "$(id -u)" != 0 ]] || chown 0:0 "$dest"
            return 0
        fi
        warn "wstunnel v${current:-?} is installed, v${WSTUNNEL_VERSION} is required — upgrading"
    fi

    local suffix
    suffix="$(wstunnel_arch_suffix)"
    local url="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_${suffix}.tar.gz"

    if [[ "$DEV" == "1" ]]; then
        dev "Downloading wstunnel from $url"
    fi

    local scratch
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    info "Downloading wstunnel v${WSTUNNEL_VERSION} for ${ARCH}..."
    curl -fsSL "$url" -o "$scratch/wstunnel.tar.gz"
    verify_download "$scratch/wstunnel.tar.gz" "${url##*/}"
    tar -xf "$scratch/wstunnel.tar.gz" -C "$scratch" wstunnel
    mkdir -p "$CHROOT/usr/local/bin"
    mv "$scratch/wstunnel" "$dest"
    # tar keeps the archive's owner (uid 1001) when run as root.
    [[ "$(id -u)" != 0 ]] || chown 0:0 "$dest"
    chmod 755 "$dest"
    rm -f "$scratch/wstunnel.tar.gz"
    info "wstunnel installed to $dest"
)

# The chroot's copy is what WireGuard uses; IDENTITY_DIR keeps a copy that
# survives a chroot rebuild and restores it before a new key would be made.
generate_wg_keys() {
    restore_wg_identity
    _generate_wg_keys
    persist_wg_identity
}

restore_wg_identity() {
    local key_dir="$CHROOT/etc/wireguard"
    [[ -s "$key_dir/client.key" && -s "$key_dir/client.pub" ]] && return 0
    [[ -s "$IDENTITY_DIR/wireguard/client.key" && -s "$IDENTITY_DIR/wireguard/client.pub" ]] || return 0
    mkdir -p "$key_dir"; chmod 700 "$key_dir"
    (umask 077; cp -f "$IDENTITY_DIR/wireguard/client.key" "$IDENTITY_DIR/wireguard/client.pub" "$key_dir/")
    info "Restored the saved WireGuard key ($(cat "$key_dir/client.pub"))"
}

persist_wg_identity() {
    local key_dir="$CHROOT/etc/wireguard" store="$IDENTITY_DIR/wireguard"
    [[ -s "$key_dir/client.key" && -s "$key_dir/client.pub" ]] || return 0
    if [[ -f "$store/client.key" ]] && cmp -s "$key_dir/client.key" "$store/client.key"; then
        return 0
    fi
    [[ -f "$store/client.key" ]] && warn "Saved WireGuard key differed from the one in use; saving the one in use"
    mkdir -p "$store"; chmod 700 "$IDENTITY_DIR" "$store"
    (umask 077; cp -f "$key_dir/client.key" "$key_dir/client.pub" "$store/")
}

_generate_wg_keys() {
    local key_dir="$CHROOT/etc/wireguard"
    local priv_key="$key_dir/client.key"
    local pub_key="$key_dir/client.pub"

    mkdir -p "$key_dir"
    chmod 700 "$key_dir"

    if [[ "$DEV" == "1" ]]; then
        if [[ -f "$priv_key" && -f "$pub_key" && -s "$pub_key" ]]; then
            info "WireGuard keys already exist, skipping (DEV)"
            return 0
        fi
        dev "DEV: creating WireGuard key stubs"
        # Valid base64 format: 42 characters + one character from a limited set + '='
        printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQ=' > "$priv_key"
        printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQ=' > "$pub_key"
        chmod 600 "$priv_key"
        return 0
    fi

    if [[ -f "$priv_key" && -f "$pub_key" ]]; then
        # Validate keys are not empty
        if [[ -s "$priv_key" && -s "$pub_key" ]]; then
            info "WireGuard keys already exist, skipping (delete $priv_key to regenerate)"
            return
        fi
        warn "WireGuard key files exist but are empty, regenerating..."
        rm -f "$priv_key" "$pub_key"
    fi

    info "Generating WireGuard key pair..."

    if [[ -f "$CHROOT/usr/bin/wg" ]]; then
        # Generate via chroot wg (preferred — works on Android without wg in PATH)
        chroot_run /usr/bin/sh -c \
            "umask 077; wg genkey > /etc/wireguard/client.key"
        chroot_run /usr/bin/sh -c \
            "umask 077; wg pubkey < /etc/wireguard/client.key > /etc/wireguard/client.pub"
    elif command -v wg &>/dev/null; then
        wg genkey | tee "$priv_key" | wg pubkey > "$pub_key"
    else
        die "Cannot generate WireGuard keys: wg not found"
    fi

    chmod 600 "$priv_key"
    info "Keys written to $key_dir"
    info "Public key: $(cat "$pub_key")"
}

# ── Step 3b: SSH server (tunnel-only) ─────────

# Make sure the main sshd_config actually reads our drop-in directory.
ensure_sshd_include() {
    local main="$CHROOT/etc/ssh/sshd_config"
    local inc='Include /etc/ssh/sshd_config.d/*.conf'
    if [[ -f "$main" ]] && grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$' "$main"; then
        return 0
    fi
    local tmp
    tmp="$(mktemp "$CHROOT/etc/ssh/sshd_config.XXXXXX")" || die "Unable to create sshd_config temp file"
    {
        printf '%s\n' "$inc"
        if [[ -f "$main" ]]; then
            cat "$main"
        fi
    } > "$tmp"
    reconcile_file "$main" 600 < "$tmp"
    rm -f "$tmp"
}

validate_effective_sshd() {
    local expected_ip="${1:-}" effective
    effective="$(chroot_run /usr/sbin/sshd -T)" || die "Cannot read effective sshd configuration"
    [[ "$(printf '%s\n' "$effective" | awk 'tolower($1)=="port" {print $2}')" == "$SSH_PORT" ]]         || die "Effective sshd Port differs from managed port"
    [[ "$(printf '%s\n' "$effective" | awk 'tolower($1)=="passwordauthentication" {print $2}')" == no ]]         || die "Effective sshd enables password authentication"
    if [[ -n "$expected_ip" ]]; then
        printf '%s\n' "$effective" | awk -v want="$expected_ip:$SSH_PORT" '
          tolower($1)=="listenaddress" {n++; if($2!=want) bad=1}
          END {exit (n==0 || bad)}' || die "Effective sshd ListenAddress is not tunnel-only"
    fi
}

prepare_sshd_runtime() {
    [[ "$ENABLE_SSH" == 1 ]] || return 0
    [[ "$DEV" != 1 ]] || { dev "Skipping real sshd validation in DEV"; return 0; }
    local status
    status="$(chroot_run /usr/bin/dpkg-query -W -f='${Status}' openssh-server)"         || die "openssh-server is absent from dpkg"
    [[ "$status" == "install ok installed" ]] || die "openssh-server is not configured"
    if chroot_run /usr/bin/getent passwd sshd; then
        : # Existing package account is preserved.
    else
        local rc=$?
        [[ "$rc" == 2 ]] || die "Cannot query sshd account (getent=$rc)"
        chroot_run /usr/sbin/useradd --system --no-create-home             --home-dir /run/sshd --shell /usr/sbin/nologin sshd
    fi
    chroot_run /usr/bin/mkdir -p /run/sshd
    chroot_run /usr/bin/chmod 0755 /run/sshd
    chroot_run /usr/sbin/sshd -t || die "Invalid sshd configuration"
    validate_effective_sshd "${1:-}"
}

# ListenAddress currently in our sshd drop-in, or 127.0.0.1 when there is
# none (fresh install, or a drop-in from before ListenAddress was managed).
current_sshd_listen_ip() {
    local conf="$CHROOT/etc/ssh/sshd_config.d/00-serverinator.conf" ip=""
    if [[ -f "$conf" ]]; then
        ip="$(awk '$1=="ListenAddress" {print $2; exit}' "$conf")"
    fi
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && (validate_ipv4 "$ip") 2>/dev/null; then
        printf '%s\n' "$ip"
    else
        printf '%s\n' 127.0.0.1
    fi
}

# write_sshd_dropin LISTEN_IP — the single source of the managed sshd config.
write_sshd_dropin() {
    local listen_ip="$1"
    validate_ipv4 "$listen_ip" "sshd listen IPv4"
    mkdir -p "$CHROOT/etc/ssh/sshd_config.d"
    reconcile_file "$CHROOT/etc/ssh/sshd_config.d/00-serverinator.conf" 644 "$STATE_DIR/backups" << EOF
# Managed by ServerInator. Tunnel-only, key-only root login.
Port ${SSH_PORT}
ListenAddress ${listen_ip}
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
UsePAM no
# Keep the KEX reply small: sntrup761's post-quantum reply is too big for the
# wstunnel path and stalls the handshake.
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
HostKeyAlgorithms ssh-ed25519
EOF
}

install_ssh_server() {
    if [[ "$ENABLE_SSH" != "1" ]]; then
        info "SSH support disabled (--no-ssh)"
        return 0
    fi
    if [[ "$DEV" == "1" ]]; then
        dev "DEV mode: skipping sshd setup"
        return 0
    fi

    [[ -f "$CHROOT/usr/sbin/sshd" ]] || die "openssh-server is not installed inside the chroot"

    mkdir -p "$CHROOT/run/sshd" "$CHROOT/etc/ssh/sshd_config.d"
    chmod 0755 "$CHROOT/run/sshd"
    ensure_sshd_include

    # Host keys live outside the chroot so a chroot rebuild keeps the phone's
    # identity (and clients don't get spurious known_hosts warnings).
    mkdir -p "$SSH_HOSTKEY_DIR"
    chmod 700 "$SSH_HOSTKEY_DIR"

    local persisted=0 f
    for f in "$SSH_HOSTKEY_DIR"/ssh_host_*_key; do
        [[ -e "$f" ]] && persisted=1
    done
    if [[ "$persisted" == "1" ]]; then
        cp -f "$SSH_HOSTKEY_DIR"/ssh_host_*_key "$CHROOT/etc/ssh/"
        cp -f "$SSH_HOSTKEY_DIR"/ssh_host_*_key.pub "$CHROOT/etc/ssh/"
        info "Restored persisted SSH host keys"
    else
        for f in "$CHROOT/etc/ssh"/ssh_host_*_key; do
            [[ -e "$f" ]] || continue
            cp -f "$f" "$SSH_HOSTKEY_DIR/"
            cp -f "${f}.pub" "$SSH_HOSTKEY_DIR/" 2>/dev/null || true
        done
        info "Persisted SSH host keys to $SSH_HOSTKEY_DIR"
    fi
    for f in "$CHROOT/etc/ssh"/ssh_host_*_key; do
        [[ -e "$f" ]] || continue
        chmod 600 "$f"
    done

    # Base sshd config. Never listen on every interface: keep the tunnel
    # address from a previous apply, or loopback until the back-handoff
    # supplies one. A re-run whose later steps fail must not leave sshd
    # exposed on Wi-Fi/cellular after the next reboot.
    SSHD_LISTEN_IP="$(current_sshd_listen_ip)"
    write_sshd_dropin "$SSHD_LISTEN_IP"

    SSH_HOST_FINGERPRINT="$(chroot_run /usr/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"
    # The public host key itself (type and key, no comment) goes in the
    # handoff so the VPS and every client can pin it instead of trusting
    # the first connection.
    SSH_HOST_PUBKEY="$(awk '{print $1" "$2; exit}' "$CHROOT/etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null || true)"
    if [[ -n "$SSH_HOST_PUBKEY" ]] && ! is_plain_pubkey "$SSH_HOST_PUBKEY"; then
        warn "The SSH host key file doesn't look like a public key; it won't be pinned"
        SSH_HOST_PUBKEY=""
    fi
    if [[ -n "$SSH_HOST_FINGERPRINT" ]]; then
        info "SSH host key fingerprint: $SSH_HOST_FINGERPRINT"
    else
        warn "Could not read SSH host key fingerprint"
    fi
}

# ── Guest file access ────────────────────────
#
# Guests (core-vps.sh --add-guest) are files-only users in the
# serverinator-guests group: internal-sftp, chrooted to a room of
# bind-mounted folders. This installs the helper the VPS drives
# (core/guest-helper.sh) and the sshd rules for the group. The rules live in
# their own file, included at the very END of sshd_config: a Match block
# applies to everything after it, so nothing of the main config may follow.

GUEST_SSHD_CONF="/etc/ssh/serverinator-guests.conf"
GUEST_HELPER="/usr/local/sbin/serverinator-guests"

# The VPS's hop asks for the "sftp" subsystem, and sshd refuses that
# request (even under ForceCommand internal-sftp) unless some Subsystem sftp
# line exists. Debian's sshd_config has one; add ours only when it doesn't,
# because a second definition is an error.
sshd_has_sftp_subsystem() {
    local f
    for f in "$CHROOT/etc/ssh/sshd_config" "$CHROOT/etc/ssh/sshd_config.d/"*.conf; do
        [[ -f "$f" ]] || continue
        grep -qiE '^[[:space:]]*Subsystem[[:space:]]+sftp[[:space:]]' "$f" && return 0
    done
    return 1
}

guest_sshd_conf() {
    echo "# Managed by ServerInator. Guests: files only, locked to their room."
    sshd_has_sftp_subsystem || echo "Subsystem sftp internal-sftp"
    cat << 'EOF'
Match Group serverinator-guests
    AuthorizedKeysFile /etc/ssh/serverinator-guests/%u
    ChrootDirectory /srv/guests/%u
    ForceCommand internal-sftp -u 0002
    DisableForwarding yes
    PermitTTY no
    PermitTunnel no
EOF
}

# Keeps "Include GUEST_SSHD_CONF" as the last line of sshd_config.
ensure_guest_include() {
    local main="$CHROOT/etc/ssh/sshd_config" inc="Include $GUEST_SSHD_CONF" tmp
    if [[ -f "$main" ]] && [[ "$(grep -v '^[[:space:]]*$' "$main" | tail -n 1)" == "$inc" ]]; then
        return 0
    fi
    tmp="$(mktemp "$CHROOT/etc/ssh/sshd_config.XXXXXX")" || die "Unable to create sshd_config temp file"
    {
        [[ ! -f "$main" ]] || grep -vFx -- "$inc" "$main" || true
        printf '%s\n' "$inc"
    } > "$tmp"
    reconcile_file "$main" 600 "$STATE_DIR/backups" < "$tmp"
    rm -f "$tmp"
}

install_guest_support() {
    [[ "$ENABLE_SSH" == 1 ]] || return 0
    local src="$CORE_DIR/guest-helper.sh" before after
    [[ -f "$src" ]] || die "Missing $src next to core-phone.sh"
    mkdir -p "$CHROOT/usr/local/sbin" "$CHROOT/etc/ssh"
    before="$(sshd_config_sum)"
    reconcile_file "$CHROOT$GUEST_HELPER" 755 "$STATE_DIR/backups" < "$src"
    guest_sshd_conf | reconcile_file "$CHROOT$GUEST_SSHD_CONF" 644 "$STATE_DIR/backups"
    ensure_sshd_include
    ensure_guest_include
    after="$(sshd_config_sum)"
    [[ "$before" == "$after" ]] || reload_running_sshd
}

# Checksum of the sshd config files guest support touches.
sshd_config_sum() {
    { cat "$CHROOT/etc/ssh/sshd_config" "$CHROOT$GUEST_SSHD_CONF" 2>/dev/null || :; } | cksum
}

# A running sshd keeps the config it started with, so new guest rules would
# only apply after a reboot. SIGHUP makes it re-read the config; open
# sessions stay up. Only our own sshd (the PID the autostart recorded, rooted
# in this chroot) is signalled.
reload_running_sshd() {
    [[ "$DEV" != 1 ]] || return 0
    local pidfile="$STATE_DIR/run/sshd.pid" pid=""
    [[ -f "$pidfile" ]] || return 0
    read -r pid < "$pidfile" || return 0
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    [[ "$(readlink "/proc/$pid/root" 2>/dev/null)" == "$CHROOT" ]] || return 0
    chroot_run /usr/sbin/sshd -t || die "Invalid sshd configuration; the running sshd was left as it was"
    kill -HUP "$pid" || { warn "Could not reload sshd; reboot the phone to apply the guest rules"; return 0; }
    info "sshd reloaded with the guest rules"
}

write_sshd_autostart() {
    [[ "$ENABLE_SSH" == "1" ]] || return 0

    local script_path="$MAGISK_SERVICE_D/30-serverinator-sshd.sh"
    mkdir -p "$MAGISK_SERVICE_D"
    local desired
    desired="$(mktemp "$MAGISK_SERVICE_D/script.XXXXXX")"
    cat > "$desired" << EOF
#!/system/bin/sh
# ServerInator managed sshd supervisor. All diagnostics stay in a root-only log.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin
export PATH
STATE_DIR='${STATE_DIR}'
CHROOT='${CHROOT}'
umask 077
mkdir -p "\$STATE_DIR/logs" "\$STATE_DIR/run" || exit 1
LOG="\$STATE_DIR/logs/sshd.log"
printf '%s\\n' "\$\$" > "\$STATE_DIR/run/sshd-supervisor.pid"
rotate_log() {
    [ -f "\$LOG" ] || return 0
    size=\$(wc -c < "\$LOG") || return 1
    if [ "\$size" -ge 1048576 ]; then
        cp "\$LOG" "\$LOG.1" && : > "\$LOG" || return 1
    fi
}
child=''
cleanup() {
    if [ -n "\$child" ]; then
        if kill -0 "\$child"; then kill "\$child"; fi
        if wait "\$child"; then :; else printf '%s\\n' 'sshd stopped' >> "\$LOG"; fi
    fi
    rm -f "\$STATE_DIR/run/sshd.pid" "\$STATE_DIR/run/sshd-supervisor.pid"
}
trap 'cleanup; exit' INT TERM
# Wait for the wg-si interface (up to 120s).
i=0
while [ "\$i" -lt 60 ]; do
    ip link show wg-si >/dev/null 2>&1 && break
    sleep 2; i=\$((i+1))
done
while true; do
    rotate_log || exit 1
    chroot "\$CHROOT" /usr/bin/env -i \\
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
        HOME=/root TMPDIR=/tmp /usr/bin/sh -c \\
        'mkdir -p /run/sshd && chmod 0755 /run/sshd && if [ -x /usr/local/sbin/serverinator-guests ]; then /usr/local/sbin/serverinator-guests mount-all || :; fi; /usr/sbin/sshd -t && exec /usr/sbin/sshd -D -e' \\
        >> "\$LOG" 2>&1 &
    child=\$!
    printf '%s\\n' "\$child" > "\$STATE_DIR/run/sshd.pid"
    while kill -0 "\$child"; do rotate_log || exit 1; sleep 5; done
    if wait "\$child"; then :; else printf '%s\\n' 'sshd exited unsuccessfully' >> "\$LOG"; fi
    child=''
    rm -f "\$STATE_DIR/run/sshd.pid"
    sleep 10
done
EOF
    reconcile_file "$script_path" 700 "$STATE_DIR/backups" < "$desired"
    rm -f "$desired"
    info "sshd autostart written: $script_path"
}

# write_wstunnel_autostart VPS_IP [DOMAIN]
# Called only from apply_back_handoff — once the VPS IP is known. With a
# DOMAIN the tunnel connects by name, so the VPS's real certificate matches;
# SERVERINATOR_TLS_VERIFY=1 also makes wstunnel check that certificate.
# Values are substituted directly; no placeholders, no sed.
write_wstunnel_autostart() {
    local vps_ip="$1" domain="${2:-}"
    [[ -n "$vps_ip" ]] || die "write_wstunnel_autostart: VPS IP not provided"
    validate_host "$vps_ip"
    [[ -z "$domain" ]] || validate_domain "$domain"
    local endpoint="${domain:-$vps_ip}" verify_line=""
    if [[ "${SERVERINATOR_TLS_VERIFY:-0}" == 1 ]]; then
        [[ -n "$domain" ]] || die "SERVERINATOR_TLS_VERIFY=1 needs a domain with a real certificate"
        verify_line="        --tls-verify-certificate \\
"
    fi
    validate_tunnel_port "$WG_LOCAL_PORT"
    validate_tunnel_port "$WG_VPS_PORT"
    validate_tunnel_port "$WSTUNNEL_PORT"

    # Readiness probe: a route to the VPS itself. A hostname can't be routed
    # before DNS works, so probe a public address instead.
    local probe_ip="$vps_ip"
    [[ "$vps_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || probe_ip="1.1.1.1"

    local script_path="$MAGISK_SERVICE_D/10-serverinator-wstunnel.sh"
    mkdir -p "$MAGISK_SERVICE_D"
    local desired
    desired="$(mktemp "$MAGISK_SERVICE_D/script.XXXXXX")"
    cat > "$desired" << EOF
#!/system/bin/sh
# ServerInator — wstunnel supervisor
# Managed by ServerInator, do not edit manually.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin
export PATH
STATE_DIR='${STATE_DIR}'
CHROOT='${CHROOT}'
umask 077
mkdir -p "\$STATE_DIR/logs" "\$STATE_DIR/run" || exit 1
LOG="\$STATE_DIR/logs/wstunnel.log"
printf '%s\\n' "\$\$" > "\$STATE_DIR/run/wstunnel-supervisor.pid"
rotate_log() {
    [ -f "\$LOG" ] || return 0
    size=\$(wc -c < "\$LOG") || return 1
    if [ "\$size" -ge 1048576 ]; then
        cp "\$LOG" "\$LOG.1" && : > "\$LOG" || return 1
    fi
}
child=''
cleanup() {
    if [ -n "\$child" ]; then
        if kill -0 "\$child" 2>/dev/null; then kill "\$child"; fi
        wait "\$child" 2>/dev/null || printf '%s\\n' 'wstunnel stopped' >> "\$LOG"
    fi
    rm -f "\$STATE_DIR/run/wstunnel.pid" "\$STATE_DIR/run/wstunnel-supervisor.pid"
}
trap 'cleanup; exit' INT TERM
# The interface the VPS is reached through (wlan0, rmnet_data1, ...), or
# nothing while there is no usable network.
route_dev() {
    route=\$(ip route get ${probe_ip} 2>/dev/null) || route=''
    case "\$route" in
        ''|*' dev lo'*|*' dev dummy'*|*unreachable*|*prohibit*) return 0 ;;
    esac
    printf '%s\\n' "\$route" | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -n 1
}
# Wait until the VPS is routable (network is up), up to 120s. Android keeps
# its default route in per-network tables, not main, so "ip route show
# default" stays empty and used to burn the full 120s on every boot.
i=0
while [ "\$i" -lt 60 ]; do
    route=\$(ip route get ${probe_ip} 2>/dev/null) || route=''
    case "\$route" in
        ''|*' dev lo'*|*' dev dummy'*|*unreachable*|*prohibit*) ;;
        *) break ;;
    esac
    sleep 2; i=\$((i+1))
done
while true; do
    rotate_log || exit 1
    chroot "\$CHROOT" /usr/bin/env -i \\
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
        HOME=/root TMPDIR=/tmp /usr/local/bin/wstunnel client \\
        --log-lvl INFO \\
${verify_line}        -L "udp://${WG_LOCAL_PORT}:127.0.0.1:${WG_VPS_PORT}?timeout_sec=0" \\
        wss://${endpoint}:${WSTUNNEL_PORT} \\
        >> "\$LOG" 2>&1 &
    child=\$!
    printf '%s\\n' "\$child" > "\$STATE_DIR/run/wstunnel.pid"
    # wstunnel keeps its connection on the network it started on. When the
    # phone moves (mobile data at boot, then Wi-Fi), reconnect on the new
    # one: a network that blocks the tunnel would otherwise hold it forever.
    dev=\$(route_dev)
    while kill -0 "\$child" 2>/dev/null; do
        rotate_log || exit 1
        sleep 5
        now=\$(route_dev)
        [ -n "\$now" ] || continue
        if [ -z "\$dev" ]; then dev="\$now"; continue; fi
        if [ "\$now" != "\$dev" ]; then
            printf '%s\\n' "network changed (\$dev -> \$now), reconnecting" >> "\$LOG"
            kill "\$child" 2>/dev/null
            break
        fi
    done
    wait "\$child" 2>/dev/null || printf '%s\\n' 'wstunnel exited unsuccessfully' >> "\$LOG"
    child=''
    rm -f "\$STATE_DIR/run/wstunnel.pid"
    sleep 10
done
EOF
    reconcile_file "$script_path" 700 "$STATE_DIR/backups" < "$desired"
    rm -f "$desired"
    info "wstunnel autostart written: $script_path"
}

# ── Step 3c: Login summary ────────────────────

# Installs core/motd.bash into the chroot and a profile.d stub that runs it
# for interactive bash logins only (sh logins and `ssh host cmd` skip it).
write_login_summary() {
    local src
    src="$CORE_DIR/motd.bash"
    [[ -f "$src" ]] || die "Missing $src next to core-phone.sh"
    [[ -n "$DEVICE_NAME" ]] || die "Device name not set. Pass --device-name NAME or set SERVERINATOR_DEVICE_NAME."
    validate_device_name "$DEVICE_NAME"
    mkdir -p "$CHROOT/usr/local/lib/serverinator" "$CHROOT/etc/profile.d"
    reconcile_file "$CHROOT/usr/local/lib/serverinator/motd.bash" 644 "$STATE_DIR/backups" < "$src"
    reconcile_file "$CHROOT/etc/profile.d/serverinator-motd.sh" 644 "$STATE_DIR/backups" << EOF
# ServerInator login summary (managed). Interactive bash logins only.
if [ -n "\${BASH_VERSION:-}" ]; then
    case \$- in
        *i*) . /usr/local/lib/serverinator/motd.bash && __si_motd '${DEVICE_NAME}'; unset -f __si_motd ;;
    esac
fi
EOF
}

# `si` inside the chroot (core/si with "chroot"), for `ssh ALIAS 'si status'`.
write_chroot_si() {
    local f
    for f in si lib.sh; do
        [[ -f "$CORE_DIR/$f" ]] || die "Missing $CORE_DIR/$f next to core-phone.sh"
    done
    mkdir -p "$CHROOT/usr/local/lib/serverinator" "$CHROOT/usr/local/bin"
    reconcile_file "$CHROOT/usr/local/lib/serverinator/si" 644 "$STATE_DIR/backups" < "$CORE_DIR/si"
    reconcile_file "$CHROOT/usr/local/lib/serverinator/lib.sh" 644 "$STATE_DIR/backups" < "$CORE_DIR/lib.sh"
    reconcile_file "$CHROOT/usr/local/bin/si" 755 "$STATE_DIR/backups" << 'EOF'
#!/bin/sh
# ServerInator: the si command (managed).
exec bash /usr/local/lib/serverinator/si chroot "$@"
EOF
}

# ── Step 4: Generate handoff file ─────────────

generate_handoff() {
    local pub_key
    pub_key="$(cat "$CHROOT/etc/wireguard/client.pub")"

    [[ -n "$DEVICE_NAME" ]] \
        || die "Device name not set. Pass --device-name NAME or set SERVERINATOR_DEVICE_NAME."
    validate_device_name "$DEVICE_NAME"
    validate_wg_key "$pub_key"
    mkdir -p "$IDENTITY_DIR"; chmod 700 "$IDENTITY_DIR"
    printf '%s\n' "$DEVICE_NAME" > "$IDENTITY_DIR/device-name"

    local ssh_enabled=0
    [[ "$ENABLE_SSH" == "1" ]] && ssh_enabled=1

    local handoff_path="$CHROOT/etc/wireguard/handoff.json"
    local staged
    staged="$(mktemp "${handoff_path}.XXXXXX")"
    chmod 600 "$staged"

    # jq is only installed inside the chroot, not on the Android host —
    # json_query falls back to chroot_run when the host has none.
    json_query -n \
        --argjson version      1 \
        --arg     device_name  "$DEVICE_NAME" \
        --arg     wg_pubkey    "$pub_key" \
        --argjson wstunnel_port "$WSTUNNEL_PORT" \
        --argjson wg_port      "$WG_VPS_PORT" \
        --argjson ssh_enabled  "$ssh_enabled" \
        --arg     ssh_user     "$SSH_USER" \
        --argjson ssh_port     "$SSH_PORT" \
        --arg     ssh_host_fingerprint "${SSH_HOST_FINGERPRINT:-}" \
        --arg     ssh_host_pubkey "${SSH_HOST_PUBKEY:-}" \
        '{
            version:               $version,
            device_name:           $device_name,
            wg_pubkey:             $wg_pubkey,
            wstunnel_port:         $wstunnel_port,
            wg_port:               $wg_port,
            ssh_enabled:           $ssh_enabled,
            ssh_user:              $ssh_user,
            ssh_port:              $ssh_port,
            ssh_host_fingerprint:  $ssh_host_fingerprint,
            ssh_host_pubkey:       $ssh_host_pubkey
        }' > "$staged" || die "jq: could not assemble handoff.json"

    reconcile_file "$handoff_path" 600 < "$staged"
    rm -f "$staged"
    info "handoff.json written: $handoff_path"
}

# ── Step 6: Apply back-handoff ────────────────

apply_back_handoff() {
    [[ -f "$BACK_HANDOFF_FILE" ]] || die "Back-handoff file not found: $BACK_HANDOFF_FILE"

    local version
    version="$(json_get_num "$BACK_HANDOFF_FILE" version)"
    [[ "$version" == "1" ]] || die "Unsupported back-handoff version: $version"

    local vps_ip vps_domain vps_wg_pubkey phone_wg_ip vps_wg_ip wg_port wstunnel_port
    vps_ip="$(json_get "$BACK_HANDOFF_FILE" vps_ip)"
    vps_domain="$(json_get "$BACK_HANDOFF_FILE" vps_domain)"
    vps_wg_pubkey="$(json_get "$BACK_HANDOFF_FILE" vps_wg_pubkey)"
    phone_wg_ip="$(json_get "$BACK_HANDOFF_FILE" phone_wg_ip)"
    vps_wg_ip="$(json_get "$BACK_HANDOFF_FILE" vps_wg_ip)"
    wg_port="$(json_get_num "$BACK_HANDOFF_FILE" wg_port)"
    wstunnel_port="$(json_get_num "$BACK_HANDOFF_FILE" wstunnel_port)"

    [[ -n "$vps_ip" ]]        || die "back-handoff: missing vps_ip"
    [[ -n "$vps_wg_pubkey" ]] || die "back-handoff: missing vps_wg_pubkey"
    [[ -n "$phone_wg_ip" ]]   || die "back-handoff: missing phone_wg_ip"
    [[ -n "$vps_wg_ip" ]]     || die "back-handoff: missing vps_wg_ip"
    local handoff_device phone_key
    handoff_device="$(json_get "$BACK_HANDOFF_FILE" device_name)"
    phone_key="$(json_get "$BACK_HANDOFF_FILE" phone_wg_pubkey)"
    validate_device_name "$handoff_device"
    validate_host "$vps_ip"
    [[ -z "$vps_domain" ]] || validate_domain "$vps_domain"
    validate_wg_key "$vps_wg_pubkey"
    validate_wg_key "$phone_key"
    validate_optional_ports "$BACK_HANDOFF_FILE"
    validate_ipv4 "$phone_wg_ip" "phone WG IPv4"
    validate_ipv4 "$vps_wg_ip" "VPS WG IPv4"
    if [[ -f "$CHROOT/etc/wireguard/client.pub" ]]; then
        [[ "$(cat "$CHROOT/etc/wireguard/client.pub")" == "$phone_key" ]] || die "Back-handoff belongs to another phone key"
    fi

    # Return ports describe the remote VPS; the local UDP listener remains fixed.
    if [[ -n "$wg_port" ]]; then validate_tunnel_port "$wg_port"; fi
    if [[ -n "$wstunnel_port" ]]; then validate_tunnel_port "$wstunnel_port"; fi
    WG_VPS_PORT="${wg_port:-$WG_VPS_PORT}"
    WSTUNNEL_PORT="${wstunnel_port:-$WSTUNNEL_PORT}"

    info "Applying back-handoff for VPS $vps_ip"
    if [[ "$DEV" == "1" ]]; then
        dev "phone_wg_ip=$phone_wg_ip vps_wg_ip=$vps_wg_ip wg_port=$wg_port"
    fi

    # ── Write WireGuard client config ──────────
    local wg_conf="$CHROOT/etc/wireguard/wg-si.conf"
    local priv_key
    priv_key="$(cat "$CHROOT/etc/wireguard/client.key")"
    validate_wg_key "$priv_key"

    if [[ -f "$wg_conf" ]]; then
        # --apply-back-handoff is itself the user's intent to (re-)apply;
        # overwrite unconditionally.  A prompt here would block non-interactive
        # runs and make idempotent re-apply impossible.
        info "Overwriting existing WireGuard client config at $wg_conf"
    fi

    local desired
    desired="$(mktemp "$CHROOT/etc/wireguard/client-conf.XXXXXX")"
    cat > "$desired" << EOF
[Interface]
PrivateKey = ${priv_key}
Address = ${phone_wg_ip}/24
MTU = 1280

[Peer]
PublicKey = ${vps_wg_pubkey}
Endpoint = 127.0.0.1:${WG_LOCAL_PORT}
AllowedIPs = ${vps_wg_ip}/32
PersistentKeepalive = 25
EOF
    reconcile_file "$wg_conf" 600 < "$desired"
    rm -f "$desired"
    info "WireGuard client config written to $wg_conf"

    # ── Write the wstunnel autostart with the real VPS IP ──
    write_wstunnel_autostart "$vps_ip" "$vps_domain"

    # ── Write WireGuard autostart script ──────
    local wg_script="$MAGISK_SERVICE_D/20-serverinator-wireguard.sh"
    desired="$(mktemp "$MAGISK_SERVICE_D/wg-script.XXXXXX")"
    cat > "$desired" << EOF
#!/system/bin/sh
# ServerInator WireGuard reconciliation; sleep values remain unchanged.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin
export PATH
STATE_DIR='${STATE_DIR}'
CHROOT='${CHROOT}'
umask 077
mkdir -p "\$STATE_DIR/logs" "\$STATE_DIR/run" || exit 1
exec >> "\$STATE_DIR/logs/wireguard.log" 2>&1
printf '%s\\n' "\$\$" > "\$STATE_DIR/run/wireguard-supervisor.pid"
trap 'rm -f "\$STATE_DIR/run/wireguard-supervisor.pid"; exit' INT TERM
# Wait for wstunnel (up to 120s).
i=0
while [ "\$i" -lt 60 ]; do
    if [ -f "\$STATE_DIR/run/wstunnel.pid" ]; then
        pid=\$(cat "\$STATE_DIR/run/wstunnel.pid")
        kill -0 "\$pid" 2>/dev/null && break
    fi
    sleep 2; i=\$((i+1))
done
while true; do
    chroot "\$CHROOT" /usr/bin/env -i \\
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
        HOME=/root TMPDIR=/tmp /usr/bin/sh -c '
            if ! ip link show wg-si; then wg-quick up /etc/wireguard/wg-si.conf || exit 1; fi
            ip link set wg-si up || exit 1
            # Omitted ListenPort resets the automatic port on every syncconf.
            # Preserve it so reconciliation does not accumulate WSS tunnels.
            listen_port=\$(wg show wg-si listen-port) || exit 1
            [ "\$listen_port" -gt 0 ] && [ "\$listen_port" -le 65535 ] || exit 1
            wg-quick strip /etc/wireguard/wg-si.conf | awk -v port="\$listen_port" '\''
                /^ListenPort[[:space:]]*=/ {next}
                {print}
                \$0=="[Interface]" {print "ListenPort = "port}
            '\'' > /etc/wireguard/runtime.conf || exit 1
            wg syncconf wg-si /etc/wireguard/runtime.conf || exit 1
            rm -f /etc/wireguard/runtime.conf
            ip address replace ${phone_wg_ip}/24 dev wg-si || exit 1
            ip link set wg-si mtu 1280 || exit 1
            ip route replace ${vps_wg_ip%.*}.0/24 dev wg-si table main || exit 1
            count=\$(ip -4 rule show | awk '\''\$1=="100:" && \$0 ~ /to ${vps_wg_ip%.*}.0\\/24 lookup main/ {n++} END {print n+0}'\'')
            if [ "\$count" -ne 1 ]; then
                while [ "\$count" -gt 0 ]; do
                    ip rule del to ${vps_wg_ip%.*}.0/24 lookup main priority 100 || exit 1
                    count=\$((count - 1))
                done
                ip rule add to ${vps_wg_ip%.*}.0/24 lookup main priority 100 || exit 1
            fi
        '
    if [ -f "\$STATE_DIR/logs/wireguard.log" ]; then
        size=\$(wc -c < "\$STATE_DIR/logs/wireguard.log") || exit 1
        if [ "\$size" -ge 1048576 ]; then
            cp "\$STATE_DIR/logs/wireguard.log" "\$STATE_DIR/logs/wireguard.log.1" && : > "\$STATE_DIR/logs/wireguard.log" || exit 1
        fi
    fi
    sleep 30
done
EOF
    reconcile_file "$wg_script" 700 "$STATE_DIR/backups" < "$desired"
    rm -f "$desired"

    # ── SSH access (tunnel-only) ───────────────
    apply_ssh_config

    info "Back-handoff applied."
    info "  Phone WG IP : $phone_wg_ip"
    info "  VPS WG IP   : $vps_wg_ip"
    info "  VPS IP      : $vps_ip"
    [[ -z "$vps_domain" ]] || info "  VPS domain  : $vps_domain (tunnel connects by name)"
    info "Reboot the phone — services will come up automatically via Magisk."
}

# ── Step 6b: Apply SSH access from back-handoff ──

AK_BEGIN="# >>> ServerInator managed keys (replaced on every apply) >>>"
AK_END="# <<< ServerInator managed keys <<<"

# write_managed_authorized_keys FILE KEY...
# Replaces the managed block with KEY... and keeps every other line. Lines
# outside the block that older versions appended (the VPS->phone key and owner
# keys, recognised by their serverinator comments) are dropped as part of the
# migration, as are exact duplicates of a managed key. --add-client keys
# (comment serverinator:client:...) are left for --revoke-client.
write_managed_authorized_keys() {
    local ak="$1"; shift
    local staged line k in_block=0
    mkdir -p "$(dirname "$ak")"
    staged="$(mktemp "${ak}.XXXXXX")" || die "Could not create a temp file for $ak"
    {
        if [[ -f "$ak" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" == "$AK_BEGIN" ]]; then in_block=1; continue; fi
                if [[ "$line" == "$AK_END" ]]; then in_block=0; continue; fi
                ((in_block)) && continue
                [[ "$line" =~ [[:space:]](serverinator-vps-|serverinator:owner:)[^[:space:]]*$ ]] && continue
                for k in "$@"; do [[ "$line" == "$k" ]] && continue 2; done
                printf '%s\n' "$line"
            done < "$ak"
        fi
        printf '%s\n' "$AK_BEGIN"
        for k in "$@"; do printf '%s\n' "$k"; done
        printf '%s\n' "$AK_END"
    } > "$staged"
    ((in_block == 0)) || { rm -f "$staged"; die "Unterminated managed block in $ak; fix it by hand"; }
    reconcile_file "$ak" 600 "$STATE_DIR/backups" < "$staged"
    rm -f "$staged"
}

apply_ssh_config() {
    if [[ "$ENABLE_SSH" != "1" ]]; then
        info "SSH skipped (--no-ssh)"
        return 0
    fi
    local enabled
    enabled="$(json_get_num "$BACK_HANDOFF_FILE" ssh_enabled)"
    enabled="${enabled:-0}"
    if [[ "$enabled" != "1" ]]; then
        info "SSH not enabled for this device; skipping SSH setup"
        return 0
    fi

    [[ -f "$CHROOT/usr/sbin/sshd" ]] || die "openssh-server is missing in the chroot; re-run phone setup"

    local phone_wg_ip ssh_user vps_to_phone fp count
    phone_wg_ip="$(json_get "$BACK_HANDOFF_FILE" ssh_phone_ip)"
    ssh_user="$(json_get "$BACK_HANDOFF_FILE" ssh_user)"; ssh_user="${ssh_user:-root}"
    vps_to_phone="$(json_get "$BACK_HANDOFF_FILE" ssh_vps_to_phone_pubkey)"
    fp="$(json_get "$BACK_HANDOFF_FILE" ssh_host_fingerprint)"
    count="$(json_get_num "$BACK_HANDOFF_FILE" ssh_client_key_count)"; count="${count:-0}"

    [[ -n "$phone_wg_ip" ]] || die "back-handoff: missing ssh_phone_ip"
    validate_ipv4 "$phone_wg_ip" "SSH listen IPv4"
    [[ "$phone_wg_ip" == "$(json_get "$BACK_HANDOFF_FILE" phone_wg_ip)" ]] || die "SSH listen IP differs from phone WG IP"
    [[ "$count" =~ ^[0-9]{1,3}$ ]] && ((count <= 128)) || die "Invalid client key count"
    [[ "$ssh_user" == "$SSH_USER" ]] || warn "back-handoff ssh_user '$ssh_user' differs from '$SSH_USER' (using $SSH_USER)"

    # sshd config now that the tunnel IP is known.
    mkdir -p "$CHROOT/etc/ssh/sshd_config.d" "$CHROOT/run/sshd" "$CHROOT/root/.ssh"
    chmod 0755 "$CHROOT/run/sshd"
    chmod 700 "$CHROOT/root/.ssh"
    ensure_sshd_include
    write_sshd_dropin "$phone_wg_ip"

    # authorized_keys: the keys from the back-handoff live in a managed block
    # that is replaced on every apply, so keys from an old VPS or a previous
    # install stop working. Lines outside the block (hand-added keys, and
    # --add-client keys) are preserved.
    local ak="$CHROOT/root/.ssh/authorized_keys"
    local -a managed=()
    local i key
    for ((i = 0; i <= count; i++)); do
        if ((i == 0)); then
            key="$vps_to_phone"
        else
            key="$(json_get "$BACK_HANDOFF_FILE" "ssh_client_key_${i}")"
        fi
        [[ -n "$key" ]] || continue
        is_plain_pubkey "$key" || die "back-handoff: SSH key $i is not a plain public key"
        managed+=("$key")
    done
    write_managed_authorized_keys "$ak" ${managed[@]+"${managed[@]}"}
    if [[ -f "$IDENTITY_DIR/pending-extra-keys" ]]; then
        merge_extra_keys "$ak" "$IDENTITY_DIR/pending-extra-keys"
        rm -f "$IDENTITY_DIR/pending-extra-keys"
    fi

    prepare_sshd_runtime "$phone_wg_ip"
    write_sshd_autostart
    info "SSH authorized_keys: ${#managed[@]} managed key(s)"
    if [[ -n "$fp" ]]; then
        info "Phone SSH host key fingerprint: $fp"
    fi
}

# ── Step 2.5: Setup chroot environment ───────────

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
stop_exact_pid() {
    local pid="$1" expected="$2" kind="$3" root _
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "$$" ]] || die "Invalid managed PID"
    [[ -d "/proc/$pid" ]] || return 0
    if [[ "$kind" == supervisor ]]; then
        tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fx -e "$expected" -e "${expected}.bak" > /dev/null \
            || die "PID file points to an unrelated supervisor; refusing kill"
    else
        root="$(readlink "/proc/$pid/root")" || die "Cannot inspect process root"
        [[ "$root" == "$CHROOT" ]] || die "PID file points outside managed chroot"
    fi
    kill -TERM "$pid" || die "Cannot stop managed process"
    for _ in 1 2 3 4 5; do
        [[ -d "/proc/$pid" ]] || return 0
        sleep 1
    done
    # Revalidate identity before escalation to avoid a reused PID.
    if [[ "$kind" == supervisor ]]; then
        tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fx -e "$expected" -e "${expected}.bak" > /dev/null \
            || die "PID identity changed before kill escalation"
    else
        [[ "$(readlink "/proc/$pid/root")" == "$CHROOT" ]] || die "PID root changed before escalation"
    fi
    kill -KILL "$pid" || die "Cannot kill remaining managed process"
}
uninstall_phone() {
    check_root
    safe_remove_path "$CHROOT"
    safe_remove_path "$SSH_HOSTKEY_DIR"
    safe_remove_path "$IDENTITY_DIR"
    local name file pid proc script
    if [[ "$DEV" != 1 ]]; then
        # Stop only supervisors named by exact script argv and children in this root.
        for name in wstunnel sshd wireguard tmpclean; do
            case "$name" in
                wstunnel) script="$MAGISK_SERVICE_D/10-serverinator-wstunnel.sh";;
                sshd) script="$MAGISK_SERVICE_D/30-serverinator-sshd.sh";;
                wireguard) script="$MAGISK_SERVICE_D/20-serverinator-wireguard.sh";;
                tmpclean) script="$MAGISK_SERVICE_D/40-serverinator-tmpclean.sh";;
            esac
            file="$STATE_DIR/run/$name-supervisor.pid"
            if [[ -f "$file" ]]; then read -r pid < "$file"; stop_exact_pid "$pid" "$script" supervisor; fi
            # Covers legacy boot scripts without PID files; no name-wide pkill.
            for proc in /proc/[0-9]*; do
                # Android host access(R_OK) may report false even when root can
                # read the file. Check existence, then inspect the actual argv.
                [[ -e "$proc/cmdline" ]] || continue
                if tr '\0' '\n' < "$proc/cmdline" | grep -Fx -e "$script" -e "${script}.bak" > /dev/null; then
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
    rm -rf "$STATE_DIR/bin"
    # Logs and .bak backups are pure operational debris, not identity state —
    # always clear them, regardless of --purge.
    rm -rf "$STATE_DIR/run" "$STATE_DIR/logs" "$STATE_DIR/backups"
    info "Phone uninstall complete; WireGuard and SSH host keys kept unless --purge"
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
    for name in wstunnel wireguard sshd; do
        if status_pid_alive "$STATE_DIR/run/$name-supervisor.pid"; then
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
    echo ""
    if [[ "$bad" == 0 ]]; then
        echo "  All good. Logs: si logs"
    else
        echo "  Something is wrong. Last lines of each log: si logs"
    fi
    return "$bad"
}

# ── Identity backup / restore ─────────────────
#
# --export-identity FILE writes a tar with everything that makes this phone
# "the same phone" to the VPS and to clients:
#   wireguard/client.key, client.pub   the tunnel key the VPS has as a peer
#   ssh/ssh_host_*_key[.pub]           the host key clients have pinned
#   orchestrator/id_ed25519[.pub]      serverinator.sh's key for the VPS
#   extra-keys                         authorized_keys lines outside the
#                                      managed block (--add-client keys and
#                                      hand-added keys)
#   manifest                           format, device name, public key
# --import-identity FILE puts those back on a new or reset phone, before
# serverinator.sh is run with the same device name and VPS. The VPS then
# sees the same peer and nothing on it or on clients has to change.

IDENTITY_TOP="serverinator-identity"

# Prints authorized_keys lines that live outside the managed block and are
# plain public keys (no options), one per line.
extra_authorized_keys() {
    local ak="$1" line in_block=0
    [[ -f "$ak" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$AK_BEGIN" ]]; then in_block=1; continue; fi
        if [[ "$line" == "$AK_END" ]]; then in_block=0; continue; fi
        ((in_block)) && continue
        [[ "$line" =~ [[:space:]](serverinator-vps-|serverinator:owner:)[^[:space:]]*$ ]] && continue
        is_plain_pubkey "$line" && printf '%s\n' "$line"
    done < "$ak"
    return 0
}

# merge_extra_keys AUTHORIZED_KEYS KEYS_FILE: appends lines not already there.
merge_extra_keys() {
    local ak="$1" keys="$2" line added=0
    mkdir -p "$(dirname "$ak")"; chmod 700 "$(dirname "$ak")"
    touch "$ak"; chmod 600 "$ak"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        grep -qFx -- "$line" "$ak" && continue
        printf '%s\n' "$line" >> "$ak"; added=$((added + 1))
    done < "$keys"
    ((added == 0)) || info "Restored $added extra SSH key(s) (clients, hand-added keys)"
}

export_identity() {
    local out="$1" wg_dir name stage f n=0
    check_root
    [[ -n "$out" ]] || die "--export-identity needs a FILE"
    [[ ! -e "$out" ]] || die "$out already exists; choose a new file name"

    if [[ -s "$CHROOT/etc/wireguard/client.key" ]]; then
        wg_dir="$CHROOT/etc/wireguard"
    elif [[ -s "$IDENTITY_DIR/wireguard/client.key" ]]; then
        wg_dir="$IDENTITY_DIR/wireguard"
    else
        die "No WireGuard key on this phone; nothing to export (install first)"
    fi
    validate_wg_key "$(cat "$wg_dir/client.pub")"

    name="${DEVICE_NAME:-}"
    [[ -n "$name" || ! -s "$IDENTITY_DIR/device-name" ]] || name="$(cat "$IDENTITY_DIR/device-name")"
    [[ -z "$name" ]] || validate_device_name "$name"

    stage="$(mktemp -d)" || die "Could not create a temp directory"
    (
        umask 077
        set -e
        mkdir -p "$stage/$IDENTITY_TOP/wireguard"
        cp "$wg_dir/client.key" "$wg_dir/client.pub" "$stage/$IDENTITY_TOP/wireguard/"
        for f in "$SSH_HOSTKEY_DIR"/ssh_host_*_key; do
            [[ -f "$f" && -f "$f.pub" ]] || continue
            mkdir -p "$stage/$IDENTITY_TOP/ssh"
            cp "$f" "$f.pub" "$stage/$IDENTITY_TOP/ssh/"
        done
        if [[ -f "$ORCHESTRATOR_SSH_DIR/id_ed25519" && -f "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub" ]]; then
            mkdir -p "$stage/$IDENTITY_TOP/orchestrator"
            cp "$ORCHESTRATOR_SSH_DIR/id_ed25519" "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub" "$stage/$IDENTITY_TOP/orchestrator/"
        fi
        extra_authorized_keys "$CHROOT/root/.ssh/authorized_keys" > "$stage/$IDENTITY_TOP/extra-keys"
        {
            echo "format=1"
            echo "device_name=$name"
            echo "wg_pubkey=$(cat "$wg_dir/client.pub")"
            echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$stage/$IDENTITY_TOP/manifest"
        tar -cf "$out" -C "$stage" "$IDENTITY_TOP"
        chmod 600 "$out"
    ) || { rm -rf "$stage"; rm -f "$out"; die "Could not write $out"; }
    rm -rf "$stage"

    [[ -d "$SSH_HOSTKEY_DIR" ]] && n="$(find "$SSH_HOSTKEY_DIR" -maxdepth 1 -name 'ssh_host_*_key' | wc -l)"
    ok "Identity saved to $out"
    info "  Device name : ${name:-(unknown; use the same name as before when reinstalling)}"
    info "  WireGuard   : $(cat "$wg_dir/client.pub")"
    info "  SSH host keys: ${n// /}"
    warn "This file holds private keys. Keep it somewhere safe and off the phone."
}

# Every path a format-1 identity tar may contain.
identity_path_ok() {
    [[ "$1" =~ ^serverinator-identity(/(manifest|extra-keys|wireguard/client\.(key|pub)|ssh/ssh_host_[a-z0-9]+_key(\.pub)?|orchestrator/id_ed25519(\.pub)?|wireguard|ssh|orchestrator))?/?$ ]]
}

import_identity() {
    local in="$1" stage top line name f base key
    check_root
    [[ -f "$in" ]] || die "No such file: $in"

    # Only regular files and directories under the expected names.
    local listing
    listing="$(tar -tvf "$in" 2>/dev/null)" || die "$in is not a readable tar file"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == -* || "$line" == d* ]] || die "$in contains something that isn't a plain file: $line"
    done <<< "$listing"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        identity_path_ok "$line" || die "$in has an unexpected entry: $line"
    done < <(tar -tf "$in")

    stage="$(mktemp -d)" || die "Could not create a temp directory"
    (umask 077; tar -xf "$in" -C "$stage") || { rm -rf "$stage"; die "Could not unpack $in"; }
    top="$stage/$IDENTITY_TOP"

    # Validate everything before changing anything.
    grep -qx 'format=1' "$top/manifest" 2>/dev/null \
        || { rm -rf "$stage"; die "$in is not a ServerInator identity (format 1)"; }
    name="$(sed -n 's/^device_name=//p' "$top/manifest")"
    [[ -z "$name" ]] || (validate_device_name "$name") > /dev/null 2>&1 \
        || { rm -rf "$stage"; die "$in has an invalid device name"; }
    [[ -s "$top/wireguard/client.key" && -s "$top/wireguard/client.pub" ]] \
        || { rm -rf "$stage"; die "$in has no WireGuard key"; }
    (validate_wg_key "$(cat "$top/wireguard/client.key")" && validate_wg_key "$(cat "$top/wireguard/client.pub")") \
        > /dev/null 2>&1 || { rm -rf "$stage"; die "$in has an invalid WireGuard key"; }
    for f in "$top"/ssh/ssh_host_*_key "$top"/orchestrator/id_ed25519; do
        [[ -e "$f" ]] || continue
        head -n 1 "$f" | grep -q -- '-----BEGIN .*PRIVATE KEY-----' \
            || { rm -rf "$stage"; die "${f#"$top/"} is not a private key"; }
        [[ -f "$f.pub" ]] && is_plain_pubkey "$(cat "$f.pub")" \
            || { rm -rf "$stage"; die "${f#"$top/"}.pub is missing or not a public key"; }
    done
    if [[ -f "$top/extra-keys" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] || is_plain_pubkey "$line" \
                || { rm -rf "$stage"; die "extra-keys has a line that isn't a public key"; }
        done < "$top/extra-keys"
    fi

    # Refuse to replace a different identity that is already installed.
    for key in "$CHROOT/etc/wireguard/client.key" "$IDENTITY_DIR/wireguard/client.key"; do
        if [[ -s "$key" ]] && ! cmp -s "$key" "$top/wireguard/client.key"; then
            rm -rf "$stage"
            die "This phone already has a different WireGuard key ($key). Run 'core-phone.sh --uninstall --purge' first if you really want to replace it."
        fi
    done
    for f in "$top"/ssh/ssh_host_*_key; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"
        if [[ -s "$SSH_HOSTKEY_DIR/$base" ]] && ! cmp -s "$SSH_HOSTKEY_DIR/$base" "$f"; then
            rm -rf "$stage"
            die "This phone already has a different SSH host key ($SSH_HOSTKEY_DIR/$base). Run 'core-phone.sh --uninstall --purge' first if you really want to replace it."
        fi
    done

    (
        umask 077
        set -e
        mkdir -p "$IDENTITY_DIR/wireguard"
        cp -f "$top/wireguard/client.key" "$top/wireguard/client.pub" "$IDENTITY_DIR/wireguard/"
        [[ -z "$name" ]] || printf '%s\n' "$name" > "$IDENTITY_DIR/device-name"
        if [[ -d "$CHROOT/etc/wireguard" ]]; then
            cp -f "$top/wireguard/client.key" "$top/wireguard/client.pub" "$CHROOT/etc/wireguard/"
        fi
        for f in "$top"/ssh/ssh_host_*_key; do
            [[ -e "$f" ]] || continue
            mkdir -p "$SSH_HOSTKEY_DIR"
            cp -f "$f" "$f.pub" "$SSH_HOSTKEY_DIR/"
            if [[ -d "$CHROOT/etc/ssh" ]]; then cp -f "$f" "$f.pub" "$CHROOT/etc/ssh/"; fi
        done
        if [[ -f "$top/orchestrator/id_ed25519" ]]; then
            mkdir -p "$ORCHESTRATOR_SSH_DIR"
            if [[ -f "$ORCHESTRATOR_SSH_DIR/id_ed25519" ]] \
                && ! cmp -s "$ORCHESTRATOR_SSH_DIR/id_ed25519" "$top/orchestrator/id_ed25519"; then
                mv -f "$ORCHESTRATOR_SSH_DIR/id_ed25519" "$ORCHESTRATOR_SSH_DIR/id_ed25519.before-import"
                mv -f "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub" "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub.before-import" 2>/dev/null || true
                echo "orchestrator-replaced" > "$stage/notes"
            fi
            cp -f "$top/orchestrator/id_ed25519" "$top/orchestrator/id_ed25519.pub" "$ORCHESTRATOR_SSH_DIR/"
        fi
    ) || { rm -rf "$stage"; die "Could not put the identity in place"; }
    chmod 700 "$IDENTITY_DIR" "$IDENTITY_DIR/wireguard" 2>/dev/null || true
    [[ -d "$SSH_HOSTKEY_DIR" ]] && chmod 700 "$SSH_HOSTKEY_DIR"
    [[ -f "$stage/notes" ]] && warn "Replaced this phone's own VPS login key; the old one is kept as id_ed25519.before-import"

    if [[ -s "$top/extra-keys" ]]; then
        if [[ -d "$CHROOT/root" ]]; then
            merge_extra_keys "$CHROOT/root/.ssh/authorized_keys" "$top/extra-keys"
        else
            (umask 077; mkdir -p "$IDENTITY_DIR"; cp -f "$top/extra-keys" "$IDENTITY_DIR/pending-extra-keys")
            info "Extra SSH keys will be added when the install finishes"
        fi
    fi
    rm -rf "$stage"

    ok "Identity imported"
    info "  WireGuard: $(cat "$IDENTITY_DIR/wireguard/client.pub")"
    echo ""
    echo "  Next: run serverinator.sh with the same VPS${name:+ and device name '$name'}."
    echo "  The VPS will see the same phone, so clients keep working unchanged."
}

# ── Main ──────────────────────────────────────

main() {
    parse_args "$@"
    if [[ "$MODE" == uninstall ]]; then uninstall_phone; return; fi
    if [[ "$MODE" == status ]]; then phone_status; return; fi
    if [[ "$MODE" == export-identity ]]; then export_identity "$IDENTITY_FILE"; return; fi
    if [[ "$MODE" == import-identity ]]; then import_identity "$IDENTITY_FILE"; return; fi
    [[ "$PURGE" == 0 ]] || die "--purge requires --uninstall"

    if [[ "$MODE" == "apply-back-handoff" ]]; then
        info "ServerInator Core — applying back-handoff"
        if [[ "$DEV" == "1" ]]; then
            dev "Running in DEV mode"
        fi
        check_root
        apply_back_handoff
        return
    fi

    info "ServerInator Core — setting up the phone"
    [[ "$DEV" == "1" ]] && dev "DEV mode (chroot=$CHROOT, service.d=$MAGISK_SERVICE_D)"

    step 1/4 "Checking environment"
    check_root
    check_magisk
    check_disk_space
    ARCH="$(detect_arch)"
    [[ -n "$ARCH_OVERRIDE" ]] && dev "Architecture overridden: $ARCH"
    info "Architecture: $ARCH"

    step 2/4 "Loading rootfs"
    bootstrap_chroot
    resolve_chroot_tmp_mode
    write_mount_script
    write_tmpclean_autostart
    [[ "$DEV" == "0" ]] && setup_chroot_env

    step 3/4 "Installing packages and keys"
    install_chroot_packages
    install_wstunnel
    generate_wg_keys
    install_ssh_server
    install_guest_support
    # wstunnel autostart is written later (apply_back_handoff) — needs the VPS IP
    prepare_sshd_runtime "${SSHD_LISTEN_IP:-}"
    write_sshd_autostart
    write_login_summary
    write_chroot_si

    step 4/4 "Generating handoff"
    generate_handoff
    info "Phone configured. Run serverinator.sh --apply-back-handoff BACK_HANDOFF.json"
}

# Only run when executed directly; allows the functions to be sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
