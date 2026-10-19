# shellcheck shell=bash
# ServerInator Core, VPS side: apt packages and jq
# Sourced by core-vps.sh, which holds the settings and globals used here.

# ─────────────────────────────────────────────
# Step 2: Install dependencies
# ─────────────────────────────────────────────

# apt that waits for a fresh VPS's unattended-upgrades instead of failing,
# and never asks.
apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"
}

install_deps() {
    if [[ "$DEV" == "1" ]]; then dev "DEV: skipping apt install"; return 0; fi
    require_cmd apt-get
    info "Updating package lists..."
    apt_get update -qq
    info "Installing wireguard-tools, iproute2, iputils-ping, curl, openssh-client, jq..."
    apt_get install -y -qq wireguard-tools iproute2 iputils-ping curl openssh-client jq
}

# jq is needed from the first step on; the orchestrator promises that this
# script installs it (review B3).
ensure_jq() {
    have_cmd jq && return 0
    [[ "$DEV" != 1 ]] && have_cmd apt-get || die "Install jq: apt-get install jq"
    info "Installing jq..."
    apt_get update -qq && apt_get install -y -qq jq || die "Could not install jq (apt-get install jq)"
}
