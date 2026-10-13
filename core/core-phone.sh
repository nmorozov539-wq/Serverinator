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
SSH_ALIAS_DEFAULT="serverinated"
ENABLE_SSH=1
SSH_HOST_FINGERPRINT=""
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

# ── Shared library ────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
            --purge)     PURGE=1; shift ;;
            --no-ssh)    ENABLE_SSH=0; shift ;;
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

# ── Step 2: Bootstrap chroot ──────────────────

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
    if [[ -d "$CHROOT/bin" ]]; then
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
        info "Stub chroot created at $CHROOT"
        return
    fi

    if command -v debootstrap &>/dev/null; then
        info "Running debootstrap..."
        debootstrap --arch="$ARCH" stable "$CHROOT" http://deb.debian.org/debian
    else
        warn "debootstrap not found, falling back to pre-built rootfs"
        local rootfs_url
        case "$ARCH" in
            aarch64) rootfs_url="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/ubuntu-base-24.04.4-base-arm64.tar.gz" ;;
            armv7)   rootfs_url="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/ubuntu-base-24.04.4-base-armhf.tar.gz" ;;
            x86_64)  rootfs_url="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/ubuntu-base-24.04.4-base-amd64.tar.gz" ;;
            *)       die "No pre-built rootfs for architecture: $ARCH" ;;
        esac
        info "Downloading Ubuntu 24.04 base rootfs for ${ARCH}..."
        local scratch
        scratch="$(mktemp -d)"
        trap 'rm -rf "$scratch"' EXIT
        curl -fsSL "$rootfs_url" -o "$scratch/rootfs.tar.gz"
        mkdir -p "$CHROOT"
        extract_rootfs "$scratch/rootfs.tar.gz"
        rm -f "$scratch/rootfs.tar.gz"
        info "Rootfs extracted to $CHROOT"
    fi
)

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
EOF
    reconcile_file "$script_path" 700 "$STATE_DIR/backups" < "$desired"
    rm -f "$desired"
    info "Mount script written to $script_path"
    if [[ "$DEV" == "1" ]]; then
        dev "DEV mode: mount script created but not executed"
    fi
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
                | grep -oP '\d+\.\d+\.\d+' | head -1 || true)"
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
    if [[ -x "$dest" ]]; then
        local current
        current="$(chroot_run /usr/local/bin/wstunnel --version 2>&1 \
            | grep -oP '\d+\.\d+\.\d+' | head -1 || true)"
        if [[ "$current" == "$WSTUNNEL_VERSION" ]]; then
            info "wstunnel v${WSTUNNEL_VERSION} already installed — skipping"
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
    tar -xf "$scratch/wstunnel.tar.gz" -C "$scratch" wstunnel
    mkdir -p "$CHROOT/usr/local/bin"
    mv "$scratch/wstunnel" "$dest"
    chmod +x "$dest"
    rm -f "$scratch/wstunnel.tar.gz"
    info "wstunnel installed to $dest"
)

generate_wg_keys() {
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

    # Base sshd config. ListenAddress is added at apply time, once the phone's
    # tunnel IP is known from the back-handoff.
    cat > "$CHROOT/etc/ssh/sshd_config.d/00-serverinator.conf" << EOF
# Managed by ServerInator. Tunnel-only, key-only root login.
Port ${SSH_PORT}
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

    SSH_HOST_FINGERPRINT="$(chroot_run /usr/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"
    if [[ -n "$SSH_HOST_FINGERPRINT" ]]; then
        info "SSH host key fingerprint: $SSH_HOST_FINGERPRINT"
    else
        warn "Could not read SSH host key fingerprint"
    fi
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
        'mkdir -p /run/sshd && chmod 0755 /run/sshd && /usr/sbin/sshd -t && exec /usr/sbin/sshd -D -e' \\
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

# write_wstunnel_autostart VPS_IP
# Called only from apply_back_handoff — once the VPS IP is known.
# Values are substituted directly; no placeholders, no sed.
write_wstunnel_autostart() {
    local vps_ip="$1"
    [[ -n "$vps_ip" ]] || die "write_wstunnel_autostart: VPS IP not provided"
    validate_host "$vps_ip"
    validate_tunnel_port "$WG_LOCAL_PORT"
    validate_tunnel_port "$WG_VPS_PORT"
    validate_tunnel_port "$WSTUNNEL_PORT"

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
# Wait for a default route to appear (network is up), up to 120s.
i=0
while [ "\$i" -lt 60 ]; do
    ip route show default 2>/dev/null | grep -q 'default' && break
    sleep 2; i=\$((i+1))
done
while true; do
    rotate_log || exit 1
    chroot "\$CHROOT" /usr/bin/env -i \\
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \\
        HOME=/root TMPDIR=/tmp /usr/local/bin/wstunnel client \\
        --log-lvl INFO \\
        -L "udp://${WG_LOCAL_PORT}:127.0.0.1:${WG_VPS_PORT}?timeout_sec=0" \\
        wss://${vps_ip}:${WSTUNNEL_PORT} \\
        >> "\$LOG" 2>&1 &
    child=\$!
    printf '%s\\n' "\$child" > "\$STATE_DIR/run/wstunnel.pid"
    while kill -0 "\$child" 2>/dev/null; do rotate_log || exit 1; sleep 5; done
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

# ── Step 4: Generate handoff file ─────────────

generate_handoff() {
    local pub_key
    pub_key="$(cat "$CHROOT/etc/wireguard/client.pub")"

    [[ -n "$DEVICE_NAME" ]] \
        || die "Device name not set. Pass --device-name NAME or set SERVERINATOR_DEVICE_NAME."
    validate_device_name "$DEVICE_NAME"
    validate_wg_key "$pub_key"

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
        '{
            version:               $version,
            device_name:           $device_name,
            wg_pubkey:             $wg_pubkey,
            wstunnel_port:         $wstunnel_port,
            wg_port:               $wg_port,
            ssh_enabled:           $ssh_enabled,
            ssh_user:              $ssh_user,
            ssh_port:              $ssh_port,
            ssh_host_fingerprint:  $ssh_host_fingerprint
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

    local vps_ip vps_wg_pubkey phone_wg_ip vps_wg_ip wg_port wstunnel_port
    vps_ip="$(json_get "$BACK_HANDOFF_FILE" vps_ip)"
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
    write_wstunnel_autostart "$vps_ip"

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
    info "Reboot the phone — services will come up automatically via Magisk."
}

# ── Step 6b: Apply SSH access from back-handoff ──

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
    cat > "$CHROOT/etc/ssh/sshd_config.d/00-serverinator.conf" << EOF
# Managed by ServerInator. Tunnel-only, key-only root login.
Port ${SSH_PORT}
ListenAddress ${phone_wg_ip}
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

    # authorized_keys: append-only + dedupe, so repeated applies are safe.
    local ak="$CHROOT/root/.ssh/authorized_keys"
    touch "$ak"
    chmod 600 "$ak"
    local added=0 i key
    _add_authorized_key() {
        local k="$1"
        [[ -n "$k" ]] || return 0
        grep -qF -- "$k" "$ak" && return 0
        printf '%s\n' "$k" >> "$ak"
        added=$((added + 1))
    }
    _add_authorized_key "$vps_to_phone"
    for ((i = 1; i <= count; i++)); do
        key="$(json_get "$BACK_HANDOFF_FILE" "ssh_client_key_${i}")"
        _add_authorized_key "$key"
    done

    prepare_sshd_runtime "$phone_wg_ip"
    write_sshd_autostart
    info "SSH authorized_keys updated ($added new key(s))"
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

    # DNS for apt inside the chroot.
    mkdir -p "$CHROOT/etc" "$CHROOT/tmp" || die "Unable to prepare chroot directories"
    if ! printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$CHROOT/etc/resolv.conf"; then
        die "Failed to write $CHROOT/etc/resolv.conf"
    fi

    info "Chroot environment configured (mounts + DNS)"
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
    local pid="$1" expected="$2" kind="$3" root exe attempt
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
    for attempt in 1 2 3 4 5; do
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
    local name file pid proc script
    if [[ "$DEV" != 1 ]]; then
        # Stop only supervisors named by exact script argv and children in this root.
        for name in wstunnel sshd wireguard; do
            case "$name" in
                wstunnel) script="$MAGISK_SERVICE_D/10-serverinator-wstunnel.sh";;
                sshd) script="$MAGISK_SERVICE_D/30-serverinator-sshd.sh";;
                wireguard) script="$MAGISK_SERVICE_D/20-serverinator-wireguard.sh";;
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
    for name in 00-serverinator-mount 10-serverinator-wstunnel 20-serverinator-wireguard 30-serverinator-sshd; do
        rm -f "$MAGISK_SERVICE_D/$name.sh" "$MAGISK_SERVICE_D/$name.sh.bak"
    done
    rm -rf "$CHROOT"
    if [[ "$PURGE" == 1 ]]; then rm -rf "$SSH_HOSTKEY_DIR"; fi
    # Logs and .bak backups are pure operational debris, not identity state —
    # always clear them, regardless of --purge.
    rm -rf "$STATE_DIR/run" "$STATE_DIR/logs" "$STATE_DIR/backups"
    info "Phone uninstall complete; host keys preserved unless --purge"
}

# ── Main ──────────────────────────────────────

main() {
    parse_args "$@"
    if [[ "$MODE" == uninstall ]]; then uninstall_phone; return; fi
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

    info "[1/4] Checking environment..."
    check_root
    check_magisk
    check_disk_space
    ARCH="$(detect_arch)"
    [[ -n "$ARCH_OVERRIDE" ]] && dev "Architecture overridden: $ARCH"
    info "Architecture: $ARCH"

    info "[2/4] Loading rootfs..."
    bootstrap_chroot
    write_mount_script
    [[ "$DEV" == "0" ]] && setup_chroot_env

    info "[3/4] Installing packages and keys..."
    install_chroot_packages
    install_wstunnel
    generate_wg_keys
    install_ssh_server
    # wstunnel autostart is written later (apply_back_handoff) — needs the VPS IP
    prepare_sshd_runtime
    write_sshd_autostart

    info "[4/4] Generating handoff..."
    generate_handoff
    info "Phone configured. Run serverinator.sh --apply-back-handoff BACK_HANDOFF.json"
}

# Only run when executed directly; allows the functions to be sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
