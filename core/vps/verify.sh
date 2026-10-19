# shellcheck shell=bash
# ServerInator Core, VPS side: --verify
# Sourced by core-vps.sh, which holds the settings and globals used here.

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
