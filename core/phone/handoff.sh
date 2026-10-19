# shellcheck shell=bash
# ServerInator Core, phone side: step 4, the handoff for the VPS, and applying its back-handoff
# Sourced by core-phone.sh, which holds the settings and globals used here.

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

# ── After the VPS: apply the back-handoff ─────

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
    write_wstunnel_autostart "$vps_ip" "$vps_domain" "$(json_get "$BACK_HANDOFF_FILE" wstunnel_path_prefix)"

    # ── Write WireGuard autostart script ──────
    local wg_script="$MAGISK_SERVICE_D/20-serverinator-wireguard.sh"
    desired="$(mktemp "$MAGISK_SERVICE_D/wg-script.XXXXXX")"
    render_template "$CORE_DIR/templates/magisk-wireguard.sh" "STATE_DIR=$STATE_DIR" "CHROOT=$CHROOT" \
        "PHONE_WG_IP=$phone_wg_ip" "VPS_WG_NET=${vps_wg_ip%.*}" > "$desired"
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
