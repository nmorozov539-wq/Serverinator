#!/usr/bin/env bash
# Tests guest file access: the phone helper (core/guest-helper.sh), the
# phone's sshd rules, and the VPS commands (--add-guest for files-only and
# shell guests, --revoke-guest, --list-guests, --sync-guests) with the phone
# mocked.
#
# SERVERINATOR_TEST_REAL_GUESTS=1 (as root, with sshd) also runs the whole
# chain for real: two local sshds standing in for the VPS and the phone, real
# users and bind mounts, and sftp through the VPS's forced command. It
# creates and removes test users on this machine, so it is opt-in.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HELPER="$REPO_ROOT/core/guest-helper.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── Helper: validation ─────────────────────────
echo "Test: helper validation"
check() { # EXPECTED_RC LABEL CODE
    local rc=0
    (source "$HELPER"; eval "$3") >/dev/null 2>&1 || rc=$?
    assert_eq "$1" "$rc" "$2"
}
check 0 'plain guest name accepted'          'valid_name anna'
check 1 'name with capitals rejected'         'valid_name Anna'
check 1 'name starting with a digit rejected' 'valid_name 1anna'
check 1 'name with a space rejected'          'valid_name "an na"'
check 0 'shared folder under /srv/files ok'   'folder_path_ok /srv/files/photos'
check 0 'folder under /root ok'               'folder_path_ok /root/music'
check 0 'folder under /data ok'               'folder_path_ok /data/media'
for bad in / /etc /etc/ssh /proc/1 /usr/lib /srv /srv/guests/x /root /var/lib/x /tmp/x \
           /srv/files/../../etc /srv/./files 'relative/path' '/srv/files/a b' '/srv/files/a;b'; do
    check 1 "folder '$bad' refused" "folder_path_ok '$bad'"
done
check 0 'rw spec parsed'      'parse_spec rw:/srv/files/photos; [[ $SPEC_MODE == rw && $SPEC_PATH == /srv/files/photos ]]'
check 1 'unknown mode refused' 'parse_spec rx:/srv/files/photos'
check 0 'ed25519 route key accepted' 'valid_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBx1"'
check 1 'key with options refused'   'valid_pubkey "command=\"x\" ssh-ed25519 AAAA"'
check 1 'two folders for one guest refused' 'cmd_set anna rw:/srv/files/a rw:/srv/files/b < /dev/null'
check 1 'a shell guest with a folder refused' 'cmd_set anna --shell rw:/srv/files/a < /dev/null'
check 1 'a guest with neither refused'        'cmd_set anna < /dev/null'
check 1 'uid below the guest range refused' 'valid_uid 1000'
check 0 'uid in the guest range accepted'   'valid_uid 2001'

# ── Phone: helper and sshd rules installed ─────
echo "Test: core-phone.sh installs guest support"
(
    export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service" SERVERINATOR_STATE_DIR="$tmp/state"
    mkdir -p "$tmp/root/etc/ssh" "$tmp/service"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nPermitRootLogin yes\nSubsystem sftp /usr/lib/openssh/sftp-server\n' > "$tmp/root/etc/ssh/sshd_config"
    source "$PHONE_SCRIPT"
    ENABLE_SSH=1
    install_guest_support >/dev/null
    install_guest_support >/dev/null   # idempotent
    write_sshd_autostart >/dev/null
) || failtest "install_guest_support failed"
assert_eq "$(cat "$HELPER")" "$(cat "$tmp/root/usr/local/sbin/serverinator-guests")" 'helper installed in the chroot'
[[ -x "$tmp/root/usr/local/sbin/serverinator-guests" ]] && pass 'helper is executable' || failtest 'helper is executable'
conf="$(cat "$tmp/root/etc/ssh/serverinator-guests.conf")"
assert_contains "$conf" 'Match Group serverinator-guests' 'sshd rules match the guest group'
assert_contains "$conf" 'ForceCommand internal-sftp' 'guests get SFTP only'
assert_contains "$conf" 'ChrootDirectory /srv/guests/%u' 'guests are locked to their room'
assert_contains "$conf" 'DisableForwarding yes' 'guests get no forwarding'
assert_eq 'Include /etc/ssh/serverinator-guests.conf' "$(tail -n 1 "$tmp/root/etc/ssh/sshd_config")" 'guest rules included at the very end'
assert_eq 1 "$(grep -c 'serverinator-guests.conf' "$tmp/root/etc/ssh/sshd_config")" 'guest include appears once'
assert_eq 'Include /etc/ssh/sshd_config.d/*.conf' "$(head -n 1 "$tmp/root/etc/ssh/sshd_config")" 'managed drop-in still read first'
assert_contains "$(cat "$tmp/service/30-serverinator-sshd.sh")" 'serverinator-guests mount-all' 'boot remounts guest folders before sshd'
assert_not_contains "$conf" 'Subsystem' 'no second sftp subsystem when sshd_config has one'
(
    export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root2" SERVERINATOR_SERVICE_D="$tmp/service2" SERVERINATOR_STATE_DIR="$tmp/state2"
    mkdir -p "$tmp/root2/etc/ssh"
    printf 'PermitRootLogin yes\n' > "$tmp/root2/etc/ssh/sshd_config"
    source "$PHONE_SCRIPT"
    ENABLE_SSH=1
    install_guest_support >/dev/null
) || failtest "install_guest_support failed without a Subsystem line"
assert_contains "$(cat "$tmp/root2/etc/ssh/serverinator-guests.conf")" 'Subsystem sftp internal-sftp' 'sftp subsystem added when sshd_config has none (the VPS hop asks for it)'

echo "Test: a running sshd is reloaded when the guest rules change"
(
    export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service" SERVERINATOR_STATE_DIR="$tmp/state"
    source "$PHONE_SCRIPT"
    ENABLE_SSH=1
    reload_running_sshd() { echo reload >> "$tmp/reloads"; }
    install_guest_support >/dev/null
    echo 'X11Forwarding no' >> "$tmp/root/etc/ssh/sshd_config"
    install_guest_support >/dev/null
)
assert_eq 1 "$(cat "$tmp/reloads" 2>/dev/null | wc -l)" 'reload only when the config changed'
assert_eq 'Include /etc/ssh/serverinator-guests.conf' "$(tail -n 1 "$tmp/root/etc/ssh/sshd_config")" 'guest include moved back to the end'
# A stand-in sshd: records SIGHUP. Its root is /, so CHROOT=/ marks it ours.
bash -c 'trap "echo hup > \"$1\"; exit 0" HUP; while :; do sleep 0.1; done' _ "$tmp/hup" &
fake=$!
mkdir -p "$tmp/state3/run"; echo "$fake" > "$tmp/state3/run/sshd.pid"
sleep 0.3
( export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_STATE_DIR="$tmp/state3"
  source "$PHONE_SCRIPT"; chroot_run() { :; }; reload_running_sshd >/dev/null )
sleep 0.3
assert_file_missing "$tmp/hup" 'a process outside this chroot is not signalled'
out="$( export SERVERINATOR_DEV=0 SERVERINATOR_CHROOT=/ SERVERINATOR_STATE_DIR="$tmp/state3"
        source "$PHONE_SCRIPT"; chroot_run() { :; }; reload_running_sshd 2>&1 )"
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$tmp/hup" ]] && break; sleep 0.2; done
assert_file_exists "$tmp/hup" 'our sshd gets SIGHUP'
assert_contains "$out" 'sshd reloaded' 'says sshd was reloaded'
kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
if have_sshd="$(command -v sshd || ls /usr/sbin/sshd 2>/dev/null)" && [[ -n "$have_sshd" ]]; then
    # The real sshd must accept the rules, and they must not leak to root.
    ssh-keygen -q -t ed25519 -N '' -f "$tmp/hk"
    # As root, sshd -t also wants its privilege separation folder.
    [[ "$(id -u)" != 0 ]] || mkdir -p /run/sshd
    printf 'HostKey %s\nPermitRootLogin prohibit-password\n' "$tmp/hk" > "$tmp/sshd_main"
    cat "$tmp/root/etc/ssh/serverinator-guests.conf" > "$tmp/guests.conf"
    printf 'X11Forwarding yes\nInclude %s\n' "$tmp/guests.conf" >> "$tmp/sshd_main"
    rc=0; "$have_sshd" -t -f "$tmp/sshd_main" >/dev/null 2>&1 || rc=$?
    assert_eq 0 "$rc" 'sshd accepts the guest rules'
    # Lowercased: OpenSSH 10.6 prints the keywords in CamelCase.
    root_eff="$("$have_sshd" -T -f "$tmp/sshd_main" -C user=root,host=x,addr=10.66.69.1 2>/dev/null | tr "[:upper:]" "[:lower:]")"
    assert_contains "$root_eff" 'chrootdirectory none' 'root is not chrooted'
    assert_contains "$root_eff" 'x11forwarding yes' 'main settings before the include still apply to root'
fi

# ── VPS: commands with the phone mocked ────────
devroot="$tmp/vps"
key_dir="$devroot/etc/wireguard/serverinator/ssh"
gdir="$devroot/etc/wireguard/serverinator/guests"
ghome="$devroot/var/lib/serverinator-files"
calls="$tmp/phone-calls"
phone_hostkey="$(ssh-keygen -q -t ed25519 -N '' -f "$tmp/phk" && awk '{print $1" "$2}' "$tmp/phk.pub")"

cat > "$tmp/handoff.json" <<EOF
{
  "version": 1,
  "device_name": "rn9p",
  "wg_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  "wstunnel_port": 9443,
  "wg_port": 51822,
  "ssh_enabled": 1,
  "ssh_user": "root",
  "ssh_port": 2222,
  "ssh_host_pubkey": "$phone_hostkey"
}
EOF

# vps ARGS... — runs core-vps.sh in DEV with the phone mocked. The mock
# records each helper call (and what came on stdin) in $calls.
vps() {
    SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" SERVERINATOR_VPS_IP=203.0.113.9 \
    CALLS="$calls" PHONE_DOWN="${PHONE_DOWN:-0}" HELPER_VERSION="${HELPER_VERSION:-2}" \
        bash -c '
            source "$1"; shift
            _phone_run() {
                [[ "$PHONE_DOWN" == 1 ]] && return 255
                local input=""
                [[ "$2" == set ]] && input="$(cat)"
                printf "%s | %s\n" "$*" "$input" >> "$CALLS"
                case "$2" in
                    version) echo "$HELPER_VERSION" ;;
                    set)     echo "created /srv/files/x"; echo "uid=2001" ;;
                    names)   printf "anna\nstale\n" ;;
                    list)    printf "anna uid=2001\n  rw /srv/files/photos 1.2G\n" ;;
                    remove)  echo "removed $3" ;;
                esac
            }
            main "$@"
        ' _ "$VPS_SCRIPT" "$@"
}

rc=0
SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" SERVERINATOR_VPS_IP=203.0.113.9 \
    bash "$VPS_SCRIPT" "$tmp/handoff.json" --vps-ip 203.0.113.9 > "$tmp/setup.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'VPS setup succeeds'
assert_file_missing "$ghome" 'no guest user home until the first guest'

echo "Test: --folder normalization"
norm() { (source "$VPS_SCRIPT" >/dev/null 2>&1; normalize_folder_spec "$1") 2>/dev/null; }
assert_eq 'rw:/srv/files/photos' "$(norm photos)" 'bare name lives in /srv/files, read-write by default'
assert_eq 'ro:/srv/files/photos' "$(norm photos:ro)" ':ro marks read-only'
assert_eq 'rw:/root/music' "$(norm /root/music/:rw)" 'full path kept, trailing slash dropped'
assert_eq '' "$(norm '../etc')" 'parent reference refused'
assert_eq '' "$(norm 'a b')" 'space refused'

echo "Test: --add-guest needs a mode when there is no terminal"
rc=0; vps --add-guest anna < /dev/null > "$tmp/nofolder.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'add-guest without --folder or --shell fails off a terminal'
assert_contains "$(cat "$tmp/nofolder.log")" '--folder' 'says how to give the folder'
assert_contains "$(cat "$tmp/nofolder.log")" '--shell' 'says how to make a shell user'

echo "Test: files guest with a generated key"
: > "$calls"
rc=0; vps --add-guest anna --folder /root/music:ro < /dev/null > "$tmp/add.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'add-guest succeeds'
rec="$gdir/anna.json"
assert_file_exists "$rec" 'guest record written'
assert_eq rn9p "$(jq -r .device "$rec")" 'record names the phone'
assert_eq files "$(jq -r .mode "$rec")" 'record says files only'
assert_eq 2001 "$(jq -r .uid "$rec")" 'record keeps the UID the phone chose'
assert_eq 'ro:/root/music' "$(jq -r '[.folders[] | "\(.mode):\(.path)"] | join(" ")' "$rec")" 'record keeps the folder'
assert_file_exists "$key_dir/guest_anna" 'guest key generated for hand-over'
assert_file_exists "$ghome/routes/anna" 'route key generated'
route_pub="$(awk '{print $1" "$2}' "$ghome/routes/anna.pub")"
set_call="$(grep ' set anna ' "$calls")"
assert_contains "$set_call" '--from 10.66.69.1' 'phone accepts the route key only from the VPS tunnel address'
assert_contains "$set_call" 'ro:/root/music |' 'folder sent to the phone'
assert_contains "$set_call" "| $route_pub" 'route public key sent on stdin'
assert_not_contains "$set_call" '--uid' 'new guest lets the phone pick a UID'
ak="$(cat "$ghome/.ssh/authorized_keys")"
guest_pub="$(awk '{print $1" "$2}' "$key_dir/guest_anna.pub")"
assert_contains "$ak" "$guest_pub serverinator-guest:anna" 'guest key authorized on the VPS'
assert_contains "$ak" ',restrict ' 'guest key is restricted'
assert_contains "$ak" "anna@${TEST_PHONE_IP} -s sftp\"" 'guest key is routed to its phone user'
assert_contains "$ak" "-i $ghome/routes/anna " 'hop uses the guest route key'
assert_contains "$ak" 'StrictHostKeyChecking=yes' 'hop pins the phone host key'
assert_contains "$(cat "$ghome/routes/known_hosts_rn9p")" "serverinator-rn9p $phone_hostkey" 'pinned phone host key written'
assert_eq 1 "$(grep -c . <<< "$ak")" 'one line per guest'
out="$(cat "$tmp/add.log")"
assert_contains "$out" 'User     : serverinator-files' 'card shows the login name'
assert_contains "$out" 'Host     : 203.0.113.9' 'card shows the VPS host'
assert_contains "$out" "Key file : $key_dir/guest_anna" 'card shows the key file'
assert_contains "$out" 'music (/root/music, read-only)' 'card shows the folder with its mode'

echo "Test: a guest gets one folder, and one mode"
rc=0; vps --add-guest cleo --folder photos --folder docs > "$tmp/two.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'two folders refused'
assert_contains "$(cat "$tmp/two.log")" 'one folder' 'says a guest gets one folder'
rc=0; vps --add-guest cleo --folder photos --shell > "$tmp/both.log" 2>&1 || rc=$?
assert_eq 1 "$rc" '--folder with --shell refused'
assert_file_missing "$gdir/cleo.json" 'nothing written'

echo "Test: --add-guest refuses a duplicate"
rc=0; vps --add-guest anna --folder photos > "$tmp/dup.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'duplicate guest refused'
assert_contains "$(cat "$tmp/dup.log")" '--revoke-guest anna' 'points at revoke and add again'
rc=0; vps --guest-access anna --folder docs > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" '--guest-access is gone'

echo "Test: files guest with the guest's own key"
own="$(awk '{print $1" "$2}' "$tmp/phk.pub")"
rc=0; vps --add-guest ben --folder photos --pubkey "$own laptop" > "$tmp/ben.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'add-guest with --pubkey succeeds'
assert_file_missing "$key_dir/guest_ben" 'no key generated when the guest brings one'
assert_contains "$(cat "$ghome/.ssh/authorized_keys")" "$own serverinator-guest:ben" 'guest-supplied key authorized'
assert_eq 'rw:/srv/files/photos' "$(jq -r '[.folders[] | "\(.mode):\(.path)"] | join(" ")' "$gdir/ben.json")" 'bare name is read-write in /srv/files'
assert_eq 2 "$(grep -c . "$ghome/.ssh/authorized_keys")" 'two guests, two lines'
rc=0; vps --add-guest cleo --folder photos --pubkey 'ssh-rsa AAAAB3Nza' > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'non-ed25519 --pubkey refused'

echo "Test: shell guest with a generated key"
: > "$calls"
rc=0; vps --add-guest carl --shell < /dev/null > "$tmp/carl.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'add-guest --shell succeeds'
crec="$gdir/carl.json"
assert_eq shell "$(jq -r .mode "$crec")" 'record says shell'
assert_eq 0 "$(jq '.folders | length' "$crec")" 'a shell guest has no folder'
carl_pub="$(awk '{print $1" "$2}' "$key_dir/guest_carl.pub")"
set_call="$(grep ' set carl ' "$calls")"
assert_contains "$set_call" '--shell |' 'phone told to make a shell user'
assert_contains "$set_call" '--from 10.66.69.1' 'phone accepts the key only from the VPS tunnel address'
assert_contains "$set_call" "| $carl_pub" "the guest's own key goes to the phone"
assert_file_missing "$ghome/routes/carl" 'no route key for a shell guest'
line="$(grep 'serverinator-guest:carl' "$ghome/.ssh/authorized_keys")"
assert_contains "$line" "permitopen=\"${TEST_PHONE_IP}:2222\"" 'shell guest may forward to its phone sshd only'
assert_contains "$line" 'command="echo' 'shell guest gets no shell on the VPS'
assert_contains "$line" ',restrict,port-forwarding,' 'everything else is off'
setup="$key_dir/guest-setup-carl.sh"
assert_file_exists "$setup" 'setup script written'
out="$(client_setup_result "$setup")"
assert_contains "$out" 'User carl' 'setup logs in as the guest on the phone'
assert_contains "$out" 'User serverinator-files' 'setup jumps through the guest login user'
assert_contains "$out" "HostName ${TEST_PHONE_IP}" 'setup reaches the phone through the tunnel'
assert_contains "$out" 'Port 2222' "setup uses the phone's sshd port"
assert_contains "$(cat "$setup")" "SI_KEY_MODE='carried'" 'setup carries the generated key'
out="$(cat "$tmp/carl.log")"
assert_contains "$out" 'shell user on rn9p' 'card says what carl gets'
assert_contains "$out" "$setup" 'card names the setup script'
assert_contains "$out" 'private key' 'card says to hand it over privately'

echo "Test: shell guest with their own key"
dan_key="$(ssh-keygen -q -t ed25519 -N '' -f "$tmp/dan" && awk '{print $1" "$2}' "$tmp/dan.pub")"
rc=0; vps --add-guest dan --shell --pubkey "$tmp/dan.pub" > "$tmp/dan.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'add-guest --shell --pubkey succeeds'
assert_file_missing "$key_dir/guest_dan" 'no private key made or kept'
assert_contains "$(cat "$key_dir/guest-setup-dan.sh")" "SI_KEY_EXPECTED='$dan_key'" 'setup only works where the key is'
assert_contains "$(cat "$key_dir/guest-setup-dan.sh")" "SI_KEY_B64=''" 'setup carries no secret'

echo "Test: a shell guest needs an up-to-date phone"
rc=0; HELPER_VERSION=1 vps --add-guest erin --shell > "$tmp/old.log" 2>&1 || rc=$?
assert_eq 1 "$rc" 'old phone refuses a shell guest'
assert_contains "$(cat "$tmp/old.log")" 'Re-run serverinator.sh' 'says how to update the phone'
assert_file_missing "$gdir/erin.json" 'nothing written'

echo "Test: --list-guests"
rc=0; vps --list-guests > "$tmp/list.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'list-guests succeeds'
out="$(cat "$tmp/list.log")"
assert_contains "$out" 'anna' 'lists anna'
assert_contains "$out" 'music (/root/music, read-only)' 'lists the folder with its mode'
assert_contains "$out" 'shell user, home /home/carl' 'lists the shell guest'
assert_contains "$out" '1.2G' 'shows folder sizes from the phone'
rc=0; PHONE_DOWN=1 vps --list-guests > "$tmp/list-down.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'list-guests works with the phone down'
assert_contains "$(cat "$tmp/list-down.log")" "isn't reachable" 'says sizes were skipped'

echo "Test: --sync-guests recreates guests and drops unknown ones"
: > "$calls"
rm -f "$ghome/routes/ben" "$ghome/routes/ben.pub"
rc=0; vps --sync-guests > "$tmp/sync.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'sync-guests succeeds'
assert_contains "$(cat "$calls")" 'set anna --from 10.66.69.1 --uid 2001 ro:/root/music' 'anna pushed with her UID and folder'
assert_contains "$(cat "$calls")" 'set ben ' 'ben pushed'
assert_contains "$(cat "$calls")" "set carl --from 10.66.69.1 --uid 2001 --shell | $carl_pub" 'carl pushed as a shell user with his key'
assert_file_exists "$ghome/routes/ben" 'missing route key recreated'
assert_contains "$(cat "$calls")" 'remove stale' 'guest unknown to the VPS removed from the phone'
assert_not_contains "$(cat "$calls")" 'remove anna' 'known guests kept'

echo "Test: a guest record from before the one-folder rule"
jq '.folders += [{mode: "rw", path: "/srv/files/old"}] | del(.mode)' "$gdir/ben.json" > "$tmp/ben.json" && mv "$tmp/ben.json" "$gdir/ben.json"
: > "$calls"
rc=0; vps --sync-guests > "$tmp/sync-old.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'sync-guests reads the old record'
assert_contains "$(grep ' set ben ' "$calls")" 'rw:/srv/files/photos |' 'only the first folder is pushed'
assert_contains "$(cat "$tmp/sync-old.log")" 'only /srv/files/photos is kept' 'says which folder is kept'

echo "Test: --revoke-guest works even with the phone down"
rc=0; PHONE_DOWN=1 vps --revoke-guest ben > "$tmp/revoke.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'revoke-guest succeeds with the phone down'
assert_file_missing "$gdir/ben.json" 'record removed'
assert_file_missing "$ghome/routes/ben" 'route key removed'
assert_not_contains "$(cat "$ghome/.ssh/authorized_keys")" 'serverinator-guest:ben' 'ben can no longer log in'
assert_contains "$(cat "$ghome/.ssh/authorized_keys")" 'serverinator-guest:anna' 'anna still can'
assert_contains "$(cat "$tmp/revoke.log")" '--sync-guests' 'says how to tidy the phone later'
: > "$calls"
rc=0; vps --revoke-guest anna > /dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'revoke-guest with the phone up'
assert_contains "$(cat "$calls")" 'remove anna' 'phone account removed'
assert_file_missing "$key_dir/guest_anna" 'generated guest key removed'
rc=0; vps --revoke-guest carl > "$tmp/revoke-carl.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'revoke a shell guest'
assert_file_missing "$key_dir/guest-setup-carl.sh" 'its setup script removed'
assert_file_missing "$key_dir/guest_carl" 'its key removed'
assert_contains "$(cat "$tmp/revoke-carl.log")" 'home folder' 'says the home folder went too'
vps --revoke-guest dan > /dev/null 2>&1
assert_eq 0 "$(grep -c . "$ghome/.ssh/authorized_keys")" 'no guest lines left'

echo "Test: --remove-device takes its guests along"
vps --add-guest dora --folder photos > /dev/null 2>&1
vps --add-guest eve --shell > /dev/null 2>&1
rc=0; vps --remove-device rn9p > "$tmp/rmdev.log" 2>&1 || rc=$?
assert_eq 0 "$rc" 'remove-device succeeds'
assert_file_missing "$gdir/dora.json" 'guest record removed with the phone'
assert_file_missing "$key_dir/guest-setup-eve.sh" 'shell guest setup removed with the phone'
assert_eq 0 "$(grep -c . "$ghome/.ssh/authorized_keys")" 'guest routes removed with the phone'

echo "Test: argument checks"
rc=0; vps --list-clients --folder photos > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" '--folder without a guest command refused'
rc=0; vps --list-clients --shell > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" '--shell without a guest command refused'
rc=0; vps --add-guest 'Bad Name' --folder x > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'invalid guest name refused'

# Sharing a .ssh or .gnupg folder would hand a guest the owner's keys.
echo "Test: key folders can't be shared with guests"
for p in /root/.ssh /home/x/.ssh/keys /root/.gnupg /srv/files/.ssh; do
    rc=0; bash -c 'source "$1" >/dev/null 2>&1; folder_path_ok "$2"' _ "$REPO_ROOT/core/guest-helper.sh" "$p" || rc=$?
    assert_eq 1 "$rc" "$p refused"
done
rc=0; bash -c 'source "$1" >/dev/null 2>&1; folder_path_ok /srv/files/photos' _ "$REPO_ROOT/core/guest-helper.sh" || rc=$?
assert_eq 0 "$rc" 'a normal folder still works'

# Read-only shares keep their modes; a folder guests can't open gets a warning.
echo "Test: a read-only folder closed to guests is pointed out"
mkdir -p "$tmp/ro-closed" "$tmp/ro-open"; chmod 700 "$tmp/ro-closed"; chmod 755 "$tmp/ro-open"
out="$(bash -c 'source "$1" >/dev/null 2>&1; prepare_source ro "$2"' _ "$HELPER" "$tmp/ro-closed" 2>&1)"
assert_contains "$out" "Guests can't open $tmp/ro-closed (mode 700" 'mode 700 is pointed out'
assert_contains "$out" "chmod -R o+rX $tmp/ro-closed" 'with the fix'
out="$(bash -c 'source "$1" >/dev/null 2>&1; prepare_source ro "$2"' _ "$HELPER" "$tmp/ro-open" 2>&1)"
assert_eq "" "$out" 'an open folder is shared silently'

# ── Real chain (opt-in) ────────────────────────
if [[ "${SERVERINATOR_TEST_REAL_GUESTS:-0}" != 1 || "$(id -u)" != 0 ]] || ! [[ -x /usr/sbin/sshd ]]; then
    echo "SKIP: real guest chain (set SERVERINATOR_TEST_REAL_GUESTS=1, as root, with sshd)"
    exit "$TESTS_FAILED"
fi

echo "Test: real chain — SFTP app -> VPS sshd -> forced hop -> phone sshd -> room"
# ChrootDirectory needs every path component root-owned and not writable by
# others, which rules out /tmp; /run is a system folder the helper refuses to share.
base="$(mktemp -d -p /srv si-guests-test.XXXXXX)"; chmod 755 "$base"
vuser="sitestfiles$$"; guest="sitestg$$"; sguest="sitests$$"
cleanup_real() {
    for p in "$base"/*.pid; do [[ -f "$p" ]] && kill "$(cat "$p")" 2>/dev/null; done
    (export SI_GUESTS_STATE_DIR="$base/state" SI_GUESTS_ROOMS_DIR="$base/rooms" SI_GUESTS_KEYS_DIR="$base/keys"
     bash "$HELPER" remove "$guest"; bash "$HELPER" remove "$sguest") >/dev/null 2>&1
    userdel -r "$vuser" >/dev/null 2>&1
    for g in serverinator-guests serverinator-shell; do
        getent group "$g" >/dev/null && [[ -z "$(getent group "$g" | cut -d: -f4)" ]] && groupdel "$g" 2>/dev/null
    done
    rm -rf "$base" "$tmp"
}
trap cleanup_real EXIT
export SI_GUESTS_STATE_DIR="$base/state" SI_GUESTS_ROOMS_DIR="$base/rooms" SI_GUESTS_KEYS_DIR="$base/keys"
mkdir -p "$base/files/photos" "$base/files/docs" "$base/phone" "$base/vps"
echo hello > "$base/files/docs/readme.txt"; chmod 755 "$base/files/docs"; chmod 644 "$base/files/docs/readme.txt"

# Phone sshd: the shipped rules, with the test's paths.
ssh-keygen -q -t ed25519 -N '' -f "$base/phone/hk"
sed -e "s#/etc/ssh/serverinator-guests/#$base/keys/#" -e "s#/srv/guests/#$base/rooms/#" \
    "$tmp/root/etc/ssh/serverinator-guests.conf" > "$base/phone/guests.conf"
cat > "$base/phone/sshd_config" <<EOF
Port 2299
ListenAddress 127.0.0.2
HostKey $base/phone/hk
PidFile $base/phone.pid
PasswordAuthentication no
UsePAM no
Subsystem sftp internal-sftp
Include $base/phone/guests.conf
EOF

# VPS side: the guest login user and its forced-command line, as core-vps.sh writes them.
useradd --system --home-dir "$base/vps/home" --create-home --shell /bin/sh "$vuser" >/dev/null 2>&1
usermod -p '*' "$vuser"
mkdir -p "$base/vps/home/.ssh" "$base/vps/home/routes"
ssh-keygen -q -t ed25519 -N '' -f "$base/vps/home/routes/$guest"
ssh-keygen -q -t ed25519 -N '' -f "$base/guestkey"
printf 'serverinator-t %s\n' "$(awk '{print $1" "$2}' "$base/phone/hk.pub")" > "$base/vps/home/routes/known_hosts_t"
(
    source "$VPS_SCRIPT" >/dev/null 2>&1
    GUEST_VPS_HOME="$base/vps/home"
    _guest_route_line "$guest" "$(awk '{print $1" "$2}' "$base/guestkey.pub")" t 127.0.0.2 2299 x
) > "$base/vps/home/.ssh/authorized_keys"
chown -R "$vuser:" "$base/vps/home"; chmod 700 "$base/vps/home/.ssh" "$base/vps/home/routes"
ssh-keygen -q -t ed25519 -N '' -f "$base/vps/hk"
cat > "$base/vps/sshd_config" <<EOF
Port 2298
ListenAddress 127.0.0.1
HostKey $base/vps/hk
PidFile $base/vps.pid
PasswordAuthentication no
UsePAM no
# The forced command only replaces a subsystem sshd knows; without this line
# the request fails before the forced command runs.
Subsystem sftp internal-sftp
EOF

# Phone helper: create the guest with a read-write folder.
out="$(awk '{print $1" "$2}' "$base/vps/home/routes/$guest.pub" | bash "$HELPER" set "$guest" --from 127.0.0.1 "rw:$base/files/photos" 2>&1)"
assert_contains "$out" 'uid=' 'helper creates the guest'
uid="$(sed -n 's/^uid=//p' <<< "$out")"
assert_eq "$(id -u "$guest" 2>/dev/null)" "$uid" 'guest user exists with that UID'
mountpoint -q "$base/rooms/$guest/photos" && pass 'photos mounted in the room' || failtest 'photos mounted in the room'
assert_contains "$(cat "$base/keys/$guest")" 'restrict,from="127.0.0.1" ssh-ed25519' 'phone key line restricted to the VPS address'

mkdir -p /run/sshd
/usr/sbin/sshd -f "$base/phone/sshd_config" -E "$base/phone.log"
/usr/sbin/sshd -f "$base/vps/sshd_config" -E "$base/vps.log"
sleep 1
sftp_as() { sftp -q -b - -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$base/guestkey" -P 2298 "$vuser@127.0.0.1" 2>&1; }
echo photo-bytes > "$base/pic.jpg"
out="$(printf 'put %s photos/pic.jpg\nmkdir photos/album\nrename photos/pic.jpg photos/album/pic.jpg\nls\n' "$base/pic.jpg" | sftp_as)"
assert_eq photo-bytes "$(cat "$base/files/photos/album/pic.jpg" 2>/dev/null)" 'upload lands in the shared folder on the phone'
assert_eq "$uid" "$(stat -c %u "$base/files/photos/album/pic.jpg" 2>/dev/null)" 'uploaded file belongs to the guest'
assert_contains "$out" 'photos' 'guest sees the folder'
assert_not_contains "$out" 'etc' 'guest sees nothing else'
out="$(timeout 10 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$base/guestkey" -p 2298 "$vuser@127.0.0.1" id < /dev/null 2>&1)"
assert_not_contains "$out" "uid=" 'guest key gets no shell on the VPS'
rc=0; timeout 10 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$base/guestkey" -p 2299 "$guest@127.0.0.2" true < /dev/null > /dev/null 2>&1 || rc=$?
[[ "$rc" != 0 ]] && pass 'guest key alone is not accepted by the phone' || failtest 'guest key alone is not accepted by the phone'

# Set again (as --sync-guests does) with docs, read-only; photos leaves the room.
awk '{print $1" "$2}' "$base/vps/home/routes/$guest.pub" | bash "$HELPER" set "$guest" --uid "$uid" --from 127.0.0.1 "ro:$base/files/docs" > /dev/null 2>&1
[[ ! -e "$base/rooms/$guest/photos" ]] && pass 'the old folder leaves the room' || failtest 'the old folder leaves the room'
assert_eq photo-bytes "$(cat "$base/files/photos/album/pic.jpg" 2>/dev/null)" 'its files stay in place'
printf 'get docs/readme.txt %s/got.txt\n' "$base" | sftp_as > /dev/null
assert_eq hello "$(cat "$base/got.txt" 2>/dev/null)" 'download works'
rc=0; printf 'put %s docs/x.jpg\n' "$base/pic.jpg" | sftp_as > /dev/null || rc=$?
[[ "$rc" != 0 && ! -e "$base/files/docs/x.jpg" ]] && pass 'read-only folder refuses uploads' || failtest 'read-only folder refuses uploads'

# Boot: mounts are gone, mount-all brings them back.
umount -l "$base/rooms/$guest/docs"
bash "$HELPER" mount-all > /dev/null 2>&1
mountpoint -q "$base/rooms/$guest/docs" && pass 'mount-all restores the folders' || failtest 'mount-all restores the folders'

bash "$HELPER" remove "$guest" > /dev/null 2>&1
! id "$guest" >/dev/null 2>&1 && pass 'remove deletes the guest user' || failtest 'remove deletes the guest user'
[[ ! -e "$base/rooms/$guest" ]] && pass 'remove deletes the room' || failtest 'remove deletes the room'
assert_file_exists "$base/files/docs/readme.txt" 'remove keeps the shared files'

echo "Test: real chain — shell guest jumps through the VPS to a shell on the phone"
ssh-keygen -q -t ed25519 -N '' -f "$base/shellkey"
out="$(awk '{print $1" "$2}' "$base/shellkey.pub" | bash "$HELPER" set "$sguest" --from 127.0.0.1 --shell 2>&1)"
assert_contains "$out" 'uid=' 'helper creates the shell guest'
assert_eq "/home/$sguest" "$(getent passwd "$sguest" | cut -d: -f6)" 'shell guest has a home folder'
assert_contains "$(cat "$base/keys/$sguest")" 'restrict,pty,from="127.0.0.1" ssh-ed25519' 'phone key line allows a terminal, from the VPS only'
(
    source "$VPS_SCRIPT" >/dev/null 2>&1
    _guest_jump_line "$sguest" "$(awk '{print $1" "$2}' "$base/shellkey.pub")" 127.0.0.2 2299
) >> "$base/vps/home/.ssh/authorized_keys"
sshopts=(-o LogLevel=ERROR -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i "$base/shellkey")
out="$(timeout 15 ssh "${sshopts[@]}" -o "ProxyCommand=ssh ${sshopts[*]} -p 2298 -W %h:%p $vuser@127.0.0.1" \
        -p 2299 "$sguest@127.0.0.2" 'id -un; id -u; ls /' < /dev/null 2>&1)"
assert_contains "$out" "$sguest" 'shell guest runs commands as itself on the phone'
assert_contains "$out" 'usr' 'shell guest sees the whole system'
[[ "$(sed -n 2p <<< "$out")" =~ ^[1-9][0-9]*$ ]] && pass 'shell guest is not root' || failtest 'shell guest is not root'
out="$(timeout 10 ssh "${sshopts[@]}" -p 2298 "$vuser@127.0.0.1" id < /dev/null 2>&1)"
assert_not_contains "$out" "uid=" 'shell guest key gets no shell on the VPS'
rc=0; timeout 10 ssh "${sshopts[@]}" -o "ProxyCommand=ssh ${sshopts[*]} -p 2298 -W %h:%p $vuser@127.0.0.1" \
    -p 22 "$sguest@127.0.0.2" true < /dev/null > /dev/null 2>&1 || rc=$?
[[ "$rc" != 0 ]] && pass 'shell guest can only forward to the phone sshd' || failtest 'shell guest can only forward to the phone sshd'
bash "$HELPER" remove "$sguest" > /dev/null 2>&1
! id "$sguest" >/dev/null 2>&1 && pass 'remove deletes the shell guest' || failtest 'remove deletes the shell guest'
[[ ! -e "/home/$sguest" ]] && pass 'remove deletes its home folder' || failtest 'remove deletes its home folder'

exit "$TESTS_FAILED"
