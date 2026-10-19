#!/usr/bin/env bash
# The si command: what each subcommand runs on the phone, in the chroot and
# on the VPS, and how serverinator.sh installs it.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# A layout like STATE_DIR/bin: serverinator.sh next to core/, with the real si
# and lib.sh and fakes that print their arguments.
bin="$tmp/bin"
mkdir -p "$bin/core" "$tmp/stub"
cp "$REPO_ROOT/core/si" "$REPO_ROOT/core/lib.sh" "$bin/core/"
for f in core/core-vps.sh core/core-phone.sh serverinator.sh; do
    printf '#!/bin/bash\necho "%s $*"\n' "${f##*/}" > "$bin/$f"
done
# ssh prints its last argument, the remote command.
printf '#!/bin/bash\necho "ssh-target ${@: -2:1}"\necho "ssh-cmd ${@: -1}"\n' > "$tmp/stub/ssh"
# Tests run as a normal user; phone commands want root.
printf '#!/bin/bash\n[[ "$1" == -u ]] && { echo 0; exit; }\nexec /usr/bin/id "$@"\n' > "$tmp/stub/id"
chmod +x "$tmp/stub/"*

state="$tmp/state"
mkdir -p "$state/orchestrator" "$state/identity" "$state/logs"
touch "$state/orchestrator/id_ed25519"
export SERVERINATOR_STATE_DIR="$state" SERVERINATOR_COLOR=never
si() { PATH="$tmp/stub:$PATH" bash "$bin/core/si" "$@" 2>&1; }

# ── VPS ──
assert_eq "core-vps.sh --add-client bob" "$(si vps add-client bob)" 'vps: add-client maps to --add-client'
assert_eq "core-vps.sh --verify --device rn9p" "$(si vps verify --device rn9p)" 'vps: verify keeps --device'
assert_eq "core-vps.sh --list-devices" "$(si vps devices)" 'vps: devices maps to --list-devices'
assert_eq "core-vps.sh --add-guest ann --folder music:ro" "$(si vps add-guest ann --folder music:ro)" 'vps: guest options pass through'
assert_eq "core-vps.sh --uninstall" "$(si vps uninstall)" 'vps: uninstall'
assert_eq "core-vps.sh --set-domain a.example.com" "$(si vps --set-domain a.example.com)" 'vps: raw flags pass through'
rc=0; out="$(si vps launch)" || rc=$?
assert_eq 1 "$rc" 'vps: unknown command refused'
assert_contains "$out" 'si help' 'vps: refusal points at si help'
assert_contains "$(si vps help)" 'si add-client LABEL' 'vps: help lists add-client'

# ── Phone ──
rc=0; out="$(si phone add-client bob)" || rc=$?
assert_eq 1 "$rc" 'phone: VPS commands need a saved VPS'
assert_contains "$out" 'si setup --vps' 'phone: says how to save the VPS'
echo 'root@1.2.3.4' > "$state/vps-target"
echo 'rn9p' > "$state/identity/device-name"
out="$(si phone add-client bob)"
assert_contains "$out" 'ssh-target root@1.2.3.4' 'phone: forwards to the saved VPS'
assert_contains "$out" 'ssh-cmd /usr/local/bin/si add-client bob --device rn9p' 'phone: adds this phone as --device'
assert_contains "$(si phone add-client bob --device other)" 'si add-client bob --device other' 'phone: an explicit --device wins'
assert_contains "$(si phone devices)" 'ssh-cmd /usr/local/bin/si devices' 'phone: devices gets no --device'
assert_contains "$(si phone add-guest 'a b')" "si add-guest a\\ b --device rn9p" 'phone: arguments are quoted for the remote shell'
assert_contains "$(si phone vps --list-clients)" 'ssh-cmd /usr/local/bin/si --list-clients' 'phone: si vps forwards anything'
assert_eq "core-phone.sh --status" "$(si phone status)" 'phone: status'
assert_eq "core-phone.sh --restart" "$(si phone restart)" 'phone: restart'
assert_eq "core-phone.sh --stop wstunnel" "$(si phone stop wstunnel)" 'phone: stop one service'
rc=0; si phone start a b > /dev/null || rc=$?
assert_eq 1 "$rc" 'phone: start takes one name at most'
assert_eq "core-phone.sh --uninstall --purge" "$(si phone uninstall --purge)" 'phone: uninstall passes --purge'
assert_eq "core-phone.sh --export-identity /sdcard/x.tar" "$(si phone export-identity /sdcard/x.tar)" 'phone: export-identity'
assert_eq "serverinator.sh --vps root@1.2.3.4 --chroot-tmp disk" "$(si phone setup --chroot-tmp disk)" 'phone: setup uses the saved VPS'
assert_eq "serverinator.sh --vps root@5.6.7.8" "$(si phone setup --vps root@5.6.7.8)" 'phone: setup --vps overrides it'
assert_eq "serverinator.sh --vps root@1.2.3.4 --set-domain d.example.com --acme-email a@b.c" \
    "$(si phone set-domain d.example.com --acme-email a@b.c)" 'phone: set-domain'
assert_eq "serverinator.sh --vps root@1.2.3.4 --remove-domain" "$(si phone remove-domain)" 'phone: remove-domain'
rc=0; out="$(si phone frobnicate)" || rc=$?
assert_eq 1 "$rc" 'phone: unknown command refused'

printf '\e[32mgreen\e[0m one\ntwo\n' > "$state/logs/wstunnel.log"
printf 'x\n' > "$state/logs/sshd.log"
printf 'f\n' > "$state/logs/addon-web.log"
out="$(si phone logs wstunnel -n 1)"
assert_contains "$out" 'wstunnel.log' 'logs: names the file'
assert_contains "$out" 'two' 'logs: last line shown'
assert_not_contains "$out" 'green' 'logs: -n limits the lines'
assert_not_contains "$out" 'sshd.log' 'logs: NAME picks one log'
assert_not_contains "$(si phone logs wstunnel -n 2)" $'\e[' 'logs: colour codes stripped'
assert_contains "$(si phone logs web)" 'addon-web.log' 'logs: NAME also matches a prefixed log'
assert_contains "$(si phone logs)" 'sshd.log' 'logs: no NAME shows all'
rc=0; si phone logs nothere > /dev/null || rc=$?
assert_eq 1 "$rc" 'logs: unknown name fails'

# ── Chroot ──
assert_contains "$(si chroot help)" 'si status' 'chroot: help lists status'
rc=0; out="$(si chroot add-client bob)" || rc=$?
assert_eq 1 "$rc" 'chroot: other commands refused'
assert_contains "$out" 'Android side' 'chroot: says where they run'

# ── serverinator.sh installs si ──
export SERVERINATOR_DEV=1 SERVERINATOR_MODULES_DIR="$tmp/modules"
src="$tmp/src"; mkdir -p "$src/core"
cp "$REPO_ROOT/serverinator.sh" "$src/"
cp "$REPO_ROOT"/core/*.sh "$REPO_ROOT/core/motd.bash" "$REPO_ROOT/core/si" "$src/core/"
cp -r "$REPO_ROOT/core/phone" "$REPO_ROOT/core/vps" "$REPO_ROOT/core/templates" "$src/core/"
istate="$tmp/istate"; mkdir -p "$istate/bin/extra"; touch "$istate/bin/extra/keep"
(
    export SERVERINATOR_STATE_DIR="$istate"
    source "$src/serverinator.sh"
    set +e
    install_si_phone > "$tmp/install.out" 2>&1
    echo "rc=$?" >> "$tmp/install.out"
    install_si_phone > /dev/null 2>&1   # again: nothing breaks
    VPS_TARGET="root@9.9.9.9"; save_vps_target
)
assert_contains "$(cat "$tmp/install.out")" 'rc=0' 'install: succeeds'
assert_file_exists "$istate/bin/serverinator.sh" 'install: serverinator.sh copied'
assert_file_exists "$istate/bin/core/si" 'install: si copied'
assert_file_exists "$istate/bin/core/core-vps.sh" 'install: core-vps.sh copied'
assert_file_exists "$istate/bin/core/vps/clients.sh" 'install: core/vps/ copied'
assert_file_exists "$istate/bin/core/phone/sshd.sh" 'install: core/phone/ copied'
assert_file_exists "$istate/bin/core/templates/magisk-sshd.sh" 'install: core/templates/ copied'
assert_file_exists "$istate/bin/extra/keep" 'install: whatever else is in bin stays'
launcher="$tmp/modules/serverinator/system/bin/si"
assert_file_exists "$launcher" 'install: launcher in the Magisk module'
assert_eq 755 "$(stat -c %a "$launcher")" 'install: launcher is executable'
sh -n "$launcher"; assert_eq 0 "$?" 'install: launcher is valid sh'
assert_contains "$(cat "$launcher")" "$istate/bin/core/si phone" 'install: launcher runs si for the phone'
assert_contains "$(cat "$tmp/modules/serverinator/module.prop")" 'id=serverinator' 'install: module.prop has the id'
assert_eq "" "$(ls "$tmp/modules/serverinator/system/bin" | grep -v '^si$')" 'install: nothing else in system/bin'
assert_contains "$(cat "$tmp/install.out")" 'after the next reboot' 'install: says when si appears'
assert_eq 'root@9.9.9.9' "$(cat "$istate/vps-target")" 'install: VPS saved for si'
# Running from the installed copy doesn't copy onto itself.
(
    export SERVERINATOR_STATE_DIR="$istate"
    source "$istate/bin/serverinator.sh"
    set +e
    install_si_phone > /dev/null 2>&1; echo "rc=$?" > "$tmp/self.out"
)
assert_eq 'rc=0' "$(cat "$tmp/self.out")" 'install: re-run from bin works'
assert_file_exists "$istate/bin/core/si" 'install: re-run from bin keeps the scripts'

# ── Uninstall removes si ──
unset SERVERINATOR_STATE_DIR
export SERVERINATOR_CHROOT="$tmp/phone/root" SERVERINATOR_SERVICE_D="$tmp/phone/service" \
    SERVERINATOR_STATE_DIR="$istate" SERVERINATOR_SSH_HOSTKEY_DIR="$tmp/phone/hostkeys"
mkdir -p "$SERVERINATOR_CHROOT" "$SERVERINATOR_SERVICE_D" "$tmp/modules/serverinator-extra" "$tmp/modules/other"
rc=0; bash "$PHONE_SCRIPT" --uninstall --yes > "$tmp/out" 2>&1 || rc=$?
assert_eq 0 "$rc" 'uninstall succeeds'
assert_file_missing "$tmp/modules/serverinator" 'uninstall removes the si module'
assert_file_missing "$tmp/modules/serverinator-extra" 'uninstall removes modules built on Core'
assert_eq 1 "$([[ -d "$tmp/modules/other" ]] && echo 1)" 'uninstall leaves other modules'
assert_file_missing "$istate/bin" 'uninstall removes the scripts'
assert_file_exists "$istate/vps-target" 'plain uninstall keeps the saved VPS'
rc=0; bash "$PHONE_SCRIPT" --uninstall --purge --yes > "$tmp/out" 2>&1 || rc=$?
assert_file_missing "$istate/vps-target" 'purge forgets the VPS'

# ── VPS uninstall removes its launcher, only if ours ──
export SERVERINATOR_DEV_ROOT="$tmp/vps" SERVERINATOR_SI_LAUNCHER="$tmp/vps/usr/local/bin/si"
mkdir -p "$tmp/vps/etc/wireguard/serverinator" "$tmp/vps/usr/local/bin"
printf '#!/bin/sh\necho someone else\n' > "$SERVERINATOR_SI_LAUNCHER"
bash "$VPS_SCRIPT" --uninstall --yes > /dev/null 2>&1
assert_file_exists "$SERVERINATOR_SI_LAUNCHER" 'VPS uninstall keeps a foreign si'
mkdir -p "$tmp/vps/etc/wireguard/serverinator"
printf '#!/bin/sh\n# ServerInator: the si command (managed). Needs root.\n' > "$SERVERINATOR_SI_LAUNCHER"
bash "$VPS_SCRIPT" --uninstall --yes > /dev/null 2>&1
assert_file_missing "$SERVERINATOR_SI_LAUNCHER" 'VPS uninstall removes our si'

exit "$TESTS_FAILED"
