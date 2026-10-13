#!/usr/bin/env bash
# ServerInator — shared library
# Include via: source "$(dirname "$0")/lib.sh"
# Do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "lib.sh: do not run directly — source it instead" >&2
    exit 1
fi

# Some su/terminal environments on Android (observed with Termux's `su`)
# start with a PATH that omits the Android system directories entirely —
# not just bash, but ssh/scp/curl/ip/wg too. Extend PATH defensively so
# every external command this project calls works regardless of which
# shell got us here. Harmless no-op on a normal Linux VPS.
for _si_dir in /system_ext/bin /system_ext/sbin /product/bin /system/bin /system/sbin /vendor/bin; do
    case ":$PATH:" in
        *":$_si_dir:"*) ;;
        *) PATH="$PATH:$_si_dir" ;;
    esac
done
export PATH
unset _si_dir

# ── Logging ────────────────────────────────────

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$*"; exit 1; }
dev()   { echo "[DEV]   $*"; }
ok()    { echo "[OK]    $*"; }
fail()  { echo "[FAIL]  $*" >&2; }

# ── Utilities ──────────────────────────────────

have_cmd()    { command -v "$1" &>/dev/null; }
require_cmd() { have_cmd "$1" || die "Command not found: $1"; }

# ── File management ────────────────────────────
#
# reconcile_file TARGET MODE [BACKUP_DIR]
#
# Reads the desired content from stdin, atomically replaces TARGET if the
# content differs. The backup goes to BACKUP_DIR (defaults to TARGET's own
# directory).
#
# If BACKUP_DIR differs from TARGET's directory and an old .bak sits next to
# TARGET, migrates it into BACKUP_DIR (protects against Magisk running the
# .bak itself).
#
# Sets RECONCILED_CHANGED=0 or 1 on completion.

reconcile_file() {
    local target="$1" mode="$2"
    local target_dir
    target_dir="$(dirname "$target")"
    local backup_dir="${3:-$target_dir}"
    local backup="$backup_dir/$(basename "$target").bak"
    local desired

    mkdir -p "$target_dir" "$backup_dir"

    # Migration: if backup_dir differs from target_dir and an old .bak sits
    # next to TARGET, move it (relevant for Magisk service.d).
    if [[ "$backup_dir" != "$target_dir" && -f "${target}.bak" ]]; then
        mv "${target}.bak" "$backup"
        chmod 600 "$backup"
    fi

    desired="$(mktemp "${target}.XXXXXX")" || die "Could not create a temp file for $target"
    cat > "$desired"
    chmod "$mode" "$desired"

    RECONCILED_CHANGED=0
    if [[ -f "$target" ]] && cmp -s "$desired" "$target"; then
        chmod "$mode" "$target"
        rm -f "$desired"
        return 0
    fi

    if [[ -e "$target" ]]; then
        cp -p "$target" "$backup" || die "Could not back up $target"
        chmod 600 "$backup"
        info "Updated $target (backup -> $backup)"
    else
        info "Created $target"
    fi

    mv "$desired" "$target"
    RECONCILED_CHANGED=1
}

# ── JSON ───────────────────────────────────────

# Runs jq: first looks in PATH, then inside the chroot (if CHROOT is set).
# The CHROOT variable and the chroot_run function are only used by
# core-phone.sh — the Android host may lack jq, or report
# access(X_OK)=false on Linux binaries. Delegating to chroot_run (rather
# than calling chroot directly) keeps the same code path as every other
# command run inside the chroot.
json_query() {
    if have_cmd jq; then
        jq "$@"
    elif [[ -n "${CHROOT:-}" && -f "$CHROOT/usr/bin/jq" ]]; then
        chroot_run /usr/bin/jq "$@"
    else
        die "jq not found — install jq"
    fi
}

# Reads a string field from a JSON file. Returns an empty string if the
# field is absent. Fails if the file isn't an object or the field isn't a
# string.
json_get() {
    json_query -r --arg field "$2" '
      if type != "object"            then error("expected an object")
      elif .[$field] == null         then ""
      elif (.[$field]|type) == "string" then .[$field]
      else error("field is not a string") end' < "$1"
}

# Reads a numeric (non-negative integer) field from a JSON file.
json_get_num() {
    json_query -r --arg field "$2" '
      if type != "object" then error("expected an object")
      elif .[$field] == null then ""
      elif (.[$field]|type) == "number"
           and (.[$field] == (.[$field]|floor))
           and .[$field] >= 0 then .[$field]
      else error("field is not a non-negative integer") end' < "$1"
}

# Escapes a string for embedding inside a JSON string (no outer quotes).
# Used when hand-assembling JSON via a heredoc.
json_escape() {
    local quoted
    quoted="$(jq -n --arg v "$1" '$v')" || die "json_escape: jq exited with an error"
    [[ "$quoted" == \"*\" ]] || die "json_escape: unexpected jq output format"
    printf '%s' "${quoted:1:${#quoted}-2}"
}

# ── Validation (all functions call die on failure) ─────────────────────────

validate_device_name() {
    [[ "$1" =~ ^[a-z0-9_-]{1,32}$ ]] \
        || die "Invalid device name '${1}': 1-32 characters, lowercase letters/digits/_/- only"
}

validate_client_label() {
    [[ "$1" =~ ^[a-z0-9_-]{1,32}$ ]] \
        || die "Invalid client label '${1}': 1-32 characters, lowercase letters/digits/_/- only"
}

validate_ssh_alias() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] \
        || die "Invalid SSH alias '${1}': 1-64 characters, letters/digits/._- only"
}

validate_wg_key() {
    # 32 bytes = 43 base64 characters + one padding-aligned character.
    # The last significant character has two zero bits, which limits the
    # allowed character set.
    [[ "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] \
        || die "Invalid WireGuard key format"
}

validate_ipv4() {
    local ip="$1" context="${2:-IPv4 address}" octets octet
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Invalid $context: '${ip}'"
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        { [[ "$octet" == 0 || "$octet" =~ ^[1-9][0-9]{0,2}$ ]] \
            && ((10#$octet <= 255)); } \
            || die "Invalid $context: '${ip}'"
    done
}

validate_host() {
    local host="$1"
    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        validate_ipv4 "$host" "VPS address"
        return
    fi
    [[ ${#host} -le 253 && "$host" != *..* && "$host" != .* && "$host" != *. ]] \
        || die "Invalid hostname: '${host}'"
    local label
    local -a labels
    IFS=. read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
            || die "Invalid label '${label}' in hostname '${host}'"
    done
}

validate_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)) \
        || die "Invalid port: '${1}' (expected 1-65535)"
}

validate_tunnel_port() {
    validate_port "$1"
    ((10#$1 >= 1024)) \
        || die "Tunnel port must be in range 1024-65535, got: '${1}'"
}

# Validates optional ports in a JSON file (wg_port, wstunnel_port, ssh_port fields).
validate_optional_ports() {
    local file="$1" field value
    for field in wg_port wstunnel_port ssh_port; do
        value="$(json_get_num "$file" "$field")" || die "Invalid type for field '$field'"
        [[ -z "$value" ]] || validate_port "$value"
    done
}

# ── SSH ────────────────────────────────────────

# Returns 0 if the string is a public key with no authorized_keys options.
is_plain_pubkey() {
    [[ "$1" =~ ^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9]+)@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

# Prints the public key's fingerprint (empty string on failure).
ssh_key_fingerprint() {
    local key="$1" tmp
    have_cmd ssh-keygen || return 0
    tmp="$(mktemp)" || return 0
    printf '%s\n' "$key" > "$tmp"
    ssh-keygen -lf "$tmp" 2>/dev/null | awk '{print $2" "$3}' || true
    rm -f "$tmp"
}

# ── Safe removal ───────────────────────────────
#
# Rejects paths with directory traversal, symlinks, and paths that are too
# short or too broad.

safe_remove_path() {
    local path="$1"
    [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ \
        && "$path" == /*/* \
        && "$path" != */../* \
        && "$path" != */./* \
        && "$path" != */ ]] \
        && [[ ! -L "$path" ]] \
        || die "Rejected unsafe path for removal: '$path'"
    case "$path" in
        /data/adb|/usr/local|/etc/wireguard|/etc/systemd|/home/*)
            die "Rejected overly broad path for removal: '$path'"
            ;;
    esac
}
