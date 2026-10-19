# shellcheck shell=bash
# ServerInator Core, VPS side: guests (files only, or a shell user)
# Sourced by core-vps.sh, which holds the settings and globals used here.

# ─────────────────────────────────────────────
# Guests (--add-guest, --list-guests, --revoke-guest, --sync-guests)
# ─────────────────────────────────────────────
#
# A guest is a key the owner adds, in one of two modes:
#
# files  Any SFTP app (FileZilla, WinSCP, ...) reaches one folder on one
#        phone, read-only or read-write. The app logs in to this VPS as
#        GUEST_VPS_USER with the guest's key. That key's authorized_keys line
#        forces a command, so the VPS ignores what the app asked for and
#        instead opens SSH to the phone over the tunnel, as the guest's phone
#        user, with a route key only this VPS holds, and asks for SFTP there.
#        The two byte streams are joined, so the app talks to the phone's
#        internal-sftp without knowing it. On the phone the guest is
#        chrooted to a room holding just that folder (core/guest-helper.sh).
# shell  A normal user in the phone's chroot, with a home folder and bash,
#        and no root. The guest's ssh jumps through this VPS like the
#        owner's clients do: GUEST_VPS_USER lets the key forward to the
#        phone's sshd and nothing else, and the phone accepts the key for
#        that user, from the VPS's tunnel address only. The guest gets a
#        client setup script, like the owner's devices.
#
# Records: GUESTS_DIR/NAME.json. The authorized_keys of GUEST_VPS_USER is
# rebuilt from them (write_guest_routes), so it never drifts.

GUEST_HELPER_PHONE="/usr/local/sbin/serverinator-guests"
GUEST_FILES_DIR="/srv/files"   # where a bare folder name lives on the phone

validate_guest_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] \
        || die "Invalid guest name '${1}': 1-31 characters, lowercase letters/digits/_/-, starting with a letter"
}

guest_record_path() { printf '%s/%s.json\n' "$GUESTS_DIR" "$1"; }

guest_names() { # [DEVICE]
    local f name
    for f in "$GUESTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"; name="${name%.json}"
        [[ -z "${1:-}" || "$(json_get "$f" device)" == "$1" ]] && printf '%s\n' "$name"
    done
    return 0
}

# normalize_folder_spec SPEC -> "MODE:PATH"
#   photos            -> rw:/srv/files/photos
#   photos:ro         -> ro:/srv/files/photos
#   /data/music:rw    -> rw:/data/music
# The phone checks the path again and refuses system folders.
normalize_folder_spec() {
    local spec="$1" mode=rw path
    case "$spec" in
        *:ro) mode=ro; path="${spec%:ro}" ;;
        *:rw) mode=rw; path="${spec%:rw}" ;;
        *)    path="$spec" ;;
    esac
    path="${path%/}"
    if [[ "$path" != /* ]]; then
        [[ "$path" =~ ^[A-Za-z0-9._@+-]+$ && "$path" != . && "$path" != .. ]] \
            || die "Folder '$spec': use a plain name (kept in $GUEST_FILES_DIR) or a full path"
        path="$GUEST_FILES_DIR/$path"
    fi
    [[ "$path" =~ ^(/[A-Za-z0-9._@+-]+)+$ && "/$path/" != *"/../"* && "/$path/" != *"/./"* ]] \
        || die "Folder '$spec': only letters, digits and ._@+- are allowed in folder names"
    printf '%s:%s\n' "$mode" "$path"
}

# Settles the guest's mode, and the folder of a files guest, asking in a
# terminal when the command line said neither. Sets GUEST_SHELL and, for a
# files guest, GUEST_FOLDER to a normalized spec.
resolve_guest_mode() { # NAME
    local name="$1" answer mode
    if [[ "$GUEST_SHELL" == 1 || -n "$GUEST_FOLDER" ]]; then
        [[ -z "$GUEST_FOLDER" ]] || GUEST_FOLDER="$(normalize_folder_spec "$GUEST_FOLDER")"
        return 0
    fi
    [[ -t 0 ]] || die "Say what '$name' gets: --folder NAME|PATH[:ro|:rw] (files only) or --shell (a shell user), or run this in a terminal to be asked"
    echo ""
    echo "  What does '$name' get?"
    echo "    f  files only: one folder, in any SFTP app (FileZilla, WinSCP, ...)"
    echo "    s  a shell user: a Linux account in the phone's chroot, with a home folder, no root"
    read -r -p "  Files or shell? [F/s]: " answer || answer=""
    if [[ "${answer,,}" == s* ]]; then
        GUEST_SHELL=1
        return 0
    fi
    echo "  Which folder? A plain name (photos) lives in $GUEST_FILES_DIR on the phone and"
    echo "  is created if missing; a full path (/root/music) shares a folder you already have."
    read -r -p "  Folder: " answer || answer=""
    [[ -n "$answer" ]] || die "No folder chosen; nothing changed"
    answer="$(normalize_folder_spec "$answer")"
    read -r -p "  Read-only or read-write? [ro/RW]: " mode || mode=""
    [[ "${mode,,}" == ro ]] && GUEST_FOLDER="ro:${answer#*:}" || GUEST_FOLDER="rw:${answer#*:}"
}

# "rw:/srv/files/photos" -> "photos (read-write)"
describe_folder() {
    local mode="${1%%:*}" path="${1#*:}"
    printf '%s (%s, %s)' "${path##*/}" "$path" "$([[ "$mode" == ro ]] && echo read-only || echo read-write)"
}

guest_folder_specs() { # RECORD -> MODE:PATH lines
    json_query -r '.folders[]? | "\(.mode):\(.path)"' < "$1"
}

# files|shell. Records from before the two modes are files guests.
guest_mode() { # RECORD
    [[ "$(json_get "$1" mode)" == shell ]] && echo shell || echo files
}

# A files guest's one folder. Records from before the one-folder rule may
# list several; the first one is kept.
guest_folder() { # RECORD
    local -a specs=()
    mapfile -t specs < <(guest_folder_specs "$1")
    ((${#specs[@]} <= 1)) || warn "Guest '$(json_get "$1" name)' had ${#specs[@]} folders; a guest has one now, so only ${specs[0]#*:} is kept" >&2
    printf '%s\n' "${specs[0]:-}"
}

# The VPS system user guests log in as. Its password is "*" (never matches,
# but not "locked": sshd with UsePAM no refuses locked accounts).
ensure_guest_vps_user() {
    mkdir -p "$GUEST_VPS_HOME/.ssh" "$GUEST_VPS_HOME/routes"
    if [[ "$DEV" != 1 ]]; then
        if ! getent passwd "$GUEST_VPS_USER" >/dev/null; then
            useradd --system --home-dir "$GUEST_VPS_HOME" --shell /bin/sh \
                --comment "ServerInator guest file access" "$GUEST_VPS_USER" \
                || die "Could not create the VPS user $GUEST_VPS_USER"
            mkdir -p "$WG_KEY_DIR"; touch "$WG_KEY_DIR/guest-user-owned"
            info "Created the VPS user '$GUEST_VPS_USER' that guests log in as"
        fi
        usermod -p '*' "$GUEST_VPS_USER"
        chown -R "$GUEST_VPS_USER:" "$GUEST_VPS_HOME"
    fi
    chmod 750 "$GUEST_VPS_HOME"
    chmod 700 "$GUEST_VPS_HOME/.ssh" "$GUEST_VPS_HOME/routes"
}

# The VPS's own sshd must let GUEST_VPS_USER in with a key from
# .ssh/authorized_keys. Warn (never change) when it looks like it won't.
check_guest_vps_sshd() {
    [[ "$DEV" != 1 ]] && have_cmd sshd || return 0
    local eff
    eff="$(sshd -T -C "user=$GUEST_VPS_USER,host=localhost,addr=127.0.0.1" 2>/dev/null)" || return 0
    local allow_u allow_g
    allow_u="$(awk 'tolower($1)=="allowusers" {$1=""; print}' <<< "$eff")"
    allow_g="$(awk 'tolower($1)=="allowgroups" {$1=""; print}' <<< "$eff")"
    if [[ -n "$allow_u$allow_g" && " $allow_u " != *" $GUEST_VPS_USER "* ]]; then
        warn "This VPS's sshd only lets some users in (AllowUsers/AllowGroups)."
        warn "  Add $GUEST_VPS_USER to AllowUsers in /etc/ssh/sshd_config and reload sshd, or guests can't log in."
    fi
    [[ "$(awk 'tolower($1)=="pubkeyauthentication" {print $2}' <<< "$eff")" != no ]] \
        || warn "sshd has PubkeyAuthentication no for $GUEST_VPS_USER; guests log in with keys, so they can't connect."
    awk 'tolower($1)=="authorizedkeysfile"' <<< "$eff" | grep -q '\.ssh/authorized_keys' \
        || warn "sshd doesn't read ~/.ssh/authorized_keys for $GUEST_VPS_USER; guests can't connect."
    # A forced command replaces the "sftp" subsystem request only when sshd
    # has that subsystem configured; otherwise the request fails first.
    awk 'tolower($1)=="subsystem" && $2=="sftp"' <<< "$eff" | grep -q . \
        || warn "sshd has no 'Subsystem sftp' line; add 'Subsystem sftp internal-sftp' to /etc/ssh/sshd_config and reload sshd, or SFTP apps can't connect."
    [[ -z "$(awk 'tolower($1)=="forcecommand"' <<< "$eff")" ]] \
        || warn "sshd has a ForceCommand for $GUEST_VPS_USER; it overrides the guest routing."
    # Shell guests jump through the VPS with a forwarding.
    [[ "$GUEST_SHELL" == 1 ]] || return 0
    case "$(awk 'tolower($1)=="allowtcpforwarding" {print tolower($2)}' <<< "$eff")" in
        no|remote) warn "sshd has AllowTcpForwarding off for $GUEST_VPS_USER; shell guests jump through it, so they can't connect." ;;
    esac
}

# The VPS's SSH port, for the guest's app.
vps_ssh_port() {
    local port=""
    [[ "$DEV" != 1 ]] && have_cmd sshd && port="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port" {print $2; exit}')"
    printf '%s\n' "${port:-22}"
}

# One authorized_keys line: this guest key may only run the hop to its phone.
# The hop must ask for the "sftp" subsystem: the phone's ForceCommand
# internal-sftp refuses plain command sessions.
_guest_route_line() { # NAME PUBKEY DEVICE PHONE_IP PORT HOSTKEY
    local name="$1" pub="$2" device="$3" ip="$4" port="$5" hostkey="$6" kh check
    kh="$GUEST_VPS_HOME/routes/known_hosts_${device}"
    if [[ -n "$hostkey" ]]; then
        check="-o StrictHostKeyChecking=yes -o HostKeyAlias=serverinator-${device}"
    else
        check="-o StrictHostKeyChecking=accept-new"
    fi
    printf 'command="exec ssh -q -T -F /dev/null -o BatchMode=yes %s -o UserKnownHostsFile=%s -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=4 -o KexAlgorithms=curve25519-sha256,curve25519-sha256@libssh.org -o HostKeyAlgorithms=ssh-ed25519 -o IdentitiesOnly=yes -i %s -p %s %s@%s -s sftp",restrict %s serverinator-guest:%s\n' \
        "$check" "$kh" "$GUEST_VPS_HOME/routes/$name" "$port" "$name" "$ip" "$pub" "$name"
}

# The line for a shell guest: forwarding to its phone's sshd and nothing else.
_guest_jump_line() { # NAME PUBKEY PHONE_IP PORT
    printf '%s serverinator-guest:%s\n' "$(_vps_jump_key_line "$2" "$3" "$4")" "$1"
}

# Rebuilds GUEST_VPS_USER's authorized_keys (and the pinned phone host keys)
# from the guest records. VPS-only: works with the tunnel down. Run after
# every guest change, a reinstall (the phone's address may change) and
# --remove-device.
write_guest_routes() {
    local -a names=()
    mapfile -t names < <(guest_names)
    if ((${#names[@]} == 0)) && [[ ! -d "$GUEST_VPS_HOME/.ssh" ]]; then
        return 0
    fi
    ensure_guest_vps_user
    local name rec device drec ip port hostkey pub staged
    staged="$(mktemp)" || die "Could not create a temp file"
    for name in "${names[@]}"; do
        rec="$(guest_record_path "$name")"
        device="$(json_get "$rec" device)"
        drec="$(device_record_path "$device")"
        if [[ ! -f "$drec" ]]; then
            warn "Guest '$name' belongs to phone '$device', which is gone; skipped"
            continue
        fi
        ip="$(json_get "$drec" ssh_phone_ip)"
        port="$(json_get_num "$drec" ssh_port)"; port="${port:-22}"
        hostkey="$(json_get "$drec" ssh_host_pubkey)"
        pub="$(json_get "$rec" guest_pubkey)"
        is_plain_pubkey "$pub" || { warn "Guest '$name' has a malformed key in $rec; skipped"; continue; }
        validate_ipv4 "$ip" "phone tunnel IPv4"
        validate_port "$port"
        if [[ "$(guest_mode "$rec")" == shell ]]; then
            _guest_jump_line "$name" "$pub" "$ip" "$port" >> "$staged"
            continue
        fi
        [[ -f "$GUEST_VPS_HOME/routes/$name" ]] || { warn "Route key for '$name' is missing; run --sync-guests"; continue; }
        if [[ -n "$hostkey" ]]; then
            printf 'serverinator-%s %s\n' "$device" "$hostkey" > "$GUEST_VPS_HOME/routes/known_hosts_${device}"
        fi
        _guest_route_line "$name" "$pub" "$device" "$ip" "$port" "$hostkey" >> "$staged"
    done
    reconcile_file "$GUEST_VPS_HOME/.ssh/authorized_keys" 600 < "$staged" >/dev/null
    rm -f "$staged"
    if [[ "$DEV" != 1 ]]; then
        chown -R "$GUEST_VPS_USER:" "$GUEST_VPS_HOME/.ssh" "$GUEST_VPS_HOME/routes"
    fi
    rm -f "$GUEST_VPS_HOME/.ssh/authorized_keys.bak"
}

# Makes sure the phone can host guests (it may run an older ServerInator).
# Shell guests need helper version 2.
_require_phone_guest_helper() { # [files|shell]
    local v
    v="$(_phone_run "$GUEST_HELPER_PHONE" version 2>/dev/null)" || v=""
    [[ "$v" =~ ^[0-9]+$ ]] \
        || die "Phone '$DEVICE_NAME' can't host guests yet, or isn't reachable. Update it first (re-run serverinator.sh on the phone; nothing else changes), check the tunnel with --verify, then try again."
    [[ "${1:-files}" != shell || "$v" -ge 2 ]] \
        || die "Phone '$DEVICE_NAME' runs an older ServerInator that has no shell guests. Re-run serverinator.sh on the phone to update it, then try again."
}

# Pushes one guest to the phone. Prints the phone's UID for it. A files
# guest's phone account takes the route key, a shell guest's its own key.
_phone_guest_set() { # NAME UID KEY (FOLDER_SPEC | --shell)
    local name="$1" uid="$2" key="$3" out
    shift 3
    local -a args=(set "$name" --from "${VPS_WG_SUBNET}.1")
    [[ -z "$uid" ]] || args+=(--uid "$uid")
    out="$(printf '%s\n' "$key" | _phone_run "$GUEST_HELPER_PHONE" "${args[@]}" "$@")" \
        || { printf '%s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out" | grep -v '^uid=' | sed 's/^/  phone: /' >&2
    out="$(printf '%s\n' "$out" | sed -n 's/^uid=\([0-9][0-9]*\)$/\1/p' | tail -n 1)"
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# The record keeps "folders" as a list (of one) so older records still read.
_write_guest_record() { # NAME UID PUBKEY GENERATED CREATED MODE [SPEC]
    local name="$1" uid="$2" pub="$3" generated="$4" created="$5" mode="$6" spec="${7:-}" staged
    mkdir -p "$GUESTS_DIR"; chmod 700 "$GUESTS_DIR"
    staged="$(mktemp "$GUESTS_DIR/.${name}.XXXXXX")"
    json_query -n \
        --arg name "$name" --arg device "$DEVICE_NAME" --argjson uid "$uid" \
        --arg pub "$pub" --argjson generated "$generated" --arg created "$created" \
        --arg mode "$mode" --arg spec "$spec" '
        {name: $name, device: $device, mode: $mode, uid: $uid, guest_pubkey: $pub,
         key_generated: $generated, created: $created,
         folders: (if $spec == "" then [] else
                   [{mode: ($spec | split(":")[0]), path: ($spec | split(":")[1:] | join(":"))}] end)}' \
        > "$staged" || { rm -f "$staged"; die "Could not write the guest record"; }
    chmod 600 "$staged"
    mv "$staged" "$(guest_record_path "$name")"
}

_guest_connection_card() { # NAME KEYFILE SPEC
    local name="$1" keyfile="$2" spec="$3" fp=""
    [[ -f "${SERVERINATOR_VPS_HOSTKEY_FILE:-/etc/ssh/ssh_host_ed25519_key.pub}" ]] \
        && fp="$(ssh_key_fingerprint "$(vps_host_pubkey)" | awk '{print $1}')"
    echo ""
    echo "  '$name' can connect with any SFTP app (FileZilla, WinSCP, an Android SFTP app):"
    echo "    Protocol : SFTP"
    echo "    Host     : $(vps_public_host)"
    echo "    Port     : $(vps_ssh_port)"
    echo "    User     : $GUEST_VPS_USER"
    if [[ -n "$keyfile" ]]; then
        echo "    Key file : $keyfile   (give this file to $name; it is the login)"
    else
        echo "    Key      : the key $name sent you"
    fi
    echo "    Folder   : $(describe_folder "$spec")"
    [[ -z "$fp" ]] || echo "    The app asks to trust the server once; its key should be $fp"
    if [[ -n "$keyfile" ]]; then
        echo ""
        echo "  Copy the key file off this VPS:"
        echo "    $(fetch_hint_file "$keyfile")"
    fi
    echo ""
}

# The setup script a shell guest runs on their own computer.
guest_setup_path() { printf '%s/guest-setup-%s.sh\n' "$SSH_KEY_DIR" "$1"; }

_shell_guest_card() { # NAME SETUP_SCRIPT GENERATED
    local name="$1" script="$2" generated="$3"
    echo ""
    echo "  '$name' is a shell user on $DEVICE_NAME: a home folder (/home/$name), no root."
    echo "  Give $name this setup script; they run it with bash (Linux, macOS, Termux):"
    echo "    $script"
    if [[ "$generated" == 1 ]]; then
        echo "  It holds $name's private key, so hand it over privately."
    else
        echo "  It works only where $name's own key is."
    fi
    echo "  Copy it off this VPS:"
    echo "    $(fetch_hint_file "$script")"
    echo "  Then $name connects with:  ssh $(guest_alias)"
    echo ""
}

# The ssh alias a shell guest's setup script writes.
guest_alias() { printf '%s\n' "${SSH_ALIAS:-$DEVICE_NAME}"; }

# Like fetch_hint, for a file that isn't a script.
fetch_hint_file() { # PATH
    local name="${1##*/}" user="${SSH_VPS_USER:-root}"
    if [[ "$user" == root ]]; then
        printf '%s' "scp root@$(vps_public_host):$1 ."
    else
        printf '%s' "ssh ${user}@$(vps_public_host) 'sudo cat $1' > $name"
    fi
}

add_guest() {
    local name="$GUEST_NAME" rec pub="" generated=0 gk="" uid created mode=files
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--add-guest requires root"
    rec="$(guest_record_path "$name")"
    [[ ! -f "$rec" ]] || die "Guest '$name' already exists (phone $(json_get "$rec" device)). To change it, --revoke-guest $name and add it again"
    _load_phone_state
    resolve_guest_mode "$name"
    [[ "$GUEST_SHELL" == 1 ]] && mode=shell
    _require_phone_guest_helper "$mode"

    require_cmd ssh-keygen
    gk="$SSH_KEY_DIR/guest_${name}"
    rm -f "$gk" "$gk.pub"
    mkdir -p "$SSH_KEY_DIR"; chmod 700 "$SSH_KEY_DIR"
    if [[ -n "$GUEST_PUBKEY" ]]; then
        pub="$GUEST_PUBKEY"
        gk=""
    else
        ssh-keygen -q -t ed25519 -N '' -C "serverinator-guest:${name}" -f "$gk"
        chmod 600 "$gk"
        pub="$(awk '{print $1" "$2}' "$gk.pub")"
        generated=1
    fi

    ensure_guest_vps_user
    if [[ "$mode" == shell ]]; then
        uid="$(_phone_guest_set "$name" "" "$pub" --shell)" || {
            [[ -z "$gk" ]] || rm -f "$gk" "$gk.pub"
            die "The phone refused or couldn't set up guest '$name' (see above)"
        }
    else
        local rk="$GUEST_VPS_HOME/routes/$name"
        rm -f "$rk" "$rk.pub"
        ssh-keygen -q -t ed25519 -N '' -C "serverinator-route:${name}" -f "$rk"
        uid="$(_phone_guest_set "$name" "" "$(awk '{print $1" "$2; exit}' "$rk.pub")" "$GUEST_FOLDER")" || {
            rm -f "$rk" "$rk.pub"; [[ -z "$gk" ]] || rm -f "$gk" "$gk.pub"
            die "The phone refused or couldn't set up guest '$name' (see above)"
        }
    fi
    created="$(date -u +%Y-%m-%d)"
    _write_guest_record "$name" "$uid" "$pub" "$generated" "$created" "$mode" "$GUEST_FOLDER"
    write_guest_routes
    check_guest_vps_sshd
    ok "Guest '$name' added on $DEVICE_NAME"
    if [[ "$mode" == files ]]; then
        _guest_connection_card "$name" "$gk" "$GUEST_FOLDER"
        return 0
    fi

    # The client setup script, as for the owner's devices, but for the
    # guest's phone user and the guest login user on this VPS.
    local script setup_mode=1
    script="$(guest_setup_path "$name")"
    if [[ "$generated" == 0 ]]; then
        setup_mode=2
        gk="$SSH_KEY_DIR/guest_${name}"
        printf '%s\n' "$pub" > "$gk.pub"
    fi
    SSH_USER="$name" SSH_VPS_USER="$GUEST_VPS_USER" \
        _write_client_setup_script "$script" "$(guest_alias)" "si-guest-${DEVICE_NAME}" "$setup_mode" "$gk" "$name"
    _shell_guest_card "$name" "$script" "$generated"
}

# Loads a guest's record and the phone it lives on.
_load_guest() { # NAME -> sets GUEST_RECORD
    GUEST_RECORD="$(guest_record_path "$1")"
    [[ -f "$GUEST_RECORD" ]] || die "No guest named '$1' (known: $(guest_names | tr '\n' ' '))"
    local device
    device="$(json_get "$GUEST_RECORD" device)"
    [[ -z "$SELECTED_DEVICE" || "$SELECTED_DEVICE" == "$device" ]] \
        || die "Guest '$1' is on phone '$device', not '$SELECTED_DEVICE'"
    SELECTED_DEVICE="$device"
}

# Everything this VPS keeps for one guest.
_remove_guest_files() { # NAME
    local setup
    setup="$(guest_setup_path "$1")"
    rm -f "$(guest_record_path "$1")" "$GUEST_VPS_HOME/routes/$1" "$GUEST_VPS_HOME/routes/$1.pub" \
        "$SSH_KEY_DIR/guest_$1" "$SSH_KEY_DIR/guest_$1.pub" "$setup"
}

revoke_guest() {
    local name="$GUEST_NAME"
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--revoke-guest requires root"
    _load_guest "$name"
    local mode
    mode="$(guest_mode "$GUEST_RECORD")"
    # The VPS side first: once the route line is gone the key can't reach
    # the phone, even if the phone can't be cleaned up right now.
    _remove_guest_files "$name"
    write_guest_routes
    info "Guest '$name' can no longer log in"
    if [[ -f "$(device_record_path "$SELECTED_DEVICE")" ]]; then
        _load_phone_state
        if _phone_run "$GUEST_HELPER_PHONE" remove "$name" >/dev/null; then
            if [[ "$mode" == shell ]]; then
                info "Removed the account '$name' and its home folder from $DEVICE_NAME"
            else
                info "Removed '$name' from $DEVICE_NAME (the shared folder and its files stay)"
            fi
        else
            warn "Couldn't reach $DEVICE_NAME to remove the '$name' account there; run --sync-guests later to tidy up"
        fi
    fi
}

list_guests() {
    local -a names=()
    mapfile -t names < <(guest_names "$SELECTED_DEVICE")
    echo ""
    if ((${#names[@]} == 0)); then
        info "No guests${SELECTED_DEVICE:+ on $SELECTED_DEVICE}. Add one: --add-guest NAME"
        return 0
    fi
    local name rec spec key fp
    printf '  %-16s %-12s %-6s %-10s %s\n' GUEST PHONE MODE CREATED KEY
    for name in "${names[@]}"; do
        rec="$(guest_record_path "$name")"
        key="$(json_get "$rec" guest_pubkey)"
        fp="$(ssh_key_fingerprint "$key" | awk '{print $1}')"
        printf '  %-16s %-12s %-6s %-10s %s\n' "$name" "$(json_get "$rec" device)" "$(guest_mode "$rec")" \
            "$(json_get "$rec" created)" "${fp:-?}"
        if [[ "$(guest_mode "$rec")" == shell ]]; then
            printf '  %-16s   %s\n' "" "shell user, home /home/$name"
            continue
        fi
        while IFS= read -r spec; do
            printf '  %-16s   %s\n' "" "$(describe_folder "$spec")"
        done < <(guest_folder_specs "$rec")
    done
    echo ""
    # Folder sizes come from the phone; best effort.
    local device out
    while IFS= read -r device; do
        [[ -f "$(device_record_path "$device")" ]] || continue
        SELECTED_DEVICE="$device"
        ( _load_phone_state >/dev/null
          if out="$(_phone_run "$GUEST_HELPER_PHONE" list 2>/dev/null)"; then
              echo "  Folder sizes on $device:"
              printf '%s\n' "$out" | awk '$1 ~ /^(ro|rw|home)$/ {print $2" "$3}' | sort -u \
                  | while read -r p s; do printf '    %-40s %s\n' "$p" "$s"; done
          else
              info "$device isn't reachable right now; folder sizes skipped"
          fi ) || true
    done < <(for name in "${names[@]}"; do json_get "$(guest_record_path "$name")" device; done | sort -u)
    echo ""
    info "Add: --add-guest NAME --folder F | --shell   Remove: --revoke-guest NAME"
}

# Makes the phone match the VPS's guest records: recreates missing guests
# (a reset or replaced phone), and removes guests the VPS no longer knows.
sync_guests() {
    [[ "$DEV" == 1 || "$(id -u)" == 0 ]] || die "--sync-guests requires root"
    _load_phone_state
    local -a names=() on_phone=()
    mapfile -t names < <(guest_names "$DEVICE_NAME")
    local need=files name
    for name in "${names[@]}"; do
        [[ "$(guest_mode "$(guest_record_path "$name")")" == files ]] || need=shell
    done
    _require_phone_guest_helper "$need"
    ensure_guest_vps_user
    local rec uid rk n=0
    for name in "${names[@]}"; do
        rec="$(guest_record_path "$name")"
        uid="$(json_get_num "$rec" uid)"
        if [[ "$(guest_mode "$rec")" == shell ]]; then
            _phone_guest_set "$name" "$uid" "$(json_get "$rec" guest_pubkey)" --shell >/dev/null \
                || { warn "Could not set up '$name' on $DEVICE_NAME"; continue; }
            n=$((n + 1))
            continue
        fi
        rk="$GUEST_VPS_HOME/routes/$name"
        if [[ ! -f "$rk" || ! -f "$rk.pub" ]]; then
            rm -f "$rk" "$rk.pub"
            ssh-keygen -q -t ed25519 -N '' -C "serverinator-route:${name}" -f "$rk"
        fi
        _phone_guest_set "$name" "$uid" "$(awk '{print $1" "$2; exit}' "$rk.pub")" "$(guest_folder "$rec")" >/dev/null \
            || { warn "Could not set up '$name' on $DEVICE_NAME"; continue; }
        n=$((n + 1))
    done
    mapfile -t on_phone < <(_phone_run "$GUEST_HELPER_PHONE" names) || on_phone=()
    for name in "${on_phone[@]}"; do
        [[ -n "$name" ]] || continue
        if [[ ! -f "$(guest_record_path "$name")" ]]; then
            _phone_run "$GUEST_HELPER_PHONE" remove "$name" >/dev/null \
                && info "Removed '$name' from $DEVICE_NAME (not a guest on this VPS any more)"
        fi
    done
    write_guest_routes
    ok "$n guest(s) in sync on $DEVICE_NAME"
}

# --remove-device: the phone's guests go with it.
remove_device_guests() { # DEVICE
    local name
    while IFS= read -r name; do
        _remove_guest_files "$name"
        info "Guest '$name' removed with the phone"
    done < <(guest_names "$1")
    rm -f "$GUEST_VPS_HOME/routes/known_hosts_$1"
    write_guest_routes
}

# --uninstall: the guest login user, if we created it.
uninstall_guest_access() {
    if [[ -f "$WG_KEY_DIR/guest-user-owned" && "$DEV" != 1 ]] && getent passwd "$GUEST_VPS_USER" >/dev/null; then
        pkill -KILL -u "$GUEST_VPS_USER" 2>/dev/null || true
        userdel -r "$GUEST_VPS_USER" 2>/dev/null || userdel "$GUEST_VPS_USER" || warn "Could not remove the VPS user $GUEST_VPS_USER"
        info "Removed the guest login user $GUEST_VPS_USER"
    fi
    [[ "$DEV" != 1 ]] || rm -rf "$GUEST_VPS_HOME"
}
