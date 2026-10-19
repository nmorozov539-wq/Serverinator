# shellcheck shell=bash
# ServerInator Core, phone side: step 3, guest support in sshd
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Step 3: Guests ────────────────────────────
#
# Guests (core-vps.sh --add-guest) come in two kinds: files-only users in
# the serverinator-guests group (internal-sftp, chrooted to a room holding
# their one folder), and shell users in the serverinator-shell group (a
# normal account, no root). This installs the helper the VPS drives
# (core/guest-helper.sh) and the sshd rules for both groups. The rules live
# in their own file, included at the very END of sshd_config: a Match block
# applies to everything after it, so nothing of the main config may follow.

GUEST_SSHD_CONF="/etc/ssh/serverinator-guests.conf"
GUEST_HELPER="/usr/local/sbin/serverinator-guests"

# The VPS's hop asks for the "sftp" subsystem, and sshd refuses that
# request (even under ForceCommand internal-sftp) unless some Subsystem sftp
# line exists. Debian's sshd_config has one; add ours only when it doesn't,
# because a second definition is an error.
sshd_has_sftp_subsystem() {
    local f
    for f in "$CHROOT/etc/ssh/sshd_config" "$CHROOT/etc/ssh/sshd_config.d/"*.conf; do
        [[ -f "$f" ]] || continue
        grep -qiE '^[[:space:]]*Subsystem[[:space:]]+sftp[[:space:]]' "$f" && return 0
    done
    return 1
}

guest_sshd_conf() {
    echo "# Managed by ServerInator. Files guests: SFTP only, locked to their room."
    echo "# Shell guests: a normal shell; only the key the owner added logs them in."
    sshd_has_sftp_subsystem || echo "Subsystem sftp internal-sftp"
    cat << 'EOF'
Match Group serverinator-guests
    AuthorizedKeysFile /etc/ssh/serverinator-guests/%u
    ChrootDirectory /srv/guests/%u
    ForceCommand internal-sftp -u 0002
    DisableForwarding yes
    PermitTTY no
    PermitTunnel no
Match Group serverinator-shell
    AuthorizedKeysFile /etc/ssh/serverinator-guests/%u
    DisableForwarding yes
    PermitTunnel no
EOF
}

# Keeps "Include GUEST_SSHD_CONF" as the last line of sshd_config.
ensure_guest_include() {
    local main="$CHROOT/etc/ssh/sshd_config" inc="Include $GUEST_SSHD_CONF" tmp
    if [[ -f "$main" ]] && [[ "$(grep -v '^[[:space:]]*$' "$main" | tail -n 1)" == "$inc" ]]; then
        return 0
    fi
    tmp="$(mktemp "$CHROOT/etc/ssh/sshd_config.XXXXXX")" || die "Unable to create sshd_config temp file"
    {
        [[ ! -f "$main" ]] || grep -vFx -- "$inc" "$main" || true
        printf '%s\n' "$inc"
    } > "$tmp"
    reconcile_file "$main" 600 "$STATE_DIR/backups" < "$tmp"
    rm -f "$tmp"
}

install_guest_support() {
    [[ "$ENABLE_SSH" == 1 ]] || return 0
    local src="$CORE_DIR/guest-helper.sh" before after
    [[ -f "$src" ]] || die "Missing $src next to core-phone.sh"
    mkdir -p "$CHROOT/usr/local/sbin" "$CHROOT/etc/ssh"
    before="$(sshd_config_sum)"
    reconcile_file "$CHROOT$GUEST_HELPER" 755 "$STATE_DIR/backups" < "$src"
    guest_sshd_conf | reconcile_file "$CHROOT$GUEST_SSHD_CONF" 644 "$STATE_DIR/backups"
    ensure_sshd_include
    ensure_guest_include
    after="$(sshd_config_sum)"
    [[ "$before" == "$after" ]] || reload_running_sshd
}
