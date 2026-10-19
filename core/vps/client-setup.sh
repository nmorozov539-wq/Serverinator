# shellcheck shell=bash
# ServerInator Core, VPS side: the client setup scripts handed to the owner's devices
# Sourced by core-vps.sh, which holds the settings and globals used here.

# ─────────────────────────────────────────────
# Step 5: Generate client-setup.sh
# ─────────────────────────────────────────────

# _write_client_setup_script OUT ALIAS SI_NAME MODE KEY_BASE [LABEL]
# MODE: 1  the VPS made the key: the script carries the private key (handed
#          out once by --client-script, then deleted here)
#       0  the owner's existing VPS keys (--client-keys existing): no key
#       2  the client's own key: the script carries no secret. With
#          KEY_BASE.pub it only works where that key is; without (pairing)
#          it makes a key on the device and prints the command to approve it.
# Each alias gets its own jump block (ALIAS-jump) so one machine can hold
# keys for several phones or labels.
_write_client_setup_script() {
    local out="$1" alias="$2" si_name="$3" mode="$4" key_file="$5" label="${6:-owner}"
    local vhost; vhost="$(vps_public_host)"
    local created expected="" fp=""
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$mode" == 2 && -f "$key_file.pub" ]]; then
        expected="$(awk '{print $1" "$2; exit}' "$key_file.pub")"
        fp="$(ssh_key_fingerprint "$expected" | awk '{print $1}')"
    fi

    # The key material the script carries (mode 1 only).
    local key_mode=none b64="" pub=""
    case "$mode" in
        1) key_mode=carried
           b64="$(base64 -w 0 "$key_file")"
           pub="$(awk '{print $1" "$2}' "$key_file.pub")" ;;
        2) key_mode=own ;;
    esac

    # Host keys to pin on the client: the phone's under the alias name
    # (HostKeyAlias, so phones on different VPSes that share a tunnel IP
    # don't collide), and the VPS's under its address for the jump hop.
    local vps_key
    vps_key="$(vps_host_pubkey)"

    # A static script; only its settings block changes. Every value is
    # validated (alias, host, user, port, key, device name) and none can
    # hold a single quote.
    render_template "$CORE_DIR/templates/client-setup.sh" \
        "DEVICE_NAME=$DEVICE_NAME" "ALIAS=$alias" "VPS_IP=$VPS_IP" "CREATED=$created" "LABEL=$label" \
        "PHONE_IP=$PHONE_WG_IP" "PHONE_PORT=$SSH_PHONE_PORT" "PHONE_USER=$SSH_USER" \
        "VPS_HOST=$vhost" "VPS_USER=$SSH_VPS_USER" \
        "KEY_MODE=$key_mode" "KEY_NAME=$si_name" "KEY_EXPECTED=$expected" "KEY_FP=$fp" \
        "KEY_PUB=$pub" "KEY_B64=$b64" \
        "PHONE_HOSTKEY=${SSH_HOST_PUBKEY:-}" "VPS_HOSTKEY=$vps_key" > "$out"

    chmod 600 "$out"
    # Setups from before the Windows tool also had a .ps1 next to them, which
    # may hold a key.
    rm -f "${out%.sh}.ps1"
}

generate_client_setup() {
    [[ "$SSH_ENABLED" == "1" ]] || return 0

    local f="$SSH_KEY_DIR/client-setup-owner-${DEVICE_NAME}.sh" key="$SSH_KEY_DIR/owner_${DEVICE_NAME}" mode=0
    if [[ "$SSH_CLIENT_KEY_IS_NEW" == 1 ]]; then
        # Handed out once: after --client-script owner only the public key stays.
        if [[ -f "$key" ]]; then mode=1; else mode=2; fi
    fi
    _write_client_setup_script "$f" "$SSH_ALIAS" "si-${DEVICE_NAME}" "$mode" "$key" owner
    info "Client script: $f"
    # shellcheck disable=SC2034  # read by main in core-vps.sh
    OWNER_CLIENT_SETUP_PATH="$f"
}

# One-line command to fetch a client's setup script from this VPS onto
# another device and run it. si on the VPS sudoes itself for a sudo user.
fetch_hint() { # LABEL
    local label="$1" user="${SSH_VPS_USER:-root}" name="client-setup-$1-${DEVICE_NAME}.sh"
    printf '%s' "ssh ${user}@${VPS_IP} si client-script ${label} --device ${DEVICE_NAME} > ${name} && bash ${name}"
}

# The same on Windows: fetch the bash script, and let the repo's
# tools/client-setup-windows.ps1 apply it (untested so far).
windows_hint() { # LABEL
    local label="$1" user="${SSH_VPS_USER:-root}" name="client-setup-$1-${DEVICE_NAME}.sh"
    printf '%s' "ssh ${user}@${VPS_IP} si client-script ${label} --device ${DEVICE_NAME} > ${name} ; powershell -ExecutionPolicy Bypass -File client-setup-windows.ps1 ${name}"
}
