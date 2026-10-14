#!/usr/bin/env bash
# Remaining items from the 2026-10-14 review: interrupted rootfs installs (#8),
# pinned download checksums (#9), host-key pinning (#13), uninstall cleanup
# (#16), firewall warning (#17), configurable chroot DNS (#18) and Debian
# architecture names (#19).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "Test: downloads are checked against pinned SHA-256 hashes"
printf 'hello\n' > "$tmp/file"
hash="$(sha256sum "$tmp/file" | cut -d' ' -f1)"
run_verify() { # NAME PINNED
    PINNED="$2" bash -c 'source "$1"; pinned_sha256() { [[ "$1" == known.tar.gz ]] && echo "$PINNED"; }
        verify_download "$2" "$3"' _ "$REPO_ROOT/core/lib.sh" "$tmp/file" "$1" 2>&1
}
out="$(run_verify known.tar.gz "$hash")"; assert_eq 0 "$?" 'matching file accepted'
assert_contains "$out" 'Checksum OK: known.tar.gz' 'reports the check'
out="$(run_verify known.tar.gz "${hash//[0-9]/0}")"; assert_eq 1 "$?" 'mismatch refused'
assert_contains "$out" 'Checksum mismatch for known.tar.gz' 'explains the mismatch'
out="$(run_verify other.tar.gz "$hash")"; assert_eq 1 "$?" 'file without a pinned hash refused'
assert_contains "$out" 'No pinned checksum for other.tar.gz' 'explains the missing hash'

echo "Test: every file the scripts can download has a pinned hash"
for arch in aarch64 armv7 x86_64; do
    names="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/p" SERVERINATOR_SERVICE_D="$tmp/svc" bash -c 'source "$1"; ARCH="$2"
        echo "ubuntu-base-24.04.4-base-$(debian_arch).tar.gz wstunnel_${WSTUNNEL_VERSION}_linux_$(wstunnel_arch_suffix).tar.gz"' \
        _ "$PHONE_SCRIPT" "$arch" 2>/dev/null)"
    for n in $names; do
        bash -c 'source "$1"; pinned_sha256 "$2" >/dev/null' _ "$REPO_ROOT/core/lib.sh" "$n"
        assert_eq 0 "$?" "phone $arch: $n"
    done
done
for arch in x86_64 aarch64 armv7l; do
    n="$(SERVERINATOR_VPS_ARCH="$arch" bash -c 'source "$1"; echo "wstunnel_${WSTUNNEL_VERSION}_linux_$(wstunnel_vps_suffix).tar.gz"' _ "$VPS_SCRIPT" 2>/dev/null)"
    bash -c 'source "$1"; pinned_sha256 "$2" >/dev/null' _ "$REPO_ROOT/core/lib.sh" "$n"
    assert_eq 0 "$?" "VPS $arch: $n"
done

echo "Test: Debian architecture names (#19)"
for pair in aarch64:arm64 armv7:armhf x86_64:amd64; do
    got="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/p" SERVERINATOR_SERVICE_D="$tmp/svc" bash -c 'source "$1"; ARCH="$2"; debian_arch' _ "$PHONE_SCRIPT" "${pair%%:*}" 2>/dev/null)"
    assert_eq "${pair##*:}" "$got" "${pair%%:*} -> ${pair##*:}"
done

echo "Test: an interrupted rootfs install is redone, not skipped (#8)"
bootstrap() { # CHROOT -> prints what happened
    SERVERINATOR_DEV=0 SERVERINATOR_YES=1 SERVERINATOR_CHROOT="$1" SERVERINATOR_SERVICE_D="$tmp/svc" \
        bash -c 'source "$1"; set +e; ARCH=aarch64
            debootstrap_missing=1; command() { [[ "$2" == debootstrap ]] && return 1; builtin command "$@"; }
            curl() { echo DOWNLOAD; : > "${@: -1}"; }
            verify_download() { :; }
            extract_rootfs() { mkdir -p "$CHROOT/bin" "$CHROOT/usr/bin" "$CHROOT/etc"
                touch "$CHROOT/bin/sh" "$CHROOT/usr/bin/env" "$CHROOT/usr/bin/dpkg" "$CHROOT/etc/os-release"; }
            bootstrap_chroot' _ "$PHONE_SCRIPT" 2>&1
}
mkdir -p "$tmp/partial/bin"
out="$(bootstrap "$tmp/partial")"
assert_contains "$out" 'is incomplete' 'partial chroot detected'
assert_contains "$out" 'DOWNLOAD' 'rootfs installed again'
assert_file_exists "$tmp/partial/.serverinator-rootfs-complete" 'marker written after success'
out="$(bootstrap "$tmp/partial")"
assert_not_contains "$out" 'DOWNLOAD' 'complete chroot is skipped next time'
mkdir -p "$tmp/legacy/bin" "$tmp/legacy/usr/bin" "$tmp/legacy/etc"
touch "$tmp/legacy/bin/sh" "$tmp/legacy/usr/bin/env" "$tmp/legacy/usr/bin/dpkg" "$tmp/legacy/etc/os-release"
out="$(bootstrap "$tmp/legacy")"
assert_not_contains "$out" 'DOWNLOAD' 'chroot from before the marker is accepted'
assert_file_exists "$tmp/legacy/.serverinator-rootfs-complete" 'and marked'

echo "Test: phone host key is pinned end to end (#13)"
ssh-keygen -q -t ed25519 -N '' -C phone-host -f "$tmp/phone_host" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C vps-host -f "$tmp/vps_host" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C other -f "$tmp/other_host" >/dev/null
host_pub="$(cut -d' ' -f1,2 "$tmp/phone_host.pub")"
host_fp="$(ssh-keygen -lf "$tmp/phone_host.pub" | awk '{print $2}')"
devroot="$tmp/vps"; key_dir="$devroot/etc/wireguard/serverinator/ssh"
handoff() { # FILE PUBKEY FINGERPRINT
    cat > "$1" <<JSON
{"version":1,"device_name":"rn9p","wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","wstunnel_port":9443,"wg_port":51822,"ssh_enabled":1,"ssh_user":"root","ssh_port":2222,"ssh_host_fingerprint":"$3","ssh_host_pubkey":"$2"}
JSON
}
vps() {
    SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" SERVERINATOR_VPS_HOSTKEY_FILE="$tmp/vps_host.pub" \
        bash -c 'source "$1"; shift; main "$@"' _ "$VPS_SCRIPT" "$@"
}
handoff "$tmp/bad.json" "$(cut -d' ' -f1,2 "$tmp/other_host.pub")" "$host_fp"
vps "$tmp/bad.json" --vps-ip 203.0.113.9 > "$tmp/bad.log" 2>&1
assert_eq 1 "$?" 'host key that does not match the fingerprint refused'
assert_contains "$(cat "$tmp/bad.log")" "doesn't match ssh_host_fingerprint" 'explains the mismatch'
handoff "$tmp/opt.json" "ssh-ed25519 AAAA x\nssh-rsa AAAA" ""
vps "$tmp/opt.json" --vps-ip 203.0.113.9 > "$tmp/opt.log" 2>&1
assert_eq 1 "$?" 'host key with an embedded newline refused'
handoff "$tmp/good.json" "$host_pub" "$host_fp"
vps "$tmp/good.json" --vps-ip 203.0.113.9 > "$tmp/good.log" 2>&1
assert_eq 0 "$?" 'install with a pinned host key succeeds'
record="$devroot/etc/wireguard/serverinator/devices/rn9p.json"
assert_eq "$host_pub" "$(jq -r .ssh_host_pubkey "$record")" 'host key kept in the device record'

script="$key_dir/client-setup-owner-rn9p.sh"
assert_contains "$(cat "$script")" 'HostKeyAlias serverinated' 'client config gets a HostKeyAlias'
mkdir -p "$tmp/client"
HOME="$tmp/client" bash "$script" > "$tmp/client.log" 2>&1
assert_eq 0 "$?" 'client script runs'
kh="$(cat "$tmp/client/.ssh/known_hosts")"
assert_contains "$kh" "serverinated $host_pub" 'phone key pinned under the alias'
assert_contains "$kh" "203.0.113.9 $(cut -d' ' -f1,2 "$tmp/vps_host.pub")" 'VPS key pinned for the jump'
HOME="$tmp/client" bash "$script" > /dev/null 2>&1
assert_eq 2 "$(wc -l < "$tmp/client/.ssh/known_hosts")" 'running it again adds no duplicates'
assert_contains "$(cat "$tmp/client/.ssh/config")" 'HostKeyAlias serverinated' 'alias block has HostKeyAlias'

opts="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" bash -c 'source "$1"; opts=(); phone_hostkey_opts rn9p "$2"; echo "${opts[*]}"; cat "$(phone_known_hosts_file rn9p)"' _ "$VPS_SCRIPT" "$host_pub" 2>/dev/null)"
assert_contains "$opts" 'StrictHostKeyChecking=yes' 'VPS checks the phone strictly'
assert_contains "$opts" "serverinator-rn9p $host_pub" 'per-phone known_hosts holds the pinned key'
opts="$(SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" bash -c 'source "$1"; opts=(); phone_hostkey_opts old ""; echo "${opts[*]}"' _ "$VPS_SCRIPT" 2>/dev/null)"
assert_contains "$opts" 'StrictHostKeyChecking=accept-new' 'phone without a pinned key: trust on first use'
assert_contains "$opts" 'known_hosts_old' 'in its own file'

if command -v sshd >/dev/null && [[ -d /run/sshd ]]; then
    port=$((20000 + RANDOM % 20000))
    cat > "$tmp/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/phone_host
PidFile $tmp/sshd.pid
PasswordAuthentication no
EOF
    chmod 600 "$tmp/phone_host"
    "$(command -v sshd)" -f "$tmp/sshd_config" -E "$tmp/sshd.log"
    sleep 0.5
    real_ssh() { # PUBKEY
        SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" bash -c 'source "$1"; opts=()
            phone_hostkey_opts rn9p "$2"
            ssh -o BatchMode=yes -o ConnectTimeout=5 "${opts[@]}" -i /dev/null -p "$3" nobody@127.0.0.1 true' \
            _ "$VPS_SCRIPT" "$1" "$port" 2>&1
    }
    out="$(real_ssh "$host_pub")"
    assert_contains "$out" 'Permission denied' 'real sshd: pinned key accepted (stops at user auth)'
    out="$(real_ssh "$(cut -d' ' -f1,2 "$tmp/other_host.pub")")"
    assert_contains "$out" 'Host key verification failed' 'real sshd: a different host key is refused'
    kill "$(cat "$tmp/sshd.pid")" 2>/dev/null
else
    echo "  SKIP: sshd unavailable; real host-key check not run"
fi

echo "Test: VPS uninstall removes jump entries and nothing else (#16)"
admin="$tmp/admin"; mkdir -p "$admin/.ssh"
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/u" SERVERINATOR_VPS_ADMIN_HOME="$admin" \
    bash -c 'source "$1"; _authorize_vps_jump_key "ssh-ed25519 AAAAJUMP1 a" 10.66.69.2 2222
        _authorize_vps_jump_key "ssh-ed25519 AAAAJUMP2 b" 10.66.69.3 2222' _ "$VPS_SCRIPT" > /dev/null 2>&1
printf 'ssh-ed25519 AAAAMINE me@laptop\n' >> "$admin/.ssh/authorized_keys"
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/u" SERVERINATOR_VPS_ADMIN_HOME="$admin" bash "$VPS_SCRIPT" --uninstall > "$tmp/u.log" 2>&1
assert_eq 0 "$?" 'uninstall succeeds'
assert_eq 'ssh-ed25519 AAAAMINE me@laptop' "$(cat "$admin/.ssh/authorized_keys")" 'only the jump entries are gone'
assert_contains "$(cat "$tmp/u.log")" 'Removed ServerInator jump entries' 'reported'

echo "Test: firewall warning (#17)"
fw() { # SCENARIO
    SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/f" bash -c 'source "$1"; WSTUNNEL_PORT=9443; scenario="$2"
        have_cmd() { case "$1" in ufw) [[ $scenario == ufw* ]];; iptables) [[ $scenario == ipt* ]];; *) return 1;; esac; }
        ufw() { echo "Status: active"; echo; [[ $scenario == ufw-open ]] && echo "9443/tcp                   ALLOW       Anywhere"; echo "22/tcp ALLOW Anywhere"; }
        iptables() { echo "-P INPUT DROP"; [[ $scenario == ipt-open ]] && echo "-A INPUT -p tcp -m tcp --dport 9443 -j ACCEPT"; true; }
        check_firewall' _ "$VPS_SCRIPT" "$1" 2>&1
}
assert_contains "$(fw ufw-closed)" 'ufw allow 9443/tcp' 'active ufw without the port: warns with the command'
assert_eq '' "$(fw ufw-open)" 'ufw with the port open: silent'
assert_contains "$(fw ipt-closed)" 'iptables -I INPUT -p tcp --dport 9443' 'default-drop iptables: warns'
assert_eq '' "$(fw ipt-open)" 'iptables with an ACCEPT rule: silent'
assert_eq '' "$(fw none)" 'no firewall: silent'

echo "Test: chroot DNS servers can be changed (#18)"
dns() { SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/p" SERVERINATOR_SERVICE_D="$tmp/svc" bash -c 'source "$1"; chroot_resolv_conf' _ "$PHONE_SCRIPT" 2>&1; }
assert_contains "$(dns)" $'nameserver 8.8.8.8\nnameserver 1.1.1.1' 'default servers unchanged'
assert_contains "$(SERVERINATOR_DNS='9.9.9.9 2620:fe::fe' dns)" $'nameserver 9.9.9.9\nnameserver 2620:fe::fe' 'custom IPv4 and IPv6 servers'
SERVERINATOR_DNS='9.9.9.9 evil;rm' dns > /dev/null; assert_eq 1 "$?" 'non-IP value refused'

exit "$TESTS_FAILED"
