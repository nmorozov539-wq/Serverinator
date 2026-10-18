#!/usr/bin/env bash
# First-time VPS authorization (core/vps-auth.sh): failure budget, ban
# detection, the chunked-typing commands, the Wi-Fi HTTP response, and — when
# sshd is available and we are root — real logins against a throwaway sshd.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d)
sshd_pid=""
cleanup() { [[ -n "$sshd_pid" ]] && kill "$sshd_pid" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

load() { # fresh copy of the module with a generated orchestrator identity
    source "$REPO_ROOT/core/lib.sh"
    source "$REPO_ROOT/core/vps-auth.sh"
    ORCHESTRATOR_SSH_DIR="$tmp/orch"; mkdir -p "$ORCHESTRATOR_SSH_DIR"
    [[ -f "$ORCHESTRATOR_SSH_DIR/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C serverinator-orchestrator-rn9p -f "$ORCHESTRATOR_SSH_DIR/id_ed25519"
    SSH_OPTS=(-o BatchMode=yes -o "IdentityFile=$ORCHESTRATOR_SSH_DIR/id_ed25519" -o IdentitiesOnly=yes -o "UserKnownHostsFile=$ORCHESTRATOR_SSH_DIR/known_hosts")
    VPS_USER=root VPS_HOST=127.0.0.1 VPS_TARGET=root@127.0.0.1 DEVICE_NAME=rn9p
    AUTH_TMP="$tmp/auth"; mkdir -p "$AUTH_TMP"
}

echo "Test: rejection parsing and the failure budget"
out="$( (load
    ssh() { echo 'root@127.0.0.1: Permission denied (publickey,password).' >&2; return 255; }
    auth_try_own_key; echo "methods=$AUTH_METHODS fails=$AUTH_FAILS"
    auth_offers password && echo offers-password
    auth_try_own_key; auth_try_own_key; echo "after3=$AUTH_FAILS"
    auth_try_own_key; echo "not reached") 2>&1)"
assert_contains "$out" 'methods=publickey,password fails=1' 'methods and first failure recorded'
assert_contains "$out" 'offers-password' 'password route detected'
assert_contains "$out" 'after3=3' 'three rejections counted'
assert_contains "$out" 'Stopped after 3 rejected logins' 'fourth attempt refused before connecting'
assert_not_contains "$out" 'not reached' 'budget is a hard stop'

echo "Test: a VPS that stops answering after a rejection is treated as a ban"
out="$( (load
    ssh() { local n; n=$(wc -c < "$tmp/calls" 2>/dev/null || echo 0); echo x >> "$tmp/calls"; if ((n == 0)); then echo 'Permission denied (publickey).' >&2; else echo 'ssh: connect to host 127.0.0.1 port 22: Connection refused' >&2; fi; return 255; }
    auth_try_own_key; auth_try_own_key; echo "not reached") 2>&1)"
assert_contains "$out" 'probably banned this IP' 'ban explained'
assert_not_contains "$out" 'not reached' 'stops instead of retrying'
out="$( (load
    ssh() { echo 'ssh: connect to host 127.0.0.1 port 22: Connection refused' >&2; return 255; }
    auth_try_own_key) 2>&1)"
assert_not_contains "$out" 'banned' 'unreachable on the first try is not called a ban'
assert_contains "$out" 'Could not reach' 'plain network error instead'

echo "Test: chunked typing rebuilds the exact key and the check codes match"
(load
    cd "$tmp" && mkdir -p chunkhome && cd chunkhome
    auth_chunk_commands > ../chunks.txt
    while IFS= read -r line; do
        [[ "$line" =~ ^\ \ ([0-9]+/[0-9]+|start|end|tidy)\ +(.*)$ ]] || continue
        cmd="${BASH_REMATCH[2]}"; cmd="${cmd%%      (check:*}"
        printf '%s\n' "$cmd" >> ../typed.txt
        HOME="$PWD" sh -c "$cmd"
        if [[ "$line" =~ \(check:\ ([0-9a-f]{4})\) ]]; then
            [[ "$(md5sum < si.k | cut -c1-4)" == "${BASH_REMATCH[1]}" ]] || echo "BADCODE $line" >> ../chunks.txt
        fi
    done < ../chunks.txt
    printf '%s\n' "$(auth_chunk_key)" > ../expected
)
assert_eq "$(cat "$tmp/expected")" "$(grep -v "^$" "$tmp/chunkhome/.ssh/authorized_keys" 2>/dev/null)" 'typed chunks produce the key line'
assert_not_contains "$(cat "$tmp/chunks.txt")" 'BADCODE' 'every chunk check code matches'
assert_file_missing "$tmp/chunkhome/si.k" 'scratch file removed'
longest="$(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$tmp/typed.txt")"
[[ "$longest" -le 52 ]] && pass "each line to type is short ($longest chars)" || failtest "lines to type too long ($longest)"

echo "Test: the Wi-Fi route serves a valid HTTP response"
(load; auth_http_response) > "$tmp/resp"
resp="$(cat "$tmp/resp")"
body_len="$( (load; printf '%s\n' "$(_auth_pubkey)" | wc -c) )"
body="${resp#*$'\r\n\r\n'}"
assert_contains "$resp" 'HTTP/1.0 200 OK' 'status line'
assert_contains "$resp" "Content-Length: ${body_len}" 'content length matches body'
assert_contains "$body" 'serverinator-orchestrator-rn9p' 'body is our public key'

echo "Test: root helper script refuses when sshd forbids root logins"
(load
    auth_is_interactive() { return 0; }
    _auth_sudo_script() { mkdir -p "$tmp/fakebin"; printf '#!/bin/sh\necho "permitrootlogin no"\n' > "$tmp/fakebin/sshd"; chmod +x "$tmp/fakebin/sshd"; sh -n "$1" && echo SYNTAX_OK; PATH="$tmp/fakebin:$PATH" sh "$1"; }
    auth_offer_sudoers() { echo SUDOERS_OFFERED; return 1; }
    printf 'y\n' | { auth_offer_root; echo "rc=$? user=$VPS_USER"; }
    sh -n "$AUTH_TMP/root.sh" && echo SYNTAX_OK
) > "$tmp/root.log" 2>&1
assert_contains "$(cat "$tmp/root.log")" 'SYNTAX_OK' 'generated root script is valid sh'
assert_contains "$(cat "$tmp/root.log")" 'PermitRootLogin no' 'reports the sshd policy'
assert_contains "$(cat "$tmp/root.log")" 'SUDOERS_OFFERED' 'falls back to the sudoers offer'
assert_contains "$(cat "$tmp/root.log")" 'user=root' 'target unchanged when root is refused'

echo "Test: orchestrator without a terminal prints the key instead of asking"
out="$(SERVERINATOR_ORCHESTRATOR_SSH_DIR="$tmp/orch2" bash -c '
    source "$1"
    ssh() { echo "Permission denied (publickey,password)." >&2; return 255; }
    VPS_TARGET=deploy@203.0.113.5; split_vps_target; DEVICE_NAME=rn9p
    check_prereqs' _ "$REPO_ROOT/serverinator.sh" < /dev/null 2>&1)"
assert_contains "$out" 'no terminal to ask you' 'explains why it cannot ask'
assert_contains "$out" 'serverinator-orchestrator-rn9p' 'prints the public key to add'
assert_contains "$out" "deploy's ~/.ssh/authorized_keys" 'names the VPS user'

echo "Test: --authorize-vps is parsed"
out="$(bash -c 'source "$1"; parse_args --authorize-vps admin@203.0.113.5; split_vps_target; echo "$MODE $VPS_USER $VPS_HOST"' _ "$REPO_ROOT/serverinator.sh" 2>&1)"
assert_eq 'authorize admin 203.0.113.5' "$out" 'mode, user and host'
rc=0; bash -c 'source "$1"; VPS_TARGET="a;b@203.0.113.5"; split_vps_target' _ "$REPO_ROOT/serverinator.sh" > /dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'unsafe user name rejected'

# ── Real sshd ──────────────────────────────────────────────────────────────
if [[ "$(id -u)" != 0 ]] || ! command -v sshd > /dev/null; then
    printf '%s\n' 'SKIP: real sshd tests need root and sshd'
    exit "$TESTS_FAILED"
fi
# A throwaway user whose home is inside $tmp, so nothing touches /root.
user="sitest$$"
useradd -M -d "$tmp/home" -s /bin/sh -p '*' "$user" || { printf '%s\n' 'SKIP: cannot create a test user'; exit "$TESTS_FAILED"; }
mkdir -p "$tmp/home/.ssh"; chown -R "$user" "$tmp/home"
cleanup() { [[ -n "$sshd_pid" ]] && kill "$sshd_pid" 2>/dev/null; userdel "$user" 2>/dev/null; rm -rf "$tmp"; }
mkdir -p /run/sshd "$tmp/sshd"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/sshd/hostkey"
port=$((20000 + RANDOM % 20000))
cat > "$tmp/sshd/config" <<CFG
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/sshd/hostkey
PidFile $tmp/sshd/pid
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
UsePAM no
CFG
"$(command -v sshd)" -f "$tmp/sshd/config" -D -e 2> "$tmp/sshd/log" &
sshd_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null && break; sleep 0.3; done

ssh-keygen -q -t ed25519 -N '' -C termux -f "$tmp/termux_id_ed25519"
mkdir -p "$tmp/termux"; mv "$tmp/termux_id_ed25519" "$tmp/termux/id_ed25519"; mv "$tmp/termux_id_ed25519.pub" "$tmp/termux/id_ed25519.pub"
cp "$tmp/termux/id_ed25519.pub" "$tmp/home/.ssh/authorized_keys"
chmod 755 "$tmp"; chown -R "$user" "$tmp/home"

echo "Test (real sshd): an existing phone key installs ours in one connection"
out="$( (load
    ssh() { command ssh -p "$port" "$@"; }; VPS_USER=$user VPS_TARGET=$user@127.0.0.1
    AUTH_KEY_DIRS="$tmp/termux"
    auth_try_own_key || echo "rejected-first methods=$AUTH_METHODS"
    printf 'Y\n' | auth_route_existing_keys && echo ROUTE0_OK
    auth_try_own_key && echo OWN_KEY_WORKS
    echo "fails=$AUTH_FAILS") 2>&1)"
assert_contains "$out" 'rejected-first methods=publickey' 'own key rejected at first; server offers publickey only'
assert_contains "$out" 'ROUTE0_OK' 'route 0 succeeded'
assert_contains "$out" 'OWN_KEY_WORKS' 'own key accepted afterwards'
assert_contains "$out" 'fails=1' 'only the first check was a failure'
assert_contains "$(cat "$tmp/home/.ssh/authorized_keys")" 'serverinator-orchestrator-rn9p' 'key appended to authorized_keys'
before="$(wc -l < "$tmp/home/.ssh/authorized_keys")"
( load; ssh() { command ssh -p "$port" "$@"; }; VPS_USER=$user VPS_TARGET=$user@127.0.0.1; AUTH_KEY_DIRS="$tmp/termux"; printf 'Y\n' | auth_route_existing_keys ) > /dev/null 2>&1
assert_eq "$before" "$(wc -l < "$tmp/home/.ssh/authorized_keys")" 'running it again adds no duplicate line'

echo "Test (real sshd): password route is not offered when the server is key-only"
out="$( (load; ssh() { command ssh -p "$port" "$@"; }; VPS_USER=$user VPS_TARGET=$user@127.0.0.1; rm -f "$ORCHESTRATOR_SSH_DIR/id_ed25519"*; ssh-keygen -q -t ed25519 -N '' -f "$ORCHESTRATOR_SSH_DIR/id_ed25519"
    auth_try_own_key; auth_route_password && echo PW || echo NO_PW) 2>&1)"
assert_contains "$out" 'NO_PW' 'password route skipped'

echo "Test (real sshd): a stopped server after a rejection reads as a ban"
out="$( (load; ssh() { command ssh -p "$port" "$@"; }; VPS_USER=$user VPS_TARGET=$user@127.0.0.1
    auth_try_own_key
    kill "$sshd_pid"; wait "$sshd_pid" 2>/dev/null
    auth_try_own_key; echo "not reached") 2>&1)"
sshd_pid=""
assert_contains "$out" 'probably banned' 'ban detected against a real connection refusal'
exit "$TESTS_FAILED"
