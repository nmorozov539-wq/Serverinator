# shellcheck shell=bash
# ServerInator Core, phone side: identity export and import
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Identity backup / restore ─────────────────
#
# --export-identity FILE writes a tar with everything that makes this phone
# "the same phone" to the VPS and to clients:
#   wireguard/client.key, client.pub   the tunnel key the VPS has as a peer
#   ssh/ssh_host_*_key[.pub]           the host key clients have pinned
#   orchestrator/id_ed25519[.pub]      serverinator.sh's key for the VPS
#   extra-keys                         authorized_keys lines outside the
#                                      managed block (--add-client keys and
#                                      hand-added keys)
#   manifest                           format, device name, public key
# --import-identity FILE puts those back on a new or reset phone, before
# serverinator.sh is run with the same device name and VPS. The VPS then
# sees the same peer and nothing on it or on clients has to change.

IDENTITY_TOP="serverinator-identity"

# Prints authorized_keys lines that live outside the managed block and are
# plain public keys (no options but a client's expiry-time), one per line.
extra_authorized_keys() {
    local ak="$1" line in_block=0
    [[ -f "$ak" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$AK_BEGIN" ]]; then in_block=1; continue; fi
        if [[ "$line" == "$AK_END" ]]; then in_block=0; continue; fi
        ((in_block)) && continue
        [[ "$line" =~ [[:space:]](serverinator-vps-|serverinator:owner:)[^[:space:]]*$ ]] && continue
        is_client_key_line "$line" && printf '%s\n' "$line"
    done < "$ak"
    return 0
}

# merge_extra_keys AUTHORIZED_KEYS KEYS_FILE: appends lines not already there.
merge_extra_keys() {
    local ak="$1" keys="$2" line added=0
    mkdir -p "$(dirname "$ak")"; chmod 700 "$(dirname "$ak")"
    touch "$ak"; chmod 600 "$ak"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        grep -qFx -- "$line" "$ak" && continue
        printf '%s\n' "$line" >> "$ak"; added=$((added + 1))
    done < "$keys"
    ((added == 0)) || info "Restored $added extra SSH key(s) (clients, hand-added keys)"
}

export_identity() {
    local out="$1" wg_dir name stage f n=0
    check_root
    [[ -n "$out" ]] || die "--export-identity needs a FILE"
    [[ ! -e "$out" ]] || die "$out already exists; choose a new file name"

    if [[ -s "$CHROOT/etc/wireguard/client.key" ]]; then
        wg_dir="$CHROOT/etc/wireguard"
    elif [[ -s "$IDENTITY_DIR/wireguard/client.key" ]]; then
        wg_dir="$IDENTITY_DIR/wireguard"
    else
        die "No WireGuard key on this phone; nothing to export (install first)"
    fi
    validate_wg_key "$(cat "$wg_dir/client.pub")"

    name="${DEVICE_NAME:-}"
    [[ -n "$name" || ! -s "$IDENTITY_DIR/device-name" ]] || name="$(cat "$IDENTITY_DIR/device-name")"
    [[ -z "$name" ]] || validate_device_name "$name"

    stage="$(mktemp -d)" || die "Could not create a temp directory"
    (
        umask 077
        set -e
        mkdir -p "$stage/$IDENTITY_TOP/wireguard"
        cp "$wg_dir/client.key" "$wg_dir/client.pub" "$stage/$IDENTITY_TOP/wireguard/"
        for f in "$SSH_HOSTKEY_DIR"/ssh_host_*_key; do
            [[ -f "$f" && -f "$f.pub" ]] || continue
            mkdir -p "$stage/$IDENTITY_TOP/ssh"
            cp "$f" "$f.pub" "$stage/$IDENTITY_TOP/ssh/"
        done
        if [[ -f "$ORCHESTRATOR_SSH_DIR/id_ed25519" && -f "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub" ]]; then
            mkdir -p "$stage/$IDENTITY_TOP/orchestrator"
            cp "$ORCHESTRATOR_SSH_DIR/id_ed25519" "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub" "$stage/$IDENTITY_TOP/orchestrator/"
        fi
        extra_authorized_keys "$CHROOT/root/.ssh/authorized_keys" > "$stage/$IDENTITY_TOP/extra-keys"
        {
            echo "format=1"
            echo "device_name=$name"
            echo "wg_pubkey=$(cat "$wg_dir/client.pub")"
            echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$stage/$IDENTITY_TOP/manifest"
        tar -cf "$out" -C "$stage" "$IDENTITY_TOP"
        chmod 600 "$out"
    ) || { rm -rf "$stage"; rm -f "$out"; die "Could not write $out"; }
    rm -rf "$stage"

    [[ -d "$SSH_HOSTKEY_DIR" ]] && n="$(find "$SSH_HOSTKEY_DIR" -maxdepth 1 -name 'ssh_host_*_key' | wc -l)"
    ok "Identity saved to $out"
    info "  Device name : ${name:-(unknown; use the same name as before when reinstalling)}"
    info "  WireGuard   : $(cat "$wg_dir/client.pub")"
    info "  SSH host keys: ${n// /}"
    warn "This file holds private keys. Keep it somewhere safe and off the phone."
}

# Every path a format-1 identity tar may contain.
identity_path_ok() {
    [[ "$1" =~ ^serverinator-identity(/(manifest|extra-keys|wireguard/client\.(key|pub)|ssh/ssh_host_[a-z0-9]+_key(\.pub)?|orchestrator/id_ed25519(\.pub)?|wireguard|ssh|orchestrator))?/?$ ]]
}

import_identity() {
    local in="$1" stage top line name f base key
    check_root
    [[ -f "$in" ]] || die "No such file: $in"

    # Only regular files and directories under the expected names.
    local listing
    listing="$(tar -tvf "$in" 2>/dev/null)" || die "$in is not a readable tar file"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == -* || "$line" == d* ]] || die "$in contains something that isn't a plain file: $line"
    done <<< "$listing"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        identity_path_ok "$line" || die "$in has an unexpected entry: $line"
    done < <(tar -tf "$in")

    stage="$(mktemp -d)" || die "Could not create a temp directory"
    (umask 077; tar -xf "$in" -C "$stage") || { rm -rf "$stage"; die "Could not unpack $in"; }
    top="$stage/$IDENTITY_TOP"

    # Validate everything before changing anything.
    grep -qx 'format=1' "$top/manifest" 2>/dev/null \
        || { rm -rf "$stage"; die "$in is not a ServerInator identity (format 1)"; }
    name="$(sed -n 's/^device_name=//p' "$top/manifest")"
    [[ -z "$name" ]] || (validate_device_name "$name") > /dev/null 2>&1 \
        || { rm -rf "$stage"; die "$in has an invalid device name"; }
    [[ -s "$top/wireguard/client.key" && -s "$top/wireguard/client.pub" ]] \
        || { rm -rf "$stage"; die "$in has no WireGuard key"; }
    (validate_wg_key "$(cat "$top/wireguard/client.key")" && validate_wg_key "$(cat "$top/wireguard/client.pub")") \
        > /dev/null 2>&1 || { rm -rf "$stage"; die "$in has an invalid WireGuard key"; }
    for f in "$top"/ssh/ssh_host_*_key "$top"/orchestrator/id_ed25519; do
        [[ -e "$f" ]] || continue
        head -n 1 "$f" | grep -q -- '-----BEGIN .*PRIVATE KEY-----' \
            || { rm -rf "$stage"; die "${f#"$top/"} is not a private key"; }
        [[ -f "$f.pub" ]] && is_plain_pubkey "$(cat "$f.pub")" \
            || { rm -rf "$stage"; die "${f#"$top/"}.pub is missing or not a public key"; }
    done
    if [[ -f "$top/extra-keys" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] || is_client_key_line "$line" \
                || { rm -rf "$stage"; die "extra-keys has a line that isn't a public key"; }
        done < "$top/extra-keys"
    fi

    # Refuse to replace a different identity that is already installed.
    for key in "$CHROOT/etc/wireguard/client.key" "$IDENTITY_DIR/wireguard/client.key"; do
        if [[ -s "$key" ]] && ! cmp -s "$key" "$top/wireguard/client.key"; then
            rm -rf "$stage"
            die "This phone already has a different WireGuard key ($key). Run 'core-phone.sh --uninstall --purge' first if you really want to replace it."
        fi
    done
    for f in "$top"/ssh/ssh_host_*_key; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"
        if [[ -s "$SSH_HOSTKEY_DIR/$base" ]] && ! cmp -s "$SSH_HOSTKEY_DIR/$base" "$f"; then
            rm -rf "$stage"
            die "This phone already has a different SSH host key ($SSH_HOSTKEY_DIR/$base). Run 'core-phone.sh --uninstall --purge' first if you really want to replace it."
        fi
    done

    (
        umask 077
        set -e
        mkdir -p "$IDENTITY_DIR/wireguard"
        cp -f "$top/wireguard/client.key" "$top/wireguard/client.pub" "$IDENTITY_DIR/wireguard/"
        [[ -z "$name" ]] || printf '%s\n' "$name" > "$IDENTITY_DIR/device-name"
        if [[ -d "$CHROOT/etc/wireguard" ]]; then
            cp -f "$top/wireguard/client.key" "$top/wireguard/client.pub" "$CHROOT/etc/wireguard/"
        fi
        for f in "$top"/ssh/ssh_host_*_key; do
            [[ -e "$f" ]] || continue
            mkdir -p "$SSH_HOSTKEY_DIR"
            cp -f "$f" "$f.pub" "$SSH_HOSTKEY_DIR/"
            if [[ -d "$CHROOT/etc/ssh" ]]; then cp -f "$f" "$f.pub" "$CHROOT/etc/ssh/"; fi
        done
        if [[ -f "$top/orchestrator/id_ed25519" ]]; then
            mkdir -p "$ORCHESTRATOR_SSH_DIR"
            if [[ -f "$ORCHESTRATOR_SSH_DIR/id_ed25519" ]] \
                && ! cmp -s "$ORCHESTRATOR_SSH_DIR/id_ed25519" "$top/orchestrator/id_ed25519"; then
                mv -f "$ORCHESTRATOR_SSH_DIR/id_ed25519" "$ORCHESTRATOR_SSH_DIR/id_ed25519.before-import"
                mv -f "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub" "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub.before-import" 2>/dev/null || true
                echo "orchestrator-replaced" > "$stage/notes"
            fi
            cp -f "$top/orchestrator/id_ed25519" "$top/orchestrator/id_ed25519.pub" "$ORCHESTRATOR_SSH_DIR/"
        fi
    ) || { rm -rf "$stage"; die "Could not put the identity in place"; }
    chmod 700 "$IDENTITY_DIR" "$IDENTITY_DIR/wireguard" 2>/dev/null || true
    [[ -d "$SSH_HOSTKEY_DIR" ]] && chmod 700 "$SSH_HOSTKEY_DIR"
    [[ -f "$stage/notes" ]] && warn "Replaced this phone's own VPS login key; the old one is kept as id_ed25519.before-import"

    if [[ -s "$top/extra-keys" ]]; then
        if [[ -d "$CHROOT/root" ]]; then
            merge_extra_keys "$CHROOT/root/.ssh/authorized_keys" "$top/extra-keys"
        else
            (umask 077; mkdir -p "$IDENTITY_DIR"; cp -f "$top/extra-keys" "$IDENTITY_DIR/pending-extra-keys")
            info "Extra SSH keys will be added when the install finishes"
        fi
    fi
    rm -rf "$stage"

    ok "Identity imported"
    info "  WireGuard: $(cat "$IDENTITY_DIR/wireguard/client.pub")"
    echo ""
    echo "  Next: run serverinator.sh with the same VPS${name:+ and device name '$name'}."
    echo "  The VPS will see the same phone, so clients keep working unchanged."
}
