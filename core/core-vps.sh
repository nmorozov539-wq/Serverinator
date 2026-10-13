#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# ServerInator Core — VPS-side setup script
#
# Usage:
#   bash core-vps.sh HANDOFF.json --vps-ip HOST [--alias NAME] [--client-keys existing|new]
#   bash core-vps.sh --verify BACK-HANDOFF.json
#   bash core-vps.sh --add-client LABEL     # after install, the tunnel must be up
#   bash core-vps.sh --revoke-client LABEL
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
fi

WG_DIR="${SERVERINATOR_WG_DIR:-/etc/wireguard}"
WG_KEY_DIR="${SERVERINATOR_WG_KEY_DIR:-$WG_DIR/serverinator}"
WG_CONF="$WG_DIR/${WG_INTERFACE}.conf"
SYSTEMD_DIR="${SERVERINATOR_SYSTEMD_DIR:-/etc/systemd/system}"
WSTUNNEL_BIN="${SERVERINATOR_WSTUNNEL_BIN:-/usr/local/bin/wstunnel}"
BACK_HANDOFF_PATH="${SERVERINATOR_BACK_HANDOFF_PATH:-/tmp/back-handoff.json}"
IPTABLES_RULES_PATH="${SERVERINATOR_IPTABLES_RULES_PATH:-/etc/iptables/rules.v4}"

# ── SSH state ─────────────────────────────────
SSH_KEY_DIR="${SERVERINATOR_SSH_KEY_DIR:-$WG_KEY_DIR/ssh}"
SSH_ALIAS_DEFAULT="serverinated"
SSH_ENABLED=0
SSH_USER="root"
SSH_PHONE_PORT=22
SSH_HOST_FINGERPRINT=""
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

# ── Shared library ────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
                [[ $# -gt 0 ]] || die "--verify requires a path to back-handoff.json"
                BACK_HANDOFF_FILE="$1"; shift
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
        verify)
            [[ -n "$BACK_HANDOFF_FILE" ]] \
                || die "--verify requires a path to back-handoff.json"
            ;;
        uninstall) ;;
        add-client|revoke-client)
            [[ -n "$CLIENT_LABEL" ]] || die "--add-client/--revoke-client requires a LABEL"
            ;;
    esac
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

    [[ -n "$DEVICE_NAME" ]]     || die "handoff.json: missing device_name"
    [[ -n "$PHONE_WG_PUBKEY" ]] || die "handoff.json: missing wg_pubkey"

    validate_device_name "$DEVICE_NAME"
    validate_wg_key "$PHONE_WG_PUBKEY"
    validate_optional_ports "$HANDOFF_FILE"

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

install_wstunnel_vps() (
    # Check both presence AND version — a mismatched version gets upgraded.
    if [[ -x "$WSTUNNEL_BIN" ]]; then
        local current
        current="$("$WSTUNNEL_BIN" --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || true)"
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
    local scratch
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    local url="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_linux_amd64.tar.gz"
    info "Installing wstunnel v${WSTUNNEL_VERSION}..."
    curl -fsSL "$url" -o "$scratch/wstunnel.tar.gz"
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
        ' "$desired" | reconcile_file "$WG_CONF" 600
        # The pipe runs reconcile_file in a subshell — RECONCILED_CHANGED does
        # not propagate out. The runtime check below always runs regardless.
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

setup_wstunnel_server() {
    local svc="$SYSTEMD_DIR/wstunnel-serverinator.service"
    mkdir -p "$SYSTEMD_DIR"
    local desired
    desired="$(mktemp "$SYSTEMD_DIR/unit.XXXXXX")"
    cat > "$desired" << EOF
[Unit]
Description=wstunnel server for ServerInator
After=network.target

[Service]
ExecStart=${WSTUNNEL_BIN} server \\
    --log-lvl INFO \\
    --restrict-to ${WG_RESTRICT_TARGET} \\
    wss://0.0.0.0:${WSTUNNEL_PORT}
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
        iptables-save | reconcile_file "$IPTABLES_RULES_PATH" 600
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
    grep -vFx -- "$line" "$auth_file" > "${auth_file}.new"
    mv "${auth_file}.new" "$auth_file"
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
    local jump="${SSH_VPS_USER}@${VPS_IP}"
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
            "if grep -q \"^Host ${VPS_IP}\$\" \"\$CONFIG\" 2>/dev/null; then" \
            "    echo \"Host ${VPS_IP} is already in \$CONFIG — skipping\"" \
            "else" \
            "    printf '\\nHost ${VPS_IP}\\n' >> \"\$CONFIG\"" \
            "    printf '    User ${SSH_VPS_USER}\\n' >> \"\$CONFIG\"" \
            "    printf '    IdentityFile ~/.ssh/${si_name}\\n' >> \"\$CONFIG\"" \
            "    echo \"Host ${VPS_IP} (ProxyJump only) added to \$CONFIG\"" \
            "fi" \
            "")"
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
# on Windows use WSL or Git Bash):
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
    printf '    ServerAliveInterval 60\\n' >> "\$CONFIG"
    printf '    ServerAliveCountMax 9999\\n' >> "\$CONFIG"
    echo "Alias '${alias}' added to ~/.ssh/config"
fi

${jump_host_lines}
echo ""
echo "Done. Connect with:  ssh ${alias}"
SETUP_EOF

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
    local state="$SSH_KEY_DIR/state.json"
    [[ -f "$state" ]] \
        || die "Phone state not found ($state) — run a full install first: bash $0 HANDOFF.json --vps-ip HOST"

    DEVICE_NAME="$(json_get "$state" device_name)"
    VPS_IP="$(json_get "$state" vps_ip)"
    PHONE_WG_IP="$(json_get "$state" ssh_phone_ip)"
    SSH_USER="$(json_get "$state" ssh_user)"; SSH_USER="${SSH_USER:-root}"
    SSH_PHONE_PORT="$(json_get_num "$state" ssh_port)"; SSH_PHONE_PORT="${SSH_PHONE_PORT:-22}"
    SSH_VPS_USER="$(json_get "$state" ssh_vps_user)"; SSH_VPS_USER="${SSH_VPS_USER:-$(id -un)}"
    local ssh_enabled
    ssh_enabled="$(json_get_num "$state" ssh_enabled)"

    [[ -n "$DEVICE_NAME" ]] || die "state.json: missing device_name"
    validate_device_name "$DEVICE_NAME"
    [[ -n "$VPS_IP" ]] || die "state.json: missing vps_ip"
    validate_host "$VPS_IP"
    [[ "$ssh_enabled" == "1" ]] \
        || die "SSH was not enabled when the phone was set up — cannot add clients"
    [[ -n "$PHONE_WG_IP" ]] || die "state.json: missing ssh_phone_ip"
    validate_ipv4 "$PHONE_WG_IP" "phone WG IPv4"
    validate_port "$SSH_PHONE_PORT"
}

# Runs a command on the phone over the up tunnel, using the VPS->phone key.
_phone_ssh() {
    local vps_key="$SSH_KEY_DIR/vps_to_phone"
    [[ -f "$vps_key" ]] || die "VPS->phone key not found ($vps_key)"
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
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
    echo "    scp ${SSH_VPS_USER}@${VPS_IP}:${f} . && bash $(basename "$f")"
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
        grep -vFx -- "$key" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new
        mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys
        echo "$before"
    ')" || die "Could not revoke the client key on the phone — is the tunnel up?"

    if [[ "$removed" == "0" ]]; then
        warn "Client key '${CLIENT_LABEL}' was not found in the phone's authorized_keys (maybe already revoked)"
    else
        info "Client '${CLIENT_LABEL}' revoked on the phone"
    fi

    _revoke_vps_jump_key "$pub" "$PHONE_WG_IP" "$SSH_PHONE_PORT"
    rm -f "$ck" "$ck.pub" "$SSH_KEY_DIR/client-setup-${CLIENT_LABEL}-${DEVICE_NAME}.sh"
    info "Local files for client '${CLIENT_LABEL}' removed"
}

# ─────────────────────────────────────────────
# Step 6: Back-handoff
# ─────────────────────────────────────────────

generate_back_handoff() {
    local staged
    mkdir -p "$(dirname "$BACK_HANDOFF_PATH")"
    staged="$(mktemp "${BACK_HANDOFF_PATH}.XXXXXX")"
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
        }')" || die "jq: could not assemble the base back-handoff"

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
            --arg     ssh_vps_host          "$VPS_IP" \
            --arg     ssh_vps_user          "$SSH_VPS_USER" \
            --arg     ssh_vps_to_phone_pubkey "$SSH_VPS_TO_PHONE_PUBKEY" \
            --arg     ssh_host_fingerprint  "${SSH_HOST_FINGERPRINT:-}" \
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
                ssh_client_key_count:     $ssh_client_key_count
            } + $keys')" || die "jq: could not add SSH fields"
    else
        result="$(jq -n --argjson base "$result" '$base + {ssh_enabled: 0}')" \
            || die "jq: could not add ssh_enabled: 0"
    fi

    printf '%s\n' "$result" > "$staged"
    jq -e . < "$staged" > /dev/null || die "Back-handoff failed jq validation"

    [[ ! -L "$BACK_HANDOFF_PATH" ]] || die "Rejected a symlink for back-handoff"
    mv "$staged" "$BACK_HANDOFF_PATH"
    # Persistent copy for future --add-client/--revoke-client (which don't go
    # through read_handoff and don't get HANDOFF.json again). Only needed
    # when SSH is enabled — without it, adding clients is pointless.
    if [[ "$SSH_ENABLED" == "1" ]]; then
        cp "$BACK_HANDOFF_PATH" "$SSH_KEY_DIR/state.json" \
            || die "Could not save state for future --add-client/--revoke-client"
        chmod 600 "$SSH_KEY_DIR/state.json"
    fi
    set_back_handoff_owner "$BACK_HANDOFF_PATH"
    info "Back-handoff written: $BACK_HANDOFF_PATH"
}

# ─────────────────────────────────────────────
# Tunnel check (--verify)
# ─────────────────────────────────────────────

verify() {
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
        local hs_line hs_count last_hs age
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
            local ssh_out
            ssh_out="$(ssh \
                -o BatchMode=yes \
                -o ConnectTimeout=10 \
                -o StrictHostKeyChecking=no \
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
# Uninstall
# ─────────────────────────────────────────────

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
    rm -rf "$WG_KEY_DIR"
    [[ "$DEV" != 1 ]] && systemctl daemon-reload
    info "VPS uninstalled. Foreign interfaces and firewall rules were preserved."
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
            awk -v port="$port" '
              {line=$0; gsub(/"/, "", line)}
              line=="-A OUTPUT -p tcp -m tcp --sport "port" --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss -j TCPMSS --set-mss 500" {next}
              line=="-A OUTPUT -p tcp -m tcp --sport "port" --tcp-flags RST,SYN SYN -m comment --comment serverinator-mss -j TCPMSS --set-mss 500" {next}
              {print}' "$IPTABLES_RULES_PATH" | reconcile_file "$IPTABLES_RULES_PATH" 600
        fi
    done
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

main() {
    parse_args "$@"

    case "$MODE" in
        uninstall)      uninstall_vps;  return ;;
        verify)         verify;         return ;;
        add-client)     add_client;     return ;;
        revoke-client)  revoke_client;  return ;;
    esac

    # MODE=setup
    info "ServerInator Core — setting up the VPS"
    [[ "$DEV" == "1" ]] && dev "DEV mode (WG_DIR=$WG_DIR, SYSTEMD_DIR=$SYSTEMD_DIR)"

    have_cmd jq || die "Install jq: apt-get install jq"

    info "[1/6] Reading handoff..."
    read_handoff

    info "[2/6] Installing dependencies..."
    install_deps
    install_wstunnel_vps

    info "[3/6] Setting up WireGuard..."
    setup_wireguard

    info "[4/6] Setting up wstunnel..."
    setup_wstunnel_server
    fix_pmtu_clamp

    info "[5/6] SSH keys and client script..."
    setup_vps_ssh_keys
    generate_client_setup

    info "[6/6] Generating back-handoff..."
    generate_back_handoff

    info "VPS configured."
    if [[ -n "${OWNER_CLIENT_SETUP_PATH:-}" ]]; then
        echo ""
        echo "  To connect from any device:"
        echo "    scp ${SSH_VPS_USER}@${VPS_IP}:${OWNER_CLIENT_SETUP_PATH} . && bash $(basename "${OWNER_CLIENT_SETUP_PATH}")"
        echo ""
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
