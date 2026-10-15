#!/usr/bin/env bash
# ServerInator — guest file access, phone side.
#
# Installed by core-phone.sh as /usr/local/sbin/serverinator-guests inside
# the chroot. The VPS runs it over its root SSH key (core-vps.sh
# --add-guest/--guest-access/--revoke-guest/--sync-guests), and the sshd
# autostart runs `mount-all` before sshd starts.
#
# A guest is a Linux user in the serverinator-guests group. sshd (see
# /etc/ssh/serverinator-guests.conf) gives that group internal-sftp only,
# chrooted to the guest's room /srv/guests/NAME. The room is root-owned
# and holds nothing but mount points: every folder the guest may use is
# bind-mounted into it, read-only or read-write per folder. Read-only is a
# property of the mount, so the guest can't get around it.
#
# Usage (as root, inside the chroot):
#   serverinator-guests set NAME [--uid UID] [--from IP] MODE:PATH...
#       (route public key on stdin; MODE is ro or rw; prints uid=N)
#   serverinator-guests remove NAME
#   serverinator-guests mount-all
#   serverinator-guests names
#   serverinator-guests list
#   serverinator-guests version
set -euo pipefail

SI_GUESTS_VERSION=1
GUEST_GROUP="serverinator-guests"
GUEST_GID_PREFERRED=2000
GUEST_UID_MIN=2001
GUEST_UID_MAX=2999

# Paths can be moved for tests.
STATE_DIR="${SI_GUESTS_STATE_DIR:-/etc/serverinator/guests}"
ROOMS_DIR="${SI_GUESTS_ROOMS_DIR:-/srv/guests}"
KEYS_DIR="${SI_GUESTS_KEYS_DIR:-/etc/ssh/serverinator-guests}"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── Validation ─────────────────────────────────

valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; }

valid_uid() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= GUEST_UID_MIN && 10#$1 <= GUEST_UID_MAX))
}

valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}

valid_pubkey() {
    [[ "$1" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,2}$ ]]
}

# Folders a guest may never be given: the system itself, the rooms, and
# anything holding keys or config.
folder_path_ok() {
    local p="$1" bad
    [[ "$p" =~ ^(/[A-Za-z0-9._@+-]+)+$ ]] || return 1
    [[ "/$p/" != *"/../"* && "/$p/" != *"/./"* ]] || return 1
    for bad in /proc /sys /dev /run /etc /usr /bin /sbin /lib /lib32 /lib64 /libx32 \
               /boot /var /tmp /srv/guests "$ROOMS_DIR"; do
        [[ "$p" == "$bad" || "$p" == "$bad"/* ]] && return 1
    done
    [[ "$p" != /srv && "$p" != /root ]] || return 1
    return 0
}

# MODE:PATH, MODE is ro or rw.
parse_spec() { # SPEC -> sets SPEC_MODE SPEC_PATH
    local spec="$1"
    SPEC_MODE="${spec%%:*}"
    SPEC_PATH="${spec#*:}"
    [[ "$SPEC_MODE" == ro || "$SPEC_MODE" == rw ]] || die "Folder '$spec': expected ro:PATH or rw:PATH"
    folder_path_ok "$SPEC_PATH" || die "Folder '$SPEC_PATH' can't be shared (system folders, /srv/guests and unusual characters are not allowed)"
}

# ── State ──────────────────────────────────────
#
# One file per guest, STATE_DIR/NAME:
#   uid 2001
#   from 10.66.69.1
#   folder rw /srv/files/photos

state_file() { printf '%s/%s\n' "$STATE_DIR" "$1"; }

state_names() {
    local f
    [[ -d "$STATE_DIR" ]] || return 0
    for f in "$STATE_DIR"/*; do
        [[ -f "$f" ]] || continue
        valid_name "${f##*/}" && printf '%s\n' "${f##*/}"
    done
    return 0
}

state_get() { # NAME KEY
    awk -v k="$2" '$1 == k {print $2; exit}' "$(state_file "$1")"
}

state_folders() { # NAME -> "MODE PATH" lines
    awk '$1 == "folder" && ($2 == "ro" || $2 == "rw") {print $2" "$3}' "$(state_file "$1")"
}

# ── Users ──────────────────────────────────────

ensure_group() {
    getent group "$GUEST_GROUP" >/dev/null && return 0
    if getent group "$GUEST_GID_PREFERRED" >/dev/null; then
        groupadd "$GUEST_GROUP"
    else
        groupadd -g "$GUEST_GID_PREFERRED" "$GUEST_GROUP"
    fi
}

lowest_free_uid() {
    local u
    for ((u = GUEST_UID_MIN; u <= GUEST_UID_MAX; u++)); do
        getent passwd "$u" >/dev/null || { printf '%s\n' "$u"; return 0; }
    done
    die "No free guest UID left ($GUEST_UID_MIN-$GUEST_UID_MAX)"
}

# ensure_user NAME [UID] -> prints the UID in use.
ensure_user() {
    local name="$1" want="${2:-}" entry uid gid group_gid
    group_gid="$(getent group "$GUEST_GROUP" | cut -d: -f3)"
    if entry="$(getent passwd "$name")"; then
        uid="$(cut -d: -f3 <<< "$entry")"
        gid="$(cut -d: -f4 <<< "$entry")"
        [[ "$gid" == "$group_gid" ]] \
            || die "A user named '$name' already exists on the phone and isn't a guest; pick another name"
        [[ -z "$want" || "$want" == "$uid" ]] \
            || die "Guest '$name' has UID $uid on the phone, but the VPS expects $want"
    else
        if [[ -n "$want" ]]; then
            ! getent passwd "$want" >/dev/null \
                || die "UID $want is already taken on the phone by $(getent passwd "$want" | cut -d: -f1)"
            uid="$want"
        else
            uid="$(lowest_free_uid)"
        fi
        useradd -u "$uid" -g "$GUEST_GROUP" -d / -M -s /usr/sbin/nologin \
            -c "ServerInator guest" "$name"
    fi
    # sshd here runs with UsePAM no, which refuses a locked account ("!").
    # "*" means: no password can ever match, but the account isn't locked.
    usermod -p '*' "$name"
    printf '%s\n' "$uid"
}

# ── Folders and mounts ─────────────────────────

is_mounted() { mountpoint -q "$1" 2>/dev/null; }

# Every mount point inside a room, deepest first.
room_mounts() { # ROOM
    awk -v root="$1" 'index($2, root "/") == 1 {print length($2) " " $2}' /proc/self/mounts \
        | sort -rn | cut -d' ' -f2-
}

unmount_room() { # ROOM
    local mp
    while IFS= read -r mp; do
        [[ -n "$mp" ]] || continue
        # Lazy: a guest who is mid-transfer keeps their open file, and the
        # folder is gone from the room right away.
        umount -l "$mp" || die "Could not unmount $mp"
    done < <(room_mounts "$1")
}

# Removes the empty mount-point folders of a room. Never rm -r: if a mount
# were still there, that would delete the shared files themselves.
clear_room() { # ROOM
    local d
    for d in "$1"/*; do
        [[ -d "$d" && ! -L "$d" ]] || continue
        is_mounted "$d" && die "$d is still mounted; not removing it"
        rmdir "$d" 2>/dev/null || warn "$d is not empty; left in place"
    done
    return 0
}

# Creates a shared folder that doesn't exist yet, or opens an existing one
# for writing by guests (top level only; files inside keep their modes).
prepare_source() { # MODE PATH
    local mode="$1" src="$2" real
    if [[ ! -e "$src" ]]; then
        mkdir -p "$src"
        chown "root:$GUEST_GROUP" "$src"
        chmod 2775 "$src"
        say "created $src"
        return 0
    fi
    [[ -d "$src" ]] || die "$src exists but isn't a folder"
    real="$(realpath -e "$src")"
    [[ "$real" == "$src" ]] || die "$src is (or goes through) a symlink to $real; give the real path instead"
    if [[ "$mode" == rw && "$(stat -c '%G' "$src")" != "$GUEST_GROUP" ]]; then
        chgrp "$GUEST_GROUP" "$src"
        chmod g+rwxs "$src"
        warn "$src now belongs to group $GUEST_GROUP so guests can write there; files already inside keep their own permissions"
    fi
}

mount_folder() { # ROOM MODE PATH
    local room="$1" mode="$2" src="$3" mp
    mp="$room/${src##*/}"
    [[ -d "$src" ]] || { warn "$src is missing; not mounted in $room"; return 0; }
    mkdir -p "$mp"
    is_mounted "$mp" || mount --bind "$src" "$mp"
    mount -o "remount,bind,$mode" "$mp"
}

make_room() { # NAME -> prints the room path
    local room="$ROOMS_DIR/$1"
    # ChrootDirectory: every component root-owned and not group/world-writable.
    mkdir -p "$ROOMS_DIR" "$room"
    chown root:root "$ROOMS_DIR" "$room"
    chmod 755 "$ROOMS_DIR" "$room"
    printf '%s\n' "$room"
}

mount_guest() { # NAME
    local room mode src
    room="$(make_room "$1")"
    while read -r mode src; do
        mount_folder "$room" "$mode" "$src"
    done < <(state_folders "$1")
}

# ── Commands ───────────────────────────────────

cmd_set() {
    local name="${1:-}" uid="" from="" spec key seen="" base
    [[ -n "$name" ]] || die "set: NAME required"
    valid_name "$name" || die "Invalid guest name '$name'"
    shift
    local -a specs=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uid)  uid="${2:-}"; shift 2 || die "--uid needs a value"
                    valid_uid "$uid" || die "Invalid UID '$uid'" ;;
            --from) from="${2:-}"; shift 2 || die "--from needs an IP"
                    valid_ipv4 "$from" || die "Invalid --from IP '$from'" ;;
            *)      specs+=("$1"); shift ;;
        esac
    done
    ((${#specs[@]} > 0)) || die "set: at least one folder required"
    for spec in "${specs[@]}"; do
        parse_spec "$spec"
        base="${SPEC_PATH##*/}"
        [[ " $seen " != *" $base "* ]] \
            || die "Two folders are both called '$base'; a guest sees folders by name, so names must differ"
        seen="$seen $base"
    done

    IFS= read -r key || true
    key="${key%$'\r'}"
    valid_pubkey "$key" || die "set: expected the route key (ssh-ed25519) on stdin"

    ensure_group
    uid="$(ensure_user "$name" "$uid")"

    for spec in "${specs[@]}"; do
        parse_spec "$spec"
        prepare_source "$SPEC_MODE" "$SPEC_PATH"
    done

    # State first, then mounts from it (mount-all at boot does the same).
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    local tmp
    tmp="$(mktemp "$STATE_DIR/.${name}.XXXXXX")"
    {
        printf 'uid %s\n' "$uid"
        [[ -z "$from" ]] || printf 'from %s\n' "$from"
        for spec in "${specs[@]}"; do
            parse_spec "$spec"
            printf 'folder %s %s\n' "$SPEC_MODE" "$SPEC_PATH"
        done
    } > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$(state_file "$name")"

    local room
    room="$(make_room "$name")"
    unmount_room "$room"
    clear_room "$room"
    mount_guest "$name"

    # The route key is accepted only for this user and, when known, only
    # from the VPS's tunnel address.
    mkdir -p "$KEYS_DIR"; chown root:root "$KEYS_DIR"; chmod 755 "$KEYS_DIR"
    tmp="$(mktemp "$KEYS_DIR/.${name}.XXXXXX")"
    printf 'restrict%s %s serverinator-route:%s\n' "${from:+,from=\"$from\"}" "$key" "$name" > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$KEYS_DIR/$name"

    say "uid=$uid"
}

cmd_remove() {
    local name="${1:-}" room
    valid_name "$name" || die "Invalid guest name '$name'"
    room="$ROOMS_DIR/$name"
    rm -f "$KEYS_DIR/$name"
    if [[ -d "$room" ]]; then
        unmount_room "$room"
        clear_room "$room"
        rmdir "$room" 2>/dev/null || warn "$room is not empty; left in place"
    fi
    if getent passwd "$name" >/dev/null; then
        local gid group_gid
        gid="$(getent passwd "$name" | cut -d: -f4)"
        group_gid="$(getent group "$GUEST_GROUP" | cut -d: -f3 || true)"
        if [[ "$gid" == "$group_gid" ]]; then
            pkill -KILL -u "$name" 2>/dev/null || true
            userdel "$name"
        else
            warn "User '$name' isn't a guest; not removing the account"
        fi
    fi
    rm -f "$(state_file "$name")"
    say "removed $name"
}

cmd_mount_all() {
    local name
    while IFS= read -r name; do
        mount_guest "$name" || warn "Could not mount the folders of $name"
    done < <(state_names)
}

cmd_list() {
    local name mode src size
    while IFS= read -r name; do
        printf '%s uid=%s\n' "$name" "$(state_get "$name" uid)"
        while read -r mode src; do
            size="$(du -sh "$src" 2>/dev/null | cut -f1 || true)"
            printf '  %s %s %s\n' "$mode" "$src" "${size:-missing}"
        done < <(state_folders "$name")
    done < <(state_names)
}

main() {
    local cmd="${1:-}"
    [[ $# -eq 0 ]] || shift
    case "$cmd" in
        version)   say "$SI_GUESTS_VERSION" ;;
        set)       [[ "$(id -u)" == 0 ]] || die "Run as root"; cmd_set "$@" ;;
        remove)    [[ "$(id -u)" == 0 ]] || die "Run as root"; cmd_remove "$@" ;;
        mount-all) [[ "$(id -u)" == 0 ]] || die "Run as root"; cmd_mount_all ;;
        names)     state_names ;;
        list)      cmd_list ;;
        *)         die "Usage: serverinator-guests set|remove|mount-all|names|list|version" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
