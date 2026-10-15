#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# ServerInator Core — VPS-side setup script
#
# Usage:
#   bash core-vps.sh HANDOFF.json --vps-ip HOST [--alias NAME] [--client-keys existing|new]
#   bash core-vps.sh --verify [BACK-HANDOFF.json] [--device NAME]
#   bash core-vps.sh --add-client LABEL     # after install, the tunnel must be up
#   bash core-vps.sh --revoke-client LABEL
#   bash core-vps.sh --list-clients [--device NAME]
#   bash core-vps.sh --add-guest NAME [--folder NAME|PATH[:ro|:rw]]... [--pubkey KEY|FILE]
#   bash core-vps.sh --guest-access NAME [--folder ...]...   # replaces the folder list
#   bash core-vps.sh --revoke-guest NAME
#   bash core-vps.sh --list-guests [--device NAME]
#   bash core-vps.sh --sync-guests [--device NAME]          # after a phone reset
#   bash core-vps.sh --list-devices
#   bash core-vps.sh --remove-device NAME
#   bash core-vps.sh --set-domain DOMAIN [--acme-email EMAIL | --tls-cert FILE --tls-key FILE]
#   bash core-vps.sh --remove-domain       # back to the built-in self-signed certificate
#
# A full install also takes --domain DOMAIN [--acme-email EMAIL | --tls-cert FILE --tls-key FILE].
#
# --add-client/--revoke-client/--list-clients/--verify act on the only phone,
# or on the one named with --device when several share this VPS.
#   bash core-vps.sh --uninstall
# ─────────────────────────────────────────────

DEV="${SERVERINATOR_DEV:-0}"

# v11.0.0 fixes reverse-tunnel idle reconnect, TCP_NODELAY stalls and dispatch
# speed (see upstream changelog). Working reference setup used 11.0.0.
WSTUNNEL_VERSION="11.0.0"

WG_INTERFACE="wg-si"
WG_PORT="${SERVERINATOR_WG_PORT-51822}"
WSTUNNEL_PORT="${SERVERINATOR_WSTUNNEL_PORT-9443}"
VPS_WG_SUBNET="10.66.69"

# wstunnel --restrict-to: forward only to local WireGuard listener.
# Without it the server acts as an open proxy for anyone reaching the port.
WG_RESTRICT_TARGET="127.0.0.1:${WG_PORT}"

# ── Install locations ─────────────────────────
if [[ "$DEV" == "1" ]]; then
    DEV_ROOT="${SERVERINATOR_DEV_ROOT:-${TMPDIR:-/tmp}/serverinator-dev}"
    : "${SERVERINATOR_WG_DIR:=$DEV_ROOT/etc/wireguard}"
    : "${SERVERINATOR_SYSTEMD_DIR:=$DEV_ROOT/etc/systemd/system}"
    : "${SERVERINATOR_WSTUNNEL_BIN:=$DEV_ROOT/usr/local/bin/wstunnel}"
    : "${SERVERINATOR_BACK_HANDOFF_PATH:=$DEV_ROOT/back-handoff.json}"
    : "${SERVERINATOR_VPS_ADMIN_HOME:=$DEV_ROOT/root}"
    : "${SERVERINATOR_LETSENCRYPT_DIR:=$DEV_ROOT/etc/letsencrypt}"
    : "${SERVERINATOR_GUEST_HOME:=$DEV_ROOT/var/lib/serverinator-files}"
fi

WG_DIR="${SERVERINATOR_WG_DIR:-/etc/wireguard}"
WG_KEY_DIR="${SERVERINATOR_WG_KEY_DIR:-$WG_DIR/serverinator}"
WG_CONF="$WG_DIR/${WG_INTERFACE}.conf"
SYSTEMD_DIR="${SERVERINATOR_SYSTEMD_DIR:-/etc/systemd/system}"
WSTUNNEL_BIN="${SERVERINATOR_WSTUNNEL_BIN:-/usr/local/bin/wstunnel}"
# Optional extra copy of the back-handoff (DEV and tests set it). The real
# record is DEVICES_DIR/<device>.json.
BACK_HANDOFF_PATH="${SERVERINATOR_BACK_HANDOFF_PATH:-}"
IPTABLES_RULES_PATH="${SERVERINATOR_IPTABLES_RULES_PATH:-/etc/iptables/rules.v4}"
# Let's Encrypt (certbot) layout; tests point it elsewhere.
LETSENCRYPT_DIR="${SERVERINATOR_LETSENCRYPT_DIR:-/etc/letsencrypt}"
CERTBOT="${SERVERINATOR_CERTBOT:-certbot}"

# ── SSH state ─────────────────────────────────
SSH_KEY_DIR="${SERVERINATOR_SSH_KEY_DIR:-$WG_KEY_DIR/ssh}"
TLS_STATE="$WG_KEY_DIR/tls.json"
# One record per phone (its back-handoff): the source of truth for
# --add-client, --verify, --list-devices and the orchestrator.
DEVICES_DIR="${SERVERINATOR_DEVICES_DIR:-$WG_KEY_DIR/devices}"
SSH_ALIAS_DEFAULT="serverinated"
# Guest file access: records, and the VPS user guests' SFTP apps log in as.
GUESTS_DIR="${SERVERINATOR_GUESTS_DIR:-$WG_KEY_DIR/guests}"
GUEST_VPS_USER="${SERVERINATOR_GUEST_USER:-serverinator-files}"
GUEST_VPS_HOME="${SERVERINATOR_GUEST_HOME:-/var/lib/serverinator-files}"
SSH_ENABLED=0
SSH_USER="root"
SSH_PHONE_PORT=22
SSH_HOST_FINGERPRINT=""
SSH_HOST_PUBKEY=""
SSH_VPS_USER=""
SSH_VPS_TO_PHONE_PUBKEY=""
SSH_CLIENT_KEYS=()
SSH_CLIENT_KEY_IS_NEW=0

# ── Runtime state ─────────────────────────────
MODE="setup"
HANDOFF_FILE=""
BACK_HANDOFF_FILE=""
VPS_IP=""
SSH_ALIAS=""
CLIENT_KEYS_MODE=""
CLIENT_LABEL=""
GUEST_NAME=""
GUEST_FOLDERS=()     # --folder, repeatable
GUEST_PUBKEY=""      # --pubkey: the guest's own key instead of a generated one
GUEST_RECORD=""
SELECTED_DEVICE=""   # --device / --remove-device
DEVICE_RECORD=""     # DEVICES_DIR/<device>.json once selected

# ── Domain and certificate (optional) ─────────
# Without a domain, wstunnel serves its built-in self-signed certificate and
# everything addresses the VPS by VPS_IP. With one, wstunnel serves a real
# certificate for it, phones connect to it by name (real SNI), and client
# configs jump through it, so moving to another VPS becomes a DNS change.
# The choice is VPS-wide and kept in TLS_STATE.
VPS_DOMAIN=""
ACME_EMAIL=""
TLS_CERT_FILE=""     # your own certificate instead of Let's Encrypt
TLS_KEY_FILE=""
TLS_SOURCE=""        # letsencrypt|custom
REMOVE_DOMAIN=0

# ── Shared library ────────────────────────────
# Resolved once at the top level: inside a function, the phone's bash gave
# BASH_SOURCE without its directory (hardware run 2026-10-14).
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CORE_DIR/lib.sh"

# Validate immediately on load — WG_PORT/WSTUNNEL_PORT can come from env vars
# set by the caller, and must never reach a generated config or firewall rule
# unvalidated.
validate_tunnel_port "$WG_PORT"
validate_tunnel_port "$WSTUNNEL_PORT"
[[ "$WG_PORT" != "$WSTUNNEL_PORT" ]] || die "WG_PORT and WSTUNNEL_PORT must differ"

# ─────────────────────────────────────────────
# Arguments
# ─────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall) MODE="uninstall"; shift ;;
            --verify)
                MODE="verify"; shift
                # Optional file; without it the device record is used.
                if [[ $# -gt 0 && "$1" != -* ]]; then BACK_HANDOFF_FILE="$1"; shift; fi
                ;;
            --device)
                shift
                [[ $# -gt 0 ]] || die "--device requires a NAME"
                SELECTED_DEVICE="$1"; shift
                validate_device_name "$SELECTED_DEVICE"
                ;;
            --list-devices) MODE="list-devices"; shift ;;
            --remove-device)
                MODE="remove-device"; shift
                [[ $# -gt 0 ]] || die "--remove-device requires a NAME"
                SELECTED_DEVICE="$1"; shift
                validate_device_name "$SELECTED_DEVICE"
                ;;
            --add-client)
                MODE="add-client"; shift
                [[ $# -gt 0 ]] || die "--add-client requires a LABEL"
                CLIENT_LABEL="$1"; shift
                validate_client_label "$CLIENT_LABEL"
                ;;
            --revoke-client)
                MODE="revoke-client"; shift
                [[ $# -gt 0 ]] || die "--revoke-client requires a LABEL"
                CLIENT_LABEL="$1"; shift
                validate_client_label "$CLIENT_LABEL"
                ;;
            --list-clients) MODE="list-clients"; shift ;;
            --add-guest|--guest-access|--revoke-guest)
                MODE="${1#--}"; shift
                [[ $# -gt 0 ]] || die "--$MODE requires a NAME"
                GUEST_NAME="$1"; shift
                validate_guest_name "$GUEST_NAME"
                ;;
            --list-guests) MODE="list-guests"; shift ;;
            --sync-guests) MODE="sync-guests"; shift ;;
            --folder)
                shift
                [[ $# -gt 0 ]] || die "--folder requires NAME or PATH (optionally :ro or :rw)"
                GUEST_FOLDERS+=("$1"); shift
                ;;
            --pubkey)
                shift
                [[ $# -gt 0 ]] || die "--pubkey requires a key or a .pub file"
                if [[ -f "$1" ]]; then GUEST_PUBKEY="$(awk 'NF {print $1" "$2; exit}' "$1")"
                else GUEST_PUBKEY="$(awk '{print $1" "$2}' <<< "$1")"; fi
                shift
                [[ "$GUEST_PUBKEY" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,2}$ ]] \
                    || die "--pubkey: expected an ssh-ed25519 public key (or a file holding one)"
                ;;
            --domain|--set-domain)
                [[ "$1" == --set-domain ]] && MODE="set-domain"
                shift
                [[ $# -gt 0 ]] || die "--domain requires a DOMAIN"
                VPS_DOMAIN="${1,,}"; shift
                validate_domain "$VPS_DOMAIN"
                ;;
            --remove-domain) MODE="set-domain"; REMOVE_DOMAIN=1; shift ;;
            --acme-email)
                shift
                [[ $# -gt 0 ]] || die "--acme-email requires an address"
                ACME_EMAIL="$1"; shift
                validate_email "$ACME_EMAIL"
                ;;
            --tls-cert|--tls-key)
                local which="$1"; shift
                [[ $# -gt 0 ]] || die "$which requires a FILE"
                [[ "$1" =~ ^/[A-Za-z0-9_./@+-]+$ && "$1" != *..* ]] || die "$which: use an absolute path without unusual characters"
                if [[ "$which" == --tls-cert ]]; then TLS_CERT_FILE="$1"; else TLS_KEY_FILE="$1"; fi
                shift
                ;;
            --vps-ip)
                shift
                [[ $# -gt 0 ]] || die "--vps-ip requires a value"
                VPS_IP="$1"; shift
                ;;
            --alias)
                shift
                [[ $# -gt 0 ]] || die "--alias requires a value"
                SSH_ALIAS="$1"; shift
                validate_ssh_alias "$SSH_ALIAS"
                ;;
            --client-keys)
                shift
                [[ $# -gt 0 ]] || die "--client-keys requires existing|new"
                CLIENT_KEYS_MODE="$1"; shift
                [[ "$CLIENT_KEYS_MODE" == "existing" || "$CLIENT_KEYS_MODE" == "new" ]] \
                    || die "--client-keys: expected existing or new"
                ;;
            -*) die "Unknown argument: $1" ;;
            *)  HANDOFF_FILE="$1"; shift ;;
        esac
    done

    [[ -z "$TLS_CERT_FILE$TLS_KEY_FILE" || ( -n "$TLS_CERT_FILE" && -n "$TLS_KEY_FILE" ) ]] \
        || die "--tls-cert and --tls-key go together"
    [[ -z "$TLS_CERT_FILE" || -n "$VPS_DOMAIN" ]] || die "--tls-cert needs --domain (the name the certificate is for)"
    [[ -z "$TLS_CERT_FILE" || -z "$ACME_EMAIL" ]] || die "--acme-email is for Let's Encrypt; it doesn't go with --tls-cert"

    case "$MODE" in
        setup)
            [[ -n "$HANDOFF_FILE" ]] \
                || die "No handoff.json given. Usage: $0 HANDOFF.json --vps-ip HOST"
            if [[ -z "$VPS_IP" ]]; then
                if [[ "$DEV" == "1" && -n "${SERVERINATOR_VPS_IP:-}" ]]; then
                    VPS_IP="$SERVERINATOR_VPS_IP"
                    dev "DEV: --vps-ip not passed, using SERVERINATOR_VPS_IP=$VPS_IP"
                else
                    die "--vps-ip HOST is required (this VPS's IP or hostname)"
                fi
            fi
            validate_host "$VPS_IP"
            [[ -n "$SSH_ALIAS" ]] || SSH_ALIAS="$SSH_ALIAS_DEFAULT"
            ;;
        verify|uninstall|list-clients|list-devices|remove-device|list-guests|sync-guests) ;;
        add-guest|guest-access|revoke-guest) ;;
        set-domain)
            [[ "$REMOVE_DOMAIN" == 1 || -n "$VPS_DOMAIN" ]] || die "--set-domain requires a DOMAIN"
            ;;
        add-client|revoke-client)
            [[ -n "$CLIENT_LABEL" ]] || die "--add-client/--revoke-client requires a LABEL"
            ;;
    esac
    [[ ${#GUEST_FOLDERS[@]} -eq 0 || "$MODE" == add-guest || "$MODE" == guest-access ]] \
        || die "--folder goes with --add-guest or --guest-access"
    [[ -z "$GUEST_PUBKEY" || "$MODE" == add-guest ]] || die "--pubkey goes with --add-guest"
}

# ─────────────────────────────────────────────
# Helper functions (VPS-specific)
# ─────────────────────────────────────────────

interface_is_up() {
    have_cmd ip && ip link show "$WG_INTERFACE" &>/dev/null
}

# The back-handoff file is created as root (sudo). Hand it to the invoking
# user so the scp command in the docs works without root.
set_back_handoff_owner() {
    local path="$1" uid gid
    if [[ "$DEV" == 1 || -z "${SUDO_USER:-}" || "$SUDO_USER" == root ]]; then
        return 0
    fi
    uid="$(id -u "$SUDO_USER")" || die "Could not get uid for $SUDO_USER"
    gid="$(id -g "$SUDO_USER")" || die "Could not get gid for $SUDO_USER"
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] \
        || die "Invalid uid/gid for $SUDO_USER"
    chown "$uid:$gid" "$path" || die "Could not hand back-handoff to $SUDO_USER"
}

# ─────────────────────────────────────────────
# Device records
# ─────────────────────────────────────────────

device_record_path() { printf '%s/%s.json\n' "$DEVICES_DIR" "$1"; }

device_names() {
    local f
    for f in "$DEVICES_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        f="${f##*/}"; printf '%s\n' "${f%.json}"
    done
}

# Older installs kept one ssh/state.json (and only when SSH was enabled).
# Move it to DEVICES_DIR/<device>.json unless a record already exists.
migrate_legacy_state() {
    local legacy="$SSH_KEY_DIR/state.json" name record
    [[ -f "$legacy" ]] || return 0
    name="$(json_get "$legacy" device_name)" || return 0
    if [[ -z "$name" ]] || ! (validate_device_name "$name") 2>/dev/null; then
        warn "Ignoring $legacy: no valid device_name"
        return 0
    fi
    record="$(device_record_path "$name")"
    mkdir -p "$DEVICES_DIR"; chmod 700 "$DEVICES_DIR"
    if [[ -f "$record" ]]; then
        rm -f "$legacy"
    else
        mv "$legacy" "$record"
        chmod 600 "$record"
        info "Moved $legacy -> $record"
    fi
}

# Sets DEVICE_NAME/DEVICE_RECORD from --device, or the only phone installed.
select_device() {
    local -a names=()
    mapfile -t names < <(device_names)
    if [[ -n "$SELECTED_DEVICE" ]]; then
        DEVICE_RECORD="$(device_record_path "$SELECTED_DEVICE")"
        [[ -f "$DEVICE_RECORD" ]] \
            || die "No phone named '$SELECTED_DEVICE' on this VPS (known: ${names[*]:-none})"
        DEVICE_NAME="$SELECTED_DEVICE"
        return 0
    fi
    case "${#names[@]}" in
        0) die "No phone is set up on this VPS yet ($DEVICES_DIR is empty) — run a full install first: bash $0 HANDOFF.json --vps-ip HOST" ;;
        1) DEVICE_NAME="${names[0]}" ;;
        *) die "Several phones use this VPS: ${names[*]}. Choose one with --device NAME" ;;
    esac
    DEVICE_RECORD="$(device_record_path "$DEVICE_NAME")"
}

# Owner and --add-client public keys issued for DEVICE (one path per line).
# Client keys are owner_<device>_<label>.pub; files that belong to another
# device whose name starts with "<device>_" are excluded.
device_client_pubs() { # DEVICE
    local dev="$1" f base other skip
    local -a others=()
    mapfile -t others < <(device_names)
    for f in "$SSH_KEY_DIR/owner_${dev}_"*.pub; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"; skip=0
        for other in "${others[@]}"; do
            [[ "$other" != "$dev" && "$other" == "${dev}_"* ]] || continue
            [[ "$base" == "owner_${other}.pub" || "$base" == "owner_${other}_"* ]] && skip=1
        done
        ((skip)) || printf '%s\n' "$f"
    done
}

# Device names that would make owner_<a>_<label> ambiguous are refused.
check_device_name_unambiguous() {
    local name="$1" other
    while IFS= read -r other; do
        [[ -n "$other" && "$other" != "$name" ]] || continue
        if [[ "$other" == "${name}_"* || "$name" == "${other}_"* ]]; then
            die "Device name '$name' clashes with existing phone '$other' (one is the other plus '_...'). Pick another name."
        fi
    done < <(device_names)
}

# ─────────────────────────────────────────────
# WireGuard peer block helpers
# ─────────────────────────────────────────────

# Number of peer blocks carrying this device's marker.
peer_block_count() {
    local conf="$1" device="$2"
    grep -cF "# ServerInator peer: ${device}" "$conf" 2>/dev/null || true
}

# PublicKey of the device's peer block (empty if not found).
peer_pubkey_for_device() {
    local conf="$1" device="$2"
    awk -v marker="# ServerInator peer: ${device}" '
        $0 == marker              { in_device=1; next }
        in_device && /^\[Peer\]/  { in_peer=1; next }
        in_device && /^\[/        { in_device=0; in_peer=0 }
        in_peer   && $1 == "PublicKey" { print $3; exit }
    ' "$conf"
}

# Removes the device's peer block atomically.
peer_remove_device() {
    local conf="$1" device="$2"
    local marker="# ServerInator peer: ${device}"
    local tmp
    tmp="$(mktemp "${conf}.XXXXXX")" || die "Could not create a temp file next to $conf"

    if ! awk -v marker="$marker" '
        $0 == marker { skipping=1; in_peer=0; next }
        skipping && !in_peer {
            if ($0 ~ /^\[Peer\]/) { in_peer=1; next }
            if ($0 ~ /^\[/ || $0 ~ /^# ServerInator peer:/) { skipping=0; in_peer=0 }
            else next
        }
        skipping && in_peer {
            if ($0 ~ /^\[/ || $0 ~ /^# ServerInator peer:/) { skipping=0; in_peer=0 }
            else next
        }
        { n++; lines[n]=$0 }
        END {
            while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
            for (i = 1; i <= n; i++) print lines[i]
        }
    ' "$conf" > "$tmp"; then
        rm -f "$tmp"; die "Could not rewrite $conf"
    fi

    chmod --reference="$conf" "$tmp" 2>/dev/null || true
    mv "$tmp" "$conf" || { rm -f "$tmp"; die "Could not replace $conf"; }
}

# Appends the device's peer block to the end of the config.
append_peer_block() {
    local conf="$1" device="$2" pubkey="$3" ip="$4"
    local last
    last="$(tail -c 1 "$conf" 2>/dev/null || true)"
    {
        [[ -s "$conf" && "$last" != "" ]] && printf '\n'
        printf '\n# ServerInator peer: %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nPersistentKeepalive = 25\n' \
            "$device" "$pubkey" "$ip"
    } >> "$conf"
}

# ─────────────────────────────────────────────
# Step 1: Read handoff
# ─────────────────────────────────────────────

read_handoff() {
    [[ -f "$HANDOFF_FILE" ]] || die "handoff.json not found: $HANDOFF_FILE"

    local version
    version="$(json_get_num "$HANDOFF_FILE" version)"
    [[ "$version" == "1" ]] || die "Unsupported handoff version: $version"

    DEVICE_NAME="$(json_get    "$HANDOFF_FILE" device_name)"
    PHONE_WG_PUBKEY="$(json_get "$HANDOFF_FILE" wg_pubkey)"

    SSH_ENABLED="$(json_get_num "$HANDOFF_FILE" ssh_enabled)";   SSH_ENABLED="${SSH_ENABLED:-0}"
    SSH_USER="$(json_get        "$HANDOFF_FILE" ssh_user)";       SSH_USER="${SSH_USER:-root}"
    SSH_PHONE_PORT="$(json_get_num "$HANDOFF_FILE" ssh_port)";   SSH_PHONE_PORT="${SSH_PHONE_PORT:-22}"
    SSH_HOST_FINGERPRINT="$(json_get "$HANDOFF_FILE" ssh_host_fingerprint)"
    SSH_HOST_PUBKEY="$(json_get "$HANDOFF_FILE" ssh_host_pubkey)"

    [[ -n "$DEVICE_NAME" ]]     || die "handoff.json: missing device_name"
    [[ -n "$PHONE_WG_PUBKEY" ]] || die "handoff.json: missing wg_pubkey"

    validate_device_name "$DEVICE_NAME"
    check_device_name_unambiguous "$DEVICE_NAME"
    validate_wg_key "$PHONE_WG_PUBKEY"
    validate_optional_ports "$HANDOFF_FILE"
    validate_phone_host_key

    info "Handoff OK — device: $DEVICE_NAME"
    info "Phone's WireGuard pubkey: $PHONE_WG_PUBKEY"
    if [[ "$SSH_ENABLED" == "1" ]]; then
        info "SSH is enabled on the phone (user: $SSH_USER, fingerprint: ${SSH_HOST_FINGERPRINT:-unknown})"
    else
        info "SSH is not enabled on the phone"
    fi
}

# ─────────────────────────────────────────────
# Step 2: Install dependencies
# ─────────────────────────────────────────────

install_deps() {
    if [[ "$DEV" == "1" ]]; then dev "DEV: skipping apt install"; return 0; fi
    require_cmd apt-get
    info "Updating package lists..."
    apt-get update -qq
    info "Installing wireguard-tools, iproute2, iputils-ping, curl, openssh-client, jq..."
    apt-get install -y -qq wireguard-tools iproute2 iputils-ping curl openssh-client jq
}

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
            return 0
        fi
        warn "wstunnel v${current:-?} is installed, v${WSTUNNEL_VERSION} is required — upgrading"
    fi

    if [[ "$DEV" == "1" ]]; then
        dev "DEV: creating wstunnel stub at $WSTUNNEL_BIN"
        mkdir -p "$(dirname "$WSTUNNEL_BIN")"
        cat > "$WSTUNNEL_BIN" << STUB
#!/usr/bin/env bash
case "\${1:-}" in --version) echo "wstunnel v${WSTUNNEL_VERSION}";; esac
echo "wstunnel STUB (DEV): \$*"
STUB
        chmod +x "$WSTUNNEL_BIN"
        mkdir -p "$WG_KEY_DIR"
        touch "$WG_KEY_DIR/wstunnel-owned"
        return 0
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
    chmod +x "$WSTUNNEL_BIN"
    mkdir -p "$WG_KEY_DIR"
    touch "$WG_KEY_DIR/wstunnel-owned"
    info "wstunnel installed: $WSTUNNEL_BIN"
)

# ─────────────────────────────────────────────
# Step 3: WireGuard
# ─────────────────────────────────────────────

# Picks an IP for the phone from the config (allocation ledger).
# Re-installing the same device/key gets the same IP back.
allocate_phone_ip() {
    local conf="$WG_CONF"
    [[ -f "$conf" ]] || conf=/dev/null
    PHONE_WG_IP="$(awk -v subnet="$VPS_WG_SUBNET" -v device="$DEVICE_NAME" -v key="$PHONE_WG_PUBKEY" '
        function ipnum(ip, a) { split(ip,a,"."); return ((a[1]*256+a[2])*256+a[3])*256+a[4] }
        function fail(msg) { print msg > "/dev/stderr"; bad=1; exit 1 }
        /^# ServerInator peer: / { marker=substr($0,22); next }
        /^\[Peer\]/ { peer=++total; names[peer]=marker; marker=""; next }
        /^\[/ { peer=0; next }
        peer && $1=="PublicKey" { keys[peer]=$3 }
        peer && $1=="AllowedIPs" {
            line=$0; sub(/^[^=]*=[[:space:]]*/,"",line); count=split(line,list,",")
            for(i=1;i<=count;i++) {
                gsub(/[[:space:]]/,"",list[i]); split(list[i],parts,"/")
                if (parts[1] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || parts[2] !~ /^[0-9]+$/ || parts[2]>32)
                    fail("Unsupported or malformed AllowedIPs in allocation ledger")
                split(parts[1],oct,"."); for(j=1;j<=4;j++) if(oct[j]>255) fail("Invalid IPv4 AllowedIPs")
                size=2^(32-parts[2]); value=ipnum(parts[1]); lo=int(value/size)*size; hi=lo+size-1
                for(j=1;j<=ranges;j++) if(lo<=high[j] && hi>=low[j]) fail("Overlapping AllowedIPs in allocation ledger")
                ranges++; low[ranges]=lo; high[ranges]=hi; owner[ranges]=peer
                if(parts[2]==32 && index(parts[1],subnet".")==1) address[peer]=parts[1]
            }
        }
        END {
            if(bad) exit 1
            for(i in keys) if(keys[i]==key) { chosen=address[i]; matches++ }
            if(matches>1) fail("Duplicate public key in allocation ledger")
            if(matches==1) {
                if(chosen=="") fail("Existing key has no usable allocated address")
                print chosen; exit
            }
            for(i in names) if(names[i]==device) { chosen=address[i]; devices++ }
            if(devices>1) fail("Duplicate device marker in allocation ledger")
            if(devices==1) {
                if(chosen=="") fail("Existing device has no usable allocated address")
                print chosen; exit
            }
            for(host=2;host<255;host++) {
                candidate=ipnum(subnet"."host); used=0
                for(j=1;j<=ranges;j++) if(candidate>=low[j] && candidate<=high[j]) used=1
                if(!used) { print subnet"."host; exit }
            }
            fail("WireGuard address pool exhausted")
        }
    ' "$conf")" || die "Could not allocate an IP for the phone"
}

setup_wireguard() {
    local priv_key="$WG_KEY_DIR/server.key" pub_key="$WG_KEY_DIR/server.pub" lock_fd desired
    mkdir -p "$WG_KEY_DIR" "$WG_DIR"
    chmod 700 "$WG_KEY_DIR"
    command -v flock >/dev/null || die "flock required for allocation reconciliation"
    exec {lock_fd}>"$WG_KEY_DIR/setup.lock"
    flock -x "$lock_fd"

    if [[ ! -f "$priv_key" ]]; then
        if [[ "$DEV" == 1 ]]; then
            printf '%s\n' STUB_PRIVATE_KEY > "$priv_key"
            printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQ= > "$pub_key"
        else
            (umask 077; wg genkey > "$priv_key"; wg pubkey < "$priv_key" > "$pub_key")
        fi
        chmod 600 "$priv_key"
    fi
    VPS_WG_PUBKEY="$(cat "$pub_key")"
    VPS_WG_PRIVKEY="$(cat "$priv_key")"

    allocate_phone_ip

    desired="$(mktemp "$WG_DIR/desired.XXXXXX")"
    chmod 600 "$desired"

    if [[ -f "$WG_CONF" ]]; then
        cp "$WG_CONF" "$desired"
        local count old_key
        count="$(peer_block_count "$desired" "$DEVICE_NAME")"
        [[ "$count" -le 1 ]] || die "Duplicate device markers in the WG config"
        if [[ "$count" == 1 ]]; then
            old_key="$(peer_pubkey_for_device "$desired" "$DEVICE_NAME")"
            [[ -n "$old_key" ]] || die "Device marker without a PublicKey"
        fi
        if ! grep -qF "$PHONE_WG_PUBKEY" "$desired"; then
            [[ "$count" == 1 ]] && peer_remove_device "$desired" "$DEVICE_NAME"
            append_peer_block "$desired" "$DEVICE_NAME" "$PHONE_WG_PUBKEY" "$PHONE_WG_IP"
        fi
        # Update only our own Interface fields; keep foreign [Peer] sections intact.
        awk -v key="$VPS_WG_PRIVKEY" -v address="$VPS_WG_SUBNET.1/24" -v port="$WG_PORT" '
          function missing() {
            if(!seen["PrivateKey"]) print "PrivateKey = " key
            if(!seen["Address"])    print "Address = " address
            if(!seen["ListenPort"]) print "ListenPort = " port
            if(!seen["MTU"])        print "MTU = 1280"
          }
          /^\[Interface\]/ { inside=1; print; next }
          /^\[/ && inside   { missing(); inside=0 }
          inside && $1=="PrivateKey"  { if(!seen[$1]++) print "PrivateKey = " key;    next }
          inside && $1=="Address"     { if(!seen[$1]++) print "Address = " address;   next }
          inside && $1=="ListenPort"  { if(!seen[$1]++) print "ListenPort = " port;   next }
          inside && $1=="MTU"         { if(!seen[$1]++) print "MTU = 1280";           next }
          { print }
          END { if(inside) missing() }
        ' "$desired" > "$desired.new" && mv "$desired.new" "$desired"
        reconcile_file "$WG_CONF" 600 < "$desired"
    else
        cat > "$desired" << EOF
[Interface]
PrivateKey = ${VPS_WG_PRIVKEY}
Address = ${VPS_WG_SUBNET}.1/24
ListenPort = ${WG_PORT}
MTU = 1280
EOF
        append_peer_block "$desired" "$DEVICE_NAME" "$PHONE_WG_PUBKEY" "$PHONE_WG_IP"
        reconcile_file "$WG_CONF" 600 < "$desired"
    fi

    rm -f "$desired"
    flock -u "$lock_fd"
    exec {lock_fd}>&-

    if [[ "$DEV" == 1 ]]; then dev "DEV: skipping runtime WG"; return 0; fi

    systemctl enable "wg-quick@${WG_INTERFACE}"
    ip link show "$WG_INTERFACE" &>/dev/null || systemctl restart "wg-quick@${WG_INTERFACE}"
    ip link set "$WG_INTERFACE" up

    desired="$(mktemp "$WG_KEY_DIR/runtime.XXXXXX")"
    chmod 600 "$desired"
    wg-quick strip "$WG_CONF" > "$desired"
    wg syncconf "$WG_INTERFACE" "$desired"
    rm -f "$desired"

    ip address replace "$VPS_WG_SUBNET.1/24" dev "$WG_INTERFACE"
    ip link set "$WG_INTERFACE" mtu 1280
}

# ─────────────────────────────────────────────
# Step 4: wstunnel server
# ─────────────────────────────────────────────

# ─────────────────────────────────────────────
# Domain and certificate
# ─────────────────────────────────────────────

# Loads the saved choice unless this run names a domain (or removes it).
load_tls_state() {
    [[ "$REMOVE_DOMAIN" == 1 || -n "$VPS_DOMAIN" || ! -f "$TLS_STATE" ]] && return 0
    VPS_DOMAIN="$(json_get "$TLS_STATE" domain)"
    TLS_CERT_FILE="$(json_get "$TLS_STATE" cert)"
    TLS_KEY_FILE="$(json_get "$TLS_STATE" key)"
    TLS_SOURCE="$(json_get "$TLS_STATE" source)"
    [[ -z "$VPS_DOMAIN" ]] || validate_domain "$VPS_DOMAIN"
}

save_tls_state() {
    mkdir -p "$WG_KEY_DIR"; chmod 700 "$WG_KEY_DIR"
    if [[ -z "$VPS_DOMAIN" ]]; then rm -f "$TLS_STATE"; return 0; fi
    jq -n --arg domain "$VPS_DOMAIN" --arg cert "$TLS_CERT_FILE" --arg key "$TLS_KEY_FILE" \
        --arg source "$TLS_SOURCE" '{domain: $domain, cert: $cert, key: $key, source: $source}' \
        > "$TLS_STATE.tmp" || die "jq: could not write $TLS_STATE"
    chmod 600 "$TLS_STATE.tmp"; mv "$TLS_STATE.tmp" "$TLS_STATE"
}

# The host clients and phones use to reach this VPS.
vps_public_host() { printf '%s\n' "${VPS_DOMAIN:-$VPS_IP}"; }

# IPv4 addresses DOMAIN resolves to, one per line (mocked in tests).
# getent exits 2 for a name that doesn't resolve; with pipefail that would end
# the whole run silently instead of reaching the "doesn't resolve" message.
resolve_domain() { { getent ahostsv4 "$1" 2>/dev/null || :; } | awk '{print $1}' | sort -u; }

# This machine's own IPv4 addresses (mocked in tests).
local_ipv4s() { { ip -4 -o addr show 2>/dev/null || :; } | awk '{split($4, a, "/"); print a[1]}'; }

# Something already listening on TCP port 80? (mocked in tests)
port80_in_use() { have_cmd ss && ss -Hltn 'sport = :80' 2>/dev/null | grep -q .; }

# The systemd service that holds TCP port 80, if one does (mocked in tests).
port80_service() {
    local pid
    have_cmd ss || return 0
    pid="$(ss -Hltnp 'sport = :80' 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2)"
    [[ -n "$pid" && -r "/proc/$pid/cgroup" ]] || return 0
    sed -n 's|^.*/system\.slice/\([^/]*\.service\)$|\1|p' "/proc/$pid/cgroup" | head -n 1
}

# Programs listening on TCP port 80, for messages.
port80_programs() {
    have_cmd ss || return 0
    ss -Hltnp 'sport = :80' 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | paste -sd, -
}

check_domain_points_here() {
    local addrs a mine
    addrs="$(resolve_domain "$VPS_DOMAIN")"
    if [[ -z "$addrs" ]]; then
        local target="$VPS_IP"
        [[ -n "$target" ]] || target="the public IPv4 of this VPS"
        die "$VPS_DOMAIN doesn't resolve yet.
  Create a DNS A record:  $VPS_DOMAIN -> $target
  then run this again (new records can take a few minutes to appear)."
    fi
    mine="$(local_ipv4s; if [[ "$VPS_IP" =~ ^[0-9.]+$ ]]; then printf '%s\n' "$VPS_IP"; fi)"
    while IFS= read -r a; do
        if grep -qxF -- "$a" <<< "$mine"; then
            ok "$VPS_DOMAIN points to this VPS ($a)"
            return 0
        fi
    done <<< "$addrs"
    warn "$VPS_DOMAIN points to $(paste -sd' ' <<< "$addrs"), which isn't an address of this VPS."
    warn "  If the VPS sits behind NAT this can be fine; otherwise fix the A record first."
}

# Checks that CERT and KEY belong together and that CERT covers VPS_DOMAIN.
check_cert_files() {
    [[ -r "$TLS_CERT_FILE" ]] || die "Certificate not found or not readable: $TLS_CERT_FILE"
    [[ -r "$TLS_KEY_FILE" ]] || die "Private key not found or not readable: $TLS_KEY_FILE"
    grep -q -- '-----BEGIN CERTIFICATE-----' "$TLS_CERT_FILE" || die "$TLS_CERT_FILE is not a PEM certificate"
    grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$TLS_KEY_FILE" || die "$TLS_KEY_FILE is not a PEM private key"
    if have_cmd openssl; then
        local cert_pub key_pub
        cert_pub="$(openssl x509 -in "$TLS_CERT_FILE" -noout -pubkey 2>/dev/null)"
        key_pub="$(openssl pkey -in "$TLS_KEY_FILE" -pubout 2>/dev/null)"
        [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] \
            || die "$TLS_KEY_FILE is not the private key for $TLS_CERT_FILE"
        openssl x509 -in "$TLS_CERT_FILE" -noout -checkhost "$VPS_DOMAIN" 2>/dev/null | grep -q 'does match' \
            || die "$TLS_CERT_FILE is not valid for $VPS_DOMAIN"
        openssl x509 -in "$TLS_CERT_FILE" -noout -checkend 0 > /dev/null 2>&1 \
            || die "$TLS_CERT_FILE has expired"
    else
        warn "openssl not found; can't check that the certificate matches the key and $VPS_DOMAIN"
    fi
}

# Restarts wstunnel after every renewal. wstunnel also reloads changed
# certificate files on its own; the restart is a backstop.
write_renewal_hook() {
    local dir="$LETSENCRYPT_DIR/renewal-hooks/deploy"
    mkdir -p "$dir"
    reconcile_file "$dir/serverinator-wstunnel.sh" 755 << 'EOF'
#!/bin/sh
# Managed by ServerInator: pick up a renewed certificate.
systemctl try-restart wstunnel-serverinator.service
EOF
}

obtain_letsencrypt_cert() {
    local live="$LETSENCRYPT_DIR/live/$VPS_DOMAIN"
    TLS_SOURCE="letsencrypt"
    TLS_CERT_FILE="$live/fullchain.pem"
    TLS_KEY_FILE="$live/privkey.pem"

    if [[ "$DEV" == 1 && -z "${SERVERINATOR_CERTBOT:-}" ]]; then
        dev "DEV: skipping Let's Encrypt for $VPS_DOMAIN"
        return 0
    fi
    check_domain_points_here

    if [[ "$DEV" != 1 ]] && ! have_cmd "$CERTBOT"; then
        info "Installing certbot..."
        apt-get install -y -qq certbot || die "Could not install certbot"
    fi
    # certbot keeps a valid certificate as it is, so re-runs are cheap and
    # don't touch the Let's Encrypt rate limits.
    if [[ -s "$TLS_CERT_FILE" ]] && have_cmd openssl \
        && openssl x509 -in "$TLS_CERT_FILE" -noout -checkend $((30 * 86400)) > /dev/null 2>&1; then
        info "Certificate for $VPS_DOMAIN is valid for at least 30 more days, keeping it"
    else
        # A web server already on port 80 (say Caddy) is paused for the few
        # seconds of each check. certbot saves the hooks, so renewals do the same.
        local pause=""
        if port80_in_use; then
            pause="$(port80_service)"
            if [[ ! "$pause" =~ ^[A-Za-z0-9@._-]+\.service$ ]]; then
                local who
                who="$(port80_programs)"
                die "Something already listens on TCP port 80${who:+ ($who)}, which Let's Encrypt needs for a moment to check the domain.
  See it with: ss -ltnp 'sport = :80'
  It isn't a systemd service, so it can't be paused automatically. Stop it
  during setup, or bring your own certificate:
    --tls-cert /path/fullchain.pem --tls-key /path/privkey.pem"
            fi
            warn "Port 80 is used by $pause. It will be stopped for the few seconds"
            warn "  Let's Encrypt needs, now and at each renewal, and started again right after."
        fi
        [[ "$DEV" == 1 ]] || check_firewall 80 "Let's Encrypt needs to reach while it checks the domain (and at every renewal)"
        local -a args=(certonly --standalone --non-interactive --agree-tos --keep-until-expiring
                       --preferred-challenges http -d "$VPS_DOMAIN" --cert-name "$VPS_DOMAIN")
        [[ -z "$pause" ]] || args+=(--pre-hook "systemctl stop $pause" --post-hook "systemctl start $pause")
        if [[ -n "$ACME_EMAIL" ]]; then args+=(--email "$ACME_EMAIL"); else args+=(--register-unsafely-without-email); fi
        info "Requesting a Let's Encrypt certificate for $VPS_DOMAIN..."
        "$CERTBOT" "${args[@]}" || die "certbot could not get a certificate for $VPS_DOMAIN (see the output above).
  Usual causes: the A record points elsewhere, or port 80 is blocked by a firewall."
    fi
    [[ -s "$TLS_CERT_FILE" && -s "$TLS_KEY_FILE" ]] || die "certbot finished but $live has no certificate"
    write_renewal_hook
    ok "Certificate for $VPS_DOMAIN: $TLS_CERT_FILE"
}

# Fills TLS_* for VPS_DOMAIN (or clears them). Called by setup and --set-domain.
setup_tls() {
    load_tls_state
    if [[ "$REMOVE_DOMAIN" == 1 || -z "$VPS_DOMAIN" ]]; then
        VPS_DOMAIN=""; TLS_CERT_FILE=""; TLS_KEY_FILE=""; TLS_SOURCE=""
        save_tls_state
        info "No domain: wstunnel uses its built-in self-signed certificate"
        return 0
    fi
    if [[ -n "$TLS_CERT_FILE" && "$TLS_SOURCE" != letsencrypt ]]; then
        TLS_SOURCE="custom"
        check_cert_files
        info "Using your certificate for $VPS_DOMAIN: $TLS_CERT_FILE"
    else
        obtain_letsencrypt_cert
    fi
    save_tls_state
}

# Points every device record at the current domain (or back at the IP) and
# rewrites the client scripts that the VPS can regenerate.
refresh_devices_for_domain() {
    local dev record tmp
    for dev in $(device_names); do
        record="$(device_record_path "$dev")"
        tmp="$(mktemp "${record}.XXXXXX")"; chmod 600 "$tmp"
        jq --arg d "$VPS_DOMAIN" 'if $d == "" then del(.vps_domain) else . + {vps_domain: $d} end' \
            "$record" > "$tmp" || { rm -f "$tmp"; die "jq: could not update $record"; }
        mv "$tmp" "$record"
        ( SELECTED_DEVICE="$dev"; regenerate_client_scripts ) \
            || warn "Could not rewrite the client scripts for $dev; re-run its install to refresh them"
    done
}

# Rewrites the owner's and every --add-client script for SELECTED_DEVICE.
regenerate_client_scripts() {
    local domain="$VPS_DOMAIN"
    _load_phone_state > /dev/null
    VPS_DOMAIN="$domain"
    local owner_alias="$SSH_ALIAS" key label f n=0
    if [[ -f "$SSH_KEY_DIR/client-setup-owner-${DEVICE_NAME}.sh" ]]; then
        key="$SSH_KEY_DIR/owner_${DEVICE_NAME}"
        _write_client_setup_script "$SSH_KEY_DIR/client-setup-owner-${DEVICE_NAME}.sh" "$owner_alias" \
            "si-${DEVICE_NAME}" "$([[ -f "$key" ]] && echo 1 || echo 0)" "$key"
        n=$((n + 1))
    fi
    for f in "$SSH_KEY_DIR"/client-setup-*-"${DEVICE_NAME}".sh; do
        [[ -e "$f" ]] || continue
        label="${f##*/client-setup-}"; label="${label%-"${DEVICE_NAME}".sh}"
        [[ "$label" != owner ]] || continue
        [[ -f "$SSH_KEY_DIR/owner_${DEVICE_NAME}_${label}" ]] || continue
        _write_client_setup_script "$f" "${owner_alias}-${label}" "si-${DEVICE_NAME}-${label}" 1 \
            "$SSH_KEY_DIR/owner_${DEVICE_NAME}_${label}"
        n=$((n + 1))
    done
    info "$DEVICE_NAME: rewrote $n client script(s)"
}

set_domain() {
    have_cmd jq || die "Install jq: apt-get install jq"
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--set-domain needs root"
    # VPS_IP for the DNS check and the IP fallback: from any device record.
    local first
    first="$(device_names | head -n 1)"
    [[ -z "$first" ]] || VPS_IP="$(json_get "$(device_record_path "$first")" vps_ip)"
    setup_tls
    setup_wstunnel_server
    refresh_devices_for_domain
    if [[ -n "$VPS_DOMAIN" ]]; then
        local label="your own"
        [[ "$TLS_SOURCE" != letsencrypt ]] || label="a Let's Encrypt"
        ok "The tunnel now serves $label certificate for $VPS_DOMAIN"
    else
        ok "The tunnel is back on the built-in self-signed certificate"
    fi
    echo ""
    echo "  Phones keep working as they are. To switch each phone over, run on it:"
    if [[ -n "$VPS_DOMAIN" ]]; then
        echo "    bash serverinator.sh --set-domain $VPS_DOMAIN"
    else
        echo "    bash serverinator.sh --remove-domain"
    fi
    echo "  Existing ssh setups keep working through the IP. The client scripts on"
    echo "  the VPS now use $(vps_public_host) as the jump host for new machines."
}

setup_wstunnel_server() {
    local svc="$SYSTEMD_DIR/wstunnel-serverinator.service"
    mkdir -p "$SYSTEMD_DIR"
    local desired tls_lines=""
    if [[ -n "$VPS_DOMAIN" ]]; then
        tls_lines="    --tls-certificate ${TLS_CERT_FILE} \\
    --tls-private-key ${TLS_KEY_FILE} \\
"
    fi
    desired="$(mktemp "$SYSTEMD_DIR/unit.XXXXXX")"
    cat > "$desired" << EOF
[Unit]
Description=wstunnel server for ServerInator
After=network.target

[Service]
ExecStart=${WSTUNNEL_BIN} server \\
    --log-lvl INFO \\
    --restrict-to ${WG_RESTRICT_TARGET} \\
${tls_lines}    wss://0.0.0.0:${WSTUNNEL_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    reconcile_file "$svc" 644 < "$desired"
    rm -f "$desired"

    if [[ "$DEV" == "1" ]]; then dev "DEV: skipping systemctl"; return 0; fi

    require_cmd systemctl
    systemctl daemon-reload
    systemctl enable --now wstunnel-serverinator
    [[ "$RECONCILED_CHANGED" == 1 ]] && systemctl restart wstunnel-serverinator
    info "wstunnel server started"
}

# ─────────────────────────────────────────────
# Step 4 (optional): MSS clamp
# ─────────────────────────────────────────────

fix_pmtu_clamp() {
    if [[ "${SERVERINATOR_SKIP_MSS:-1}" != "0" ]]; then
        dev "MSS clamp disabled by default (set SERVERINATOR_SKIP_MSS=0 to enable)"
        return 0
    fi

    require_cmd iptables
    validate_tunnel_port "$WSTUNNEL_PORT"

    local receipt_dir="$WG_KEY_DIR/mss-owned"
    mkdir -p "$receipt_dir"
    local receipt="$receipt_dir/${WSTUNNEL_PORT}"

    if [[ -f "$receipt" ]]; then
        info "MSS clamp already set for port $WSTUNNEL_PORT"
        return 0
    fi

    # An equivalent rule without our ownership tag already covers this port —
    # leave it alone (not ours to claim) and don't add a redundant duplicate.
    local rc=0
    iptables -t mangle -C OUTPUT -p tcp --sport "$WSTUNNEL_PORT" \
        --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500 2>/dev/null || rc=$?
    if [[ "$rc" == 0 ]]; then
        warn "An equivalent MSS rule for port $WSTUNNEL_PORT already exists without our tag — leaving it alone"
        return 0
    fi

    rc=0
    iptables -t mangle -C OUTPUT -p tcp --sport "$WSTUNNEL_PORT" \
        --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss \
        -j TCPMSS --set-mss 500 2>/dev/null || rc=$?

    if [[ "$rc" == 1 ]]; then
        iptables -t mangle -A OUTPUT -p tcp --sport "$WSTUNNEL_PORT" \
            --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss \
            -j TCPMSS --set-mss 500
        info "MSS clamp added for port $WSTUNNEL_PORT"
    fi

    printf '%s\n' "$WSTUNNEL_PORT" > "$receipt"

    if [[ -f "$IPTABLES_RULES_PATH" ]]; then
        local saved
        saved="$(mktemp)"
        iptables-save > "$saved" || { rm -f "$saved"; die "iptables-save failed"; }
        reconcile_file "$IPTABLES_RULES_PATH" 600 < "$saved"
        rm -f "$saved"
        info "iptables-save updated"
    else
        warn "File $IPTABLES_RULES_PATH not found — the rule is not persistent"
    fi
}

# ─────────────────────────────────────────────
# Step 5: SSH keys
# ─────────────────────────────────────────────

# The VPS admin's home directory (whose authorized_keys we read, and whose
# authorized_keys we write restricted jump entries into).
_vps_user_home() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        echo "${SERVERINATOR_VPS_ADMIN_HOME:-/root}"
    fi
}

# Builds the authorized_keys line for a jump key: NEITHER port-forwarding
# NOR restrict on their own block exec/shell (restrict only disables
# pty/agent/X11-forwarding and ~/.ssh/rc) — an explicit command= is
# mandatory, otherwise the key gets a full shell on the VPS.
_vps_jump_key_line() {
    local pub="$1" phone_ip="$2" phone_port="$3"
    printf 'command="echo '\''ServerInator: forwarding-only key, no shell access'\''; exit 1",restrict,port-forwarding,permitopen="%s:%s" %s' \
        "$phone_ip" "$phone_port" "$pub"
}

# Adds a restricted entry to the VPS admin's authorized_keys — only
# port-forwarding to the phone's specific address, no shell. Needed because
# ProxyJump with a freshly-generated key (which is not yet in the VPS's
# authorized_keys) would otherwise fail at the jump host.
_authorize_vps_jump_key() {
    local pub="$1" phone_ip="$2" phone_port="$3" user_home auth_file line
    user_home="$(_vps_user_home)" || die "Could not get the VPS admin's home directory"
    [[ -n "$user_home" ]] || die "Empty home directory for the VPS admin"
    auth_file="$user_home/.ssh/authorized_keys"
    mkdir -p "$user_home/.ssh"
    chmod 700 "$user_home/.ssh"
    touch "$auth_file"
    chmod 600 "$auth_file"
    line="$(_vps_jump_key_line "$pub" "$phone_ip" "$phone_port")"
    grep -qFx -- "$line" "$auth_file" || printf '%s\n' "$line" >> "$auth_file"
}

# Removes the jump entry added by _authorize_vps_jump_key for this key.
_revoke_vps_jump_key() {
    local pub="$1" phone_ip="$2" phone_port="$3" user_home auth_file line
    user_home="$(_vps_user_home)" || die "Could not get the VPS admin's home directory"
    auth_file="$user_home/.ssh/authorized_keys"
    [[ -f "$auth_file" ]] || return 0
    line="$(_vps_jump_key_line "$pub" "$phone_ip" "$phone_port")"
    local tmp rc=0
    tmp="$(mktemp "${auth_file}.XXXXXX")" || die "Could not create a temp file next to $auth_file"
    # grep -v exits 1 when no lines remain; that is a valid (empty) result.
    grep -vFx -- "$line" "$auth_file" > "$tmp" || rc=$?
    if [[ "$rc" -gt 1 ]]; then rm -f "$tmp"; die "Could not rewrite $auth_file"; fi
    chmod 600 "$tmp"
    chown --reference="$auth_file" "$tmp" 2>/dev/null || true
    mv "$tmp" "$auth_file" || { rm -f "$tmp"; die "Could not replace $auth_file"; }
}

setup_vps_ssh_keys() {
    if [[ "$SSH_ENABLED" != "1" ]]; then
        info "SSH is not enabled on the phone — skipping"
        return 0
    fi

    SSH_VPS_USER="${SUDO_USER:-$(id -un)}"
    mkdir -p "$SSH_KEY_DIR" || die "Could not create $SSH_KEY_DIR"
    chmod 700 "$SSH_KEY_DIR"

    # VPS -> phone key (automation / emergency access)
    local vk="$SSH_KEY_DIR/vps_to_phone"
    if [[ ! -f "$vk" ]]; then
        require_cmd ssh-keygen
        ssh-keygen -t ed25519 -N '' -C "serverinator-vps-${DEVICE_NAME}" -f "$vk" >/dev/null
        chmod 600 "$vk"
        info "Generated VPS->phone key"
    else
        info "VPS->phone key already exists"
    fi
    SSH_VPS_TO_PHONE_PUBKEY="$(cat "$vk.pub")"

    # Owner client keys — read from the VPS user's authorized_keys
    local user_home
    user_home="$(_vps_user_home)" || die "Could not get the VPS admin's home directory"
    local auth_file="$user_home/.ssh/authorized_keys"

    local found=() line
    if [[ -f "$auth_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ -z "$line" || "$line" == \#* ]] && continue
            if is_plain_pubkey "$line"; then
                found+=("$line")
            else
                warn "Skipping a line in authorized_keys (options/not a key): ${line:0:50}..."
            fi
        done < "$auth_file"
        info "Found ${#found[@]} key(s) in $auth_file"
    else
        warn "authorized_keys not found: $auth_file"
    fi

    # By default we always generate our own owner key — it needs to be
    # portable to any of the owner's devices (Linux/Termux) via
    # client-setup-owner-*.sh, not dependent on whatever is already sitting
    # in this VPS's authorized_keys. --client-keys existing remains an
    # explicit opt-in.
    local mode="${CLIENT_KEYS_MODE:-new}"

    if [[ "$mode" == "existing" && "${#found[@]}" -gt 0 ]]; then
        SSH_CLIENT_KEYS=("${found[@]}")
        SSH_CLIENT_KEY_IS_NEW=0
        info "Using ${#SSH_CLIENT_KEYS[@]} existing key(s)"
        local k fp
        for k in "${SSH_CLIENT_KEYS[@]}"; do
            fp="$(ssh_key_fingerprint "$k")"
            info "  -> ${fp:0:80}"
        done
    else
        require_cmd ssh-keygen
        local ck="$SSH_KEY_DIR/owner_${DEVICE_NAME}"
        if [[ ! -f "$ck" ]]; then
            ssh-keygen -t ed25519 -N '' \
                -C "serverinator:owner:${DEVICE_NAME}" -f "$ck" >/dev/null
            chmod 600 "$ck"
            info "Generated a new client key: $ck"
        else
            info "Client key already exists: $ck"
        fi
        SSH_CLIENT_KEYS=("$(cat "$ck.pub")")
        SSH_CLIENT_KEY_IS_NEW=1
        # The new key is not in the VPS's authorized_keys, so ProxyJump with
        # it would fail at the jump host without a restricted jump entry.
        _authorize_vps_jump_key "${SSH_CLIENT_KEYS[0]}" "$PHONE_WG_IP" "$SSH_PHONE_PORT"
    fi
}

# ─────────────────────────────────────────────
# Host keys (review #13)
# ─────────────────────────────────────────────
#
# The phone's handoff carries its ed25519 host key. The VPS pins it for its
# own connections, and client scripts pin both it and the VPS's host key,
# so no connection has to trust whatever answers first.

# Checks the handoff's host key: a plain ed25519 key that matches the
# fingerprint shown on the phone. Older phones send none, which is allowed.
validate_phone_host_key() {
    [[ -n "${SSH_HOST_PUBKEY:-}" ]] || return 0
    is_plain_pubkey "$SSH_HOST_PUBKEY" && [[ "$SSH_HOST_PUBKEY" == "ssh-ed25519 "* ]] \
        || die "handoff.json: ssh_host_pubkey is not an ed25519 public key"
    if [[ -n "${SSH_HOST_FINGERPRINT:-}" ]] && have_cmd ssh-keygen; then
        local fp
        fp="$(ssh_key_fingerprint "$SSH_HOST_PUBKEY")"
        [[ "$fp" == *"$SSH_HOST_FINGERPRINT"* ]] \
            || die "handoff.json: ssh_host_pubkey doesn't match ssh_host_fingerprint"
    fi
}

phone_known_hosts_file() { printf '%s/known_hosts_%s\n' "$SSH_KEY_DIR" "$1"; }

# phone_hostkey_opts DEVICE PUBKEY — fills the caller's `opts` array.
# With a pinned key: strict checking against a file holding only that key.
# Without one (a phone set up before pinning): trust on first use, but in a
# per-phone file so one phone's key can't stand in for another's.
phone_hostkey_opts() {
    local device="$1" pubkey="$2" file
    file="$(phone_known_hosts_file "$device")"
    if [[ -n "$pubkey" ]]; then
        printf 'serverinator-%s %s\n' "$device" "$pubkey" > "$file"
        chmod 600 "$file"
        opts=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$file" -o "HostKeyAlias=serverinator-$device")
    else
        opts=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$file")
    fi
}

# The VPS's own ed25519 host key (type and key), for the clients' jump hop.
vps_host_pubkey() {
    local f="${SERVERINATOR_VPS_HOSTKEY_FILE:-/etc/ssh/ssh_host_ed25519_key.pub}" key
    [[ -r "$f" ]] || return 0
    key="$(awk '{print $1" "$2; exit}' "$f")"
    is_plain_pubkey "$key" && printf '%s\n' "$key"
}

# ─────────────────────────────────────────────
# Step 5: Generate client-setup.sh
# ─────────────────────────────────────────────

# _write_client_setup_script OUT_FILE ALIAS SI_NAME IS_NEW KEY_FILE
#   OUT_FILE  — where to write the generated script
#   ALIAS     — SSH Host alias in the client's ~/.ssh/config
#   SI_NAME   — local identity filename on the client (~/.ssh/SI_NAME)
#   IS_NEW    — 1 if we generated the key (embed the private key)
#   KEY_FILE  — path to the private key on the VPS (only needed if IS_NEW=1)
# Uses the globals DEVICE_NAME, VPS_IP, SSH_VPS_USER, PHONE_WG_IP,
# SSH_PHONE_PORT, SSH_USER — populated either by read_handoff+setup, or by
# _load_phone_state (--add-client/--revoke-client).
_write_client_setup_script() {
    local out="$1" alias="$2" si_name="$3" is_new="$4" key_file="$5"
    local vhost; vhost="$(vps_public_host)"
    local jump="${SSH_VPS_USER}@${vhost}"
    local created
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Private-key section (only if we generated it ourselves)
    local key_lines=""
    if [[ "$is_new" == "1" ]]; then
        local b64
        b64="$(base64 -w 0 "$key_file")"
        key_lines="$(printf '%s\n' \
            "# Installing the private key (original on the VPS: $key_file)" \
            "KEY=\"\$HOME/.ssh/${si_name}\"" \
            "if [[ ! -f \"\$KEY\" ]]; then" \
            "    printf '%s' '${b64}' | base64 -d > \"\$KEY\"" \
            "    chmod 600 \"\$KEY\"" \
            "    echo \"Key installed: \$KEY\"" \
            "else" \
            "    echo \"Key already present: \$KEY — skipping\"" \
            "fi" \
            "")"
    fi

    # IdentityFile line (empty if the user already had their own key)
    local id_line=""
    [[ "$is_new" == "1" ]] \
        && id_line=$'\n'"    IdentityFile ~/.ssh/${si_name}"

    # For a NEW key, a separate Host block for the VPS itself: ProxyJump
    # matches ssh_config again against the jump host, not against the
    # destination block — without this block, a new key (not originally in
    # the VPS's authorized_keys) would never be offered at the jump host.
    # The VPS already has a restricted entry for it (port-forwarding to the
    # phone only, no shell).
    local jump_host_lines=""
    if [[ "$is_new" == "1" ]]; then
        jump_host_lines="$(printf '%s\n' \
            "if grep -q \"^Host ${vhost}\$\" \"\$CONFIG\" 2>/dev/null; then" \
            "    echo \"Host ${vhost} is already in \$CONFIG — skipping\"" \
            "else" \
            "    printf '\\nHost ${vhost}\\n' >> \"\$CONFIG\"" \
            "    printf '    User ${SSH_VPS_USER}\\n' >> \"\$CONFIG\"" \
            "    printf '    IdentityFile ~/.ssh/${si_name}\\n' >> \"\$CONFIG\"" \
            "    echo \"Host ${vhost} (ProxyJump only) added to \$CONFIG\"" \
            "fi" \
            "")"
    fi

    # Host keys to pin on the client: the phone's under the alias name
    # (HostKeyAlias, so phones on different VPSes that share a tunnel IP
    # don't collide), and the VPS's under its address for the jump hop.
    local hka_line="" known_hosts_lines="" vps_key entry entries=()
    if [[ -n "${SSH_HOST_PUBKEY:-}" ]]; then
        hka_line="    printf '    HostKeyAlias ${alias}\\n' >> \"\$CONFIG\""$'\n'
        entries+=("${alias} ${SSH_HOST_PUBKEY}")
    fi
    vps_key="$(vps_host_pubkey)"
    [[ -z "$vps_key" ]] || entries+=("${vhost} ${vps_key}")
    if (( ${#entries[@]} )); then
        known_hosts_lines="KNOWN=\"\$HOME/.ssh/known_hosts\""$'\n'"touch \"\$KNOWN\" && chmod 600 \"\$KNOWN\""
        for entry in "${entries[@]}"; do
            known_hosts_lines+=$'\n'"grep -qxF '${entry}' \"\$KNOWN\" || { echo '${entry}' >> \"\$KNOWN\"; echo \"Pinned host key for ${entry%% *}\"; }"
        done
    fi

    # Generate the script. Values are substituted NOW (at generation time).
    # \$ and \$HOME below are literal $ for runtime expansion inside the
    # generated script.
    cat > "$out" << SETUP_EOF
#!/usr/bin/env bash
# ServerInator — client access to ${DEVICE_NAME}
# Alias: ${alias}   VPS: ${VPS_IP}   Created: ${created}
#
# Run this on the client device (bash; works out of the box on Linux/Termux;
# on Windows run the .ps1 next to this file instead):
#   bash $(basename "$out")
set -euo pipefail
echo "Setting up SSH access to ${DEVICE_NAME} (alias: ${alias})..."
mkdir -p "\$HOME/.ssh" && chmod 700 "\$HOME/.ssh"

${key_lines}
CONFIG="\$HOME/.ssh/config"
touch "\$CONFIG" && chmod 600 "\$CONFIG"

if grep -q "^Host ${alias}\$" "\$CONFIG" 2>/dev/null; then
    echo "Alias '${alias}' is already in \$CONFIG — skipping"
else
    printf '\\nHost ${alias}\\n' >> "\$CONFIG"
    printf '    HostName ${PHONE_WG_IP}\\n' >> "\$CONFIG"
    printf '    Port ${SSH_PHONE_PORT}\\n' >> "\$CONFIG"
    printf '    User ${SSH_USER}\\n' >> "\$CONFIG"
    printf '    ${id_line:+IdentityFile ~/.ssh/${si_name}\\n}' >> "\$CONFIG"
    printf '    ProxyJump ${jump}\\n' >> "\$CONFIG"
${hka_line}    printf '    ServerAliveInterval 60\\n' >> "\$CONFIG"
    printf '    ServerAliveCountMax 9999\\n' >> "\$CONFIG"
    echo "Alias '${alias}' added to ~/.ssh/config"
fi

${jump_host_lines}
${known_hosts_lines}
echo ""
echo "Done. Connect with:  ssh ${alias}"
SETUP_EOF

    chmod 600 "$out"
    _write_client_setup_ps1 "${out%.sh}.ps1" "$alias" "$si_name" "$is_new" "$key_file" "${entries[@]+"${entries[@]}"}"
}

# _write_client_setup_ps1 OUT_FILE ALIAS SI_NAME IS_NEW KEY_FILE [KNOWN_HOSTS_ENTRY...]
# The same setup as the bash script, for Windows PowerShell 5.1+ with the
# built-in OpenSSH client. Kept to plain ASCII: PowerShell 5 reads a script
# without a BOM as ANSI. Every substituted value is already validated
# (host, alias, device name, base64), and none can contain a single quote.
_write_client_setup_ps1() {
    local out="$1" alias="$2" si_name="$3" is_new="$4" key_file="$5"; shift 5
    local vhost; vhost="$(vps_public_host)"
    local jump="${SSH_VPS_USER}@${vhost}" created entry b64=""
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ "$is_new" == "1" ]] && b64="$(base64 -w 0 "$key_file")"

    {
        cat << PS1_EOF
# ServerInator - client access to ${DEVICE_NAME} (Windows)
# Alias: ${alias}   VPS: ${VPS_IP}   Created: ${created}
#
# Run in PowerShell on the Windows machine:
#   powershell -ExecutionPolicy Bypass -File .\\$(basename "$out")
# Needs the OpenSSH client (Settings > Apps > Optional features > OpenSSH Client).
\$ErrorActionPreference = 'Stop'
Write-Host 'Setting up SSH access to ${DEVICE_NAME} (alias: ${alias})...'
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Warning 'ssh was not found. Install the OpenSSH Client: Settings > Apps > Optional features.'
}
\$SshDir = Join-Path \$env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Force -Path \$SshDir | Out-Null

# Appends LINES to FILE (LF endings, no BOM), starting on a fresh line.
function Add-Lines([string]\$File, [string[]]\$Lines) {
    \$prefix = ''
    if ((Test-Path \$File) -and (Get-Item \$File).Length -gt 0) {
        \$last = [IO.File]::ReadAllBytes(\$File)[-1]
        if (\$last -ne 10) { \$prefix = "\`n" }
    }
    [IO.File]::AppendAllText(\$File, \$prefix + ((\$Lines -join "\`n") + "\`n"))
}
function Test-Line([string]\$File, [string]\$Line) {
    if (-not (Test-Path \$File)) { return \$false }
    foreach (\$l in [IO.File]::ReadAllLines(\$File)) { if (\$l -ceq \$Line) { return \$true } }
    return \$false
}
PS1_EOF
        if [[ "$is_new" == "1" ]]; then
            cat << PS1_EOF

# Installing the private key (original on the VPS: ${key_file})
\$Key = Join-Path \$SshDir '${si_name}'
if (-not (Test-Path \$Key)) {
    [IO.File]::WriteAllBytes(\$Key, [Convert]::FromBase64String('${b64}'))
    if (\$IsLinux -or \$IsMacOS) {
        chmod 600 \$Key
    } else {
        # OpenSSH for Windows refuses a key that anyone but its owner can read.
        \$Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        icacls \$Key /inheritance:r /grant:r "*\${Sid}:F" | Out-Null
    }
    Write-Host "Key installed: \$Key"
} else {
    Write-Host "Key already present: \$Key - skipping"
}
PS1_EOF
        fi
        cat << PS1_EOF

\$Config = Join-Path \$SshDir 'config'
if (Test-Line \$Config 'Host ${alias}') {
    Write-Host "Alias '${alias}' is already in \$Config - skipping"
} else {
    \$block = @('', 'Host ${alias}', '    HostName ${PHONE_WG_IP}', '    Port ${SSH_PHONE_PORT}', '    User ${SSH_USER}')
PS1_EOF
        [[ "$is_new" == "1" ]] && echo "    \$block += '    IdentityFile ~/.ssh/${si_name}'"
        echo "    \$block += '    ProxyJump ${jump}'"
        [[ -n "${SSH_HOST_PUBKEY:-}" ]] && echo "    \$block += '    HostKeyAlias ${alias}'"
        cat << PS1_EOF
    \$block += @('    ServerAliveInterval 60', '    ServerAliveCountMax 9999')
    Add-Lines \$Config \$block
    Write-Host "Alias '${alias}' added to \$Config"
}
PS1_EOF
        if [[ "$is_new" == "1" ]]; then
            cat << PS1_EOF

if (Test-Line \$Config 'Host ${vhost}') {
    Write-Host "Host ${vhost} is already in \$Config - skipping"
} else {
    Add-Lines \$Config @('', 'Host ${vhost}', '    User ${SSH_VPS_USER}', '    IdentityFile ~/.ssh/${si_name}')
    Write-Host 'Host ${vhost} (ProxyJump only) added to config'
}
PS1_EOF
        fi
        if (( $# )); then
            echo ""
            echo "\$Known = Join-Path \$SshDir 'known_hosts'"
            for entry in "$@"; do
                echo "if (-not (Test-Line \$Known '${entry}')) { Add-Lines \$Known @('${entry}'); Write-Host 'Pinned host key for ${entry%% *}' }"
            done
        fi
        cat << PS1_EOF

Write-Host ''
Write-Host 'Done. Connect with:  ssh ${alias}'
PS1_EOF
    } > "$out"
    chmod 600 "$out"
}

generate_client_setup() {
    [[ "$SSH_ENABLED" == "1" ]] || return 0

    local f="$SSH_KEY_DIR/client-setup-owner-${DEVICE_NAME}.sh"
    _write_client_setup_script "$f" "$SSH_ALIAS" "si-${DEVICE_NAME}" \
        "$SSH_CLIENT_KEY_IS_NEW" "$SSH_KEY_DIR/owner_${DEVICE_NAME}"
    info "Client script: $f"
    OWNER_CLIENT_SETUP_PATH="$f"
}

# One-line command to fetch a root-only file from this VPS onto another
# device and run it: scp as root, or `sudo cat` for a sudo user.
fetch_hint() { # PATH
    local name="${1##*/}" user="${SSH_VPS_USER:-root}"
    if [[ "$user" == root ]]; then
        printf '%s' "scp root@${VPS_IP}:$1 . && bash $name"
    else
        printf '%s' "ssh ${user}@${VPS_IP} 'sudo cat $1' > $name && bash $name"
    fi
}

# The same for Windows PowerShell, fetching the .ps1 next to PATH (.sh).
fetch_hint_windows() { # PATH
    local path="${1%.sh}.ps1" user="${SSH_VPS_USER:-root}"
    local name="${path##*/}"
    if [[ "$user" == root ]]; then
        printf '%s' "scp root@${VPS_IP}:$path . ; powershell -ExecutionPolicy Bypass -File .\\$name"
    else
        printf '%s' "ssh ${user}@${VPS_IP} 'sudo cat $path' > $name ; powershell -ExecutionPolicy Bypass -File .\\$name"
    fi
}

# ─────────────────────────────────────────────
# --add-client / --revoke-client
# ─────────────────────────────────────────────
#
# Add/revoke a separate, independently-named client after installation —
# using the VPS->phone channel (vps_to_phone), which holds a live
# root-capable connection to the phone over the already-up tunnel.
# Root access only for now; access levels are the next step.

# Restores DEVICE_NAME/VPS_IP/PHONE_WG_IP/SSH_USER/SSH_PHONE_PORT/
# SSH_VPS_USER from the state saved during the last full install
# (generate_back_handoff). --add-client/--revoke-client don't go through
# read_handoff, so this is the only source for this data.
_load_phone_state() {
    select_device
    local state="$DEVICE_RECORD"

    DEVICE_NAME="$(json_get "$state" device_name)"
    VPS_IP="$(json_get "$state" vps_ip)"
    PHONE_WG_IP="$(json_get "$state" ssh_phone_ip)"
    SSH_USER="$(json_get "$state" ssh_user)"; SSH_USER="${SSH_USER:-root}"
    SSH_PHONE_PORT="$(json_get_num "$state" ssh_port)"; SSH_PHONE_PORT="${SSH_PHONE_PORT:-22}"
    SSH_VPS_USER="$(json_get "$state" ssh_vps_user)"; SSH_VPS_USER="${SSH_VPS_USER:-$(id -un)}"
    SSH_HOST_PUBKEY="$(json_get "$state" ssh_host_pubkey)"
    SSH_HOST_FINGERPRINT="$(json_get "$state" ssh_host_fingerprint)"
    load_tls_state
    # The alias chosen at install time names the per-client aliases too
    # (ALIAS-LABEL). An explicit --alias still wins.
    if [[ -z "$SSH_ALIAS" ]]; then
        SSH_ALIAS="$(json_get "$state" ssh_alias)"
        [[ -z "$SSH_ALIAS" ]] || validate_ssh_alias "$SSH_ALIAS"
    fi
    local ssh_enabled
    ssh_enabled="$(json_get_num "$state" ssh_enabled)"

    [[ -n "$DEVICE_NAME" ]] || die "$state: missing device_name"
    validate_device_name "$DEVICE_NAME"
    [[ "$state" == "$(device_record_path "$DEVICE_NAME")" ]] || die "$state names device '$DEVICE_NAME'"
    [[ -n "$VPS_IP" ]] || die "$state: missing vps_ip"
    validate_host "$VPS_IP"
    [[ "$ssh_enabled" == "1" ]] \
        || die "SSH was not enabled when the phone was set up — cannot add clients"
    [[ -n "$PHONE_WG_IP" ]] || die "$state: missing ssh_phone_ip"
    validate_ipv4 "$PHONE_WG_IP" "phone WG IPv4"
    validate_port "$SSH_PHONE_PORT"
    validate_phone_host_key
}

# Runs a command on the phone over the up tunnel, using the VPS->phone key.
_phone_ssh() {
    local vps_key="$SSH_KEY_DIR/vps_to_phone"
    [[ -f "$vps_key" ]] || die "VPS->phone key not found ($vps_key)"
    local opts=()
    phone_hostkey_opts "$DEVICE_NAME" "$SSH_HOST_PUBKEY"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${opts[@]}" \
        -i "$vps_key" -p "$SSH_PHONE_PORT" "${SSH_USER}@${PHONE_WG_IP}" "$@"
}

add_client() {
    _load_phone_state

    local ck="$SSH_KEY_DIR/owner_${DEVICE_NAME}_${CLIENT_LABEL}"
    [[ ! -f "$ck" ]] \
        || die "Client '${CLIENT_LABEL}' already exists (key $ck) — run --revoke-client ${CLIENT_LABEL} first if you want to replace it"

    require_cmd ssh-keygen
    ssh-keygen -t ed25519 -N '' \
        -C "serverinator:client:${DEVICE_NAME}:${CLIENT_LABEL}" -f "$ck" >/dev/null
    chmod 600 "$ck"

    local pub
    pub="$(cat "$ck.pub")"
    printf '%s\n' "$pub" | _phone_ssh '
        set -e
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        key="$(cat)"
        grep -qFx -- "$key" ~/.ssh/authorized_keys || printf "%s\n" "$key" >> ~/.ssh/authorized_keys
    ' || { rm -f "$ck" "$ck.pub"; die "Could not add the client key on the phone — is the tunnel up?"; }

    # This key is not in the VPS's authorized_keys, so ProxyJump with it
    # would fail at the jump host without a restricted jump entry.
    _authorize_vps_jump_key "$pub" "$PHONE_WG_IP" "$SSH_PHONE_PORT"

    info "Client '${CLIENT_LABEL}' added on the phone"

    local f="$SSH_KEY_DIR/client-setup-${CLIENT_LABEL}-${DEVICE_NAME}.sh"
    _write_client_setup_script "$f" "${SSH_ALIAS:-$SSH_ALIAS_DEFAULT}-${CLIENT_LABEL}" \
        "si-${DEVICE_NAME}-${CLIENT_LABEL}" 1 "$ck"

    echo ""
    echo "  Client script for '${CLIENT_LABEL}': $f"
    echo "  To connect from that device:"
    echo "    $(fetch_hint "$f")"
    echo "  From Windows (PowerShell):"
    echo "    $(fetch_hint_windows "$f")"
    echo ""
}

revoke_client() {
    _load_phone_state

    local ck="$SSH_KEY_DIR/owner_${DEVICE_NAME}_${CLIENT_LABEL}"
    [[ -f "$ck.pub" ]] || die "Client '${CLIENT_LABEL}' not found (no file $ck.pub)"
    local pub
    pub="$(cat "$ck.pub")"

    local removed
    removed="$(printf '%s\n' "$pub" | _phone_ssh '
        set -e
        [ -f ~/.ssh/authorized_keys ] || { echo 0; exit 0; }
        key="$(cat)"
        before=$(grep -cFx -- "$key" ~/.ssh/authorized_keys || true)
        tmp=$(mktemp ~/.ssh/authorized_keys.XXXXXX)
        grep -vFx -- "$key" ~/.ssh/authorized_keys > "$tmp" || [ $? -eq 1 ]
        chmod 600 "$tmp"
        mv "$tmp" ~/.ssh/authorized_keys
        echo "$before"
    ')" || die "Could not revoke the client key on the phone — is the tunnel up?"

    if [[ "$removed" == "0" ]]; then
        warn "Client key '${CLIENT_LABEL}' was not found in the phone's authorized_keys (maybe already revoked)"
    else
        info "Client '${CLIENT_LABEL}' revoked on the phone"
    fi

    _revoke_vps_jump_key "$pub" "$PHONE_WG_IP" "$SSH_PHONE_PORT"
    rm -f "$ck" "$ck.pub" "$SSH_KEY_DIR/client-setup-${CLIENT_LABEL}-${DEVICE_NAME}".{sh,ps1}
    info "Local files for client '${CLIENT_LABEL}' removed"
}

# Lists who has SSH access to the phone, from the keys kept on this VPS. Works
# without the tunnel; it shows what the VPS issued, not a live read of the
# phone's authorized_keys.
list_clients() {
    _load_phone_state
    local alias="${SSH_ALIAS:-$SSH_ALIAS_DEFAULT}" f label fp created count=0

    _list_client_row() { # LABEL ALIAS PUBFILE
        fp="$(ssh_key_fingerprint "$(cat "$3")")"
        created="$(date -u -r "$3" +%Y-%m-%d 2>/dev/null || echo '?')"
        printf '  %-16s %-24s %-10s %s\n' "$1" "$2" "$created" "${fp:-?}"
    }

    echo ""
    echo "  SSH access to ${DEVICE_NAME} (via ${VPS_IP})"
    echo ""
    printf '  %-16s %-24s %-10s %s\n' LABEL ALIAS CREATED FINGERPRINT
    if [[ -f "$SSH_KEY_DIR/owner_${DEVICE_NAME}.pub" ]]; then
        _list_client_row owner "$alias" "$SSH_KEY_DIR/owner_${DEVICE_NAME}.pub"
    else
        printf '  %-16s %s\n' owner "(your existing VPS keys; installed with --client-keys existing)"
    fi
    while IFS= read -r f; do
        label="${f##*/owner_${DEVICE_NAME}_}"; label="${label%.pub}"
        validate_client_label "$label"
        _list_client_row "$label" "${alias}-${label}" "$f"
        count=$((count + 1))
    done < <(device_client_pubs "$DEVICE_NAME")
    echo ""
    info "${count} extra client(s). Add: --add-client LABEL   Remove: --revoke-client LABEL"
}

# ─────────────────────────────────────────────
# Guest file access (--add-guest and friends)
# ─────────────────────────────────────────────
#
# A guest uses any SFTP app (FileZilla, WinSCP, ...) to reach chosen folders
# on one phone. The app logs in to this VPS as GUEST_VPS_USER with the
# guest's key. That key's authorized_keys line forces a command, so the VPS
# ignores what the app asked for and instead opens SSH to the phone over the
# tunnel, as the guest's phone user, with a route key only this VPS holds,
# and asks for SFTP there. The two byte streams are joined, so the app
# talks to the phone's internal-sftp without knowing it. On the phone the
# guest is chrooted to a room of bind-mounted folders (core/guest-helper.sh).
#
# Records: GUESTS_DIR/NAME.json. The authorized_keys of GUEST_VPS_USER is
# rebuilt from them (write_guest_routes), so it never drifts.

GUEST_HELPER_PHONE="/usr/local/sbin/serverinator-guests"
GUEST_FILES_DIR="/srv/files"   # where a bare folder name lives on the phone

validate_guest_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] \
        || die "Invalid guest name '${1}': 1-31 characters, lowercase letters/digits/_/-, starting with a letter"
}

guest_record_path() { printf '%s/%s.json\n' "$GUESTS_DIR" "$1"; }

guest_names() { # [DEVICE]
    local f name
    for f in "$GUESTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"; name="${name%.json}"
        [[ -z "${1:-}" || "$(json_get "$f" device)" == "$1" ]] && printf '%s\n' "$name"
    done
    return 0
}

# normalize_folder_spec SPEC -> "MODE:PATH"
#   photos            -> rw:/srv/files/photos
#   photos:ro         -> ro:/srv/files/photos
#   /data/music:rw    -> rw:/data/music
# The phone checks the path again and refuses system folders.
normalize_folder_spec() {
    local spec="$1" mode=rw path
    case "$spec" in
        *:ro) mode=ro; path="${spec%:ro}" ;;
        *:rw) mode=rw; path="${spec%:rw}" ;;
        *)    path="$spec" ;;
    esac
    path="${path%/}"
    if [[ "$path" != /* ]]; then
        [[ "$path" =~ ^[A-Za-z0-9._@+-]+$ && "$path" != . && "$path" != .. ]] \
            || die "Folder '$spec': use a plain name (kept in $GUEST_FILES_DIR) or a full path"
        path="$GUEST_FILES_DIR/$path"
    fi
    [[ "$path" =~ ^(/[A-Za-z0-9._@+-]+)+$ && "/$path/" != *"/../"* && "/$path/" != *"/./"* ]] \
        || die "Folder '$spec': only letters, digits and ._@+- are allowed in folder names"
    printf '%s:%s\n' "$mode" "$path"
}

# Asks for the folders when none were given on the command line. Fills
# GUEST_FOLDERS with normalized specs.
ask_guest_folders() { # NAME [CURRENT...]
    local name="$1" answer mode
    shift
    [[ -t 0 ]] || die "No folders given. Use --folder NAME[:ro|:rw] (repeatable), or run this in a terminal to be asked"
    echo ""
    if [[ $# -gt 0 ]]; then
        echo "  '$name' can use these folders now:"
        printf '    %s\n' "$@"
        echo "  Enter the complete new list below."
    fi
    echo "  Which folders may '$name' use? One per line, empty line to finish."
    echo "  A plain name (photos) lives in $GUEST_FILES_DIR on the phone and is created if"
    echo "  missing; a full path (/root/music) shares a folder you already have."
    GUEST_FOLDERS=()
    while :; do
        read -r -p "  Folder: " answer || break
        [[ -n "$answer" ]] || break
        answer="$(normalize_folder_spec "$answer")" || continue
        read -r -p "  Read-only or read-write? [ro/RW]: " mode || mode=""
        [[ "${mode,,}" == ro ]] && answer="ro:${answer#*:}" || answer="rw:${answer#*:}"
        GUEST_FOLDERS+=("$answer")
    done
    ((${#GUEST_FOLDERS[@]} > 0)) || die "No folders chosen; nothing changed"
}

# Turns the --folder values into normalized specs (or asks for them).
resolve_guest_folders() { # NAME [CURRENT...]
    local -a given=("${GUEST_FOLDERS[@]+"${GUEST_FOLDERS[@]}"}") spec
    if ((${#given[@]} == 0)); then
        ask_guest_folders "$@"
        return 0
    fi
    GUEST_FOLDERS=()
    for spec in "${given[@]}"; do GUEST_FOLDERS+=("$(normalize_folder_spec "$spec")"); done
}

# "rw:/srv/files/photos" -> "photos (read-write)"
describe_folder() {
    local mode="${1%%:*}" path="${1#*:}"
    printf '%s (%s, %s)' "${path##*/}" "$path" "$([[ "$mode" == ro ]] && echo read-only || echo read-write)"
}

guest_folder_specs() { # RECORD -> MODE:PATH lines
    json_query -r '.folders[] | "\(.mode):\(.path)"' < "$1"
}

# The VPS system user guests log in as. Its password is "*" (never matches,
# but not "locked": sshd with UsePAM no refuses locked accounts).
ensure_guest_vps_user() {
    mkdir -p "$GUEST_VPS_HOME/.ssh" "$GUEST_VPS_HOME/routes"
    if [[ "$DEV" != 1 ]]; then
        if ! getent passwd "$GUEST_VPS_USER" >/dev/null; then
            useradd --system --home-dir "$GUEST_VPS_HOME" --shell /bin/sh \
                --comment "ServerInator guest file access" "$GUEST_VPS_USER" \
                || die "Could not create the VPS user $GUEST_VPS_USER"
            mkdir -p "$WG_KEY_DIR"; touch "$WG_KEY_DIR/guest-user-owned"
            info "Created the VPS user '$GUEST_VPS_USER' that guests log in as"
        fi
        usermod -p '*' "$GUEST_VPS_USER"
        chown -R "$GUEST_VPS_USER:" "$GUEST_VPS_HOME"
    fi
    chmod 750 "$GUEST_VPS_HOME"
    chmod 700 "$GUEST_VPS_HOME/.ssh" "$GUEST_VPS_HOME/routes"
}

# The VPS's own sshd must let GUEST_VPS_USER in with a key from
# .ssh/authorized_keys. Warn (never change) when it looks like it won't.
check_guest_vps_sshd() {
    [[ "$DEV" != 1 ]] && have_cmd sshd || return 0
    local eff
    eff="$(sshd -T -C "user=$GUEST_VPS_USER,host=localhost,addr=127.0.0.1" 2>/dev/null)" || return 0
    local allow_u allow_g
    allow_u="$(awk 'tolower($1)=="allowusers" {$1=""; print}' <<< "$eff")"
    allow_g="$(awk 'tolower($1)=="allowgroups" {$1=""; print}' <<< "$eff")"
    if [[ -n "$allow_u$allow_g" && " $allow_u " != *" $GUEST_VPS_USER "* ]]; then
        warn "This VPS's sshd only lets some users in (AllowUsers/AllowGroups)."
        warn "  Add $GUEST_VPS_USER to AllowUsers in /etc/ssh/sshd_config and reload sshd, or guests can't log in."
    fi
    [[ "$(awk 'tolower($1)=="pubkeyauthentication" {print $2}' <<< "$eff")" != no ]] \
        || warn "sshd has PubkeyAuthentication no for $GUEST_VPS_USER; guests log in with keys, so they can't connect."
    awk 'tolower($1)=="authorizedkeysfile"' <<< "$eff" | grep -q '\.ssh/authorized_keys' \
        || warn "sshd doesn't read ~/.ssh/authorized_keys for $GUEST_VPS_USER; guests can't connect."
    # A forced command replaces the "sftp" subsystem request only when sshd
    # has that subsystem configured; otherwise the request fails first.
    awk 'tolower($1)=="subsystem" && $2=="sftp"' <<< "$eff" | grep -q . \
        || warn "sshd has no 'Subsystem sftp' line; add 'Subsystem sftp internal-sftp' to /etc/ssh/sshd_config and reload sshd, or SFTP apps can't connect."
    [[ -z "$(awk 'tolower($1)=="forcecommand"' <<< "$eff")" ]] \
        || warn "sshd has a ForceCommand for $GUEST_VPS_USER; it overrides the guest routing."
}

# The VPS's SSH port, for the guest's app.
vps_ssh_port() {
    local port=""
    [[ "$DEV" != 1 ]] && have_cmd sshd && port="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port" {print $2; exit}')"
    printf '%s\n' "${port:-22}"
}

# One authorized_keys line: this guest key may only run the hop to its phone.
# The hop must ask for the "sftp" subsystem: the phone's ForceCommand
# internal-sftp refuses plain command sessions.
_guest_route_line() { # NAME PUBKEY DEVICE PHONE_IP PORT HOSTKEY
    local name="$1" pub="$2" device="$3" ip="$4" port="$5" hostkey="$6" kh check
    kh="$GUEST_VPS_HOME/routes/known_hosts_${device}"
    if [[ -n "$hostkey" ]]; then
        check="-o StrictHostKeyChecking=yes -o HostKeyAlias=serverinator-${device}"
    else
        check="-o StrictHostKeyChecking=accept-new"
    fi
    printf 'command="exec ssh -q -T -F /dev/null -o BatchMode=yes %s -o UserKnownHostsFile=%s -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 -o KexAlgorithms=curve25519-sha256,curve25519-sha256@libssh.org -o HostKeyAlgorithms=ssh-ed25519 -o IdentitiesOnly=yes -i %s -p %s %s@%s -s sftp",restrict %s serverinator-guest:%s\n' \
        "$check" "$kh" "$GUEST_VPS_HOME/routes/$name" "$port" "$name" "$ip" "$pub" "$name"
}

# Rebuilds GUEST_VPS_USER's authorized_keys (and the pinned phone host keys)
# from the guest records. VPS-only: works with the tunnel down. Run after
# every guest change, a reinstall (the phone's address may change) and
# --remove-device.
write_guest_routes() {
    local -a names=()
    mapfile -t names < <(guest_names)
    if ((${#names[@]} == 0)) && [[ ! -d "$GUEST_VPS_HOME/.ssh" ]]; then
        return 0
    fi
    ensure_guest_vps_user
    local name rec device drec ip port hostkey pub staged
    staged="$(mktemp)" || die "Could not create a temp file"
    for name in "${names[@]}"; do
        rec="$(guest_record_path "$name")"
        device="$(json_get "$rec" device)"
        drec="$(device_record_path "$device")"
        if [[ ! -f "$drec" ]]; then
            warn "Guest '$name' belongs to phone '$device', which is gone; skipped"
            continue
        fi
        ip="$(json_get "$drec" ssh_phone_ip)"
        port="$(json_get_num "$drec" ssh_port)"; port="${port:-22}"
        hostkey="$(json_get "$drec" ssh_host_pubkey)"
        pub="$(json_get "$rec" guest_pubkey)"
        is_plain_pubkey "$pub" || { warn "Guest '$name' has a malformed key in $rec; skipped"; continue; }
        [[ -f "$GUEST_VPS_HOME/routes/$name" ]] || { warn "Route key for '$name' is missing; run --sync-guests"; continue; }
        validate_ipv4 "$ip" "phone tunnel IPv4"
        validate_port "$port"
        if [[ -n "$hostkey" ]]; then
            printf 'serverinator-%s %s\n' "$device" "$hostkey" > "$GUEST_VPS_HOME/routes/known_hosts_${device}"
        fi
        _guest_route_line "$name" "$pub" "$device" "$ip" "$port" "$hostkey" >> "$staged"
    done
    reconcile_file "$GUEST_VPS_HOME/.ssh/authorized_keys" 600 < "$staged" >/dev/null
    rm -f "$staged"
    if [[ "$DEV" != 1 ]]; then
        chown -R "$GUEST_VPS_USER:" "$GUEST_VPS_HOME/.ssh" "$GUEST_VPS_HOME/routes"
    fi
    rm -f "$GUEST_VPS_HOME/.ssh/authorized_keys.bak"
}

# Makes sure the phone can host guests (it may run an older ServerInator).
_require_phone_guest_helper() {
    local v
    v="$(_phone_ssh "$GUEST_HELPER_PHONE" version 2>/dev/null)" || v=""
    [[ "$v" =~ ^[0-9]+$ ]] \
        || die "Phone '$DEVICE_NAME' can't host guests yet, or isn't reachable. Update it first (re-run serverinator.sh on the phone; nothing else changes), check the tunnel with --verify, then try again."
}

# Pushes one guest to the phone. Prints the phone's UID for it.
_phone_guest_set() { # NAME UID SPEC...
    local name="$1" uid="$2" out
    shift 2
    local -a args=(set "$name" --from "${VPS_WG_SUBNET}.1")
    [[ -z "$uid" ]] || args+=(--uid "$uid")
    out="$(awk '{print $1" "$2; exit}' "$GUEST_VPS_HOME/routes/$name.pub" \
        | _phone_ssh "$GUEST_HELPER_PHONE" "${args[@]}" "$@")" \
        || { printf '%s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out" | grep -v '^uid=' | sed 's/^/  phone: /' >&2
    out="$(printf '%s\n' "$out" | sed -n 's/^uid=\([0-9][0-9]*\)$/\1/p' | tail -n 1)"
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

_write_guest_record() { # NAME UID PUBKEY GENERATED CREATED SPEC...
    local name="$1" uid="$2" pub="$3" generated="$4" created="$5" spec staged
    shift 5
    mkdir -p "$GUESTS_DIR"; chmod 700 "$GUESTS_DIR"
    staged="$(mktemp "$GUESTS_DIR/.${name}.XXXXXX")"
    {
        for spec in "$@"; do printf '%s\n' "$spec"; done
    } | json_query -R -s \
        --arg name "$name" --arg device "$DEVICE_NAME" --argjson uid "$uid" \
        --arg pub "$pub" --argjson generated "$generated" --arg created "$created" '
        {name: $name, device: $device, uid: $uid, guest_pubkey: $pub,
         key_generated: $generated, created: $created,
         folders: [split("\n")[] | select(length > 0)
                   | {mode: (split(":")[0]), path: (split(":")[1:] | join(":"))}]}' \
        > "$staged" || { rm -f "$staged"; die "Could not write the guest record"; }
    chmod 600 "$staged"
    mv "$staged" "$(guest_record_path "$name")"
}

_guest_connection_card() { # NAME KEYFILE SPEC...
    local name="$1" keyfile="$2" spec fp=""
    shift 2
    [[ -f "${SERVERINATOR_VPS_HOSTKEY_FILE:-/etc/ssh/ssh_host_ed25519_key.pub}" ]] \
        && fp="$(ssh_key_fingerprint "$(vps_host_pubkey)" | awk '{print $1}')"
    echo ""
    echo "  '$name' can connect with any SFTP app (FileZilla, WinSCP, an Android SFTP app):"
    echo "    Protocol : SFTP"
    echo "    Host     : $(vps_public_host)"
    echo "    Port     : $(vps_ssh_port)"
    echo "    User     : $GUEST_VPS_USER"
    if [[ -n "$keyfile" ]]; then
        echo "    Key file : $keyfile   (give this file to $name; it is the login)"
    else
        echo "    Key      : the key $name sent you"
    fi
    for spec in "$@"; do echo "    Folder   : $(describe_folder "$spec")"; done
    [[ -z "$fp" ]] || echo "    The app asks to trust the server once; its key should be $fp"
    if [[ -n "$keyfile" ]]; then
        echo ""
        echo "  Copy the key file off this VPS:"
        echo "    $(fetch_hint_file "$keyfile")"
    fi
    echo ""
}

# Like fetch_hint, for a file that isn't a script.
fetch_hint_file() { # PATH
    local name="${1##*/}" user="${SSH_VPS_USER:-root}"
    if [[ "$user" == root ]]; then
        printf '%s' "scp root@$(vps_public_host):$1 ."
    else
        printf '%s' "ssh ${user}@$(vps_public_host) 'sudo cat $1' > $name"
    fi
}

add_guest() {
    local name="$GUEST_NAME" rec pub="" generated=0 gk="" uid created
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--add-guest requires root"
    rec="$(guest_record_path "$name")"
    [[ ! -f "$rec" ]] || die "Guest '$name' already exists (phone $(json_get "$rec" device)). Change folders with --guest-access $name, or --revoke-guest $name first"
    _load_phone_state
    resolve_guest_folders "$name"
    _require_phone_guest_helper

    require_cmd ssh-keygen
    if [[ -n "$GUEST_PUBKEY" ]]; then
        pub="$GUEST_PUBKEY"
    else
        gk="$SSH_KEY_DIR/guest_${name}"
        rm -f "$gk" "$gk.pub"
        mkdir -p "$SSH_KEY_DIR"; chmod 700 "$SSH_KEY_DIR"
        ssh-keygen -q -t ed25519 -N '' -C "serverinator-guest:${name}" -f "$gk"
        chmod 600 "$gk"
        pub="$(awk '{print $1" "$2}' "$gk.pub")"
        generated=1
    fi

    ensure_guest_vps_user
    local rk="$GUEST_VPS_HOME/routes/$name"
    rm -f "$rk" "$rk.pub"
    ssh-keygen -q -t ed25519 -N '' -C "serverinator-route:${name}" -f "$rk"

    uid="$(_phone_guest_set "$name" "" "${GUEST_FOLDERS[@]}")" || {
        rm -f "$rk" "$rk.pub"; [[ -z "$gk" ]] || rm -f "$gk" "$gk.pub"
        die "The phone refused or couldn't set up guest '$name' (see above)"
    }
    created="$(date -u +%Y-%m-%d)"
    _write_guest_record "$name" "$uid" "$pub" "$generated" "$created" "${GUEST_FOLDERS[@]}"
    write_guest_routes
    check_guest_vps_sshd
    ok "Guest '$name' added on $DEVICE_NAME"
    _guest_connection_card "$name" "$gk" "${GUEST_FOLDERS[@]}"
}

# Loads a guest's record and the phone it lives on.
_load_guest() { # NAME -> sets GUEST_RECORD
    GUEST_RECORD="$(guest_record_path "$1")"
    [[ -f "$GUEST_RECORD" ]] || die "No guest named '$1' (known: $(guest_names | tr '\n' ' '))"
    local device
    device="$(json_get "$GUEST_RECORD" device)"
    [[ -z "$SELECTED_DEVICE" || "$SELECTED_DEVICE" == "$device" ]] \
        || die "Guest '$1' is on phone '$device', not '$SELECTED_DEVICE'"
    SELECTED_DEVICE="$device"
}

guest_access() {
    local name="$GUEST_NAME" uid
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--guest-access requires root"
    _load_guest "$name"
    _load_phone_state
    local -a current=()
    mapfile -t current < <(guest_folder_specs "$GUEST_RECORD")
    local spec described=()
    for spec in "${current[@]}"; do described+=("$(describe_folder "$spec")"); done
    resolve_guest_folders "$name" "${described[@]}"
    [[ -f "$GUEST_VPS_HOME/routes/$name.pub" ]] || die "Route key for '$name' is missing; run --sync-guests first"
    _require_phone_guest_helper
    uid="$(_phone_guest_set "$name" "$(json_get_num "$GUEST_RECORD" uid)" "${GUEST_FOLDERS[@]}")" \
        || die "The phone refused or couldn't change guest '$name' (see above)"
    _write_guest_record "$name" "$uid" "$(json_get "$GUEST_RECORD" guest_pubkey)" \
        "$(json_get_num "$GUEST_RECORD" key_generated)" "$(json_get "$GUEST_RECORD" created)" "${GUEST_FOLDERS[@]}"
    ok "Guest '$name' can now use:"
    for spec in "${GUEST_FOLDERS[@]}"; do echo "    $(describe_folder "$spec")"; done
}

revoke_guest() {
    local name="$GUEST_NAME"
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--revoke-guest requires root"
    _load_guest "$name"
    # The VPS side first: once the route line is gone the key can't reach
    # the phone, even if the phone can't be cleaned up right now.
    rm -f "$GUEST_RECORD" "$GUEST_VPS_HOME/routes/$name" "$GUEST_VPS_HOME/routes/$name.pub" \
        "$SSH_KEY_DIR/guest_${name}" "$SSH_KEY_DIR/guest_${name}.pub"
    write_guest_routes
    info "Guest '$name' can no longer log in"
    if [[ -f "$(device_record_path "$SELECTED_DEVICE")" ]]; then
        _load_phone_state
        if _phone_ssh "$GUEST_HELPER_PHONE" remove "$name" >/dev/null; then
            info "Removed '$name' from $DEVICE_NAME (shared folders and their files stay)"
        else
            warn "Couldn't reach $DEVICE_NAME to remove the '$name' account there; run --sync-guests later to tidy up"
        fi
    fi
}

list_guests() {
    local -a names=()
    mapfile -t names < <(guest_names "$SELECTED_DEVICE")
    echo ""
    if ((${#names[@]} == 0)); then
        info "No guests${SELECTED_DEVICE:+ on $SELECTED_DEVICE}. Add one: --add-guest NAME"
        return 0
    fi
    local name rec spec key fp
    printf '  %-16s %-12s %-10s %s\n' GUEST PHONE CREATED KEY
    for name in "${names[@]}"; do
        rec="$(guest_record_path "$name")"
        key="$(json_get "$rec" guest_pubkey)"
        fp="$(ssh_key_fingerprint "$key" | awk '{print $1}')"
        printf '  %-16s %-12s %-10s %s\n' "$name" "$(json_get "$rec" device)" "$(json_get "$rec" created)" "${fp:-?}"
        while IFS= read -r spec; do
            printf '  %-16s   %s\n' "" "$(describe_folder "$spec")"
        done < <(guest_folder_specs "$rec")
    done
    echo ""
    # Folder sizes come from the phone; best effort.
    local device out
    while IFS= read -r device; do
        [[ -f "$(device_record_path "$device")" ]] || continue
        SELECTED_DEVICE="$device"
        ( _load_phone_state >/dev/null
          if out="$(_phone_ssh "$GUEST_HELPER_PHONE" list 2>/dev/null)"; then
              echo "  Folder sizes on $device:"
              printf '%s\n' "$out" | awk '$1 ~ /^(ro|rw)$/ {print $2" "$3}' | sort -u \
                  | while read -r p s; do printf '    %-40s %s\n' "$p" "$s"; done
          else
              info "$device isn't reachable right now; folder sizes skipped"
          fi ) || true
    done < <(for name in "${names[@]}"; do json_get "$(guest_record_path "$name")" device; done | sort -u)
    echo ""
    info "Add: --add-guest NAME   Change folders: --guest-access NAME   Remove: --revoke-guest NAME"
}

# Makes the phone match the VPS's guest records: recreates missing guests
# (a reset or replaced phone), and removes guests the VPS no longer knows.
sync_guests() {
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--sync-guests requires root"
    _load_phone_state
    _require_phone_guest_helper
    local -a names=() on_phone=()
    mapfile -t names < <(guest_names "$DEVICE_NAME")
    ensure_guest_vps_user
    local name rec uid rk n=0
    for name in "${names[@]}"; do
        rec="$(guest_record_path "$name")"
        rk="$GUEST_VPS_HOME/routes/$name"
        if [[ ! -f "$rk" || ! -f "$rk.pub" ]]; then
            rm -f "$rk" "$rk.pub"
            ssh-keygen -q -t ed25519 -N '' -C "serverinator-route:${name}" -f "$rk"
        fi
        local -a specs=()
        mapfile -t specs < <(guest_folder_specs "$rec")
        uid="$(_phone_guest_set "$name" "$(json_get_num "$rec" uid)" "${specs[@]}")" \
            || { warn "Could not set up '$name' on $DEVICE_NAME"; continue; }
        n=$((n + 1))
    done
    mapfile -t on_phone < <(_phone_ssh "$GUEST_HELPER_PHONE" names) || on_phone=()
    for name in "${on_phone[@]}"; do
        [[ -n "$name" ]] || continue
        if [[ ! -f "$(guest_record_path "$name")" ]]; then
            _phone_ssh "$GUEST_HELPER_PHONE" remove "$name" >/dev/null \
                && info "Removed '$name' from $DEVICE_NAME (not a guest on this VPS any more)"
        fi
    done
    write_guest_routes
    ok "$n guest(s) in sync on $DEVICE_NAME"
}

# --remove-device: the phone's guests go with it.
remove_device_guests() { # DEVICE
    local name
    while IFS= read -r name; do
        rm -f "$(guest_record_path "$name")" "$GUEST_VPS_HOME/routes/$name" "$GUEST_VPS_HOME/routes/$name.pub" \
            "$SSH_KEY_DIR/guest_${name}" "$SSH_KEY_DIR/guest_${name}.pub"
        info "Guest '$name' removed with the phone"
    done < <(guest_names "$1")
    rm -f "$GUEST_VPS_HOME/routes/known_hosts_$1"
    write_guest_routes
}

# --uninstall: the guest login user, if we created it.
uninstall_guest_access() {
    if [[ -f "$WG_KEY_DIR/guest-user-owned" && "$DEV" != 1 ]] && getent passwd "$GUEST_VPS_USER" >/dev/null; then
        pkill -KILL -u "$GUEST_VPS_USER" 2>/dev/null || true
        userdel -r "$GUEST_VPS_USER" 2>/dev/null || userdel "$GUEST_VPS_USER" || warn "Could not remove the VPS user $GUEST_VPS_USER"
        info "Removed the guest login user $GUEST_VPS_USER"
    fi
    [[ "$DEV" != 1 ]] || rm -rf "$GUEST_VPS_HOME"
}

# ─────────────────────────────────────────────
# Step 6: Back-handoff
# ─────────────────────────────────────────────

generate_back_handoff() {
    local staged record
    record="$(device_record_path "$DEVICE_NAME")"
    mkdir -p "$DEVICES_DIR"
    chmod 700 "$DEVICES_DIR"
    staged="$(mktemp "${record}.XXXXXX")"
    chmod 600 "$staged"

    # Base fields (always present)
    local result
    result="$(jq -n \
        --argjson version      1 \
        --arg  device_name     "$DEVICE_NAME" \
        --arg  vps_ip          "$VPS_IP" \
        --arg  vps_wg_pubkey   "$VPS_WG_PUBKEY" \
        --arg  phone_wg_pubkey "$PHONE_WG_PUBKEY" \
        --arg  phone_wg_ip     "$PHONE_WG_IP" \
        --arg  vps_wg_ip       "${VPS_WG_SUBNET}.1" \
        --argjson wg_port      "$WG_PORT" \
        --argjson wstunnel_port "$WSTUNNEL_PORT" \
        --arg  ssh_alias       "$SSH_ALIAS" \
        --arg  vps_domain      "$VPS_DOMAIN" \
        '{
            version:        $version,
            device_name:    $device_name,
            vps_ip:         $vps_ip,
            vps_wg_pubkey:  $vps_wg_pubkey,
            phone_wg_pubkey: $phone_wg_pubkey,
            phone_wg_ip:    $phone_wg_ip,
            vps_wg_ip:      $vps_wg_ip,
            wg_port:        $wg_port,
            wstunnel_port:  $wstunnel_port,
            ssh_alias:      $ssh_alias
        } + (if $vps_domain == "" then {} else {vps_domain: $vps_domain} end)')" || die "jq: could not assemble the base back-handoff"

    # SSH fields (conditional)
    if [[ "$SSH_ENABLED" == "1" ]]; then
        # Build the client-keys object
        local keys_obj='{}'
        local i=1 k
        for k in "${SSH_CLIENT_KEYS[@]}"; do
            keys_obj="$(jq -n \
                --argjson obj   "$keys_obj" \
                --arg     key   "$k" \
                --arg     field "ssh_client_key_${i}" \
                '$obj + {($field): $key}')" || die "jq: could not add key $i"
            i=$((i+1))
        done

        result="$(jq -n \
            --argjson base                  "$result" \
            --argjson keys                  "$keys_obj" \
            --argjson ssh_enabled           1 \
            --arg     ssh_user              "$SSH_USER" \
            --argjson ssh_port              "$SSH_PHONE_PORT" \
            --arg     ssh_phone_ip          "$PHONE_WG_IP" \
            --arg     ssh_vps_host          "$(vps_public_host)" \
            --arg     ssh_vps_user          "$SSH_VPS_USER" \
            --arg     ssh_vps_to_phone_pubkey "$SSH_VPS_TO_PHONE_PUBKEY" \
            --arg     ssh_host_fingerprint  "${SSH_HOST_FINGERPRINT:-}" \
            --arg     ssh_host_pubkey       "${SSH_HOST_PUBKEY:-}" \
            --argjson ssh_client_key_count  "${#SSH_CLIENT_KEYS[@]}" \
            '$base + {
                ssh_enabled:              $ssh_enabled,
                ssh_user:                 $ssh_user,
                ssh_port:                 $ssh_port,
                ssh_phone_ip:             $ssh_phone_ip,
                ssh_vps_host:             $ssh_vps_host,
                ssh_vps_user:             $ssh_vps_user,
                ssh_vps_to_phone_pubkey:  $ssh_vps_to_phone_pubkey,
                ssh_host_fingerprint:     $ssh_host_fingerprint,
                ssh_host_pubkey:          $ssh_host_pubkey,
                ssh_client_key_count:     $ssh_client_key_count
            } + $keys')" || die "jq: could not add SSH fields"
    else
        result="$(jq -n --argjson base "$result" '$base + {ssh_enabled: 0}')" \
            || die "jq: could not add ssh_enabled: 0"
    fi

    printf '%s\n' "$result" > "$staged"
    jq -e . < "$staged" > /dev/null || die "Back-handoff failed jq validation"

    [[ ! -L "$record" ]] || die "Rejected a symlink for $record"
    mv "$staged" "$record"
    info "Device record written: $record"
    # The single legacy state file is superseded by the record.
    rm -f "$SSH_KEY_DIR/state.json"

    if [[ -n "$BACK_HANDOFF_PATH" ]]; then
        [[ ! -L "$BACK_HANDOFF_PATH" ]] || die "Rejected a symlink for back-handoff"
        mkdir -p "$(dirname "$BACK_HANDOFF_PATH")"
        cp "$record" "$BACK_HANDOFF_PATH"
        chmod 600 "$BACK_HANDOFF_PATH"
        set_back_handoff_owner "$BACK_HANDOFF_PATH"
        info "Back-handoff copy written: $BACK_HANDOFF_PATH"
    fi
}

# ─────────────────────────────────────────────
# Tunnel check (--verify)
# ─────────────────────────────────────────────

verify() {
    if [[ -z "$BACK_HANDOFF_FILE" ]]; then
        select_device
        BACK_HANDOFF_FILE="$DEVICE_RECORD"
    fi
    [[ -f "$BACK_HANDOFF_FILE" ]] || die "Back-handoff not found: $BACK_HANDOFF_FILE"

    local version
    version="$(json_get_num "$BACK_HANDOFF_FILE" version)"
    [[ "$version" == "1" ]] || die "Unsupported back-handoff version: $version"

    local phone_wg_ip phone_wg_pubkey device_name ssh_enabled_bh
    phone_wg_ip="$(json_get     "$BACK_HANDOFF_FILE" phone_wg_ip)"
    phone_wg_pubkey="$(json_get  "$BACK_HANDOFF_FILE" phone_wg_pubkey)"
    device_name="$(json_get      "$BACK_HANDOFF_FILE" device_name)"
    ssh_enabled_bh="$(json_get_num "$BACK_HANDOFF_FILE" ssh_enabled)"

    [[ -n "$device_name" ]]    || die "back-handoff: no device_name"
    [[ -n "$phone_wg_ip" ]]    || die "back-handoff: no phone_wg_ip"
    [[ -n "$phone_wg_pubkey" ]] || die "back-handoff: no phone_wg_pubkey (regenerate the back-handoff)"

    info "Checking the tunnel for device: $device_name"
    echo ""
    local errors=0

    # ── 1. WireGuard interface ────────────────
    if [[ "$DEV" == "1" ]]; then
        ok "WireGuard interface ${WG_INTERFACE} (skipped in DEV)"
    elif ! have_cmd ip; then
        fail "ip not found (install iproute2)"; ((errors++)) || true
    elif interface_is_up; then
        ok "WireGuard interface ${WG_INTERFACE} is up"
    else
        fail "WireGuard interface ${WG_INTERFACE} not found"; ((errors++)) || true
    fi

    # ── 2. WireGuard peer handshake ───────────
    if [[ "$DEV" == "1" ]]; then
        ok "WireGuard peer handshake (skipped in DEV)"
    elif ! have_cmd wg; then
        fail "wg not found (install wireguard-tools)"; ((errors++)) || true
    else
        local hs_line hs_count age
        hs_line="$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null \
            | awk -v key="$phone_wg_pubkey" '$1 == key { print $2 }')"
        hs_count="$(printf '%s\n' "$hs_line" | grep -c . || true)"

        if [[ "${hs_count:-0}" -eq 0 ]]; then
            fail "Peer ${phone_wg_pubkey} not found on ${WG_INTERFACE} — did the phone connect?"; ((errors++)) || true
        elif [[ "${hs_count:-0}" -gt 1 ]]; then
            fail "Multiple handshake entries for the peer — refusing to pick one"; ((errors++)) || true
        elif [[ "$hs_line" == "0" ]]; then
            fail "No handshake yet (timestamp 0) — the phone is not connected"; ((errors++)) || true
        elif [[ ! "$hs_line" =~ ^[0-9]+$ ]]; then
            fail "Invalid handshake timestamp: '${hs_line}'"; ((errors++)) || true
        else
            age=$(( $(date +%s) - hs_line ))
            if [[ "$age" -lt 180 ]]; then
                ok "WireGuard peer handshake ${age}s ago"
            else
                fail "WireGuard peer handshake is stale (${age}s ago)"; ((errors++)) || true
            fi
        fi
    fi

    # ── 3. wstunnel service ───────────────────
    if [[ "$DEV" == "1" ]]; then
        ok "wstunnel service (skipped in DEV)"
    elif ! have_cmd systemctl; then
        fail "systemctl not found"; ((errors++)) || true
    elif systemctl is-active --quiet wstunnel-serverinator; then
        ok "wstunnel server is running"
    else
        fail "wstunnel server is not running"; ((errors++)) || true
    fi

    # ── 4. Ping the phone over the WG tunnel ─────
    if [[ "$DEV" == "1" ]]; then
        ok "Ping ${phone_wg_ip} (skipped in DEV)"
    elif ! have_cmd ping; then
        fail "ping not found (install iputils-ping)"; ((errors++)) || true
    elif ping -c 3 -W 2 "$phone_wg_ip" &>/dev/null; then
        ok "Ping to the phone (${phone_wg_ip}) — OK"
    else
        fail "Ping to the phone (${phone_wg_ip}) failed — has the tunnel come up yet?"; ((errors++)) || true
    fi

    # ── 5. SSH: actual data transfer ──────
    # Handshake + ping are necessary but NOT sufficient.
    # (Contabo: handshake and ping worked, but the provider blocked data.)
    if [[ "$ssh_enabled_bh" == "1" ]]; then
        local vps_key="$SSH_KEY_DIR/vps_to_phone"
        local ssh_user_bh ssh_port_bh
        ssh_user_bh="$(json_get     "$BACK_HANDOFF_FILE" ssh_user)";    ssh_user_bh="${ssh_user_bh:-root}"
        ssh_port_bh="$(json_get_num "$BACK_HANDOFF_FILE" ssh_port)";    ssh_port_bh="${ssh_port_bh:-22}"

        if [[ ! -f "$vps_key" ]]; then
            warn "VPS->phone key not found ($vps_key) — skipping the SSH test"
        elif [[ "$DEV" == "1" ]]; then
            ok "SSH data transfer (skipped in DEV)"
        else
            local ssh_out opts=()
            phone_hostkey_opts "$(json_get "$BACK_HANDOFF_FILE" device_name)" \
                "$(json_get "$BACK_HANDOFF_FILE" ssh_host_pubkey)"
            ssh_out="$(ssh \
                -o BatchMode=yes \
                -o ConnectTimeout=10 \
                "${opts[@]}" \
                -i "$vps_key" \
                -p "$ssh_port_bh" \
                "${ssh_user_bh}@${phone_wg_ip}" \
                "echo serverinator-ok" 2>&1 || true)"
            if [[ "$ssh_out" == *"serverinator-ok"* ]]; then
                ok "SSH data transfer through the tunnel — data is flowing"
            else
                fail "SSH data transfer failed — the tunnel passes the handshake but drops data?"
                warn "  (this is exactly what happened on Contabo — try another VPS or network)"
                ((errors++)) || true
            fi
        fi
    fi

    echo ""
    if [[ "$errors" -eq 0 ]]; then
        echo "  OK - all checks passed, the tunnel is working"
    else
        echo "  FAILED - checks failed: $errors"
    fi
    echo ""
    return "$errors"
}

# ─────────────────────────────────────────────
# --list-devices / --remove-device
# ─────────────────────────────────────────────

list_devices() {
    local -a names=()
    local name record ip ssh_on clients hs age="" now
    mapfile -t names < <(device_names)
    echo ""
    if ((${#names[@]} == 0)); then
        info "No phone is set up on this VPS yet."
        return 0
    fi
    now="$(date +%s)"
    printf '  %-20s %-14s %-5s %-8s %s\n' DEVICE TUNNEL-IP SSH CLIENTS LAST-HANDSHAKE
    for name in "${names[@]}"; do
        record="$(device_record_path "$name")"
        ip="$(json_get "$record" phone_wg_ip 2>/dev/null || echo '?')"
        ssh_on="$(json_get_num "$record" ssh_enabled 2>/dev/null || echo 0)"
        clients="$(device_client_pubs "$name" | grep -c . || true)"
        hs="?"
        if [[ "$DEV" != 1 ]] && have_cmd wg; then
            age="$(wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null \
                | awk -v key="$(json_get "$record" phone_wg_pubkey 2>/dev/null)" '$1 == key {print $2}')"
            if [[ "$age" =~ ^[0-9]+$ ]]; then
                if ((age == 0)); then hs="never"; else hs="$((now - age))s ago"; fi
            fi
        fi
        printf '  %-20s %-14s %-5s %-8s %s\n' "$name" "${ip:-?}" "$([[ "$ssh_on" == 1 ]] && echo yes || echo no)" "$clients" "$hs"
    done
    echo ""
}

# Removes one phone: its WireGuard peer (config and live), its record, the
# owner/client keys and setup scripts issued for it, and their VPS jump
# entries. Other phones are untouched.
remove_device() {
    local name="$SELECTED_DEVICE" record lock_fd desired pubkey="" phone_ip="" port="" f
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--remove-device requires root"
    record="$(device_record_path "$name")"
    if [[ ! -f "$record" ]] && ! { [[ -f "$WG_CONF" ]] && [[ "$(peer_block_count "$WG_CONF" "$name")" -gt 0 ]]; }; then
        die "No phone named '$name' on this VPS (known: $(device_names | tr '\n' ' '))"
    fi
    if [[ -f "$record" ]]; then
        phone_ip="$(json_get "$record" ssh_phone_ip)"
        port="$(json_get_num "$record" ssh_port)"
    fi

    # WireGuard peer, under the same lock as setup.
    if [[ -f "$WG_CONF" ]]; then
        mkdir -p "$WG_KEY_DIR"
        exec {lock_fd}>"$WG_KEY_DIR/setup.lock"
        flock -x "$lock_fd"
        if [[ "$(peer_block_count "$WG_CONF" "$name")" -gt 0 ]]; then
            pubkey="$(peer_pubkey_for_device "$WG_CONF" "$name")"
            desired="$(mktemp "$WG_DIR/desired.XXXXXX")"
            cp "$WG_CONF" "$desired"
            peer_remove_device "$desired" "$name"
            reconcile_file "$WG_CONF" 600 < "$desired"
            rm -f "$desired"
            info "Removed the WireGuard peer for $name"
        fi
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        if [[ "$DEV" != 1 && -n "$pubkey" ]] && interface_is_up; then
            wg set "$WG_INTERFACE" peer "$pubkey" remove || warn "Could not remove the live peer; it goes at the next restart"
        fi
    fi

    # Keys issued for this phone and their restricted jump entries.
    while IFS= read -r f; do
        [[ -n "$phone_ip" && -n "$port" ]] && _revoke_vps_jump_key "$(cat "$f")" "$phone_ip" "$port"
        rm -f "${f%.pub}" "$f"
    done < <( { [[ -f "$SSH_KEY_DIR/owner_${name}.pub" ]] && echo "$SSH_KEY_DIR/owner_${name}.pub"; device_client_pubs "$name"; } )
    rm -f "$SSH_KEY_DIR/client-setup-owner-${name}".{sh,ps1} "$SSH_KEY_DIR"/client-setup-*-"${name}".{sh,ps1}
    rm -f "$record"
    remove_device_guests "$name"
    info "Phone '$name' removed from this VPS."
    [[ -n "$(device_names)" ]] || info "No phones left; the VPS services stay installed (use --uninstall to remove everything)."
}

# ─────────────────────────────────────────────
# Uninstall
# ─────────────────────────────────────────────

# Removes every restricted jump entry we added (all phones) from the
# authorized_keys of each VPS admin the records name, plus the current one.
_remove_all_vps_jump_entries() {
    local prefix="command=\"echo 'ServerInator: forwarding-only key, no shell access'; exit 1\",restrict,port-forwarding,permitopen="
    local homes=() home rec user auth_file tmp rc
    home="$(_vps_user_home 2>/dev/null || true)"; [[ -z "$home" ]] || homes+=("$home")
    for rec in "$DEVICES_DIR"/*.json "$SSH_KEY_DIR/state.json"; do
        [[ -f "$rec" ]] || continue
        user="$(json_get "$rec" ssh_vps_user 2>/dev/null || true)"
        [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || continue
        if [[ "$user" == root ]]; then home="${SERVERINATOR_VPS_ADMIN_HOME:-/root}"
        else home="$(getent passwd "$user" | cut -d: -f6 || true)"; fi
        [[ -z "$home" ]] || homes+=("$home")
    done
    for home in $(printf '%s\n' "${homes[@]}" | sort -u); do
        auth_file="$home/.ssh/authorized_keys"
        [[ -f "$auth_file" && ! -L "$auth_file" ]] || continue
        grep -qF -- "$prefix" "$auth_file" || continue
        tmp="$(mktemp "${auth_file}.XXXXXX")" || die "Could not create a temp file next to $auth_file"
        rc=0
        awk -v p="$prefix" 'index($0, p) != 1' "$auth_file" > "$tmp" || rc=$?
        [[ "$rc" == 0 ]] || { rm -f "$tmp"; die "Could not rewrite $auth_file"; }
        chmod 600 "$tmp"
        chown --reference="$auth_file" "$tmp" 2>/dev/null || true
        mv "$tmp" "$auth_file" || { rm -f "$tmp"; die "Could not replace $auth_file"; }
        info "Removed ServerInator jump entries from $auth_file"
    done
}

uninstall_vps() {
    safe_remove_path "$WG_KEY_DIR"
    local svc="$SYSTEMD_DIR/wstunnel-serverinator.service"
    if [[ "$DEV" != 1 ]]; then
        [[ "$(id -u)" == 0 ]] || die "VPS uninstall requires root"
        systemctl cat wstunnel-serverinator.service &>/dev/null \
            && systemctl disable --now wstunnel-serverinator.service
        [[ ! -f "$WG_CONF" ]] || systemctl disable --now "wg-quick@$WG_INTERFACE"
        remove_owned_mss
    fi
    rm -f "$svc" "${svc}.bak" "$WG_CONF" "${WG_CONF}.bak"
    if [[ -f "$WG_KEY_DIR/wstunnel-owned" ]]; then
        rm -f "$WSTUNNEL_BIN"
    else
        warn "wstunnel was not installed by us — not removing the binary"
    fi
    _remove_all_vps_jump_entries
    uninstall_guest_access
    if [[ -f "$TLS_STATE" ]]; then
        local domain
        domain="$(json_get "$TLS_STATE" domain)"
        [[ "$(json_get "$TLS_STATE" source)" != letsencrypt ]] \
            || info "The Let's Encrypt certificate for $domain stays; remove it with: certbot delete --cert-name $domain"
    fi
    rm -f "$LETSENCRYPT_DIR/renewal-hooks/deploy/serverinator-wstunnel.sh"
    rm -rf "$WG_KEY_DIR"
    [[ "$DEV" != 1 ]] && systemctl daemon-reload
    # The orchestrator keeps these scripts in /root/.serverinator/bin. Bash
    # has this file open already, so removing it doesn't stop the run.
    local bin_dir
    bin_dir="$(cd "$CORE_DIR" && pwd -P)"
    if [[ "$DEV" != 1 && "$bin_dir" == /root/.serverinator/bin ]]; then
        rm -f "$bin_dir"/core-vps.sh "$bin_dir"/lib.sh
        rmdir "$bin_dir" /root/.serverinator 2>/dev/null || true
        info "Removed the scripts in $bin_dir"
    fi
    info "VPS uninstalled. Foreign interfaces and firewall rules were preserved."
}

# Warns when a host firewall would drop the tunnel port (review #17). It
# never changes firewall rules: the admin decides.
check_firewall() { # [PORT [PURPOSE]]
    local port="${1:-$WSTUNNEL_PORT}" purpose="${2:-the tunnel needs}" hint=""
    if have_cmd ufw && ufw status 2>/dev/null | head -1 | grep -q '^Status: active'; then
        ufw status 2>/dev/null | grep -qE "^${port}(/tcp)?[[:space:]].*ALLOW" \
            || hint="ufw allow ${port}/tcp"
    elif have_cmd firewall-cmd && firewall-cmd --state &>/dev/null; then
        firewall-cmd --query-port="${port}/tcp" &>/dev/null \
            || hint="firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload"
    elif have_cmd iptables && iptables -S INPUT 2>/dev/null | grep -qx -- '-P INPUT DROP'; then
        iptables -S INPUT 2>/dev/null | grep -qE -- "--dport ${port}( |$)" \
            || hint="iptables -I INPUT -p tcp --dport ${port} -j ACCEPT (and save it)"
    fi
    if [[ -n "$hint" ]]; then
        warn "A firewall on this VPS seems to block TCP port ${port}, which ${purpose}."
        warn "  Open it with:  $hint"
        warn "  (Also check your provider's firewall or security group.)"
    fi
}

remove_owned_mss() {
    local receipt port rc
    for receipt in "$WG_KEY_DIR/mss-owned/"*; do
        [[ -f "$receipt" ]] || continue
        port="$(cat "$receipt")"
        validate_tunnel_port "$port"
        [[ "${receipt##*/}" == "$port" && ! -L "$receipt" ]] || die "Invalid MSS receipt"
        while :; do
            rc=0
            iptables -t mangle -C OUTPUT -p tcp --sport "$port" \
                --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss \
                -j TCPMSS --set-mss 500 || rc=$?
            [[ "$rc" == 1 ]] && break
            [[ "$rc" == 0 ]] || die "Could not check the TCPMSS rule"
            iptables -t mangle -D OUTPUT -p tcp --sport "$port" \
                --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss \
                -j TCPMSS --set-mss 500
        done
        if [[ -f "$IPTABLES_RULES_PATH" ]]; then
            local rules
            rules="$(mktemp)"
            awk -v port="$port" '
              {line=$0; gsub(/"/, "", line)}
              line=="-A OUTPUT -p tcp -m tcp --sport "port" --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss -j TCPMSS --set-mss 500" {next}
              line=="-A OUTPUT -p tcp -m tcp --sport "port" --tcp-flags RST,SYN SYN -m comment --comment serverinator-mss -j TCPMSS --set-mss 500" {next}
              {print}' "$IPTABLES_RULES_PATH" > "$rules"
            reconcile_file "$IPTABLES_RULES_PATH" 600 < "$rules"
            rm -f "$rules"
        fi
    done
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

main() {
    parse_args "$@"
    [[ "$MODE" == uninstall ]] || migrate_legacy_state

    case "$MODE" in
        uninstall)      uninstall_vps;  return ;;
        list-devices)   list_devices;   return ;;
        remove-device)  remove_device;  return ;;
        verify)         verify;         return ;;
        add-client)     add_client;     return ;;
        revoke-client)  revoke_client;  return ;;
        list-clients)   list_clients;   return ;;
        set-domain)     set_domain;     return ;;
        add-guest)      add_guest;      return ;;
        guest-access)   guest_access;   return ;;
        revoke-guest)   revoke_guest;   return ;;
        list-guests)    list_guests;    return ;;
        sync-guests)    sync_guests;    return ;;
    esac

    # MODE=setup
    info "ServerInator Core — setting up the VPS"
    [[ "$DEV" == "1" ]] && dev "DEV mode (WG_DIR=$WG_DIR, SYSTEMD_DIR=$SYSTEMD_DIR)"

    have_cmd jq || die "Install jq: apt-get install jq"

    step 1/6 "Reading handoff"
    read_handoff

    step 2/6 "Installing dependencies"
    install_deps
    install_wstunnel_vps

    step 3/6 "Setting up WireGuard"
    setup_wireguard

    step 4/6 "Setting up wstunnel"
    setup_tls
    setup_wstunnel_server
    fix_pmtu_clamp
    [[ "$DEV" == 1 ]] || check_firewall

    step 5/6 "SSH keys and client script"
    setup_vps_ssh_keys
    generate_client_setup

    step 6/6 "Generating back-handoff"
    generate_back_handoff
    # A reinstall can move the phone to another tunnel address.
    write_guest_routes

    info "VPS configured."
    if [[ -n "${OWNER_CLIENT_SETUP_PATH:-}" ]]; then
        echo ""
        echo "  To connect from any device:"
        echo "    $(fetch_hint "$OWNER_CLIENT_SETUP_PATH")"
        echo "  From Windows (PowerShell):"
        echo "    $(fetch_hint_windows "$OWNER_CLIENT_SETUP_PATH")"
        echo ""
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
