#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# ─────────────────────────────────────────────
# ServerInator Core — phone-side setup script
#
# serverinator.sh runs the setup; si runs the rest. As root on the phone:
#   bash core-phone.sh --status | --report | --preflight
#   bash core-phone.sh --start|--stop|--restart [wstunnel|wireguard|sshd]
#   bash core-phone.sh --export-identity FILE | --import-identity FILE
#   bash core-phone.sh --uninstall [--purge] [--yes]
# ─────────────────────────────────────────────

# ── Shared library ────────────────────────────
# Resolved once at the top level: inside a function, the phone's bash gave
# BASH_SOURCE without its directory (hardware run 2026-10-14).
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CORE_DIR/lib.sh"

DEV="${SERVERINATOR_DEV:-0}"
ARCH_OVERRIDE="${SERVERINATOR_ARCH_OVERRIDE:-}"
CHROOT="${SERVERINATOR_CHROOT:-$SI_CHROOT_DEFAULT}"

if [[ "$DEV" == "1" ]]; then
    MAGISK_SERVICE_D="${SERVERINATOR_SERVICE_D:?DEV mode requires SERVERINATOR_SERVICE_D to be set}"
else
    # Honor an explicit override so tests (and unusual setups) can redirect the
    # Magisk service directory without modifying the script.
    MAGISK_SERVICE_D="${SERVERINATOR_SERVICE_D:-/data/adb/service.d}"
fi

BACK_HANDOFF_FILE=""
DEVICE_NAME="${SERVERINATOR_DEVICE_NAME:-}"
MODE="setup"
PURGE=0
SERVICE_NAME=""   # --start/--stop/--restart: one service, or all of them

# /tmp inside the chroot: "tmpfs" (RAM, cleared on reboot) or "disk"
# (persistent storage, old files removed by a periodic cleaner). Empty means
# keep the previous choice, or pick by RAM on a first install.
CHROOT_TMP_MODE="${SERVERINATOR_CHROOT_TMP:-}"
CHROOT_TMP_SIZE="${SERVERINATOR_CHROOT_TMP_SIZE:-256M}"
CHROOT_TMP_MAX_AGE_DAYS=7

# Port arrangement (must stay consistent with the VPS script and the
# autostart/wg config generated below):
#   WG_LOCAL_PORT : local UDP port the phone's wstunnel client binds, and the
#                   port the phone's WireGuard client uses as its Endpoint.
#   WG_VPS_PORT   : the VPS WireGuard ListenPort, i.e. the wstunnel forwarding
#                   target (127.0.0.1:WG_VPS_PORT on the VPS).
#   WSTUNNEL_PORT : the VPS wstunnel server TLS port.
WG_LOCAL_PORT=51823
WG_VPS_PORT=51822
WSTUNNEL_PORT=9443

# SSH access (tunnel-only, root, public-key auth)
SSH_USER="root"
SSH_PORT=2222
ENABLE_SSH=1
SSH_HOST_FINGERPRINT=""
SSH_HOST_PUBKEY=""
SSHD_LISTEN_IP=""
STATE_DIR="${SERVERINATOR_STATE_DIR:-$SI_STATE_DIR_DEFAULT}"
if [[ "$DEV" == "1" ]]; then STATE_DIR="${SERVERINATOR_STATE_DIR:-${CHROOT%/}-state}"; fi
if [[ "${SERVERINATOR_NO_SSH:-0}" == "1" ]]; then
    ENABLE_SSH=0
fi
if [[ "$DEV" == "1" ]]; then
    SSH_HOSTKEY_DIR="${SERVERINATOR_SSH_HOSTKEY_DIR:-${CHROOT%/}-ssh-hostkeys}"
else
    SSH_HOSTKEY_DIR="${SERVERINATOR_SSH_HOSTKEY_DIR:-$SI_STATE_DIR_DEFAULT/ssh}"
fi

# Identity kept outside the chroot so a chroot rebuild, an uninstall without
# --purge, or a move to another phone (--export/--import-identity) keeps the
# WireGuard key the VPS knows. SSH host keys live in SSH_HOSTKEY_DIR.
IDENTITY_DIR="${SERVERINATOR_IDENTITY_DIR:-$STATE_DIR/identity}"
# serverinator.sh's key for logging into the VPS (same default as there).
ORCHESTRATOR_SSH_DIR="${SERVERINATOR_ORCHESTRATOR_SSH_DIR:-$SI_STATE_DIR_DEFAULT/orchestrator}"
IDENTITY_FILE=""
# Magisk modules: serverinator.sh's `si` command lives in one. DEV never
# touches the real folder.
if [[ "$DEV" == "1" ]]; then
    MAGISK_MODULES_DIR="${SERVERINATOR_MODULES_DIR:-}"
else
    MAGISK_MODULES_DIR="${SERVERINATOR_MODULES_DIR:-/data/adb/modules}"
fi

# The functions, one file per feature.
# shellcheck source=phone/checks.sh
source "$CORE_DIR/phone/checks.sh"
# shellcheck source=phone/chroot.sh
source "$CORE_DIR/phone/chroot.sh"
# shellcheck source=phone/packages.sh
source "$CORE_DIR/phone/packages.sh"
# shellcheck source=phone/tunnel.sh
source "$CORE_DIR/phone/tunnel.sh"
# shellcheck source=phone/sshd.sh
source "$CORE_DIR/phone/sshd.sh"
# shellcheck source=phone/guests.sh
source "$CORE_DIR/phone/guests.sh"
# shellcheck source=phone/login.sh
source "$CORE_DIR/phone/login.sh"
# shellcheck source=phone/handoff.sh
source "$CORE_DIR/phone/handoff.sh"
# shellcheck source=phone/status.sh
source "$CORE_DIR/phone/status.sh"
# shellcheck source=phone/service-control.sh
source "$CORE_DIR/phone/service-control.sh"
# shellcheck source=phone/identity.sh
source "$CORE_DIR/phone/identity.sh"
# shellcheck source=phone/uninstall.sh
source "$CORE_DIR/phone/uninstall.sh"

# ── Argument parsing ──────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)  print_usage "$CORE_DIR/core-phone.sh"; exit 0 ;;
            --version)  echo "ServerInator $SERVERINATOR_VERSION"; exit 0 ;;
            --device-name)
                shift
                [[ $# -gt 0 ]] || die "--device-name requires a value"
                DEVICE_NAME="$1"; shift
                ;;
            --apply-back-handoff|--back-handoff)
                MODE="apply-back-handoff"; shift
                [[ $# -gt 0 ]] || die "--back-handoff requires a file path"
                BACK_HANDOFF_FILE="$1"; shift
                ;;
            --uninstall) MODE="uninstall"; shift ;;
            --status)    MODE="status"; shift ;;
            --preflight) MODE="preflight"; shift ;;
            --report)    MODE="report"; shift ;;
            --start|--stop|--restart)
                MODE="${1#--}"; shift
                if [[ $# -gt 0 && "$1" != -* ]]; then SERVICE_NAME="$1"; shift; fi
                ;;
            --export-identity|--import-identity)
                [[ "$1" == --export-identity ]] && MODE="export-identity" || MODE="import-identity"
                shift
                [[ $# -gt 0 ]] || die "${MODE/-identity/} needs a FILE"
                IDENTITY_FILE="$1"; shift
                ;;
            --purge)     PURGE=1; shift ;;
            --yes)       ASSUME_YES=1; shift ;;
            --no-ssh)    ENABLE_SSH=0; shift ;;
            --chroot-tmp)
                shift
                [[ $# -gt 0 ]] || die "--chroot-tmp requires tmpfs or disk"
                CHROOT_TMP_MODE="$1"; shift
                ;;
            # Without this a stray word looped forever (review B6).
            *) die "Unknown argument: $1" ;;
        esac
    done
}

# ── Main ──────────────────────────────────────

main() {
    parse_args "$@"
    if [[ "$MODE" == uninstall ]]; then uninstall_phone; return; fi
    if [[ "$MODE" == status ]]; then phone_status; return; fi
    if [[ "$MODE" == preflight ]]; then phone_preflight; return; fi
    if [[ "$MODE" == report ]]; then phone_report; return; fi
    case "$MODE" in start|stop|restart) control_services "$MODE" "$SERVICE_NAME"; return ;; esac
    if [[ "$MODE" == export-identity ]]; then export_identity "$IDENTITY_FILE"; return; fi
    if [[ "$MODE" == import-identity ]]; then import_identity "$IDENTITY_FILE"; return; fi
    [[ "$PURGE" == 0 ]] || die "--purge requires --uninstall"

    if [[ "$MODE" == "apply-back-handoff" ]]; then
        info "ServerInator Core — applying back-handoff"
        if [[ "$DEV" == "1" ]]; then
            dev "Running in DEV mode"
        fi
        check_root
        apply_back_handoff
        return
    fi

    info "ServerInator Core — setting up the phone"
    [[ "$DEV" == "1" ]] && dev "DEV mode (chroot=$CHROOT, service.d=$MAGISK_SERVICE_D)"

    step 1/4 "Checking environment"
    check_root
    check_magisk
    check_disk_space
    ARCH="$(detect_arch)"
    [[ -n "$ARCH_OVERRIDE" ]] && dev "Architecture overridden: $ARCH"
    info "Architecture: $ARCH"

    step 2/4 "Loading rootfs"
    bootstrap_chroot
    resolve_chroot_tmp_mode
    write_mount_script
    write_tmpclean_autostart
    [[ "$DEV" == "0" ]] && setup_chroot_env

    step 3/4 "Installing packages and keys"
    install_chroot_packages
    install_wstunnel
    generate_wg_keys
    install_ssh_server
    install_guest_support
    # wstunnel autostart is written later (apply_back_handoff) — needs the VPS IP
    prepare_sshd_runtime "${SSHD_LISTEN_IP:-}"
    write_sshd_autostart
    write_login_summary
    write_chroot_si

    step 4/4 "Generating handoff"
    generate_handoff
    info "Phone side ready; the VPS side comes next (serverinator.sh does it)"
}

# Only run when executed directly; allows the functions to be sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
