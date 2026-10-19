# shellcheck shell=bash
# ServerInator Core, phone side: step 1, environment checks (root, Magisk, disk space, architecture)
# Sourced by core-phone.sh, which holds the settings and globals used here.

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
    available_kb="$(df -P "$check_path" | awk 'NR==2{print $4}')"
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
