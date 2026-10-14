#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# ServerInator — orchestrator
#
# Run as root (su) on the phone:
#   bash serverinator.sh
#   bash serverinator.sh --vps root@1.2.3.4 --device-name rn9p --alias rn9p [--chroot-tmp tmpfs|disk]
#   bash serverinator.sh --authorize-vps user@1.2.3.4   # only get SSH access set up
# ─────────────────────────────────────────────

DEV="${SERVERINATOR_DEV:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/core/lib.sh"
source "$SCRIPT_DIR/core/vps-auth.sh"

# Android's ssh resolves the default identity/known_hosts path via the passwd
# database's home directory, not $HOME — for root that is "/", which is
# read-only. Relying on default identity discovery (or ssh-copy-id) never
# works on a phone, so we keep our own identity under a writable, persistent
# path and pass it explicitly on every ssh/scp call.
ORCHESTRATOR_SSH_DIR="${SERVERINATOR_ORCHESTRATOR_SSH_DIR:-/data/adb/serverinator/orchestrator}"
SSH_OPTS=()

# ── Runtime state ─────────────────────────────
VPS_TARGET=""       # user@host (final)
VPS_HOST=""         # host only
VPS_USER=""         # user only
VPS_NEEDS_SUDO=0
DEVICE_NAME="${SERVERINATOR_DEVICE_NAME:-}"
SSH_ALIAS=""
CLIENT_KEYS_MODE="" # existing|new|""
CHROOT_TMP=""       # tmpfs|disk|"" (asked in ask_questions)
MODE="install"       # install|authorize
VPS_BIN_DIR="/root/.serverinator/bin"  # permanent script location on the VPS
VPS_STATE_DIR="/etc/wireguard/serverinator"  # core-vps.sh's WG_KEY_DIR

# Directory for temp files on the VPS (cleaned up on exit)
VPS_TMP_DIR=""
LOCAL_TMP=""
BACK_HANDOFF_LOCAL=""  # local copy of the VPS's back-handoff (set in step 3)

_cleanup() {
    if [[ -n "$LOCAL_TMP" ]]; then
        rm -rf "$LOCAL_TMP"
    fi
    if [[ -n "$AUTH_TMP" ]]; then
        rm -rf "$AUTH_TMP"
    fi
    if [[ -n "$VPS_TMP_DIR" && -n "$VPS_TARGET" ]]; then
        _vps_cmd "rm -rf '${VPS_TMP_DIR}'" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

# ─────────────────────────────────────────────
# SSH helpers
# ─────────────────────────────────────────────

# Prepares the orchestrator's identity file (generates it on first run) and
# fills SSH_OPTS — the shared flags for every ssh/scp call below.
ensure_ssh_identity() {
    local key="$ORCHESTRATOR_SSH_DIR/id_ed25519"
    mkdir -p "$ORCHESTRATOR_SSH_DIR"
    chmod 700 "$ORCHESTRATOR_SSH_DIR"
    if [[ ! -f "$key" ]]; then
        require_cmd ssh-keygen
        ssh-keygen -t ed25519 -N '' -C "serverinator-orchestrator-${DEVICE_NAME:-phone}" -f "$key" >/dev/null
        chmod 600 "$key"
        info "Generated orchestrator identity key: $key"
    fi
    SSH_OPTS=(
        -o BatchMode=yes
        -o "IdentityFile=$key"
        -o IdentitiesOnly=yes
        -o "UserKnownHostsFile=$ORCHESTRATOR_SSH_DIR/known_hosts"
    )
}

# Run a single command on the VPS.
_vps_cmd() {
    ssh "${SSH_OPTS[@]}" -o ConnectTimeout=30 "$VPS_TARGET" "$@"
}

# Run a script on the VPS (content read from stdin), with sudo if needed.
vps_run() {
    if [[ "$VPS_NEEDS_SUDO" == "1" ]]; then
        _vps_cmd "sudo bash -s" "$@"
    else
        _vps_cmd "bash -s" "$@"
    fi
}

# Copy a file TO the VPS.
vps_push() {
    local src="$1" dest="$2"
    scp -q "${SSH_OPTS[@]}" "$src" "${VPS_TARGET}:${dest}"
}

# Copy a file FROM the VPS.
vps_pull() {
    local src="$1" dest="$2"
    if [[ "$VPS_NEEDS_SUDO" == "1" ]]; then
        # The file may only be readable by root — read it via sudo cat
        _vps_cmd "sudo cat '${src}'" > "$dest"
    else
        scp -q "${SSH_OPTS[@]}" "${VPS_TARGET}:${src}" "$dest"
    fi
}

# ─────────────────────────────────────────────
# Arguments
# ─────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vps)
                shift; [[ $# -gt 0 ]] || die "--vps requires a value: user@host"
                VPS_TARGET="$1"; shift ;;
            --authorize-vps)
                shift; [[ $# -gt 0 ]] || die "--authorize-vps requires a value: user@host"
                MODE="authorize"; VPS_TARGET="$1"; shift ;;
            --device-name)
                shift; [[ $# -gt 0 ]] || die "--device-name requires a value"
                DEVICE_NAME="$1"; shift ;;
            --alias)
                shift; [[ $# -gt 0 ]] || die "--alias requires a value"
                SSH_ALIAS="$1"; shift ;;
            --client-keys)
                shift; [[ $# -gt 0 ]] || die "--client-keys requires existing|new"
                CLIENT_KEYS_MODE="$1"; shift
                [[ "$CLIENT_KEYS_MODE" == "existing" || "$CLIENT_KEYS_MODE" == "new" ]] \
                    || die "--client-keys: expected existing or new" ;;
            --chroot-tmp)
                shift; [[ $# -gt 0 ]] || die "--chroot-tmp requires tmpfs or disk"
                CHROOT_TMP="$1"; shift
                [[ "$CHROOT_TMP" == tmpfs || "$CHROOT_TMP" == disk ]] \
                    || die "--chroot-tmp: expected tmpfs or disk" ;;
            -*) die "Unknown argument: $1" ;;
            *)  die "Unknown argument: $1" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Questions for the user (all asked up front)
# ─────────────────────────────────────────────

ask_questions() {
    echo ""
    echo "══════════════════════════════════════════════"
    echo "  ServerInator — setup"
    echo "══════════════════════════════════════════════"
    echo ""

    if [[ -z "$VPS_TARGET" ]]; then
        read -r -p "  VPS address (user@host or host): " VPS_TARGET
        echo ""
    fi
    [[ -n "$VPS_TARGET" ]] || die "VPS address cannot be empty"

    split_vps_target

    if [[ -z "$DEVICE_NAME" ]]; then
        read -r -p "  Name for this device (e.g. rn9p): " DEVICE_NAME
        echo ""
    fi
    [[ -n "$DEVICE_NAME" ]] || die "Device name cannot be empty"
    validate_device_name "$DEVICE_NAME"

    if [[ -z "$SSH_ALIAS" ]]; then
        read -r -p "  SSH alias for connecting to the phone [${DEVICE_NAME}]: " SSH_ALIAS
        echo ""
        SSH_ALIAS="${SSH_ALIAS:-$DEVICE_NAME}"
    fi
    # SSH_ALIAS is spliced into a remote shell command string below
    # (step_vps_setup) — must be restricted to safe characters.
    validate_ssh_alias "$SSH_ALIAS"

    ask_chroot_tmp

    echo "  VPS:    $VPS_TARGET"
    echo "  Device: $DEVICE_NAME"
    echo "  Alias:  $SSH_ALIAS"
    echo "  /tmp:   $CHROOT_TMP"
    echo ""
}

# Splits VPS_TARGET into VPS_USER/VPS_HOST (user defaults to root).
split_vps_target() {
    if [[ "$VPS_TARGET" == *@* ]]; then
        VPS_USER="${VPS_TARGET%%@*}"
        VPS_HOST="${VPS_TARGET##*@}"
    else
        VPS_USER="root"
        VPS_HOST="$VPS_TARGET"
        VPS_TARGET="root@$VPS_HOST"
    fi
    [[ "$VPS_USER" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || die "Invalid VPS user name: '$VPS_USER'"
    validate_host "$VPS_HOST"
}

# Where the chroot's /tmp lives. The default is the previous choice, else
# tmpfs on phones with at least 3 GB of RAM and disk below that.
ask_chroot_tmp() {
    [[ -z "$CHROOT_TMP" ]] || return 0
    local saved="${SERVERINATOR_STATE_DIR:-/data/adb/serverinator}/chroot-tmp-mode" def ram
    ram="$(awk '$1=="MemTotal:" {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
    if [[ -f "$saved" ]]; then
        def="$(cat "$saved")"
    elif (( ${ram:-0} >= 3072 )); then
        def=tmpfs
    else
        def=disk
    fi
    [[ "$def" == tmpfs || "$def" == disk ]] || def=disk
    if [[ -t 0 ]]; then
        echo "  Chroot /tmp (phone RAM: ${ram:-?} MB):"
        echo "    tmpfs  in RAM (256 MB max), cleared on every reboot"
        echo "    disk   on storage, files unused for 7 days are cleaned"
        read -r -p "  Choose tmpfs or disk [${def}]: " CHROOT_TMP
        echo ""
    fi
    CHROOT_TMP="${CHROOT_TMP:-$def}"
    [[ "$CHROOT_TMP" == tmpfs || "$CHROOT_TMP" == disk ]] \
        || die "Chroot /tmp must be tmpfs or disk, got '$CHROOT_TMP'"
}

# ─────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────

check_root_phone() {
    [[ "$(id -u)" == "0" ]] \
        || die "Run as root: su -c 'bash serverinator.sh'"
}

check_prereqs() {
    ensure_ssh_identity
    info "Checking connection to the VPS..."

    # Our key first (one counted attempt). If the VPS rejects it, walk the
    # authorization routes in core/vps-auth.sh; they return once it works.
    if ! auth_try_own_key; then
        authorize_vps
    fi
    ok "SSH to the VPS"

    # sudo or root
    if [[ "$VPS_USER" != "root" ]] && ! _vps_cmd "sudo -n true" 2>/dev/null; then
        auth_init
        auth_offer_root || true   # may switch VPS_TARGET to root, or add sudoers
    fi
    if [[ "$VPS_USER" == "root" ]]; then
        VPS_NEEDS_SUDO=0
        info "VPS: logging in as root — sudo not needed"
    elif _vps_cmd "sudo -n true" 2>/dev/null; then
        VPS_NEEDS_SUDO=1
        ok "VPS: passwordless sudo"
    else
        die "VPS: user $VPS_USER does not have passwordless sudo.
  Add this to /etc/sudoers on the VPS:
    $VPS_USER ALL=(ALL) NOPASSWD: ALL"
    fi

    # jq on the VPS
    if ! _vps_cmd "command -v jq >/dev/null 2>&1"; then
        info "jq not found on the VPS — core-vps.sh will install it"
    fi
}

# ─────────────────────────────────────────────
# Steps
# ─────────────────────────────────────────────

step_phone_setup() {
    section 1/5 "Setting up the phone"
    bash "$SCRIPT_DIR/core/core-phone.sh" --device-name "$DEVICE_NAME" --chroot-tmp "$CHROOT_TMP"
}

step_vps_setup() {
    section 2/5 "Copying files to the VPS and running setup"

    # Temp directory on the VPS (holds core-vps.sh + lib.sh + handoff.json)
    VPS_TMP_DIR="$(_vps_cmd 'mktemp -d /tmp/serverinator.XXXXXX')"
    [[ -n "$VPS_TMP_DIR" ]] || die "Could not create a temp directory on the VPS"

    local handoff_path="${SERVERINATOR_CHROOT:-/data/serverinator-root}/etc/wireguard/handoff.json"
    [[ -f "$handoff_path" ]] || die "handoff.json not found: $handoff_path (did step 1 finish correctly?)"

    vps_push "$SCRIPT_DIR/core/lib.sh"      "$VPS_TMP_DIR/lib.sh"
    vps_push "$SCRIPT_DIR/core/core-vps.sh" "$VPS_TMP_DIR/core-vps.sh"
    vps_push "$handoff_path"                "$VPS_TMP_DIR/handoff.json"

    # Build core-vps.sh's arguments
    local vps_args="$VPS_TMP_DIR/handoff.json --vps-ip $VPS_HOST --alias $SSH_ALIAS"
    [[ -z "$CLIENT_KEYS_MODE" ]] || vps_args="$vps_args --client-keys $CLIENT_KEYS_MODE"

    # Run on the VPS. Its ssh session has no tty, so carry our colour choice
    # over explicitly (env, not sudo VAR=, which some sudoers refuse).
    local color=never
    [[ "$SI_COLOR_ON" == 1 ]] && color=always
    if [[ "$VPS_NEEDS_SUDO" == "1" ]]; then
        _vps_cmd "sudo env SERVERINATOR_COLOR=$color bash $VPS_TMP_DIR/core-vps.sh $vps_args"
    else
        _vps_cmd "env SERVERINATOR_COLOR=$color bash $VPS_TMP_DIR/core-vps.sh $vps_args"
    fi

    # Install the scripts in a permanent location on the VPS (for --verify and future runs)
    # /root/.serverinator/bin/ — alongside the rest of ServerInator's data
    local vps_bin="/root/.serverinator/bin"
    if [[ "$VPS_NEEDS_SUDO" == "1" ]]; then
        _vps_cmd "sudo mkdir -p '$vps_bin' && \
            sudo cp '$VPS_TMP_DIR/core-vps.sh' '$VPS_TMP_DIR/lib.sh' '$vps_bin/' && \
            sudo chmod 700 '$vps_bin' && \
            sudo chmod 600 '$vps_bin/core-vps.sh' '$vps_bin/lib.sh'"
    else
        _vps_cmd "mkdir -p '$vps_bin' && \
            cp '$VPS_TMP_DIR/core-vps.sh' '$VPS_TMP_DIR/lib.sh' '$vps_bin/' && \
            chmod 700 '$vps_bin' && chmod 600 '$vps_bin/core-vps.sh' '$vps_bin/lib.sh'"
    fi
    VPS_BIN_DIR="$vps_bin"
}

step_apply_back_handoff() {
    section 3/5 "Fetching back-handoff from the VPS"

    LOCAL_TMP="$(mktemp -d /tmp/si-orchestrator.XXXXXX)"
    local back_handoff_local="$LOCAL_TMP/back-handoff.json"
    BACK_HANDOFF_LOCAL="$back_handoff_local"

    vps_pull "$VPS_STATE_DIR/devices/${DEVICE_NAME}.json" "$back_handoff_local"
    [[ -s "$back_handoff_local" ]] || die "back-handoff.json is empty or missing"

    section 4/5 "Applying back-handoff on the phone"
    bash "$SCRIPT_DIR/core/core-phone.sh" --back-handoff "$back_handoff_local"
}

# The wstunnel port the VPS actually uses, from the fetched back-handoff.
# Read with sed rather than jq: the Android host usually has no jq, and the
# value is validated before use. Falls back to the configured default.
back_handoff_wstunnel_port() {
    local port=""
    if [[ -n "$BACK_HANDOFF_LOCAL" && -f "$BACK_HANDOFF_LOCAL" ]]; then
        port="$(sed -n 's/.*"wstunnel_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$BACK_HANDOFF_LOCAL" | head -1)"
    fi
    port="${port:-${SERVERINATOR_WSTUNNEL_PORT:-9443}}"
    validate_tunnel_port "$port"
    printf '%s\n' "$port"
}

step_wss_preflight() {
    section 5/5 "Checking the WSS connection, phone -> VPS"

    # Check that the TLS handshake to the wstunnel port completes.
    # If the provider drops data (like Contabo from Russian networks), the
    # connection will hang.
    # Expected: a certificate error ("SSL certificate problem: self signed")
    #           -> wstunnel responded -> the connection is alive.
    # Failure: a timeout -> the provider is blocking it -> this VPS doesn't work.
    local wstunnel_port
    wstunnel_port="$(back_handoff_wstunnel_port)" || return 1
    local curl_out
    if curl_out="$(curl -sv --max-time 15 \
            "https://${VPS_HOST}:${wstunnel_port}" 2>&1)"; then
        ok "WSS: TLS handshake completed (unexpected 200, but the connection is alive)"
    elif printf '%s\n' "$curl_out" | grep -qiE 'SSL certificate|self.signed|handshake'; then
        ok "WSS: TLS handshake completed (expected certificate error — all good)"
    elif printf '%s\n' "$curl_out" | grep -qiE 'timed out|Operation timed|CURLE_OPERATION'; then
        echo ""
        fail "WSS: the connection hung — the provider is blocking the tunnel"
        warn "This VPS ($VPS_HOST) is unreachable from your network."
        warn "Try a different VPS or network."
        warn "Configs have been written — after switching VPS, run:"
        warn "  bash serverinator.sh --vps NEW_VPS ..."
        echo ""
        return 1
    else
        warn "WSS: unexpected response — check manually after rebooting"
        [[ "$DEV" == "1" ]] && dev "curl output: $(printf '%s\n' "$curl_out" | head -5)"
    fi
}

# One-line command that downloads a root-only file from the VPS and runs
# it. A sudo user cannot scp from /etc/wireguard, so read it through sudo.
fetch_hint() { # REMOTE_PATH
    local name="${1##*/}"
    if [[ "$VPS_NEEDS_SUDO" == "1" ]]; then
        printf '%s' "ssh $VPS_TARGET 'sudo cat $1' > $name && bash $name"
    else
        printf '%s' "scp ${VPS_TARGET}:$1 . && bash $name"
    fi
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

main() {
    parse_args "$@"

    [[ "$DEV" == "1" ]] || check_root_phone

    if [[ "$MODE" == authorize ]]; then
        split_vps_target
        section 1/1 "Authorizing this phone on the VPS"
        check_prereqs
        echo ""
        ok "This phone can now run setup against $VPS_TARGET without a password."
        return 0
    fi

    ask_questions
    SECONDS=0   # time the install itself, not the questions
    check_prereqs

    step_phone_setup
    step_vps_setup
    step_apply_back_handoff
    step_wss_preflight || true   # don't stop just because the WSS test failed

    # ── Summary ──────────────────────────────────
    echo ""
    echo "${C_GREEN}══════════════════════════════════════════════${C_RESET}"
    echo "${C_GREEN}${C_BOLD}  Setup complete!${C_RESET} (took $(elapsed))"
    echo "${C_GREEN}══════════════════════════════════════════════${C_RESET}"
    echo ""
    echo "  Reboot the phone — services will come up automatically via Magisk."
    echo ""
    local sudo="" core="$VPS_BIN_DIR/core-vps.sh" ssh_dir="$VPS_STATE_DIR/ssh"
    [[ "$VPS_NEEDS_SUDO" == "1" ]] && sudo="sudo "
    echo "  After rebooting — check the tunnel:"
    echo "    ssh $VPS_TARGET '${sudo}bash $core --verify --device $DEVICE_NAME'"
    echo ""
    echo "  Add SSH access for this device (owner):"
    echo "    $(fetch_hint "$ssh_dir/client-setup-owner-${DEVICE_NAME}.sh")"
    echo ""
    echo "  Add access for another device/person (once the tunnel is up):"
    echo "    ssh $VPS_TARGET '${sudo}bash $core --add-client LABEL --device $DEVICE_NAME'"
    echo "    $(fetch_hint "$ssh_dir/client-setup-LABEL-${DEVICE_NAME}.sh")"
    echo ""
    echo "  See every phone on this VPS:"
    echo "    ssh $VPS_TARGET '${sudo}bash $core --list-devices'"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
