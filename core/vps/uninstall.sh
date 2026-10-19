# shellcheck shell=bash
# ServerInator Core, VPS side: --uninstall
# Sourced by core-vps.sh, which holds the settings and globals used here.

# ─────────────────────────────────────────────
# Uninstall
# ─────────────────────────────────────────────

# Removes every restricted jump entry we added (all phones) from the
# authorized_keys of each VPS admin the records name, plus the current one.
_remove_all_vps_jump_entries() {
    local prefix="command=\"echo 'ServerInator: forwarding-only key, no shell access'; exit 1\",restrict,port-forwarding,permitopen="
    local homes=() home rec user auth_file tmp rc
    home="$(_vps_user_home 2>/dev/null || true)"; [[ -z "$home" ]] || homes+=("$home")
    for rec in "$DEVICES_DIR"/*.json "$SSH_KEY_DIR/state.json"; do
        [[ -f "$rec" ]] || continue
        user="$(json_get "$rec" ssh_vps_user 2>/dev/null || true)"
        [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || continue
        if [[ "$user" == root ]]; then home="${SERVERINATOR_VPS_ADMIN_HOME:-/root}"
        else home="$(getent passwd "$user" | cut -d: -f6 || true)"; fi
        [[ -z "$home" ]] || homes+=("$home")
    done
    for home in $(printf '%s\n' "${homes[@]}" | sort -u); do
        auth_file="$home/.ssh/authorized_keys"
        [[ -f "$auth_file" && ! -L "$auth_file" ]] || continue
        grep -qF -- "$prefix" "$auth_file" || continue
        tmp="$(mktemp "${auth_file}.XXXXXX")" || die "Could not create a temp file next to $auth_file"
        rc=0
        awk -v p="$prefix" 'index($0, p) != 1' "$auth_file" > "$tmp" || rc=$?
        [[ "$rc" == 0 ]] || { rm -f "$tmp"; die "Could not rewrite $auth_file"; }
        chmod 600 "$tmp"
        chown --reference="$auth_file" "$tmp" 2>/dev/null || true
        mv "$tmp" "$auth_file" || { rm -f "$tmp"; die "Could not replace $auth_file"; }
        info "Removed ServerInator jump entries from $auth_file"
    done
}

uninstall_vps() {
    safe_remove_path "$WG_KEY_DIR"
    local phones clients=0 guests=0 f
    phones="$(device_names 2>/dev/null | tr '\n' ' ')"
    for f in "$SSH_KEY_DIR"/owner_*.pub; do [[ -f "$f" ]] && clients=$((clients + 1)); done
    for f in "$GUESTS_DIR"/*.json; do [[ -f "$f" ]] && guests=$((guests + 1)); done
    echo ""
    echo "  This removes ServerInator from this VPS: the tunnel (wstunnel, WireGuard),"
    echo "  ${phones:+the phones ${phones}and }${clients} client key(s), ${guests} guest(s), and its firewall rules."
    echo "  Phones lose the tunnel until they are set up again, and every client needs"
    echo "  a new setup script. Other services and your own SSH keys stay."
    echo ""
    confirm_destructive "Remove it?"
    local svc="$SYSTEMD_DIR/wstunnel-serverinator.service"
    if [[ "$DEV" != 1 ]]; then
        [[ "$(id -u)" == 0 ]] || die "VPS uninstall requires root"
        systemctl cat wstunnel-serverinator.service &>/dev/null \
            && systemctl disable --now wstunnel-serverinator.service
        [[ ! -f "$WG_CONF" ]] || systemctl disable --now "wg-quick@$WG_INTERFACE"
        remove_owned_mss
    fi
    rm -f "$svc" "${svc}.bak" "$WG_CONF" "${WG_CONF}.bak"
    if [[ -f "$WG_KEY_DIR/wstunnel-owned" ]]; then
        rm -f "$WSTUNNEL_BIN"
    else
        warn "wstunnel was not installed by us — not removing the binary"
    fi
    _remove_all_vps_jump_entries
    uninstall_guest_access
    if [[ -f "$TLS_STATE" ]]; then
        local domain
        domain="$(json_get "$TLS_STATE" domain)"
        [[ "$(json_get "$TLS_STATE" source)" != letsencrypt ]] \
            || info "The Let's Encrypt certificate for $domain stays; remove it with: certbot delete --cert-name $domain"
    fi
    rm -f "$LETSENCRYPT_DIR/renewal-hooks/deploy/serverinator-wstunnel.sh"
    rm -rf "$WG_KEY_DIR"
    [[ "$DEV" != 1 ]] && systemctl daemon-reload
    # The orchestrator keeps these scripts in /root/.serverinator/bin. Bash
    # has this file open already, so removing it doesn't stop the run.
    local bin_dir
    bin_dir="$(cd "$CORE_DIR" && pwd -P)"
    if [[ "$DEV" != 1 && "$bin_dir" == /root/.serverinator/bin ]]; then
        rm -f "$bin_dir"/core-vps.sh "$bin_dir"/lib.sh "$bin_dir"/si
        rm -rf "$bin_dir"/vps "$bin_dir"/templates
        rmdir "$bin_dir" /root/.serverinator 2>/dev/null || true
        info "Removed the scripts in $bin_dir"
    fi
    # The si launcher, only if it's ours.
    local si_launcher="${SERVERINATOR_SI_LAUNCHER:-/usr/local/bin/si}"
    [[ "$DEV" != 1 || -n "${SERVERINATOR_SI_LAUNCHER:-}" ]] || si_launcher=""
    if [[ -n "$si_launcher" && -f "$si_launcher" ]] \
            && grep -q '^# ServerInator: the si command (managed)' "$si_launcher"; then
        rm -f "$si_launcher"
        info "Removed the si command ($si_launcher)"
    fi
    info "VPS uninstalled. Foreign interfaces and firewall rules were preserved."
}
