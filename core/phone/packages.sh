# shellcheck shell=bash
# ServerInator Core, phone side: step 3, packages inside the chroot
# Sourced by core-phone.sh, which holds the settings and globals used here.

# ── Step 3: Install packages into chroot ──────

install_chroot_packages() {
    if [[ "$DEV" == "1" ]]; then
        dev "DEV mode: skipping package install"
        return
    fi

    local packages=(wireguard-tools iproute2 iputils-ping curl jq)
    if [[ "$ENABLE_SSH" == "1" ]]; then
        packages+=(openssh-server)
    fi

    local pkg status all_installed=1
    for pkg in "${packages[@]}"; do
        if status="$(chroot_run /usr/bin/dpkg-query -W -f='${Status}' "$pkg")"; then
            [[ "$status" == "install ok installed" ]] || all_installed=0
        else
            all_installed=0
        fi
    done
    if [[ "$all_installed" == 1 ]]; then
        chroot_run /usr/bin/dpkg --configure -a || die "dpkg configuration failed"
        return 0
    fi

    info "Installing packages into chroot (${packages[*]})..."
    chroot_run /usr/bin/apt-get update -qq \
        || die "APT update failed; check chroot time, repository configuration and signing keys"

    chroot_run /usr/bin/apt-get install -y "${packages[@]}" \
        || die "APT package installation failed; repository authentication remains required"

    chroot_run /usr/bin/dpkg --configure -a || die "dpkg --configure -a failed inside chroot"
    info "Packages installed"
}
