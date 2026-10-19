# shellcheck shell=bash
# ServerInator Core, VPS side: phone records (one back-handoff per phone), handoffs, list and remove
# Sourced by core-vps.sh, which holds the settings and globals used here.

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
# ARGS are joined into one command line for the phone's shell, so a script
# goes in as one string; for a program and its arguments use _phone_run.
_phone_ssh() {
    local vps_key="$SSH_KEY_DIR/vps_to_phone"
    [[ -f "$vps_key" ]] || die "VPS->phone key not found ($vps_key)"
    local opts=()
    phone_hostkey_opts "$DEVICE_NAME" "$SSH_HOST_PUBKEY"
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${opts[@]}" \
        -i "$vps_key" -p "$SSH_PHONE_PORT" "${SSH_USER}@${PHONE_WG_IP}" "$@"
}

# Runs PROGRAM ARGS... on the phone, each word quoted (remote_cmd).
_phone_run() { _phone_ssh "$(remote_cmd "$@")"; }

# ─────────────────────────────────────────────
# Step 6: Back-handoff
# ─────────────────────────────────────────────

generate_back_handoff() {
    local staged record
    ensure_wstunnel_path_prefix
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
        --arg  path_prefix     "${WSTUNNEL_PATH_PREFIX:-}" \
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
        } + (if $vps_domain == "" then {} else {vps_domain: $vps_domain} end)
          + (if $path_prefix == "" then {} else {wstunnel_path_prefix: $path_prefix} end)')" || die "jq: could not assemble the base back-handoff"

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
    # Its pinned host key too: a new phone with this name has another one.
    rm -f "$(phone_known_hosts_file "$name")"
    rm -f "$record"
    remove_device_guests "$name"
    info "Phone '$name' removed from this VPS."
    [[ -n "$(device_names)" ]] || info "No phones left; the VPS services stay installed (use --uninstall to remove everything)."
}
