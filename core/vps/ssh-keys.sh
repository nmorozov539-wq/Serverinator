# shellcheck shell=bash
# ServerInator Core, VPS side: SSH keys: the VPS jump keys, client key expiry, the phone's host key
# Sourced by core-vps.sh, which holds the settings and globals used here.

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

# parse_expiry 30d|YYYY-MM-DD -> YYYYMMDD (a future date), for --expires.
parse_expiry() {
    local spec="$1" day today
    today="$(date -u +%Y%m%d)"
    if [[ "$spec" =~ ^([0-9]{1,4})d$ ]]; then
        day="$(date -u -d "+${BASH_REMATCH[1]} days" +%Y%m%d)" || return 1
    elif [[ "$spec" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        day="$(date -u -d "$spec" +%Y%m%d 2>/dev/null)" || { error "--expires: no such date: $spec"; return 1; }
    else
        error "--expires: use 30d (days from now) or a date like 2026-12-31"; return 1
    fi
    [[ "$day" > "$today" ]] || { error "--expires: $spec is not in the future"; return 1; }
    printf '%s\n' "$day"
}

# The expiry kept next to a client key (empty: never expires).
client_expiry() { # KEY_BASE (…/owner_DEV_LABEL)
    [[ -f "$1.expires" ]] && head -n 1 "$1.expires" | grep -E '^[0-9]{8}$' || true
}

# Builds the authorized_keys line for a jump key: NEITHER port-forwarding
# NOR restrict on their own block exec/shell (restrict only disables
# pty/agent/X11-forwarding and ~/.ssh/rc) — an explicit command= is
# mandatory, otherwise the key gets a full shell on the VPS.
_vps_jump_key_line() {
    local pub="$1" phone_ip="$2" phone_port="$3" expiry="${4:-}" exp=""
    [[ -z "$expiry" ]] || exp=",expiry-time=\"${expiry}\""
    printf 'command="echo '\''ServerInator: forwarding-only key, no shell access'\''; exit 1",restrict,port-forwarding,permitopen="%s:%s"%s %s' \
        "$phone_ip" "$phone_port" "$exp" "$pub"
}

# Adds a restricted entry to the VPS admin's authorized_keys — only
# port-forwarding to the phone's specific address, no shell. Needed because
# ProxyJump with a freshly-generated key (which is not yet in the VPS's
# authorized_keys) would otherwise fail at the jump host.
_authorize_vps_jump_key() {
    local pub="$1" phone_ip="$2" phone_port="$3" expiry="${4:-}" user_home auth_file line
    user_home="$(_vps_user_home)" || die "Could not get the VPS admin's home directory"
    [[ -n "$user_home" ]] || die "Empty home directory for the VPS admin"
    auth_file="$user_home/.ssh/authorized_keys"
    mkdir -p "$user_home/.ssh"
    chmod 700 "$user_home/.ssh"
    touch "$auth_file"
    chmod 600 "$auth_file"
    line="$(_vps_jump_key_line "$pub" "$phone_ip" "$phone_port" "$expiry")"
    grep -qFx -- "$line" "$auth_file" && return 0
    # Without a final newline the admin's last key would fuse with ours (B4).
    [[ ! -s "$auth_file" || -z "$(tail -c 1 "$auth_file")" ]] || echo >> "$auth_file"
    printf '%s\n' "$line" >> "$auth_file"
}

# Removes the jump entry added by _authorize_vps_jump_key for this key.
_revoke_vps_jump_key() {
    local pub="$1" phone_ip="$2" phone_port="$3" expiry="${4:-}" user_home auth_file line
    user_home="$(_vps_user_home)" || die "Could not get the VPS admin's home directory"
    auth_file="$user_home/.ssh/authorized_keys"
    [[ -f "$auth_file" ]] || return 0
    line="$(_vps_jump_key_line "$pub" "$phone_ip" "$phone_port" "$expiry")"
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

    # shellcheck disable=SC2034  # read by the client setup and the back-handoff
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
    # shellcheck disable=SC2034  # read by generate_back_handoff
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
        # The public half decides: after --client-script owner only it stays,
        # and the owner's devices still hold the private key.
        if [[ ! -f "$ck.pub" ]]; then
            ssh-keygen -t ed25519 -N '' \
                -C "serverinator:owner:${DEVICE_NAME}" -f "$ck" >/dev/null
            chmod 600 "$ck"
            info "Generated a new client key: $ck"
        else
            info "Client key already exists: $ck"
        fi
        SSH_CLIENT_KEYS=("$(cat "$ck.pub")")
        # shellcheck disable=SC2034  # read by generate_client_setup
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
        # shellcheck disable=SC2034  # the caller's array
        opts=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$file" -o "HostKeyAlias=serverinator-$device")
    else
        # shellcheck disable=SC2034  # the caller's array
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
