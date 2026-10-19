#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# ─────────────────────────────────────────────
# ServerInator Core — VPS-side setup script
#
# Usage:
#   bash core-vps.sh HANDOFF.json --vps-ip HOST [--alias NAME] [--client-keys existing|new]
#   bash core-vps.sh --verify [BACK-HANDOFF.json] [--device NAME]
#   bash core-vps.sh --add-client LABEL     # after install, the tunnel must be up
#   bash core-vps.sh --revoke-client LABEL
#   bash core-vps.sh --list-clients [--device NAME]
#   bash core-vps.sh --add-guest NAME --folder NAME|PATH[:ro|:rw] [--pubkey KEY|FILE]  # files only
#   bash core-vps.sh --add-guest NAME --shell [--pubkey KEY|FILE]                     # a shell user
#   bash core-vps.sh --revoke-guest NAME
#   bash core-vps.sh --list-guests [--device NAME]
#   bash core-vps.sh --sync-guests [--device NAME]          # after a phone reset
#   bash core-vps.sh --list-devices
#   bash core-vps.sh --remove-device NAME
#   bash core-vps.sh --set-domain DOMAIN [--acme-email EMAIL | --tls-cert FILE --tls-key FILE]
#   bash core-vps.sh --remove-domain       # back to the built-in self-signed certificate
#
# A full install also takes --domain DOMAIN [--acme-email EMAIL | --tls-cert FILE --tls-key FILE].
#
# --add-client/--revoke-client/--list-clients/--verify act on the only phone,
# or on the one named with --device when several share this VPS.
#   bash core-vps.sh --uninstall
# ─────────────────────────────────────────────

DEV="${SERVERINATOR_DEV:-0}"

WG_INTERFACE="wg-si"
WG_PORT="${SERVERINATOR_WG_PORT-51822}"
WSTUNNEL_PORT="${SERVERINATOR_WSTUNNEL_PORT-9443}"
VPS_WG_SUBNET="10.66.69"

# wstunnel --restrict-to: forward only to local WireGuard listener.
# Without it the server acts as an open proxy for anyone reaching the port.
WG_RESTRICT_TARGET="127.0.0.1:${WG_PORT}"

# ── Install locations ─────────────────────────
if [[ "$DEV" == "1" ]]; then
    DEV_ROOT="${SERVERINATOR_DEV_ROOT:-${TMPDIR:-/tmp}/serverinator-dev}"
    : "${SERVERINATOR_WG_DIR:=$DEV_ROOT/etc/wireguard}"
    : "${SERVERINATOR_SYSTEMD_DIR:=$DEV_ROOT/etc/systemd/system}"
    : "${SERVERINATOR_WSTUNNEL_BIN:=$DEV_ROOT/usr/local/bin/wstunnel}"
    : "${SERVERINATOR_BACK_HANDOFF_PATH:=$DEV_ROOT/back-handoff.json}"
    : "${SERVERINATOR_VPS_ADMIN_HOME:=$DEV_ROOT/root}"
    : "${SERVERINATOR_LETSENCRYPT_DIR:=$DEV_ROOT/etc/letsencrypt}"
    : "${SERVERINATOR_GUEST_HOME:=$DEV_ROOT/var/lib/serverinator-files}"
fi

WG_DIR="${SERVERINATOR_WG_DIR:-/etc/wireguard}"
WG_KEY_DIR="${SERVERINATOR_WG_KEY_DIR:-$WG_DIR/serverinator}"
WG_CONF="$WG_DIR/${WG_INTERFACE}.conf"
SYSTEMD_DIR="${SERVERINATOR_SYSTEMD_DIR:-/etc/systemd/system}"
WSTUNNEL_BIN="${SERVERINATOR_WSTUNNEL_BIN:-/usr/local/bin/wstunnel}"
# Optional extra copy of the back-handoff (DEV and tests set it). The real
# record is DEVICES_DIR/<device>.json.
BACK_HANDOFF_PATH="${SERVERINATOR_BACK_HANDOFF_PATH:-}"
IPTABLES_RULES_PATH="${SERVERINATOR_IPTABLES_RULES_PATH:-/etc/iptables/rules.v4}"
# Let's Encrypt (certbot) layout; tests point it elsewhere.
LETSENCRYPT_DIR="${SERVERINATOR_LETSENCRYPT_DIR:-/etc/letsencrypt}"
CERTBOT="${SERVERINATOR_CERTBOT:-certbot}"

# ── SSH state ─────────────────────────────────
SSH_KEY_DIR="${SERVERINATOR_SSH_KEY_DIR:-$WG_KEY_DIR/ssh}"
TLS_STATE="$WG_KEY_DIR/tls.json"
# One record per phone (its back-handoff): the source of truth for
# --add-client, --verify, --list-devices and the orchestrator.
DEVICES_DIR="${SERVERINATOR_DEVICES_DIR:-$WG_KEY_DIR/devices}"
SSH_ALIAS_DEFAULT="serverinated"
# Guest file access: records, and the VPS user guests' SFTP apps log in as.
GUESTS_DIR="${SERVERINATOR_GUESTS_DIR:-$WG_KEY_DIR/guests}"
GUEST_VPS_USER="${SERVERINATOR_GUEST_USER:-serverinator-files}"
GUEST_VPS_HOME="${SERVERINATOR_GUEST_HOME:-/var/lib/serverinator-files}"
SSH_ENABLED=0
SSH_USER="root"
SSH_PHONE_PORT=22
SSH_HOST_FINGERPRINT=""
SSH_HOST_PUBKEY=""
SSH_VPS_USER=""
SSH_VPS_TO_PHONE_PUBKEY=""
SSH_CLIENT_KEYS=()
SSH_CLIENT_KEY_IS_NEW=0

# ── Runtime state ─────────────────────────────
MODE="setup"
HANDOFF_FILE=""
BACK_HANDOFF_FILE=""
VPS_IP=""
SSH_ALIAS=""
CLIENT_KEYS_MODE=""
CLIENT_LABEL=""
CLIENT_GENERATE=0    # --generate-key: the VPS makes the client's key (handed out once)
CLIENT_EXPIRES=""    # --expires: YYYYMMDD after which the client key stops working
GUEST_NAME=""
GUEST_FOLDER=""      # --folder: a files guest's one folder
GUEST_SHELL=0        # --shell: a shell guest
GUEST_PUBKEY=""      # --pubkey: the guest's own key instead of a generated one
GUEST_RECORD=""
SELECTED_DEVICE=""   # --device / --remove-device
DEVICE_RECORD=""     # DEVICES_DIR/<device>.json once selected

# ── Domain and certificate (optional) ─────────
# Without a domain, wstunnel serves its built-in self-signed certificate and
# everything addresses the VPS by VPS_IP. With one, wstunnel serves a real
# certificate for it, phones connect to it by name (real SNI), and client
# configs jump through it, so moving to another VPS becomes a DNS change.
# The choice is VPS-wide and kept in TLS_STATE.
VPS_DOMAIN=""
WSTUNNEL_PATH_PREFIX=""  # secret upgrade path (ensure_wstunnel_path_prefix)
ACME_EMAIL=""
TLS_CERT_FILE=""     # your own certificate instead of Let's Encrypt
TLS_KEY_FILE=""
TLS_SOURCE=""        # letsencrypt|custom
REMOVE_DOMAIN=0

# ── Shared library ────────────────────────────
# Resolved once at the top level: inside a function, the phone's bash gave
# BASH_SOURCE without its directory (hardware run 2026-10-14).
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CORE_DIR/lib.sh"
# The functions, one file per feature.
# shellcheck source=vps/packages.sh
source "$CORE_DIR/vps/packages.sh"
# shellcheck source=vps/devices.sh
source "$CORE_DIR/vps/devices.sh"
# shellcheck source=vps/wireguard.sh
source "$CORE_DIR/vps/wireguard.sh"
# shellcheck source=vps/wstunnel.sh
source "$CORE_DIR/vps/wstunnel.sh"
# shellcheck source=vps/tls.sh
source "$CORE_DIR/vps/tls.sh"
# shellcheck source=vps/ssh-keys.sh
source "$CORE_DIR/vps/ssh-keys.sh"
# shellcheck source=vps/client-setup.sh
source "$CORE_DIR/vps/client-setup.sh"
# shellcheck source=vps/clients.sh
source "$CORE_DIR/vps/clients.sh"
# shellcheck source=vps/guests.sh
source "$CORE_DIR/vps/guests.sh"
# shellcheck source=vps/verify.sh
source "$CORE_DIR/vps/verify.sh"
# shellcheck source=vps/uninstall.sh
source "$CORE_DIR/vps/uninstall.sh"

# Validate immediately on load — WG_PORT/WSTUNNEL_PORT can come from env vars
# set by the caller, and must never reach a generated config or firewall rule
# unvalidated.
validate_tunnel_port "$WG_PORT"
validate_tunnel_port "$WSTUNNEL_PORT"
[[ "$WG_PORT" != "$WSTUNNEL_PORT" ]] || die "WG_PORT and WSTUNNEL_PORT must differ"

# ─────────────────────────────────────────────
# Arguments
# ─────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)  print_usage "$CORE_DIR/core-vps.sh"; exit 0 ;;
            --version)  echo "ServerInator $SERVERINATOR_VERSION"; exit 0 ;;
            --uninstall) MODE="uninstall"; shift ;;
            --yes)       ASSUME_YES=1; shift ;;
            --verify)
                MODE="verify"; shift
                # Optional file; without it the device record is used.
                if [[ $# -gt 0 && "$1" != -* ]]; then BACK_HANDOFF_FILE="$1"; shift; fi
                ;;
            --device)
                shift
                [[ $# -gt 0 ]] || die "--device requires a NAME"
                SELECTED_DEVICE="$1"; shift
                validate_device_name "$SELECTED_DEVICE"
                ;;
            --list-devices) MODE="list-devices"; shift ;;
            --remove-device)
                MODE="remove-device"; shift
                [[ $# -gt 0 ]] || die "--remove-device requires a NAME"
                SELECTED_DEVICE="$1"; shift
                validate_device_name "$SELECTED_DEVICE"
                ;;
            --add-client)
                MODE="add-client"; shift
                [[ $# -gt 0 ]] || die "--add-client requires a LABEL"
                CLIENT_LABEL="$1"; shift
                validate_client_label "$CLIENT_LABEL"
                ;;
            --revoke-client)
                MODE="revoke-client"; shift
                [[ $# -gt 0 ]] || die "--revoke-client requires a LABEL"
                CLIENT_LABEL="$1"; shift
                validate_client_label "$CLIENT_LABEL"
                ;;
            --list-clients) MODE="list-clients"; shift ;;
            --client-script)
                MODE="client-script"; shift
                [[ $# -gt 0 ]] || die "--client-script requires a LABEL (or owner)"
                CLIENT_LABEL="$1"; shift
                validate_client_label "$CLIENT_LABEL"
                ;;
            --generate-key) CLIENT_GENERATE=1; shift ;;
            --expires)
                shift
                [[ $# -gt 0 ]] || die "--expires requires 30d (days from now) or a date like 2026-12-31"
                CLIENT_EXPIRES="$(parse_expiry "$1")" || exit 1
                shift
                ;;
            --add-guest|--revoke-guest)
                MODE="${1#--}"; shift
                [[ $# -gt 0 ]] || die "--$MODE requires a NAME"
                GUEST_NAME="$1"; shift
                validate_guest_name "$GUEST_NAME"
                ;;
            --list-guests) MODE="list-guests"; shift ;;
            --sync-guests) MODE="sync-guests"; shift ;;
            --folder)
                shift
                [[ $# -gt 0 ]] || die "--folder requires NAME or PATH (optionally :ro or :rw)"
                [[ -z "$GUEST_FOLDER" ]] || die "A guest gets one folder; give --folder once"
                GUEST_FOLDER="$1"; shift
                ;;
            --shell) GUEST_SHELL=1; shift ;;
            --pubkey)
                shift
                [[ $# -gt 0 ]] || die "--pubkey requires a key or a .pub file"
                if [[ -f "$1" ]]; then GUEST_PUBKEY="$(awk 'NF {print $1" "$2; exit}' "$1")"
                else GUEST_PUBKEY="$(awk '{print $1" "$2}' <<< "$1")"; fi
                shift
                [[ "$GUEST_PUBKEY" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+={0,2}$ ]] \
                    || die "--pubkey: expected an ssh-ed25519 public key (or a file holding one)"
                ;;
            --domain|--set-domain)
                [[ "$1" == --set-domain ]] && MODE="set-domain"
                shift
                [[ $# -gt 0 ]] || die "--domain requires a DOMAIN"
                VPS_DOMAIN="${1,,}"; shift
                validate_domain "$VPS_DOMAIN"
                ;;
            --remove-domain) MODE="set-domain"; REMOVE_DOMAIN=1; shift ;;
            --acme-email)
                shift
                [[ $# -gt 0 ]] || die "--acme-email requires an address"
                ACME_EMAIL="$1"; shift
                validate_email "$ACME_EMAIL"
                ;;
            --tls-cert|--tls-key)
                local which="$1"; shift
                [[ $# -gt 0 ]] || die "$which requires a FILE"
                [[ "$1" =~ ^/[A-Za-z0-9_./@+-]+$ && "$1" != *..* ]] || die "$which: use an absolute path without unusual characters"
                if [[ "$which" == --tls-cert ]]; then TLS_CERT_FILE="$1"; else TLS_KEY_FILE="$1"; fi
                shift
                ;;
            --vps-ip)
                shift
                [[ $# -gt 0 ]] || die "--vps-ip requires a value"
                VPS_IP="$1"; shift
                ;;
            --alias)
                shift
                [[ $# -gt 0 ]] || die "--alias requires a value"
                SSH_ALIAS="$1"; shift
                validate_ssh_alias "$SSH_ALIAS"
                ;;
            --client-keys)
                shift
                [[ $# -gt 0 ]] || die "--client-keys requires existing|new"
                CLIENT_KEYS_MODE="$1"; shift
                [[ "$CLIENT_KEYS_MODE" == "existing" || "$CLIENT_KEYS_MODE" == "new" ]] \
                    || die "--client-keys: expected existing or new"
                ;;
            -*) die "Unknown argument: $1" ;;
            *)  HANDOFF_FILE="$1"; shift ;;
        esac
    done

    [[ -z "$TLS_CERT_FILE$TLS_KEY_FILE" || ( -n "$TLS_CERT_FILE" && -n "$TLS_KEY_FILE" ) ]] \
        || die "--tls-cert and --tls-key go together"
    [[ -z "$TLS_CERT_FILE" || -n "$VPS_DOMAIN" ]] || die "--tls-cert needs --domain (the name the certificate is for)"
    [[ -z "$TLS_CERT_FILE" || -z "$ACME_EMAIL" ]] || die "--acme-email is for Let's Encrypt; it doesn't go with --tls-cert"

    case "$MODE" in
        setup)
            [[ -n "$HANDOFF_FILE" ]] \
                || die "No handoff.json given. Usage: $0 HANDOFF.json --vps-ip HOST"
            if [[ -z "$VPS_IP" ]]; then
                if [[ "$DEV" == "1" && -n "${SERVERINATOR_VPS_IP:-}" ]]; then
                    VPS_IP="$SERVERINATOR_VPS_IP"
                    dev "DEV: --vps-ip not passed, using SERVERINATOR_VPS_IP=$VPS_IP"
                else
                    die "--vps-ip HOST is required (this VPS's IP or hostname)"
                fi
            fi
            validate_host "$VPS_IP"
            [[ -n "$SSH_ALIAS" ]] || SSH_ALIAS="$SSH_ALIAS_DEFAULT"
            ;;
        verify|uninstall|list-clients|list-devices|remove-device|list-guests|sync-guests) ;;
        add-guest|revoke-guest) ;;
        set-domain)
            [[ "$REMOVE_DOMAIN" == 1 || -n "$VPS_DOMAIN" ]] || die "--set-domain requires a DOMAIN"
            ;;
        add-client|revoke-client)
            [[ -n "$CLIENT_LABEL" ]] || die "--add-client/--revoke-client requires a LABEL"
            [[ "$CLIENT_LABEL" != owner ]] \
                || die "'owner' is the phone's own key from the install; pick another label"
            ;;
        client-script) ;;
    esac
    # Only setup takes a file; elsewhere a stray word was silently taken as one.
    [[ -z "$HANDOFF_FILE" || "$MODE" == setup ]] || die "Unexpected argument: $HANDOFF_FILE"
    [[ "$CLIENT_GENERATE" == 0 || "$MODE" == add-client ]] || die "--generate-key goes with --add-client"
    [[ "$CLIENT_GENERATE" == 0 || -z "$GUEST_PUBKEY" ]] || die "--generate-key and --pubkey don't go together"
    [[ -z "$CLIENT_EXPIRES" || "$MODE" == add-client ]] || die "--expires goes with --add-client"
    [[ -z "$GUEST_FOLDER" && "$GUEST_SHELL" == 0 || "$MODE" == add-guest ]] \
        || die "--folder and --shell go with --add-guest"
    [[ -z "$GUEST_FOLDER" || "$GUEST_SHELL" == 0 ]] \
        || die "A guest is files only (--folder) or a shell user (--shell), not both"
    [[ -z "$GUEST_PUBKEY" || "$MODE" == add-guest || "$MODE" == add-client ]] \
        || die "--pubkey goes with --add-client or --add-guest"
}

# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

main() {
    parse_args "$@"
    [[ "$MODE" == uninstall ]] || migrate_legacy_state

    case "$MODE" in
        uninstall)      uninstall_vps;  return ;;
        list-devices)   list_devices;   return ;;
        remove-device)  remove_device;  return ;;
        verify)         verify;         return ;;
        add-client)     add_client;     return ;;
        revoke-client)  revoke_client;  return ;;
        list-clients)   list_clients;   return ;;
        client-script)  client_script;  return ;;
        set-domain)     set_domain;     return ;;
        add-guest)      add_guest;      return ;;
        revoke-guest)   revoke_guest;   return ;;
        list-guests)    list_guests;    return ;;
        sync-guests)    sync_guests;    return ;;
    esac

    # MODE=setup
    info "ServerInator Core — setting up the VPS"
    [[ "$DEV" == "1" ]] && dev "DEV mode (WG_DIR=$WG_DIR, SYSTEMD_DIR=$SYSTEMD_DIR)"

    ensure_jq

    step 1/6 "Reading handoff"
    read_handoff

    step 2/6 "Installing dependencies"
    install_deps
    install_wstunnel_vps

    step 3/6 "Setting up WireGuard"
    setup_wireguard

    step 4/6 "Setting up wstunnel"
    setup_tls
    setup_wstunnel_server
    fix_pmtu_clamp
    [[ "$DEV" == 1 ]] || check_firewall

    step 5/6 "SSH keys and client script"
    setup_vps_ssh_keys
    generate_client_setup

    step 6/6 "Generating back-handoff"
    generate_back_handoff
    # A reinstall can move the phone to another tunnel address.
    write_guest_routes

    info "VPS configured."
    if [[ -n "${OWNER_CLIENT_SETUP_PATH:-}" ]]; then
        echo ""
        echo "  To connect from any device:"
        echo "    $(fetch_hint owner)"
        echo "  From Windows (PowerShell, with tools/client-setup-windows.ps1; untested):"
        echo "    $(windows_hint owner)"
        echo ""
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
