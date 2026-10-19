# shellcheck shell=bash
# ServerInator Core, phone side: step 3, the SSH server (tunnel-only) and its autostart; SSH access from the back-handoff
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Step 3: SSH server (tunnel-only) ──────────

# Make sure the main sshd_config actually reads our drop-in directory.
ensure_sshd_include() {
    local main="$CHROOT/etc/ssh/sshd_config"
    local inc='Include /etc/ssh/sshd_config.d/*.conf'
    if [[ -f "$main" ]] && grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$' "$main"; then
        return 0
    fi
    local tmp
    tmp="$(mktemp "$CHROOT/etc/ssh/sshd_config.XXXXXX")" || die "Unable to create sshd_config temp file"
    {
        printf '%s\n' "$inc"
        if [[ -f "$main" ]]; then
            cat "$main"
        fi
    } > "$tmp"
    reconcile_file "$main" 600 "$STATE_DIR/backups" < "$tmp"
    rm -f "$tmp"
}

validate_effective_sshd() {
    local expected_ip="${1:-}" effective
    effective="$(chroot_run /usr/sbin/sshd -T)" || die "Cannot read effective sshd configuration"
    [[ "$(printf '%s\n' "$effective" | awk 'tolower($1)=="port" {print $2}')" == "$SSH_PORT" ]]         || die "Effective sshd Port differs from managed port"
    [[ "$(printf '%s\n' "$effective" | awk 'tolower($1)=="passwordauthentication" {print $2}')" == no ]]         || die "Effective sshd enables password authentication"
    if [[ -n "$expected_ip" ]]; then
        printf '%s\n' "$effective" | awk -v want="$expected_ip:$SSH_PORT" '
          tolower($1)=="listenaddress" {n++; if($2!=want) bad=1}
          END {exit (n==0 || bad)}' || die "Effective sshd ListenAddress is not tunnel-only"
    fi
}

prepare_sshd_runtime() {
    [[ "$ENABLE_SSH" == 1 ]] || return 0
    [[ "$DEV" != 1 ]] || { dev "Skipping real sshd validation in DEV"; return 0; }
    local status
    status="$(chroot_run /usr/bin/dpkg-query -W -f='${Status}' openssh-server)"         || die "openssh-server is absent from dpkg"
    [[ "$status" == "install ok installed" ]] || die "openssh-server is not configured"
    if chroot_run /usr/bin/getent passwd sshd; then
        : # Existing package account is preserved.
    else
        local rc=$?
        [[ "$rc" == 2 ]] || die "Cannot query sshd account (getent=$rc)"
        chroot_run /usr/sbin/useradd --system --no-create-home             --home-dir /run/sshd --shell /usr/sbin/nologin sshd
    fi
    chroot_run /usr/bin/mkdir -p /run/sshd
    chroot_run /usr/bin/chmod 0755 /run/sshd
    chroot_run /usr/sbin/sshd -t || die "Invalid sshd configuration"
    validate_effective_sshd "${1:-}"
}

# ListenAddress currently in our sshd drop-in, or 127.0.0.1 when there is
# none (fresh install, or a drop-in from before ListenAddress was managed).
current_sshd_listen_ip() {
    local conf="$CHROOT/etc/ssh/sshd_config.d/00-serverinator.conf" ip=""
    if [[ -f "$conf" ]]; then
        ip="$(awk '$1=="ListenAddress" {print $2; exit}' "$conf")"
    fi
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && (validate_ipv4 "$ip") 2>/dev/null; then
        printf '%s\n' "$ip"
    else
        printf '%s\n' 127.0.0.1
    fi
}

# write_sshd_dropin LISTEN_IP — the single source of the managed sshd config.
write_sshd_dropin() {
    local listen_ip="$1"
    validate_ipv4 "$listen_ip" "sshd listen IPv4"
    mkdir -p "$CHROOT/etc/ssh/sshd_config.d"
    render_template "$CORE_DIR/templates/sshd-serverinator.conf" "SSH_PORT=$SSH_PORT" "LISTEN_IP=$listen_ip" \
        | reconcile_file "$CHROOT/etc/ssh/sshd_config.d/00-serverinator.conf" 644 "$STATE_DIR/backups"
}

install_ssh_server() {
    if [[ "$ENABLE_SSH" != "1" ]]; then
        info "SSH support disabled (--no-ssh)"
        return 0
    fi
    if [[ "$DEV" == "1" ]]; then
        dev "DEV mode: skipping sshd setup"
        return 0
    fi

    [[ -f "$CHROOT/usr/sbin/sshd" ]] || die "openssh-server is not installed inside the chroot"

    mkdir -p "$CHROOT/run/sshd" "$CHROOT/etc/ssh/sshd_config.d"
    chmod 0755 "$CHROOT/run/sshd"
    ensure_sshd_include

    # Host keys live outside the chroot so a chroot rebuild keeps the phone's
    # identity (and clients don't get spurious known_hosts warnings).
    mkdir -p "$SSH_HOSTKEY_DIR"
    chmod 700 "$SSH_HOSTKEY_DIR"

    local persisted=0 f
    for f in "$SSH_HOSTKEY_DIR"/ssh_host_*_key; do
        [[ -e "$f" ]] && persisted=1
    done
    if [[ "$persisted" == "1" ]]; then
        cp -f "$SSH_HOSTKEY_DIR"/ssh_host_*_key "$CHROOT/etc/ssh/"
        cp -f "$SSH_HOSTKEY_DIR"/ssh_host_*_key.pub "$CHROOT/etc/ssh/"
        info "Restored persisted SSH host keys"
    else
        for f in "$CHROOT/etc/ssh"/ssh_host_*_key; do
            [[ -e "$f" ]] || continue
            cp -f "$f" "$SSH_HOSTKEY_DIR/"
            cp -f "${f}.pub" "$SSH_HOSTKEY_DIR/" 2>/dev/null || true
        done
        info "Persisted SSH host keys to $SSH_HOSTKEY_DIR"
    fi
    for f in "$CHROOT/etc/ssh"/ssh_host_*_key; do
        [[ -e "$f" ]] || continue
        chmod 600 "$f"
    done

    # Base sshd config. Never listen on every interface: keep the tunnel
    # address from a previous apply, or loopback until the back-handoff
    # supplies one. A re-run whose later steps fail must not leave sshd
    # exposed on Wi-Fi/cellular after the next reboot.
    SSHD_LISTEN_IP="$(current_sshd_listen_ip)"
    write_sshd_dropin "$SSHD_LISTEN_IP"

    SSH_HOST_FINGERPRINT="$(chroot_run /usr/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}')"
    # The public host key itself (type and key, no comment) goes in the
    # handoff so the VPS and every client can pin it instead of trusting
    # the first connection.
    SSH_HOST_PUBKEY="$(awk '{print $1" "$2; exit}' "$CHROOT/etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null || true)"
    if [[ -n "$SSH_HOST_PUBKEY" ]] && ! is_plain_pubkey "$SSH_HOST_PUBKEY"; then
        warn "The SSH host key file doesn't look like a public key; it won't be pinned"
        SSH_HOST_PUBKEY=""
    fi
    if [[ -n "$SSH_HOST_FINGERPRINT" ]]; then
        info "SSH host key fingerprint: $SSH_HOST_FINGERPRINT"
    else
        warn "Could not read SSH host key fingerprint"
    fi
}

# Checksum of the sshd config files guest support touches.
sshd_config_sum() {
    { cat "$CHROOT/etc/ssh/sshd_config" "$CHROOT$GUEST_SSHD_CONF" 2>/dev/null || :; } | cksum
}

# A running sshd keeps the config it started with, so new guest rules would
# only apply after a reboot. SIGHUP makes it re-read the config; open
# sessions stay up. Only our own sshd (the PID the autostart recorded, rooted
# in this chroot) is signalled.
reload_running_sshd() {
    [[ "$DEV" != 1 ]] || return 0
    local pidfile="$STATE_DIR/run/sshd.pid" pid=""
    [[ -f "$pidfile" ]] || return 0
    read -r pid < "$pidfile" || return 0
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    [[ "$(readlink "/proc/$pid/root" 2>/dev/null)" == "$CHROOT" ]] || return 0
    chroot_run /usr/sbin/sshd -t || die "Invalid sshd configuration; the running sshd was left as it was"
    kill -HUP "$pid" || { warn "Could not reload sshd; reboot the phone to apply the guest rules"; return 0; }
    info "sshd reloaded with the guest rules"
}

write_sshd_autostart() {
    [[ "$ENABLE_SSH" == "1" ]] || return 0

    local script_path="$MAGISK_SERVICE_D/30-serverinator-sshd.sh"
    mkdir -p "$MAGISK_SERVICE_D"
    local desired
    desired="$(mktemp "$MAGISK_SERVICE_D/script.XXXXXX")"
    render_template "$CORE_DIR/templates/magisk-sshd.sh" "STATE_DIR=$STATE_DIR" "CHROOT=$CHROOT" > "$desired"
    reconcile_file "$script_path" 700 "$STATE_DIR/backups" < "$desired"
    rm -f "$desired"
    info "sshd autostart written: $script_path"
}

# ── After the VPS: SSH access from the back-handoff ───

AK_BEGIN="# >>> ServerInator managed keys (replaced on every apply) >>>"
AK_END="# <<< ServerInator managed keys <<<"

# write_managed_authorized_keys FILE KEY...
# Replaces the managed block with KEY... and keeps every other line. Lines
# outside the block that older versions appended (the VPS->phone key and owner
# keys, recognised by their serverinator comments) are dropped as part of the
# migration, as are exact duplicates of a managed key. --add-client keys
# (comment serverinator:client:...) are left for --revoke-client.
write_managed_authorized_keys() {
    local ak="$1"; shift
    local staged line k in_block=0
    mkdir -p "$(dirname "$ak")"
    staged="$(mktemp "${ak}.XXXXXX")" || die "Could not create a temp file for $ak"
    {
        if [[ -f "$ak" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" == "$AK_BEGIN" ]]; then in_block=1; continue; fi
                if [[ "$line" == "$AK_END" ]]; then in_block=0; continue; fi
                ((in_block)) && continue
                [[ "$line" =~ [[:space:]](serverinator-vps-|serverinator:owner:)[^[:space:]]*$ ]] && continue
                for k in "$@"; do [[ "$line" == "$k" ]] && continue 2; done
                printf '%s\n' "$line"
            done < "$ak"
        fi
        printf '%s\n' "$AK_BEGIN"
        for k in "$@"; do printf '%s\n' "$k"; done
        printf '%s\n' "$AK_END"
    } > "$staged"
    ((in_block == 0)) || { rm -f "$staged"; die "Unterminated managed block in $ak; fix it by hand"; }
    reconcile_file "$ak" 600 "$STATE_DIR/backups" < "$staged"
    rm -f "$staged"
}

apply_ssh_config() {
    if [[ "$ENABLE_SSH" != "1" ]]; then
        info "SSH skipped (--no-ssh)"
        return 0
    fi
    local enabled
    enabled="$(json_get_num "$BACK_HANDOFF_FILE" ssh_enabled)"
    enabled="${enabled:-0}"
    if [[ "$enabled" != "1" ]]; then
        info "SSH not enabled for this device; skipping SSH setup"
        return 0
    fi

    [[ -f "$CHROOT/usr/sbin/sshd" ]] || die "openssh-server is missing in the chroot; re-run phone setup"

    local phone_wg_ip ssh_user vps_to_phone fp count
    phone_wg_ip="$(json_get "$BACK_HANDOFF_FILE" ssh_phone_ip)"
    ssh_user="$(json_get "$BACK_HANDOFF_FILE" ssh_user)"; ssh_user="${ssh_user:-root}"
    vps_to_phone="$(json_get "$BACK_HANDOFF_FILE" ssh_vps_to_phone_pubkey)"
    fp="$(json_get "$BACK_HANDOFF_FILE" ssh_host_fingerprint)"
    count="$(json_get_num "$BACK_HANDOFF_FILE" ssh_client_key_count)"; count="${count:-0}"

    [[ -n "$phone_wg_ip" ]] || die "back-handoff: missing ssh_phone_ip"
    validate_ipv4 "$phone_wg_ip" "SSH listen IPv4"
    [[ "$phone_wg_ip" == "$(json_get "$BACK_HANDOFF_FILE" phone_wg_ip)" ]] || die "SSH listen IP differs from phone WG IP"
    [[ "$count" =~ ^[0-9]{1,3}$ ]] && ((count <= 128)) || die "Invalid client key count"
    [[ "$ssh_user" == "$SSH_USER" ]] || warn "back-handoff ssh_user '$ssh_user' differs from '$SSH_USER' (using $SSH_USER)"

    # sshd config now that the tunnel IP is known.
    mkdir -p "$CHROOT/etc/ssh/sshd_config.d" "$CHROOT/run/sshd" "$CHROOT/root/.ssh"
    chmod 0755 "$CHROOT/run/sshd"
    chmod 700 "$CHROOT/root/.ssh"
    ensure_sshd_include
    write_sshd_dropin "$phone_wg_ip"

    # authorized_keys: the keys from the back-handoff live in a managed block
    # that is replaced on every apply, so keys from an old VPS or a previous
    # install stop working. Lines outside the block (hand-added keys, and
    # --add-client keys) are preserved.
    local ak="$CHROOT/root/.ssh/authorized_keys"
    local -a managed=()
    local i key
    for ((i = 0; i <= count; i++)); do
        if ((i == 0)); then
            key="$vps_to_phone"
        else
            key="$(json_get "$BACK_HANDOFF_FILE" "ssh_client_key_${i}")"
        fi
        [[ -n "$key" ]] || continue
        is_plain_pubkey "$key" || die "back-handoff: SSH key $i is not a plain public key"
        managed+=("$key")
    done
    write_managed_authorized_keys "$ak" ${managed[@]+"${managed[@]}"}
    if [[ -f "$IDENTITY_DIR/pending-extra-keys" ]]; then
        merge_extra_keys "$ak" "$IDENTITY_DIR/pending-extra-keys"
        rm -f "$IDENTITY_DIR/pending-extra-keys"
    fi

    prepare_sshd_runtime "$phone_wg_ip"
    write_sshd_autostart
    info "SSH authorized_keys: ${#managed[@]} managed key(s)"
    if [[ -n "$fp" ]]; then
        info "Phone SSH host key fingerprint: $fp"
    fi
}
