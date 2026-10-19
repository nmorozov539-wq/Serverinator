# shellcheck shell=bash
# ServerInator Core, VPS side: the WireGuard server, peers, addresses and the firewall
# Sourced by core-vps.sh, which holds the settings and globals used here.

# ─────────────────────────────────────────────
# WireGuard peer block helpers
# ─────────────────────────────────────────────

# Number of peer blocks carrying this device's marker.
peer_block_count() {
    local conf="$1" device="$2"
    # Whole lines: "rn9" must not count "rn9p"'s marker (review B2).
    grep -cxF "# ServerInator peer: ${device}" "$conf" 2>/dev/null || true
}

# PublicKey of the device's peer block (empty if not found).
peer_pubkey_for_device() {
    local conf="$1" device="$2"
    awk -v marker="# ServerInator peer: ${device}" '
        $0 == marker              { in_device=1; next }
        in_device && /^\[Peer\]/  { in_peer=1; next }
        in_device && /^\[/        { in_device=0; in_peer=0 }
        in_peer   && $1 == "PublicKey" { print $3; exit }
    ' "$conf"
}

# Removes the device's peer block atomically.
peer_remove_device() {
    local conf="$1" device="$2"
    local marker="# ServerInator peer: ${device}"
    local tmp
    tmp="$(mktemp "${conf}.XXXXXX")" || die "Could not create a temp file next to $conf"

    if ! awk -v marker="$marker" '
        $0 == marker { skipping=1; in_peer=0; next }
        skipping && !in_peer {
            if ($0 ~ /^\[Peer\]/) { in_peer=1; next }
            if ($0 ~ /^\[/ || $0 ~ /^# ServerInator peer:/) { skipping=0; in_peer=0 }
            else next
        }
        skipping && in_peer {
            if ($0 ~ /^\[/ || $0 ~ /^# ServerInator peer:/) { skipping=0; in_peer=0 }
            else next
        }
        { n++; lines[n]=$0 }
        END {
            while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
            for (i = 1; i <= n; i++) print lines[i]
        }
    ' "$conf" > "$tmp"; then
        rm -f "$tmp"; die "Could not rewrite $conf"
    fi

    chmod --reference="$conf" "$tmp" 2>/dev/null || true
    mv "$tmp" "$conf" || { rm -f "$tmp"; die "Could not replace $conf"; }
}

# Appends the device's peer block to the end of the config.
append_peer_block() {
    local conf="$1" device="$2" pubkey="$3" ip="$4"
    local last
    last="$(tail -c 1 "$conf" 2>/dev/null || true)"
    {
        [[ -s "$conf" && "$last" != "" ]] && printf '\n'
        printf '\n# ServerInator peer: %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nPersistentKeepalive = 25\n' \
            "$device" "$pubkey" "$ip"
    } >> "$conf"
}

# ─────────────────────────────────────────────
# Step 3: WireGuard
# ─────────────────────────────────────────────

# Picks an IP for the phone from the config (allocation ledger).
# Re-installing the same device/key gets the same IP back.
allocate_phone_ip() {
    local conf="$WG_CONF"
    [[ -f "$conf" ]] || conf=/dev/null
    PHONE_WG_IP="$(awk -v subnet="$VPS_WG_SUBNET" -v device="$DEVICE_NAME" -v key="$PHONE_WG_PUBKEY" '
        function ipnum(ip, a) { split(ip,a,"."); return ((a[1]*256+a[2])*256+a[3])*256+a[4] }
        function fail(msg) { print msg > "/dev/stderr"; bad=1; exit 1 }
        /^# ServerInator peer: / { marker=substr($0,22); next }
        /^\[Peer\]/ { peer=++total; names[peer]=marker; marker=""; next }
        /^\[/ { peer=0; next }
        peer && $1=="PublicKey" { keys[peer]=$3 }
        peer && $1=="AllowedIPs" {
            line=$0; sub(/^[^=]*=[[:space:]]*/,"",line); count=split(line,list,",")
            for(i=1;i<=count;i++) {
                gsub(/[[:space:]]/,"",list[i]); split(list[i],parts,"/")
                if (parts[1] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || parts[2] !~ /^[0-9]+$/ || parts[2]>32)
                    fail("Unsupported or malformed AllowedIPs in allocation ledger")
                split(parts[1],oct,"."); for(j=1;j<=4;j++) if(oct[j]>255) fail("Invalid IPv4 AllowedIPs")
                size=2^(32-parts[2]); value=ipnum(parts[1]); lo=int(value/size)*size; hi=lo+size-1
                for(j=1;j<=ranges;j++) if(lo<=high[j] && hi>=low[j]) fail("Overlapping AllowedIPs in allocation ledger")
                ranges++; low[ranges]=lo; high[ranges]=hi; owner[ranges]=peer
                if(parts[2]==32 && index(parts[1],subnet".")==1) address[peer]=parts[1]
            }
        }
        END {
            if(bad) exit 1
            for(i in keys) if(keys[i]==key) { chosen=address[i]; matches++ }
            if(matches>1) fail("Duplicate public key in allocation ledger")
            if(matches==1) {
                if(chosen=="") fail("Existing key has no usable allocated address")
                print chosen; exit
            }
            for(i in names) if(names[i]==device) { chosen=address[i]; devices++ }
            if(devices>1) fail("Duplicate device marker in allocation ledger")
            if(devices==1) {
                if(chosen=="") fail("Existing device has no usable allocated address")
                print chosen; exit
            }
            for(host=2;host<255;host++) {
                candidate=ipnum(subnet"."host); used=0
                for(j=1;j<=ranges;j++) if(candidate>=low[j] && candidate<=high[j]) used=1
                if(!used) { print subnet"."host; exit }
            }
            fail("WireGuard address pool exhausted")
        }
    ' "$conf")" || die "Could not allocate an IP for the phone"
}

setup_wireguard() {
    local priv_key="$WG_KEY_DIR/server.key" pub_key="$WG_KEY_DIR/server.pub" lock_fd desired
    mkdir -p "$WG_KEY_DIR" "$WG_DIR"
    chmod 700 "$WG_KEY_DIR"
    command -v flock >/dev/null || die "flock required for allocation reconciliation"
    exec {lock_fd}>"$WG_KEY_DIR/setup.lock"
    flock -x "$lock_fd"

    if [[ ! -f "$priv_key" ]]; then
        (umask 077; wg genkey > "$priv_key"; wg pubkey < "$priv_key" > "$pub_key")
        chmod 600 "$priv_key"
    fi
    # shellcheck disable=SC2034  # read by generate_back_handoff
    VPS_WG_PUBKEY="$(cat "$pub_key")"
    VPS_WG_PRIVKEY="$(cat "$priv_key")"

    allocate_phone_ip

    desired="$(mktemp "$WG_DIR/desired.XXXXXX")"
    chmod 600 "$desired"

    if [[ -f "$WG_CONF" ]]; then
        cp "$WG_CONF" "$desired"
        local count old_key
        count="$(peer_block_count "$desired" "$DEVICE_NAME")"
        [[ "$count" -le 1 ]] || die "Duplicate device markers in the WG config"
        if [[ "$count" == 1 ]]; then
            old_key="$(peer_pubkey_for_device "$desired" "$DEVICE_NAME")"
            [[ -n "$old_key" ]] || die "Device marker without a PublicKey"
        fi
        if ! grep -qF "$PHONE_WG_PUBKEY" "$desired"; then
            [[ "$count" == 1 ]] && peer_remove_device "$desired" "$DEVICE_NAME"
            append_peer_block "$desired" "$DEVICE_NAME" "$PHONE_WG_PUBKEY" "$PHONE_WG_IP"
        fi
        # Update only our own Interface fields; keep foreign [Peer] sections intact.
        awk -v key="$VPS_WG_PRIVKEY" -v address="$VPS_WG_SUBNET.1/24" -v port="$WG_PORT" '
          function missing() {
            if(!seen["PrivateKey"]) print "PrivateKey = " key
            if(!seen["Address"])    print "Address = " address
            if(!seen["ListenPort"]) print "ListenPort = " port
            if(!seen["MTU"])        print "MTU = 1280"
          }
          /^\[Interface\]/ { inside=1; print; next }
          /^\[/ && inside   { missing(); inside=0 }
          inside && $1=="PrivateKey"  { if(!seen[$1]++) print "PrivateKey = " key;    next }
          inside && $1=="Address"     { if(!seen[$1]++) print "Address = " address;   next }
          inside && $1=="ListenPort"  { if(!seen[$1]++) print "ListenPort = " port;   next }
          inside && $1=="MTU"         { if(!seen[$1]++) print "MTU = 1280";           next }
          { print }
          END { if(inside) missing() }
        ' "$desired" > "$desired.new" && mv "$desired.new" "$desired"
        reconcile_file "$WG_CONF" 600 < "$desired"
    else
        cat > "$desired" << EOF
[Interface]
PrivateKey = ${VPS_WG_PRIVKEY}
Address = ${VPS_WG_SUBNET}.1/24
ListenPort = ${WG_PORT}
MTU = 1280
EOF
        append_peer_block "$desired" "$DEVICE_NAME" "$PHONE_WG_PUBKEY" "$PHONE_WG_IP"
        reconcile_file "$WG_CONF" 600 < "$desired"
    fi

    rm -f "$desired"
    flock -u "$lock_fd"
    exec {lock_fd}>&-

    if [[ "$DEV" == 1 ]]; then dev "DEV: skipping runtime WG"; return 0; fi

    systemctl enable "wg-quick@${WG_INTERFACE}"
    ip link show "$WG_INTERFACE" &>/dev/null || systemctl restart "wg-quick@${WG_INTERFACE}"
    ip link set "$WG_INTERFACE" up

    desired="$(mktemp "$WG_KEY_DIR/runtime.XXXXXX")"
    chmod 600 "$desired"
    wg-quick strip "$WG_CONF" > "$desired"
    wg syncconf "$WG_INTERFACE" "$desired"
    rm -f "$desired"

    ip address replace "$VPS_WG_SUBNET.1/24" dev "$WG_INTERFACE"
    ip link set "$WG_INTERFACE" mtu 1280
}

# ─────────────────────────────────────────────
# Step 4 (optional): MSS clamp
# ─────────────────────────────────────────────

fix_pmtu_clamp() {
    if [[ "${SERVERINATOR_SKIP_MSS:-1}" != "0" ]]; then
        dev "MSS clamp disabled by default (set SERVERINATOR_SKIP_MSS=0 to enable)"
        return 0
    fi

    require_cmd iptables
    validate_tunnel_port "$WSTUNNEL_PORT"

    local receipt_dir="$WG_KEY_DIR/mss-owned"
    mkdir -p "$receipt_dir"
    local receipt="$receipt_dir/${WSTUNNEL_PORT}"

    if [[ -f "$receipt" ]]; then
        info "MSS clamp already set for port $WSTUNNEL_PORT"
        return 0
    fi

    # An equivalent rule without our ownership tag already covers this port —
    # leave it alone (not ours to claim) and don't add a redundant duplicate.
    local rc=0
    iptables -t mangle -C OUTPUT -p tcp --sport "$WSTUNNEL_PORT" \
        --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 500 2>/dev/null || rc=$?
    if [[ "$rc" == 0 ]]; then
        warn "An equivalent MSS rule for port $WSTUNNEL_PORT already exists without our tag — leaving it alone"
        return 0
    fi

    rc=0
    iptables -t mangle -C OUTPUT -p tcp --sport "$WSTUNNEL_PORT" \
        --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss \
        -j TCPMSS --set-mss 500 2>/dev/null || rc=$?

    if [[ "$rc" == 1 ]]; then
        iptables -t mangle -A OUTPUT -p tcp --sport "$WSTUNNEL_PORT" \
            --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss \
            -j TCPMSS --set-mss 500
        info "MSS clamp added for port $WSTUNNEL_PORT"
    fi

    printf '%s\n' "$WSTUNNEL_PORT" > "$receipt"

    if [[ -f "$IPTABLES_RULES_PATH" ]]; then
        local saved
        saved="$(mktemp)"
        iptables-save > "$saved" || { rm -f "$saved"; die "iptables-save failed"; }
        reconcile_file "$IPTABLES_RULES_PATH" 600 < "$saved"
        rm -f "$saved"
        info "iptables-save updated"
    else
        warn "File $IPTABLES_RULES_PATH not found — the rule is not persistent"
    fi
}

# Warns when a host firewall would drop the tunnel port (review #17). It
# never changes firewall rules: the admin decides.
check_firewall() { # [PORT [PURPOSE]]
    local port="${1:-$WSTUNNEL_PORT}" purpose="${2:-the tunnel needs}" hint=""
    if have_cmd ufw && ufw status 2>/dev/null | head -1 | grep -q '^Status: active'; then
        ufw status 2>/dev/null | grep -qE "^${port}(/tcp)?[[:space:]].*ALLOW" \
            || hint="ufw allow ${port}/tcp"
    elif have_cmd firewall-cmd && firewall-cmd --state &>/dev/null; then
        firewall-cmd --query-port="${port}/tcp" &>/dev/null \
            || hint="firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload"
    elif have_cmd iptables && iptables -S INPUT 2>/dev/null | grep -qx -- '-P INPUT DROP'; then
        iptables -S INPUT 2>/dev/null | grep -qE -- "--dport ${port}( |$)" \
            || hint="iptables -I INPUT -p tcp --dport ${port} -j ACCEPT (and save it)"
    fi
    if [[ -n "$hint" ]]; then
        warn "A firewall on this VPS seems to block TCP port ${port}, which ${purpose}."
        warn "  Open it with:  $hint"
        warn "  (Also check your provider's firewall or security group.)"
    fi
}

remove_owned_mss() {
    local receipt port rc
    for receipt in "$WG_KEY_DIR/mss-owned/"*; do
        [[ -f "$receipt" ]] || continue
        port="$(cat "$receipt")"
        validate_tunnel_port "$port"
        [[ "${receipt##*/}" == "$port" && ! -L "$receipt" ]] || die "Invalid MSS receipt"
        while :; do
            rc=0
            iptables -t mangle -C OUTPUT -p tcp --sport "$port" \
                --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss \
                -j TCPMSS --set-mss 500 || rc=$?
            [[ "$rc" == 1 ]] && break
            [[ "$rc" == 0 ]] || die "Could not check the TCPMSS rule"
            iptables -t mangle -D OUTPUT -p tcp --sport "$port" \
                --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss \
                -j TCPMSS --set-mss 500
        done
        if [[ -f "$IPTABLES_RULES_PATH" ]]; then
            local rules
            rules="$(mktemp)"
            awk -v port="$port" '
              {line=$0; gsub(/"/, "", line)}
              line=="-A OUTPUT -p tcp -m tcp --sport "port" --tcp-flags SYN,RST SYN -m comment --comment serverinator-mss -j TCPMSS --set-mss 500" {next}
              line=="-A OUTPUT -p tcp -m tcp --sport "port" --tcp-flags RST,SYN SYN -m comment --comment serverinator-mss -j TCPMSS --set-mss 500" {next}
              {print}' "$IPTABLES_RULES_PATH" > "$rules"
            reconcile_file "$IPTABLES_RULES_PATH" 600 < "$rules"
            rm -f "$rules"
        fi
    done
}
