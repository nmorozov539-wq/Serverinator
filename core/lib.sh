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
#
# Tags stay plain text ("[INFO]", "[ERROR]", ...) so logs remain greppable;
# colour only wraps them. Colour is on when stdout is a terminal, unless
# NO_COLOR is set or TERM=dumb. SERVERINATOR_COLOR=always|never overrides
# (the orchestrator passes "always" to the VPS, whose ssh session has no tty).

_si_color_init() {
    local mode="${SERVERINATOR_COLOR:-auto}" on=0
    case "$mode" in
        always) on=1 ;;
        never)  on=0 ;;
        *) [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]] && on=1 ;;
    esac
    if [[ "$on" == 1 ]]; then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m'
        C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
    else
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
    fi
    SI_COLOR_ON="$on"
}
_si_color_init

info()  { echo "${C_BLUE}[INFO]${C_RESET}  $*"; }
warn()  { echo "${C_YELLOW}[WARN]${C_RESET}  $*"; }
error() { echo "${C_RED}${C_BOLD}[ERROR]${C_RESET} $*" >&2; }
die()   { error "$*"; exit 1; }
dev()   { echo "${C_DIM}[DEV]   $*${C_RESET}"; }
ok()    { echo "${C_GREEN}[OK]${C_RESET}    $*"; }
fail()  { echo "${C_RED}[FAIL]${C_RESET}  $*" >&2; }

# section N/M TITLE — a top-level stage of the orchestrator. Sized for a
# phone terminal (38 columns).
section() {
    local rule="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "${C_CYAN}${rule}${C_RESET}"
    echo "${C_BOLD}${C_CYAN} [$1]${C_RESET}${C_BOLD} $2${C_RESET}"
    echo "${C_CYAN}${rule}${C_RESET}"
}

# step N/M TITLE — a step inside core-phone.sh / core-vps.sh.
step() {
    echo ""
    echo "${C_BOLD}── [$1] $2${C_RESET}"
}

# Elapsed time since the script started, e.g. "3m07s".
elapsed() {
    printf '%dm%02ds' $((SECONDS / 60)) $((SECONDS % 60))
}

# ── Utilities ──────────────────────────────────

have_cmd()    { command -v "$1" &>/dev/null; }

# For `read ... || no_answer QUESTION [HINT]`: the input ended (no terminal,
# or a pipe that ran out) before the answer. Without it, set -e quits silently.
no_answer() { die "No answer to \"$1\": the input ended. ${2:-Run it in a terminal.}"; }
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

    # Staged in BACKUP_DIR when there is one: Magisk runs every executable
    # file in service.d, so an interrupted run must not leave a runnable
    # copy next to the target (review 2026-10-18).
    desired="$(mktemp "${backup_dir}/.$(basename "$target").XXXXXX")" || die "Could not create a temp file for $target"
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

    mv "$desired" "$target" || { rm -f "$desired"; die "Could not replace $target"; }
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

# A DNS name for a certificate: a hostname with at least one dot, not an IP,
# lower-cased by the caller. Wildcards aren't accepted.
# An e-mail address for Let's Encrypt notices. Restricted to characters
# that are safe in a remote shell command line.
validate_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
        || die "Invalid e-mail address: '$1'"
}

validate_domain() {
    local d="$1"
    [[ -n "$d" && "$d" == *.* && ! "$d" =~ ^[0-9.]+$ && "$d" =~ ^[a-z0-9.-]+$ ]] \
        || die "Invalid domain: '${d}' (expected something like vps.example.com)"
    [[ "${d##*.}" =~ [a-z] ]] || die "Invalid domain: '${d}' (the last part must contain a letter)"
    validate_host "$d"
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

# Returns 0 if the string is a single-line public key with no
# authorized_keys options.
is_plain_pubkey() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || return 1
    [[ "$1" =~ ^(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[a-z0-9]+|sk-(ssh-ed25519|ecdsa-sha2-[a-z0-9]+)@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

# A client's authorized_keys line: a plain public key, or one that expires
# (expiry-time="YYYYMMDD", from --add-client --expires).
is_client_key_line() {
    is_plain_pubkey "$1" && return 0
    [[ "$1" =~ ^expiry-time=\"[0-9]{8}\"\ (.*)$ ]] && is_plain_pubkey "${BASH_REMATCH[1]}"
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

# ── Download checksums ─────────────────────────
#
# SHA-256 of every file the scripts download, copied from the publishers'
# own lists (Ubuntu's SHA256SUMS, wstunnel's checksums.txt). Bumping a
# version means adding its hashes here; an unknown file is refused.

pinned_sha256() {
    case "$1" in
        ubuntu-base-24.04.4-base-arm64.tar.gz) echo 04207713ece899c3740823d33690441ad3a7f0ded1101aca744e2b0f37ac7ff2 ;;
        ubuntu-base-24.04.4-base-armhf.tar.gz) echo 991520b47f6586f38a78505cf016e300b6191bb8ff86a0723481ec23a37ab7f4 ;;
        ubuntu-base-24.04.4-base-amd64.tar.gz) echo c1e67ef7b17a6300e136118bd1dc04725009cb376c1aad10abcf8cd453628d58 ;;
        wstunnel_11.0.0_linux_arm64.tar.gz)    echo b86abf73e340ed0c3ff9a77a5458aa27213784920ec65513132b36def45edc94 ;;
        wstunnel_11.0.0_linux_armv7.tar.gz)    echo 50e2855b527869b77402a902b58b83872ddd24271550df289b54729836c8abbc ;;
        wstunnel_11.0.0_linux_amd64.tar.gz)    echo 9708a99717b5a951453c2ff7c14c25d3418d02ca7fcb96fdb382a8f2083bab5e ;;
        *) return 1 ;;
    esac
}

sha256_of() {
    local out
    if have_cmd sha256sum; then out="$(sha256sum "$1")"
    elif have_cmd shasum; then out="$(shasum -a 256 "$1")"
    elif have_cmd openssl; then out="$(openssl dgst -sha256 -r "$1")"
    else die "No SHA-256 tool found (sha256sum, shasum or openssl)"
    fi
    printf '%s\n' "${out%%[ *]*}"
}

# verify_download FILE NAME — dies unless FILE has NAME's pinned hash.
verify_download() {
    local file="$1" name="$2" want got
    want="$(pinned_sha256 "$name")" || die "No pinned checksum for $name; refusing to install it"
    got="$(sha256_of "$file")"
    [[ "$got" == "$want" ]] \
        || die "Checksum mismatch for $name (expected $want, got ${got:-nothing}). The download is incomplete or not the published file."
    info "Checksum OK: $name"
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

# ── Magisk launchers (phone) ──────────────────

# write_magisk_launcher MODULES_DIR BACKUP_DIR ID COMMAND NAME DESCRIPTION "SCRIPT ARGS"
# A minimal Magisk module whose only file is system/bin/COMMAND, a launcher
# that runs SCRIPT with the first bash it finds. Magisk mounts it at boot.
write_magisk_launcher() {
    local modules="$1" backups="$2" id="$3" cmd="$4" name="$5" desc="$6" target="$7"
    local dir="$modules/$id"
    mkdir -p "$dir/system/bin"
    # Backups go elsewhere: a .bak in system/bin would be mounted too.
    reconcile_file "$dir/module.prop" 644 "$backups" << EOF
id=$id
name=$name
version=1
versionCode=1
author=ServerInator
description=$desc
EOF
    reconcile_file "$dir/system/bin/$cmd" 755 "$backups" << EOF
#!/system/bin/sh
# ServerInator: the $cmd command (managed).
[ "\$(id -u)" = 0 ] || { echo "$cmd: run it as root: su -c '$cmd \$*'" >&2; exit 1; }
for b in /system_ext/bin/bash /system/bin/bash /data/data/com.termux/files/usr/bin/bash; do
    [ -x "\$b" ] && exec "\$b" $target "\$@"
done
echo "$cmd: no bash found" >&2
exit 1
EOF
    local changed="$RECONCILED_CHANGED"
    rm -f "$dir/remove" "$dir/disable"
    # -f, not -x: on Android bash's access() check can say no to root.
    if [[ -f "/system/bin/$cmd" ]]; then
        [[ "$changed" == 0 ]] || info "The $cmd launcher changed; the new one is used after the next reboot"
    else
        info "The $cmd command appears after the next reboot. Until then: sh $dir/system/bin/$cmd help"
    fi
}
