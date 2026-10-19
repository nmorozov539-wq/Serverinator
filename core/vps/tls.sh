# shellcheck shell=bash
# ServerInator Core, VPS side: the optional domain and its certificate
# Sourced by core-vps.sh, which holds the settings and globals used here.

# ─────────────────────────────────────────────
# Step 4: wstunnel server
# ─────────────────────────────────────────────

# ─────────────────────────────────────────────
# Domain and certificate
# ─────────────────────────────────────────────

# Loads the saved choice unless this run names a domain (or removes it).
load_tls_state() {
    [[ "$REMOVE_DOMAIN" == 1 || -n "$VPS_DOMAIN" || ! -f "$TLS_STATE" ]] && return 0
    VPS_DOMAIN="$(json_get "$TLS_STATE" domain)"
    TLS_CERT_FILE="$(json_get "$TLS_STATE" cert)"
    TLS_KEY_FILE="$(json_get "$TLS_STATE" key)"
    TLS_SOURCE="$(json_get "$TLS_STATE" source)"
    [[ -z "$VPS_DOMAIN" ]] || validate_domain "$VPS_DOMAIN"
}

save_tls_state() {
    mkdir -p "$WG_KEY_DIR"; chmod 700 "$WG_KEY_DIR"
    if [[ -z "$VPS_DOMAIN" ]]; then rm -f "$TLS_STATE"; return 0; fi
    jq -n --arg domain "$VPS_DOMAIN" --arg cert "$TLS_CERT_FILE" --arg key "$TLS_KEY_FILE" \
        --arg source "$TLS_SOURCE" '{domain: $domain, cert: $cert, key: $key, source: $source}' \
        > "$TLS_STATE.tmp" || die "jq: could not write $TLS_STATE"
    chmod 600 "$TLS_STATE.tmp"; mv "$TLS_STATE.tmp" "$TLS_STATE"
}

# The host clients and phones use to reach this VPS.
vps_public_host() { printf '%s\n' "${VPS_DOMAIN:-$VPS_IP}"; }

# IPv4 addresses DOMAIN resolves to, one per line (mocked in tests).
# getent exits 2 for a name that doesn't resolve; with pipefail that would end
# the whole run silently instead of reaching the "doesn't resolve" message.
resolve_domain() { { getent ahostsv4 "$1" 2>/dev/null || :; } | awk '{print $1}' | sort -u; }

# This machine's own IPv4 addresses (mocked in tests).
local_ipv4s() { { ip -4 -o addr show 2>/dev/null || :; } | awk '{split($4, a, "/"); print a[1]}'; }

# Something already listening on TCP port 80? (mocked in tests)
port80_in_use() { have_cmd ss && ss -Hltn 'sport = :80' 2>/dev/null | grep -q .; }

# The systemd service that holds TCP port 80, if one does (mocked in tests).
port80_service() {
    local pid
    have_cmd ss || return 0
    pid="$(ss -Hltnp 'sport = :80' 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2)"
    [[ -n "$pid" && -r "/proc/$pid/cgroup" ]] || return 0
    sed -n 's|^.*/system\.slice/\([^/]*\.service\)$|\1|p' "/proc/$pid/cgroup" | head -n 1
}

# Programs listening on TCP port 80, for messages.
port80_programs() {
    have_cmd ss || return 0
    ss -Hltnp 'sport = :80' 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u | paste -sd, -
}

check_domain_points_here() {
    local addrs a mine
    addrs="$(resolve_domain "$VPS_DOMAIN")"
    if [[ -z "$addrs" ]]; then
        local target="$VPS_IP"
        [[ -n "$target" ]] || target="the public IPv4 of this VPS"
        die "$VPS_DOMAIN doesn't resolve yet.
  Create a DNS A record:  $VPS_DOMAIN -> $target
  then run this again (new records can take a few minutes to appear)."
    fi
    mine="$(local_ipv4s; if [[ "$VPS_IP" =~ ^[0-9.]+$ ]]; then printf '%s\n' "$VPS_IP"; fi)"
    while IFS= read -r a; do
        if grep -qxF -- "$a" <<< "$mine"; then
            ok "$VPS_DOMAIN points to this VPS ($a)"
            return 0
        fi
    done <<< "$addrs"
    warn "$VPS_DOMAIN points to $(paste -sd' ' <<< "$addrs"), which isn't an address of this VPS."
    warn "  If the VPS sits behind NAT this can be fine; otherwise fix the A record first."
}

# Checks that CERT and KEY belong together and that CERT covers VPS_DOMAIN.
check_cert_files() {
    [[ -r "$TLS_CERT_FILE" ]] || die "Certificate not found or not readable: $TLS_CERT_FILE"
    [[ -r "$TLS_KEY_FILE" ]] || die "Private key not found or not readable: $TLS_KEY_FILE"
    grep -q -- '-----BEGIN CERTIFICATE-----' "$TLS_CERT_FILE" || die "$TLS_CERT_FILE is not a PEM certificate"
    grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$TLS_KEY_FILE" || die "$TLS_KEY_FILE is not a PEM private key"
    if have_cmd openssl; then
        local cert_pub key_pub
        cert_pub="$(openssl x509 -in "$TLS_CERT_FILE" -noout -pubkey 2>/dev/null)"
        key_pub="$(openssl pkey -in "$TLS_KEY_FILE" -pubout 2>/dev/null)"
        [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] \
            || die "$TLS_KEY_FILE is not the private key for $TLS_CERT_FILE"
        openssl x509 -in "$TLS_CERT_FILE" -noout -checkhost "$VPS_DOMAIN" 2>/dev/null | grep -q 'does match' \
            || die "$TLS_CERT_FILE is not valid for $VPS_DOMAIN"
        openssl x509 -in "$TLS_CERT_FILE" -noout -checkend 0 > /dev/null 2>&1 \
            || die "$TLS_CERT_FILE has expired"
    else
        warn "openssl not found; can't check that the certificate matches the key and $VPS_DOMAIN"
    fi
}

# Restarts wstunnel after every renewal. wstunnel also reloads changed
# certificate files on its own; the restart is a backstop.
write_renewal_hook() {
    local dir="$LETSENCRYPT_DIR/renewal-hooks/deploy"
    mkdir -p "$dir"
    reconcile_file "$dir/serverinator-wstunnel.sh" 755 << 'EOF'
#!/bin/sh
# Managed by ServerInator: pick up a renewed certificate.
systemctl try-restart wstunnel-serverinator.service
EOF
}

obtain_letsencrypt_cert() {
    local live="$LETSENCRYPT_DIR/live/$VPS_DOMAIN"
    TLS_SOURCE="letsencrypt"
    TLS_CERT_FILE="$live/fullchain.pem"
    TLS_KEY_FILE="$live/privkey.pem"

    if [[ "$DEV" == 1 && -z "${SERVERINATOR_CERTBOT:-}" ]]; then
        dev "DEV: skipping Let's Encrypt for $VPS_DOMAIN"
        return 0
    fi
    check_domain_points_here

    if [[ "$DEV" != 1 ]] && ! have_cmd "$CERTBOT"; then
        info "Installing certbot..."
        apt-get install -y -qq certbot || die "Could not install certbot"
    fi
    # certbot keeps a valid certificate as it is, so re-runs are cheap and
    # don't touch the Let's Encrypt rate limits.
    if [[ -s "$TLS_CERT_FILE" ]] && have_cmd openssl \
        && openssl x509 -in "$TLS_CERT_FILE" -noout -checkend $((30 * 86400)) > /dev/null 2>&1; then
        info "Certificate for $VPS_DOMAIN is valid for at least 30 more days, keeping it"
    else
        # A web server already on port 80 (say Caddy) is paused for the few
        # seconds of each check. certbot saves the hooks, so renewals do the same.
        local pause=""
        if port80_in_use; then
            pause="$(port80_service)"
            if [[ ! "$pause" =~ ^[A-Za-z0-9@._-]+\.service$ ]]; then
                local who
                who="$(port80_programs)"
                die "Something already listens on TCP port 80${who:+ ($who)}, which Let's Encrypt needs for a moment to check the domain.
  See it with: ss -ltnp 'sport = :80'
  It isn't a systemd service, so it can't be paused automatically. Stop it
  during setup, or bring your own certificate:
    --tls-cert /path/fullchain.pem --tls-key /path/privkey.pem"
            fi
            warn "Port 80 is used by $pause. It will be stopped for the few seconds"
            warn "  Let's Encrypt needs, now and at each renewal, and started again right after."
        fi
        [[ "$DEV" == 1 ]] || check_firewall 80 "Let's Encrypt needs to reach while it checks the domain (and at every renewal)"
        local -a args=(certonly --standalone --non-interactive --agree-tos --keep-until-expiring
                       --preferred-challenges http -d "$VPS_DOMAIN" --cert-name "$VPS_DOMAIN")
        [[ -z "$pause" ]] || args+=(--pre-hook "systemctl stop $pause" --post-hook "systemctl start $pause")
        if [[ -n "$ACME_EMAIL" ]]; then args+=(--email "$ACME_EMAIL"); else args+=(--register-unsafely-without-email); fi
        info "Requesting a Let's Encrypt certificate for $VPS_DOMAIN..."
        "$CERTBOT" "${args[@]}" || die "certbot could not get a certificate for $VPS_DOMAIN (see the output above).
  Usual causes: the A record points elsewhere, or port 80 is blocked by a firewall."
    fi
    [[ -s "$TLS_CERT_FILE" && -s "$TLS_KEY_FILE" ]] || die "certbot finished but $live has no certificate"
    write_renewal_hook
    ok "Certificate for $VPS_DOMAIN: $TLS_CERT_FILE"
}

# Fills TLS_* for VPS_DOMAIN (or clears them). Called by setup and --set-domain.
setup_tls() {
    load_tls_state
    if [[ "$REMOVE_DOMAIN" == 1 || -z "$VPS_DOMAIN" ]]; then
        VPS_DOMAIN=""; TLS_CERT_FILE=""; TLS_KEY_FILE=""; TLS_SOURCE=""
        save_tls_state
        info "No domain: wstunnel uses its built-in self-signed certificate"
        return 0
    fi
    if [[ -n "$TLS_CERT_FILE" && "$TLS_SOURCE" != letsencrypt ]]; then
        TLS_SOURCE="custom"
        check_cert_files
        info "Using your certificate for $VPS_DOMAIN: $TLS_CERT_FILE"
    else
        obtain_letsencrypt_cert
    fi
    save_tls_state
}

# Points every device record at the current domain (or back at the IP) and
# rewrites the client scripts that the VPS can regenerate.
refresh_devices_for_domain() {
    local dev record tmp
    for dev in $(device_names); do
        record="$(device_record_path "$dev")"
        tmp="$(mktemp "${record}.XXXXXX")"; chmod 600 "$tmp"
        jq --arg d "$VPS_DOMAIN" --arg p "${WSTUNNEL_PATH_PREFIX:-}" \
            '(if $d == "" then del(.vps_domain) else . + {vps_domain: $d} end)
             | (if $p == "" then . else . + {wstunnel_path_prefix: $p} end)' \
            "$record" > "$tmp" || { rm -f "$tmp"; die "jq: could not update $record"; }
        mv "$tmp" "$record"
        # shellcheck disable=SC2034  # read by select_device
        ( SELECTED_DEVICE="$dev"; regenerate_client_scripts ) \
            || warn "Could not rewrite the client scripts for $dev; re-run its install to refresh them"
    done
}

# Rewrites the owner's and every --add-client script for SELECTED_DEVICE.
regenerate_client_scripts() {
    local domain="$VPS_DOMAIN"
    _load_phone_state > /dev/null
    VPS_DOMAIN="$domain"
    local owner_alias="$SSH_ALIAS" key label f n=0 mode
    if [[ -f "$SSH_KEY_DIR/client-setup-owner-${DEVICE_NAME}.sh" ]]; then
        key="$SSH_KEY_DIR/owner_${DEVICE_NAME}"
        if [[ -f "$key" ]]; then mode=1; elif [[ -f "$key.pub" ]]; then mode=2; else mode=0; fi
        _write_client_setup_script "$SSH_KEY_DIR/client-setup-owner-${DEVICE_NAME}.sh" "$owner_alias" \
            "si-${DEVICE_NAME}" "$mode" "$key" owner
        n=$((n + 1))
    fi
    for f in "$SSH_KEY_DIR"/client-setup-*-"${DEVICE_NAME}".sh; do
        [[ -e "$f" ]] || continue
        label="${f##*/client-setup-}"; label="${label%-"${DEVICE_NAME}".sh}"
        [[ "$label" != owner ]] || continue
        key="$SSH_KEY_DIR/owner_${DEVICE_NAME}_${label}"
        if [[ -f "$key" ]]; then mode=1; else mode=2; fi
        _write_client_setup_script "$f" "${owner_alias}-${label}" "si-${DEVICE_NAME}-${label}" "$mode" "$key" "$label"
        n=$((n + 1))
    done
    info "$DEVICE_NAME: rewrote $n client script(s)"
}

set_domain() {
    ensure_jq
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--set-domain needs root"
    # VPS_IP for the DNS check and the IP fallback: from any device record.
    local first
    first="$(device_names | head -n 1)"
    [[ -z "$first" ]] || VPS_IP="$(json_get "$(device_record_path "$first")" vps_ip)"
    setup_tls
    setup_wstunnel_server
    refresh_devices_for_domain
    if [[ -n "$VPS_DOMAIN" ]]; then
        local label="your own"
        [[ "$TLS_SOURCE" != letsencrypt ]] || label="a Let's Encrypt"
        ok "The tunnel now serves $label certificate for $VPS_DOMAIN"
    else
        ok "The tunnel is back on the built-in self-signed certificate"
    fi
    echo ""
    echo "  Phones keep working as they are. To switch each phone over, run on it:"
    if [[ -n "$VPS_DOMAIN" ]]; then
        echo "    bash serverinator.sh --set-domain $VPS_DOMAIN"
    else
        echo "    bash serverinator.sh --remove-domain"
    fi
    echo "  Existing ssh setups keep working through the IP. The client scripts on"
    echo "  the VPS now use $(vps_public_host) as the jump host for new machines."
}
