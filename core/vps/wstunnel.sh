# shellcheck shell=bash
# ServerInator Core, VPS side: the wstunnel server (WireGuard inside TLS)
# Sourced by core-vps.sh, which holds the settings and globals used here.

# wstunnel release suffix for this VPS's CPU (SERVERINATOR_VPS_ARCH overrides
# uname -m, for tests).
wstunnel_vps_suffix() {
    local raw="${SERVERINATOR_VPS_ARCH:-$(uname -m)}"
    case "$raw" in
        x86_64|amd64)   echo amd64 ;;
        aarch64|arm64)  echo arm64 ;;
        armv7l|armv8l)  echo armv7 ;;
        *) die "No wstunnel binary for VPS architecture: $raw" ;;
    esac
}

install_wstunnel_vps() (
    # Check both presence AND version — a mismatched version gets upgraded.
    if [[ -x "$WSTUNNEL_BIN" ]]; then
        local current
        current="$("$WSTUNNEL_BIN" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
        if [[ "$current" == "$WSTUNNEL_VERSION" ]]; then
            info "wstunnel v${WSTUNNEL_VERSION} already installed — skipping"
            # Older installs kept the archive's owner; see below.
            [[ "$(id -u)" != 0 ]] || chown 0:0 "$WSTUNNEL_BIN"
            return 0
        fi
        warn "wstunnel v${current:-?} is installed, v${WSTUNNEL_VERSION} is required — upgrading"
    fi

    require_cmd curl
    require_cmd tar
    local suffix
    suffix="$(wstunnel_vps_suffix)"
    local scratch
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    local url="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_${suffix}.tar.gz"
    info "Installing wstunnel v${WSTUNNEL_VERSION} (${suffix})..."
    curl -fsSL "$url" -o "$scratch/wstunnel.tar.gz"
    verify_download "$scratch/wstunnel.tar.gz" "${url##*/}"
    tar -xf "$scratch/wstunnel.tar.gz" -C "$scratch" wstunnel
    mkdir -p "$(dirname "$WSTUNNEL_BIN")"
    mv "$scratch/wstunnel" "$WSTUNNEL_BIN"
    # tar keeps the archive's owner (uid 1001) when run as root; a user who
    # later gets that uid could swap the binary root runs.
    [[ "$(id -u)" != 0 ]] || chown 0:0 "$WSTUNNEL_BIN"
    chmod 755 "$WSTUNNEL_BIN"
    mkdir -p "$WG_KEY_DIR"
    touch "$WG_KEY_DIR/wstunnel-owned"
    info "wstunnel installed: $WSTUNNEL_BIN"
)

# The secret path prefix phones put in the WebSocket upgrade request
# (review #12). Without it wstunnel answers every path, and its default
# path ("v1") is the same on every install, so a scanner can tell it's
# wstunnel. One per VPS, kept across re-installs, sent to phones in the
# back-handoff; the server refuses any other path.
ensure_wstunnel_path_prefix() {
    local f="$WG_KEY_DIR/wstunnel-path-prefix" p=""
    mkdir -p "$WG_KEY_DIR"; chmod 700 "$WG_KEY_DIR"
    [[ -f "$f" ]] && p="$(head -n 1 "$f")"
    if [[ ! "$p" =~ ^[A-Za-z0-9]{16,64}$ ]]; then
        p="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
        [[ "$p" =~ ^[A-Za-z0-9]{24}$ ]] || die "Could not make a random wstunnel path prefix"
        (umask 077; printf '%s\n' "$p" > "$f")
    fi
    WSTUNNEL_PATH_PREFIX="$p"
}

setup_wstunnel_server() {
    local svc="$SYSTEMD_DIR/wstunnel-serverinator.service"
    mkdir -p "$SYSTEMD_DIR"
    ensure_wstunnel_path_prefix
    # The prefix goes in a root-only environment file: the unit file is
    # world-readable.
    reconcile_file "$WG_KEY_DIR/wstunnel.env" 600 << EOF
WSTUNNEL_RESTRICT_HTTP_UPGRADE_PATH_PREFIX=${WSTUNNEL_PATH_PREFIX}
EOF
    # wstunnel runs as a throwaway user (DynamicUser) with nothing it
    # doesn't need (review #12). It can't read the root-only certificate, so
    # systemd hands it a copy (LoadCredential, under %d); the renewal hook
    # restarts it to load a new one.
    local desired tls_lines="" cred_lines=""
    if [[ -n "$VPS_DOMAIN" ]]; then
        tls_lines="    --tls-certificate %d/tls-cert \\
    --tls-private-key %d/tls-key \\
"
        cred_lines="LoadCredential=tls-cert:${TLS_CERT_FILE}
LoadCredential=tls-key:${TLS_KEY_FILE}
"
    fi
    desired="$(mktemp "$SYSTEMD_DIR/unit.XXXXXX")"
    render_template "$CORE_DIR/templates/wstunnel-serverinator.service" \
        "CERTIFICATE=${TLS_CERT_FILE:-built-in self-signed}" "CRED_LINES=$cred_lines" "WG_KEY_DIR=$WG_KEY_DIR" \
        "WSTUNNEL_BIN=$WSTUNNEL_BIN" "WG_RESTRICT_TARGET=$WG_RESTRICT_TARGET" "TLS_LINES=$tls_lines" \
        "WSTUNNEL_PORT=$WSTUNNEL_PORT" > "$desired"
    reconcile_file "$svc" 644 < "$desired"
    rm -f "$desired"

    if [[ "$DEV" == "1" ]]; then dev "DEV: skipping systemctl"; return 0; fi

    require_cmd systemctl
    systemctl daemon-reload
    systemctl enable --now wstunnel-serverinator
    [[ "$RECONCILED_CHANGED" == 1 ]] && systemctl restart wstunnel-serverinator
    info "wstunnel server started"
}
