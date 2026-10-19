# shellcheck shell=bash
# ServerInator Core, phone side: step 3, the login summary and si inside the chroot
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Step 3: Login summary and si in the chroot ───

# Installs core/motd.bash into the chroot and a profile.d stub that runs it
# for interactive bash logins only (sh logins and `ssh host cmd` skip it).
write_login_summary() {
    local src
    src="$CORE_DIR/motd.bash"
    [[ -f "$src" ]] || die "Missing $src next to core-phone.sh"
    [[ -n "$DEVICE_NAME" ]] || die "Device name not set. Pass --device-name NAME or set SERVERINATOR_DEVICE_NAME."
    validate_device_name "$DEVICE_NAME"
    mkdir -p "$CHROOT/usr/local/lib/serverinator" "$CHROOT/etc/profile.d"
    reconcile_file "$CHROOT/usr/local/lib/serverinator/motd.bash" 644 "$STATE_DIR/backups" < "$src"
    reconcile_file "$CHROOT/etc/profile.d/serverinator-motd.sh" 644 "$STATE_DIR/backups" << EOF
# ServerInator login summary (managed). Interactive bash logins only.
if [ -n "\${BASH_VERSION:-}" ]; then
    case \$- in
        *i*) . /usr/local/lib/serverinator/motd.bash && __si_motd '${DEVICE_NAME}'; unset -f __si_motd ;;
    esac
fi
EOF
}

# `si` inside the chroot (core/si with "chroot"), for `ssh ALIAS 'si status'`.
write_chroot_si() {
    local f
    for f in si lib.sh; do
        [[ -f "$CORE_DIR/$f" ]] || die "Missing $CORE_DIR/$f next to core-phone.sh"
    done
    mkdir -p "$CHROOT/usr/local/lib/serverinator" "$CHROOT/usr/local/bin"
    reconcile_file "$CHROOT/usr/local/lib/serverinator/si" 644 "$STATE_DIR/backups" < "$CORE_DIR/si"
    reconcile_file "$CHROOT/usr/local/lib/serverinator/lib.sh" 644 "$STATE_DIR/backups" < "$CORE_DIR/lib.sh"
    reconcile_file "$CHROOT/usr/local/bin/si" 755 "$STATE_DIR/backups" << 'EOF'
#!/bin/sh
# ServerInator: the si command (managed).
exec bash /usr/local/lib/serverinator/si chroot "$@"
EOF
}
