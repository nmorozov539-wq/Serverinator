#!/usr/bin/env bash
# ServerInator — first-time VPS authorization (sourced by serverinator.sh).
#
# Gets the orchestrator's public key into the VPS user's authorized_keys when
# it is not there yet. Routes, cheapest first:
#   0. a key already on this phone (Termux etc.) that the VPS accepts
#   1. password login, when the server offers it
#   2. manual: adb from a computer, a short curl over Wi-Fi, or typing the key
#      in short checked chunks (provider web console)
#
# Rules this file keeps:
#   - Passwords are never read, stored or logged here: ssh and sudo prompt on
#     the terminal themselves. Only our *public* key is moved around.
#   - Failed logins are budgeted (SERVERINATOR_AUTH_MAX_FAILS, default 3 per
#     run, counting the first check) so fail2ban-style bans are not tripped.
#     Nothing polls; manual routes try once per Enter.
#   - When a VPS that just rejected us stops answering, assume a ban and stop.
#
# Expects from the caller: VPS_TARGET, VPS_USER, VPS_HOST, DEVICE_NAME,
# ORCHESTRATOR_SSH_DIR, SSH_OPTS (ensure_ssh_identity), and lib.sh.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "vps-auth.sh: do not run directly — source it instead" >&2
    exit 1
fi

AUTH_FAILS=0
AUTH_MAX_FAILS="${SERVERINATOR_AUTH_MAX_FAILS:-3}"
AUTH_METHODS=""      # from the server's "Permission denied (...)" list
AUTH_WIFI_PORT="${SERVERINATOR_AUTH_WIFI_PORT:-8765}"
AUTH_WIFI_SECONDS="${SERVERINATOR_AUTH_WIFI_SECONDS:-300}"
AUTH_ADB_PATH="${SERVERINATOR_AUTH_ADB_PATH:-/data/local/tmp/si.pub}"
# Where to look for keys that may already have access (route 0).
AUTH_KEY_DIRS="${SERVERINATOR_AUTH_KEY_DIRS:-/data/data/com.termux/files/home/.ssh /data/adb/.ssh /root/.ssh /sdcard/.ssh}"
AUTH_MAX_CANDIDATES=5   # sshd's default MaxAuthTries is 6
AUTH_TMP=""             # scratch dir; serverinator.sh's _cleanup removes it
AUTH_SUDOERS_ASKED=0

# Remote snippet: append the key read from stdin to ~/.ssh/authorized_keys
# unless an identical line is already there.
# shellcheck disable=SC2016  # expanded on the VPS, not here
AUTH_INSTALL_SNIPPET='umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && k=$(cat) && { grep -qxF -- "$k" ~/.ssh/authorized_keys || printf "%s\n" "$k" >> ~/.ssh/authorized_keys; } && echo SI_KEY_INSTALLED'

_auth_pubkey() { cat "$ORCHESTRATOR_SSH_DIR/id_ed25519.pub"; }

# Our identity without BatchMode (ssh keeps the *first* value of an option,
# so interactive calls must not start from SSH_OPTS, which sets BatchMode=yes).
_auth_key_opts() {
    printf '%s\n' -o "IdentityFile=$ORCHESTRATOR_SSH_DIR/id_ed25519" -o IdentitiesOnly=yes
}

_auth_known_hosts_opts() {
    printf '%s\n' -o "UserKnownHostsFile=$ORCHESTRATOR_SSH_DIR/known_hosts" \
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15
}

auth_is_interactive() { [[ -t 0 && -t 1 ]]; }

# Records the result of one connection attempt. Returns 0 on success.
# A rejection costs one unit of budget; a connection that fails right after
# a rejection is treated as a likely ban.
_auth_note() { # RC ERR_TEXT
    local rc="$1" err="$2"
    [[ "$rc" == 0 ]] && return 0
    if [[ "$err" =~ Permission\ denied\ \(([a-z,-]+)\) ]]; then
        AUTH_METHODS="${BASH_REMATCH[1]}"
        AUTH_FAILS=$((AUTH_FAILS + 1))
        return 1
    fi
    if ((AUTH_FAILS > 0)) && [[ "$err" =~ (Connection\ refused|timed\ out|Connection\ reset|Connection\ closed|kex_exchange_identification|No\ route) ]]; then
        die "The VPS stopped answering right after a rejected login.
  It has probably banned this IP for a while (fail2ban often bans for ~10 minutes).
  Wait, or switch between Wi-Fi and mobile data to get a different IP, then run again.
  ssh said: ${err:-(no output)}"
    fi
    die "Could not reach $VPS_TARGET: ${err:-(no output)}"
}

auth_budget_left() { ((AUTH_FAILS < AUTH_MAX_FAILS)); }

_auth_require_budget() {
    auth_budget_left && return 0
    die "Stopped after $AUTH_FAILS rejected logins to protect this IP from a ban.
  Authorize this key on the VPS by hand, then run again:
    $(_auth_pubkey)"
}

# One login with our own key. Returns 0 if it works.
auth_try_own_key() {
    local err rc=0
    _auth_require_budget
    # shellcheck disable=SC2046
    err="$(ssh "${SSH_OPTS[@]}" $(_auth_known_hosts_opts) "$VPS_TARGET" true 2>&1)" || rc=$?
    _auth_note "$rc" "$err"
}

auth_offers() { [[ ",$AUTH_METHODS," == *",$1,"* ]]; }

auth_show_host_fingerprint() {
    local fp
    fp="$(ssh-keygen -lf "$ORCHESTRATOR_SSH_DIR/known_hosts" -F "$VPS_HOST" 2>/dev/null \
        | awk '!/^#/ {print $2" ("$NF")"; exit}')"
    [[ -n "$fp" ]] || return 0
    echo ""
    echo "  VPS host key: ${C_BOLD}${fp}${C_RESET}"
    echo "  If your provider shows a host key fingerprint, check it matches before typing a password."
}

# ── Route 0: keys already on this phone ─────────────

auth_candidate_keys() {
    local dir f own="$ORCHESTRATOR_SSH_DIR/id_ed25519" n=0
    for dir in $AUTH_KEY_DIRS; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"/id_*; do
            [[ -f "$f" && "$f" != *.pub && "$f" != "$own" ]] || continue
            [[ -f "$f.pub" ]] || continue
            printf '%s\n' "$f"
            n=$((n + 1))
            ((n < AUTH_MAX_CANDIDATES)) || return 0
        done
    done
}

auth_route_existing_keys() {
    local -a keys=() opts=()
    local k err rc=0 answer=""
    mapfile -t keys < <(auth_candidate_keys)
    ((${#keys[@]} > 0)) || return 1
    _auth_require_budget
    echo ""
    echo "  Found key(s) on this phone that may already have access to the VPS:"
    for k in "${keys[@]}"; do echo "    $k"; done
    read -r -p "  Use them once to add this script's key? [Y/n] " answer || [[ -n "$answer" ]] || no_answer "Use them once"
    [[ "${answer:-Y}" =~ ^[Yy]$ ]] || return 1
    for k in "${keys[@]}"; do opts+=(-i "$k"); done
    # One connection offers every candidate. BatchMode stays off so a
    # passphrase-protected key can prompt (ssh reads it from the terminal).
    # shellcheck disable=SC2046
    err="$(_auth_pubkey | ssh -o IdentitiesOnly=yes "${opts[@]}" -o PreferredAuthentications=publickey \
        $(_auth_known_hosts_opts) "$VPS_TARGET" "$AUTH_INSTALL_SNIPPET" 2>&1)" || rc=$?
    _auth_note "$rc" "$err" || { warn "None of those keys was accepted."; return 1; }
    [[ "$err" == *SI_KEY_INSTALLED* ]] || { warn "Logged in, but the key was not added: $err"; return 1; }
    ok "Added this script's key using an existing key"
}

# ── Route 1: password ───────────────────────────────

auth_route_password() {
    local err rc=0
    auth_offers password || auth_offers keyboard-interactive || return 1
    _auth_require_budget
    auth_show_host_fingerprint
    echo ""
    info "Log in once with ${VPS_USER}'s password to add this script's key."
    info "ssh asks for it directly; this script never sees it."
    # One password prompt per connection, so each wrong password is one
    # counted failure. The key travels on stdin; the password is read by ssh
    # from the terminal.
    # shellcheck disable=SC2046
    err="$(_auth_pubkey | ssh -o BatchMode=no -o PubkeyAuthentication=no \
        -o PreferredAuthentications=keyboard-interactive,password \
        -o NumberOfPasswordPrompts=1 $(_auth_known_hosts_opts) \
        "$VPS_TARGET" "$AUTH_INSTALL_SNIPPET" 2>&1)" || rc=$?
    _auth_note "$rc" "$err" || { warn "Password login was rejected."; return 1; }
    [[ "$err" == *SI_KEY_INSTALLED* ]] || { warn "Logged in, but the key was not added: $err"; return 1; }
    ok "Added this script's key using the password"
}

# ── Route 2a: adb ───────────────────────────────────

# The part typed on the other device. Kept short: that device already logs
# in to this user with a key, so ~/.ssh/authorized_keys exists already.
_auth_remote_append() {
    printf '%s' "ssh ${VPS_TARGET} \"cat>>.ssh/authorized_keys\""
}

auth_route_adb() {
    mkdir -p "$(dirname "$AUTH_ADB_PATH")"
    _auth_pubkey > "$AUTH_ADB_PATH"
    chmod 644 "$AUTH_ADB_PATH"
    echo ""
    echo "  On the computer connected to this phone over adb, run:"
    echo ""
    echo "    ${C_BOLD}adb shell cat ${AUTH_ADB_PATH} | $(_auth_remote_append)${C_RESET}"
    echo ""
    _auth_wait_and_check
    local rc=$?
    rm -f "$AUTH_ADB_PATH"
    return "$rc"
}

# ── Route 2b: Wi-Fi ─────────────────────────────────

auth_lan_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')"
    [[ "$ip" =~ ^(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\. ]] || return 1
    printf '%s\n' "$ip"
}

_auth_nc() {
    if have_cmd nc; then nc "$@"; elif have_cmd toybox; then toybox nc "$@"; else return 127; fi
}

# A complete HTTP/1.0 response, so plain `curl` accepts it.
auth_http_response() {
    local body
    body="$(_auth_pubkey)"$'\n'
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "${#body}" "$body"
}

# Serves the key to whoever connects, for AUTH_WIFI_SECONDS. Runs in the
# background; prints nothing.
_auth_serve_key() {
    local resp="$1" end=$((SECONDS + AUTH_WIFI_SECONDS))
    while ((SECONDS < end)); do
        _auth_nc -l -p "$AUTH_WIFI_PORT" < "$resp" > /dev/null 2>&1 || sleep 1
    done
}

auth_route_wifi() {
    local ip resp pid
    ip="$(auth_lan_ip)" || { warn "This phone does not seem to be on a local network (Wi-Fi)."; return 1; }
    have_cmd nc || have_cmd toybox || { warn "No nc on this phone; the Wi-Fi route is unavailable."; return 1; }
    resp="$AUTH_TMP/http-response"
    auth_http_response > "$resp"
    _auth_serve_key "$resp" &
    pid=$!
    echo ""
    echo "  For the next $((AUTH_WIFI_SECONDS / 60)) minutes this phone shares its *public* key on your network."
    echo "  On a device on the same Wi-Fi that can already reach the VPS, run:"
    echo ""
    echo "    ${C_BOLD}curl -s ${ip}:${AUTH_WIFI_PORT} | $(_auth_remote_append)${C_RESET}"
    echo ""
    local rc=0
    _auth_wait_and_check || rc=$?
    # Stop the loop and the nc it may be blocked in.
    if have_cmd pkill; then pkill -P "$pid" 2>/dev/null; fi
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return "$rc"
}

# ── Route 2c: type it in chunks ─────────────────────

AUTH_CHUNK=20

# The key as typed: type and base64 only (the comment is dropped to keep it
# short; the key itself identifies it).
auth_chunk_key() { _auth_pubkey | awk '{print $1" "$2}'; }

# Prints the lines to type. Each chunk line shows a 4-character code: after
# typing it, `md5sum si.k` should start with that code.
auth_chunk_commands() {
    local key part sofar="" i=0 n code op
    key="$(auth_chunk_key)"
    n=$(( (${#key} + AUTH_CHUNK - 1) / AUTH_CHUNK ))
    printf '  start  umask 077; mkdir -p .ssh\n'
    while ((i * AUTH_CHUNK < ${#key})); do
        part="${key:i*AUTH_CHUNK:AUTH_CHUNK}"
        sofar+="$part"
        code="$(printf '%s' "$sofar" | md5sum | cut -c1-4)"
        op='>>'; ((i == 0)) && op='>'
        printf "  %d/%d    printf %%s '%s' %s si.k      (check: %s)\n" $((i + 1)) "$n" "$part" "$op" "$code"
        i=$((i + 1))
    done
    printf '  end    echo >> si.k; cat si.k >> .ssh/authorized_keys\n'
    printf '  tidy   rm si.k\n'
}

auth_route_chunks() {
    echo ""
    echo "  Log in to the VPS as ${C_BOLD}${VPS_USER}${C_RESET} any way you can (another device, or your"
    echo "  provider's web console), then type these lines one by one."
    echo "  To check a line, run  md5sum si.k  and compare the first 4 characters."
    echo ""
    auth_chunk_commands
    echo ""
    _auth_wait_and_check
}

# ── Manual routes: wait for Enter, then exactly one login attempt ──

_auth_wait_and_check() {
    local answer
    while :; do
        _auth_require_budget
        read -r -p "  Press Enter once it has run (or type q to choose another way): " answer \
            || [[ -n "$answer" ]] || no_answer "Press Enter once it has run"
        [[ "$answer" == q ]] && return 1
        if auth_try_own_key; then
            ok "The VPS now accepts this script's key"
            return 0
        fi
        warn "Still rejected. Make sure the command ran without errors, for user ${VPS_USER}."
    done
}

# ── Root access without a sudo password ─────────────

# Runs a root script on the VPS through one interactive sudo. The script is
# uploaded first (no terminal needed), then run with -t so sudo can ask for
# the password on the terminal itself. Output is shown live and captured.
_auth_sudo_script() { # LOCAL_SCRIPT_FILE → prints captured output
    local remote=".si-auth-$$.sh" rc=0
    # shellcheck disable=SC2046
    ssh "${SSH_OPTS[@]}" -o ConnectTimeout=30 "$VPS_TARGET" "umask 077; cat > $remote" < "$1" \
        || die "Could not upload a helper script to the VPS"
    # shellcheck disable=SC2046
    ssh $(_auth_key_opts) $(_auth_known_hosts_opts) -o BatchMode=no -t "$VPS_TARGET" \
        "sudo sh $remote; rc=\$?; rm -f $remote; exit \$rc" | tee "$AUTH_TMP/sudo.out" || rc=$?
    tr -d '\r' < "$AUTH_TMP/sudo.out"
    return "$rc"
}

# For a non-root user without passwordless sudo: if sshd allows root key
# logins, add our key to root's authorized_keys (one sudo password, typed to
# sudo itself) and switch VPS_TARGET to root. Otherwise offer sudoers.
auth_offer_root() {
    local pub answer out mode script="$AUTH_TMP/root.sh"
    auth_is_interactive || return 1
    pub="$(_auth_pubkey)"
    is_plain_pubkey "$pub" || die "Unexpected orchestrator public key format"
    echo ""
    info "${VPS_USER} needs a password for sudo, which this script never types for you."
    read -r -p "  Let this script log in as root with its key from now on? (asks your sudo password once) [Y/n] " answer \
        || [[ -n "$answer" ]] || no_answer "Log in as root from now on"
    if [[ ! "${answer:-Y}" =~ ^[Yy]$ ]]; then
        auth_offer_sudoers
        return
    fi
    cat > "$script" <<EOF
key='$pub'
mode=\$(sshd -T 2>/dev/null | awk '\$1=="permitrootlogin" {print \$2}')
case "\$mode" in
    yes|prohibit-password|without-password)
        umask 077
        mkdir -p /root/.ssh && touch /root/.ssh/authorized_keys
        grep -qxF -- "\$key" /root/.ssh/authorized_keys || printf '%s\n' "\$key" >> /root/.ssh/authorized_keys
        echo SI_ROOT_OK ;;
    *) echo "SI_ROOT_NO=\${mode:-unknown}" ;;
esac
EOF
    out="$(_auth_sudo_script "$script")" || true
    if [[ "$out" == *SI_ROOT_OK* ]]; then
        VPS_TARGET="root@$VPS_HOST"; VPS_USER=root
        if auth_try_own_key; then
            ok "Root login with this script's key works"
            return 0
        fi
        warn "Root login is still rejected (an sshd Match or AllowUsers rule may forbid it)."
        auth_offer_sudoers
        return
    fi
    if [[ "$out" == *SI_ROOT_NO=* ]]; then
        mode="${out##*SI_ROOT_NO=}"; mode="${mode%%[[:space:]]*}"
        warn "This VPS does not allow root logins (PermitRootLogin ${mode})."
        auth_offer_sudoers
        return
    fi
    warn "sudo did not complete."
    return 1
}

# With explicit consent: passwordless sudo for this user via a drop-in that
# visudo validates first. Asked at most once per run.
auth_offer_sudoers() {
    local answer out file="/etc/sudoers.d/serverinator-${VPS_USER}" script="$AUTH_TMP/sudoers.sh"
    ((AUTH_SUDOERS_ASKED == 0)) || return 1
    AUTH_SUDOERS_ASKED=1
    [[ "$VPS_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    echo ""
    echo "  Alternative: give ${VPS_USER} passwordless sudo by creating ${file}:"
    echo "    ${VPS_USER} ALL=(ALL) NOPASSWD: ALL"
    echo "  This changes the server's security: whoever holds ${VPS_USER}'s SSH key gets root without a password."
    read -r -p "  Create it? [y/N] " answer || [[ -n "$answer" ]] || no_answer "Create it"
    [[ "$answer" =~ ^[Yy]$ ]] || return 1
    cat > "$script" <<EOF
t=\$(mktemp) || exit 1
printf '%s\n' '${VPS_USER} ALL=(ALL) NOPASSWD: ALL' > "\$t"
chmod 0440 "\$t"
visudo -cf "\$t" >/dev/null && mv "\$t" '${file}' && echo SI_SUDOERS_OK || rm -f "\$t"
EOF
    out="$(_auth_sudo_script "$script")" || true
    if [[ "$out" == *SI_SUDOERS_OK* ]]; then
        ok "Created ${file}"
        return 0
    fi
    warn "Could not create ${file}."
    return 1
}

# ── Entry point ─────────────────────────────────────

auth_init() {
    [[ -n "$AUTH_TMP" ]] || AUTH_TMP="$(mktemp -d)"
}

# authorize_vps — called after the first own-key attempt failed (its result
# is already recorded via _auth_note). Returns once the key works, or dies.
authorize_vps() {
    local choice
    auth_init

    if ! auth_is_interactive; then
        die "The VPS does not accept this script's key yet, and there is no terminal to ask you.
  Add this line to ${VPS_USER}'s ~/.ssh/authorized_keys on the VPS, then run again:
    $(_auth_pubkey)"
    fi

    echo ""
    warn "The VPS does not accept this script's key yet (it offers: ${AUTH_METHODS:-unknown})."
    auth_route_existing_keys && return 0

    while :; do
        _auth_require_budget
        echo ""
        echo "  How can you get this phone's key onto the VPS?"
        local -a opts=()
        if auth_offers password || auth_offers keyboard-interactive; then
            opts+=("password:Type ${VPS_USER}'s password (the server allows it)")
        fi
        opts+=("adb:A computer connected to this phone over adb can reach the VPS")
        opts+=("wifi:A device on the same Wi-Fi can reach the VPS")
        opts+=("chunks:Type the key by hand (another device or the provider's web console)")
        local i=1 o
        for o in "${opts[@]}"; do echo "    $i) ${o#*:}"; i=$((i + 1)); done
        echo "    q) Quit"
        read -r -p "  Choose: " choice || [[ -n "$choice" ]] || no_answer "Choose" "This step needs a terminal. This script's key: $(_auth_pubkey)"
        [[ "$choice" == q ]] && die "Stopped. This script's key: $(_auth_pubkey)"
        [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#opts[@]})) || continue
        case "${opts[choice-1]%%:*}" in
            password) auth_route_password && return 0 ;;
            adb)      auth_route_adb && return 0 ;;
            wifi)     auth_route_wifi && return 0 ;;
            chunks)   auth_route_chunks && return 0 ;;
        esac
    done
}
