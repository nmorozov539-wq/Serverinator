# shellcheck shell=bash
# ServerInator Core, VPS side: client devices: add, revoke, list
# Sourced by core-vps.sh, which holds the settings and globals used here.

# Three ways in (owner's call, 2026-10-17: a key per device):
#   --pubkey KEY     the device's own key; nothing secret leaves it
#   (no key)         a pairing script: run on the device, it makes a key there
#                    and prints the --pubkey command to approve it
#   --generate-key   the VPS makes the key; the script carries it and is
#                    handed out once (--client-script), then deleted here
# --expires DATE puts expiry-time on the key, on the phone and on the VPS.
add_client() {
    _load_phone_state

    local ck="$SSH_KEY_DIR/owner_${DEVICE_NAME}_${CLIENT_LABEL}"
    local f="$SSH_KEY_DIR/client-setup-${CLIENT_LABEL}-${DEVICE_NAME}.sh"
    local alias="${SSH_ALIAS:-$SSH_ALIAS_DEFAULT}-${CLIENT_LABEL}" si_name="si-${DEVICE_NAME}-${CLIENT_LABEL}"
    [[ ! -f "$ck.pub" ]] \
        || die "Client '${CLIENT_LABEL}' already exists — run --revoke-client ${CLIENT_LABEL} first if you want to replace it"

    if [[ -z "$GUEST_PUBKEY" && "$CLIENT_GENERATE" == 0 ]]; then
        _write_client_setup_script "$f" "$alias" "$si_name" 2 "$ck" "$CLIENT_LABEL"
        echo ""
        echo "  Pairing script for '${CLIENT_LABEL}' (holds no key): $f"
        echo "  On that device, run:"
        echo "    $(fetch_hint "$CLIENT_LABEL")"
        echo "    Windows (untested): $(windows_hint "$CLIENT_LABEL")"
        echo "  It makes the device's own key and prints the command that approves it:"
        echo "    si add-client ${CLIENT_LABEL} --pubkey 'ssh-ed25519 ...'${CLIENT_EXPIRES:+ --expires DATE}"
        echo ""
        return 0
    fi

    local pub mode
    if [[ -n "$GUEST_PUBKEY" ]]; then
        pub="${GUEST_PUBKEY} serverinator:client:${DEVICE_NAME}:${CLIENT_LABEL}"
        local k
        for k in "$SSH_KEY_DIR"/owner_*.pub; do
            [[ -f "$k" ]] || continue
            [[ "$(awk '{print $1" "$2}' "$k")" != "$GUEST_PUBKEY" ]] \
                || die "That key is already in use (${k##*/}); one key per device"
        done
        (umask 077; printf '%s\n' "$pub" > "$ck.pub")
        mode=2
    else
        require_cmd ssh-keygen
        ssh-keygen -t ed25519 -N '' \
            -C "serverinator:client:${DEVICE_NAME}:${CLIENT_LABEL}" -f "$ck" >/dev/null
        chmod 600 "$ck"
        pub="$(cat "$ck.pub")"
        mode=1
    fi
    if [[ -n "$CLIENT_EXPIRES" ]]; then
        (umask 077; printf '%s\n' "$CLIENT_EXPIRES" > "$ck.expires")
    fi

    local line="$pub"
    [[ -z "$CLIENT_EXPIRES" ]] || line="expiry-time=\"${CLIENT_EXPIRES}\" ${pub}"
    printf '%s\n' "$line" | _phone_ssh '
        set -e
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
        key="$(cat)"
        if ! grep -qFx -- "$key" ~/.ssh/authorized_keys; then
            [ -z "$(tail -c 1 ~/.ssh/authorized_keys)" ] || echo >> ~/.ssh/authorized_keys
            printf "%s\n" "$key" >> ~/.ssh/authorized_keys
        fi
    ' || { rm -f "$ck" "$ck.pub" "$ck.expires"; die "Could not add the client key on the phone — is the tunnel up?"; }

    # This key is not in the VPS's authorized_keys, so ProxyJump with it
    # would fail at the jump host without a restricted jump entry.
    _authorize_vps_jump_key "$pub" "$PHONE_WG_IP" "$SSH_PHONE_PORT" "$CLIENT_EXPIRES"

    info "Client '${CLIENT_LABEL}' added on the phone${CLIENT_EXPIRES:+ (works until ${CLIENT_EXPIRES:0:4}-${CLIENT_EXPIRES:4:2}-${CLIENT_EXPIRES:6:2})}"
    _write_client_setup_script "$f" "$alias" "$si_name" "$mode" "$ck" "$CLIENT_LABEL"

    echo ""
    if [[ "$mode" == 2 ]]; then
        echo "  Approved. If that device ran the pairing script, ssh ${alias} works now."
        echo "  Otherwise, set it up there with:"
    else
        echo "  The VPS made this key. Its setup script carries it and can be"
        echo "  fetched once; after that the private key is deleted here."
        echo "  On that device, run:"
    fi
    echo "    $(fetch_hint "$CLIENT_LABEL")"
    echo "    Windows (untested): $(windows_hint "$CLIENT_LABEL")"
    echo ""
}

revoke_client() {
    _load_phone_state

    local ck="$SSH_KEY_DIR/owner_${DEVICE_NAME}_${CLIENT_LABEL}"
    local scripts=("$SSH_KEY_DIR/client-setup-${CLIENT_LABEL}-${DEVICE_NAME}".{sh,ps1})
    if [[ ! -f "$ck.pub" ]]; then
        # A pairing script nobody approved yet: nothing to revoke but the script.
        [[ -f "${scripts[0]}" ]] || die "Client '${CLIENT_LABEL}' not found (no file $ck.pub)"
        rm -f "${scripts[@]}"
        info "Pairing for '${CLIENT_LABEL}' cancelled (it was never approved)"
        return 0
    fi
    local pub expiry line
    pub="$(cat "$ck.pub")"
    expiry="$(client_expiry "$ck")"
    line="$pub"
    [[ -z "$expiry" ]] || line="expiry-time=\"${expiry}\" ${pub}"

    # The VPS hop first: it works without the phone, and alone it locks the
    # key out (every client reaches the phone through it). A lost laptop can
    # be revoked while the phone is offline (review B5).
    _revoke_vps_jump_key "$pub" "$PHONE_WG_IP" "$SSH_PHONE_PORT" "$expiry"
    rm -f "$ck" "${scripts[@]}"
    info "Client '${CLIENT_LABEL}' can no longer pass the VPS"

    local removed rc=0
    removed="$(printf '%s\n%s\n' "$pub" "$line" | _phone_ssh '
        set -e
        [ -f ~/.ssh/authorized_keys ] || { echo 0; exit 0; }
        read -r key; read -r line
        before=$(grep -cFx -e "$key" -e "$line" ~/.ssh/authorized_keys || true)
        tmp=$(mktemp ~/.ssh/authorized_keys.XXXXXX)
        grep -vFx -e "$key" -e "$line" ~/.ssh/authorized_keys > "$tmp" || [ $? -eq 1 ]
        chmod 600 "$tmp"
        mv "$tmp" ~/.ssh/authorized_keys
        echo "$before"
    ')" || rc=$?
    if [[ "$rc" != 0 ]]; then
        warn "The phone didn't answer, so its authorized_keys still lists '${CLIENT_LABEL}'."
        warn "Run si revoke-client ${CLIENT_LABEL} again once the tunnel is up to clean it."
        return 1
    fi
    if [[ "$removed" == "0" ]]; then
        warn "Client key '${CLIENT_LABEL}' was not found in the phone's authorized_keys (maybe already revoked)"
    else
        info "Client '${CLIENT_LABEL}' revoked on the phone"
    fi
    rm -f "$ck.pub" "$ck.expires"
    info "Local files for client '${CLIENT_LABEL}' removed"
}

# --client-script LABEL: prints a client's setup script, made
# fresh (so a domain change or new host key is in it). A script that
# carries a key the VPS made is handed out once: afterwards the private key
# is deleted here and the script only works on the device that has it.
client_script() {
    _load_phone_state
    local label="$CLIENT_LABEL" ck f alias si_name mode
    if [[ "$label" == owner ]]; then
        ck="$SSH_KEY_DIR/owner_${DEVICE_NAME}"
        f="$SSH_KEY_DIR/client-setup-owner-${DEVICE_NAME}.sh"
        alias="${SSH_ALIAS:-$SSH_ALIAS_DEFAULT}"; si_name="si-${DEVICE_NAME}"
    else
        ck="$SSH_KEY_DIR/owner_${DEVICE_NAME}_${label}"
        f="$SSH_KEY_DIR/client-setup-${label}-${DEVICE_NAME}.sh"
        alias="${SSH_ALIAS:-$SSH_ALIAS_DEFAULT}-${label}"; si_name="si-${DEVICE_NAME}-${label}"
    fi
    if [[ -f "$ck" ]]; then mode=1
    elif [[ -f "$ck.pub" || -f "$f" ]]; then mode=2
    elif [[ "$label" == owner ]]; then mode=0
    else die "No client '${label}' for ${DEVICE_NAME} (si clients lists them; si add-client ${label} makes one)"
    fi
    _write_client_setup_script "$f" "$alias" "$si_name" "$mode" "$ck" "$label" >&2
    cat "$f"
    if [[ "$mode" == 1 ]]; then
        rm -f "$ck"
        _write_client_setup_script "$f" "$alias" "$si_name" 2 "$ck" "$label" >&2
        warn "That script was the only copy of ${label}'s private key; it's deleted from the VPS now." >&2
        warn "Fetching it again gives one that only works on the device that ran this one." >&2
    fi
}

# Last login per key fingerprint, from sshd's log on this VPS: every client
# jumps through here, so this sees them all. Fills LAST_SEEN[SHA256:...]
# with "YYYY-MM-DD HH:MM IP".
declare -A LAST_SEEN=()
load_last_seen() {
    local lines
    if [[ -n "${SERVERINATOR_AUTH_LOG:-}" ]]; then
        lines="$(grep -h 'Accepted publickey' "$SERVERINATOR_AUTH_LOG" 2>/dev/null || true)"
    elif have_cmd journalctl; then
        lines="$(journalctl --no-pager -q -o short-iso --since -90d _COMM=sshd -g 'Accepted publickey' 2>/dev/null \
            || journalctl --no-pager -q -o short-iso --since -90d -u ssh -u sshd 2>/dev/null | grep 'Accepted publickey' || true)"
    else
        lines="$(grep -h 'Accepted publickey' /var/log/auth.log 2>/dev/null || true)"
    fi
    local ts ip fp
    while read -r ts ip fp; do
        if [[ "$fp" == SHA256:* ]]; then LAST_SEEN["$fp"]="$ts $ip"; fi
    done < <(awk '{
        ip=""; for (i=1; i<=NF; i++) if ($i=="from") ip=$(i+1)
        t=$1; sub(/T/, " ", t); t=substr(t, 1, 16)
        print substr(t,1,10) "_" substr(t,12,5), ip, $NF }' <<< "$lines")
}

# Lists who has SSH access to the phone, from the keys kept on this VPS. Works
# without the tunnel; it shows what the VPS issued, not a live read of the
# phone's authorized_keys.
list_clients() {
    _load_phone_state
    local alias="${SSH_ALIAS:-$SSH_ALIAS_DEFAULT}" f label fp created count=0 base exp seen pending=()
    load_last_seen

    _list_client_row() { # LABEL ALIAS PUBFILE
        fp="$(ssh_key_fingerprint "$(cat "$3")" | awk '{print $1}')"
        created="$(date -u -r "$3" +%Y-%m-%d 2>/dev/null || echo '?')"
        base="${3%.pub}"; exp="$(client_expiry "$base")"
        if [[ -z "$exp" ]]; then exp=never
        elif [[ "$exp" < "$(date -u +%Y%m%d)" || "$exp" == "$(date -u +%Y%m%d)" ]]; then exp="EXPIRED"
        else exp="${exp:0:4}-${exp:4:2}-${exp:6:2}"; fi
        seen="${LAST_SEEN[$fp]:-}"
        printf '  %-14s %-20s %-10s %-10s %-16s %-15s %s\n' "$1" "$2" "$created" "$exp" \
            "${seen:+${seen%% *}}" "${seen:+${seen##* }}" "${fp:0:20}"
    }

    echo ""
    echo "  SSH access to ${DEVICE_NAME} (via ${VPS_IP})"
    echo ""
    printf '  %-14s %-20s %-10s %-10s %-16s %-15s %s\n' LABEL ALIAS CREATED EXPIRES LAST-LOGIN FROM KEY
    if [[ -f "$SSH_KEY_DIR/owner_${DEVICE_NAME}.pub" ]]; then
        _list_client_row owner "$alias" "$SSH_KEY_DIR/owner_${DEVICE_NAME}.pub"
    else
        printf '  %-14s %s\n' owner "(your existing VPS keys; installed with --client-keys existing)"
    fi
    while IFS= read -r f; do
        label="${f##*/owner_${DEVICE_NAME}_}"; label="${label%.pub}"
        validate_client_label "$label"
        _list_client_row "$label" "${alias}-${label}" "$f"
        count=$((count + 1))
    done < <(device_client_pubs "$DEVICE_NAME")
    for f in "$SSH_KEY_DIR"/client-setup-*-"${DEVICE_NAME}".sh; do
        [[ -e "$f" ]] || continue
        label="${f##*/client-setup-}"; label="${label%-"${DEVICE_NAME}".sh}"
        [[ "$label" != owner && ! -f "$SSH_KEY_DIR/owner_${DEVICE_NAME}_${label}.pub" ]] || continue
        pending+=("$label")
    done
    echo ""
    (( ${#pending[@]} == 0 )) || info "Waiting for approval: ${pending[*]} (si add-client LABEL --pubkey KEY)"
    info "${count} extra client(s). Add: si add-client LABEL   Remove: si revoke-client LABEL"
}
