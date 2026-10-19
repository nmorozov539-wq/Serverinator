#!/usr/bin/env bash
# ServerInator — client access to @DEVICE_NAME@
# Alias: @ALIAS@   VPS: @VPS_IP@   Created: @CREATED@
#
# Run this on the client device (bash; works out of the box on Linux, macOS
# and Termux). On Windows, tools/client-setup-windows.ps1 from the
# ServerInator repo reads the settings below and does the same.
set -euo pipefail

# ── Settings for this client (written by the VPS) ──
SI_DEVICE='@DEVICE_NAME@'
SI_ALIAS='@ALIAS@'
SI_LABEL='@LABEL@'
SI_PHONE_IP='@PHONE_IP@'
SI_PHONE_PORT='@PHONE_PORT@'
SI_PHONE_USER='@PHONE_USER@'
SI_VPS_HOST='@VPS_HOST@'
SI_VPS_USER='@VPS_USER@'
# Key: none (the owner's own VPS keys), carried (the private key is below),
# or own (a key of this device's; SI_KEY_EXPECTED names it, or empty to make one).
SI_KEY_MODE='@KEY_MODE@'
SI_KEY_NAME='@KEY_NAME@'
SI_KEY_EXPECTED='@KEY_EXPECTED@'
SI_KEY_FP='@KEY_FP@'
SI_KEY_PUB='@KEY_PUB@'
SI_KEY_B64='@KEY_B64@'
# Host keys to pin: the phone's under the alias, the VPS's under its address.
SI_PHONE_HOSTKEY='@PHONE_HOSTKEY@'
SI_VPS_HOSTKEY='@VPS_HOSTKEY@'
# ── End of settings ──

echo "Setting up SSH access to ${SI_DEVICE} (alias: ${SI_ALIAS})..."
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

KEY=""
case "$SI_KEY_MODE" in
    carried)
        # The private key. This script is its only copy once fetched: keep it safe.
        KEY="$HOME/.ssh/${SI_KEY_NAME}"
        if [[ ! -f "$KEY" ]]; then
            printf '%s' "$SI_KEY_B64" | base64 -d > "$KEY"
            chmod 600 "$KEY"
            printf '%s\n' "$SI_KEY_PUB" > "$KEY.pub"
            echo "Key installed: $KEY"
        else
            echo "Key already present: $KEY — skipping"
        fi
        ;;
    own)
        if [[ -n "$SI_KEY_EXPECTED" ]]; then
            # This device's own key. The private key never left it.
            for k in "$HOME/.ssh/${SI_KEY_NAME}" "$HOME"/.ssh/*; do
                [[ -f "$k" && "$k" != *.pub ]] || continue
                [[ "$(ssh-keygen -y -f "$k" 2>/dev/null | awk '{print $1" "$2}')" == "$SI_KEY_EXPECTED" ]] && { KEY="$k"; break; }
            done
            if [[ -z "$KEY" ]]; then
                echo "This setup is for the key ${SI_KEY_FP}, and that key isn't in ~/.ssh on this device." >&2
                echo "Run it on the device the key belongs to, or ask for a new setup." >&2
                exit 1
            fi
            echo "Using your key $KEY"
        else
            # A key of this device's own; its private part never leaves the device.
            KEY="$HOME/.ssh/${SI_KEY_NAME}"
            if [[ ! -f "$KEY" ]]; then
                command -v ssh-keygen >/dev/null || { echo 'ssh-keygen not found (install the OpenSSH client)' >&2; exit 1; }
                ssh-keygen -q -t ed25519 -N '' -C "serverinator:${SI_LABEL}@$(hostname 2>/dev/null || echo device)" -f "$KEY"
                echo "Made a key for this device: $KEY"
            fi
        fi
        ;;
esac

CONFIG="$HOME/.ssh/config"
touch "$CONFIG" && chmod 600 "$CONFIG"

# With a key of ours the jump to the VPS uses it too, in a block of its own;
# the VPS has a restricted entry for it (forwarding to this phone only, no
# shell). Without one, the jump uses the owner's own keys.
JUMP="${SI_VPS_USER}@${SI_VPS_HOST}"
[[ -z "$KEY" ]] || JUMP="${SI_ALIAS}-jump"

if grep -q "^Host ${SI_ALIAS}\$" "$CONFIG" 2>/dev/null; then
    echo "Alias '${SI_ALIAS}' is already in $CONFIG — skipping"
else
    printf '\nHost %s\n' "$SI_ALIAS" >> "$CONFIG"
    printf '    HostName %s\n' "$SI_PHONE_IP" >> "$CONFIG"
    printf '    Port %s\n' "$SI_PHONE_PORT" >> "$CONFIG"
    printf '    User %s\n' "$SI_PHONE_USER" >> "$CONFIG"
    [[ -z "$KEY" ]] || printf '    IdentityFile %s\n    IdentitiesOnly yes\n' "$KEY" >> "$CONFIG"
    printf '    ProxyJump %s\n' "$JUMP" >> "$CONFIG"
    [[ -z "$SI_PHONE_HOSTKEY" ]] || printf '    HostKeyAlias %s\n' "$SI_ALIAS" >> "$CONFIG"
    printf '    ServerAliveInterval 60\n' >> "$CONFIG"
    printf '    ServerAliveCountMax 9999\n' >> "$CONFIG"
    echo "Alias '${SI_ALIAS}' added to ~/.ssh/config"
fi

if [[ -n "$KEY" ]]; then
    if grep -q "^Host ${SI_ALIAS}-jump\$" "$CONFIG" 2>/dev/null; then
        echo "Host ${SI_ALIAS}-jump is already in $CONFIG — skipping"
    else
        printf '\nHost %s-jump\n    HostName %s\n    User %s\n' "$SI_ALIAS" "$SI_VPS_HOST" "$SI_VPS_USER" >> "$CONFIG"
        printf '    IdentityFile %s\n    IdentitiesOnly yes\n    HostKeyAlias %s\n' "$KEY" "$SI_VPS_HOST" >> "$CONFIG"
        echo "Host ${SI_ALIAS}-jump (the hop through the VPS) added to $CONFIG"
    fi
fi

pin() { # NAME HOSTKEY
    local entry="$1 $2"
    grep -qxF "$entry" "$KNOWN" || { echo "$entry" >> "$KNOWN"; echo "Pinned host key for $1"; }
}
if [[ -n "$SI_PHONE_HOSTKEY" || -n "$SI_VPS_HOSTKEY" ]]; then
    KNOWN="$HOME/.ssh/known_hosts"
    touch "$KNOWN" && chmod 600 "$KNOWN"
    [[ -z "$SI_PHONE_HOSTKEY" ]] || pin "$SI_ALIAS" "$SI_PHONE_HOSTKEY"
    [[ -z "$SI_VPS_HOSTKEY" ]] || pin "$SI_VPS_HOST" "$SI_VPS_HOSTKEY"
fi

echo ""
echo "Done. Connect with:  ssh ${SI_ALIAS}"
if [[ "$SI_KEY_MODE" == own && -z "$SI_KEY_EXPECTED" ]]; then
    echo ""
    echo "Last step: approve this device. As root on the phone, or on the VPS:"
    echo "  si add-client ${SI_LABEL} --device ${SI_DEVICE} --pubkey '$(awk '{print $1" "$2}' "$KEY.pub")'"
    echo "Until then, ssh ${SI_ALIAS} is refused."
fi
