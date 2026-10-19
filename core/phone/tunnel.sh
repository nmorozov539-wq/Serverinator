# shellcheck shell=bash
# ServerInator Core, phone side: step 3, the tunnel: wstunnel client, WireGuard keys, wstunnel autostart
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Step 3: wstunnel client and WireGuard keys ───

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

# write_wstunnel_autostart VPS_IP [DOMAIN [PATH_PREFIX]]
# Called only from apply_back_handoff — once the VPS IP is known. With a
# DOMAIN the tunnel connects by name, so the VPS's real certificate matches;
# SERVERINATOR_TLS_VERIFY=1 also makes wstunnel check that certificate.
# Values are substituted directly; no placeholders, no sed.
write_wstunnel_autostart() {
    local vps_ip="$1" domain="${2:-}" prefix="${3:-}"
    [[ -n "$vps_ip" ]] || die "write_wstunnel_autostart: VPS IP not provided"
    validate_host "$vps_ip"
    [[ -z "$domain" ]] || validate_domain "$domain"
    local endpoint="${domain:-$vps_ip}" verify_line="" prefix_line=""
    if [[ -n "$prefix" ]]; then
        [[ "$prefix" =~ ^[A-Za-z0-9]{16,64}$ ]] || die "back-handoff: odd wstunnel_path_prefix"
        prefix_line="        --http-upgrade-path-prefix ${prefix} \\
"
    fi
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
    render_template "$CORE_DIR/templates/magisk-wstunnel.sh" "STATE_DIR=$STATE_DIR" "CHROOT=$CHROOT" \
        "PROBE_IP=$probe_ip" "VERIFY_LINE=$verify_line" "PREFIX_LINE=$prefix_line" \
        "WG_LOCAL_PORT=$WG_LOCAL_PORT" "WG_VPS_PORT=$WG_VPS_PORT" "ENDPOINT=$endpoint" \
        "WSTUNNEL_PORT=$WSTUNNEL_PORT" > "$desired"
    reconcile_file "$script_path" 700 "$STATE_DIR/backups" < "$desired"
    rm -f "$desired"
    info "wstunnel autostart written: $script_path"
}
