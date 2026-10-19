#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
collector="$REPO_ROOT/tools/collect-tunnel-diag.sh"
(cd "$tmp"; bash "$collector" --dry-run --duration 2) > "$tmp/dry" 2>&1
assert_eq 0 "$?" 'dry-run succeeds'
assert_contains "$(cat "$tmp/dry")" 'adb' 'phone command printed'
assert_contains "$(cat "$tmp/dry")" 'uber@' 'VPS command printed'
assert_eq 0 "$(find "$tmp" -maxdepth 1 -name 'diag-*' | wc -l | tr -d ' ')" 'dry-run creates no artifacts'
assert_not_contains "$(cat "$tmp/dry")" 'wg show all dump' 'no secret WG dump'
assert_contains "$(cat "$tmp/dry")" '/proc/net/snmp' 'counter fallback present'
if (cd "$tmp"; bash "$collector" --duration '1;id' --dry-run > "$tmp/bad" 2>&1); then failtest 'invalid duration rejected'; else pass 'invalid duration rejected'; fi

(cd "$tmp"; bash "$collector" --duration 2 --interactive-sudo --dry-run) > "$tmp/interactive" 2>&1
assert_eq 0 "$?" 'interactive-sudo dry-run succeeds'
assert_contains "$(cat "$tmp/interactive")" 'ssh -tt' 'interactive sudo allocates a VPS tty'
assert_contains "$(cat "$tmp/interactive")" 'sudo sh' 'interactive mode allows sudo prompt'
assert_not_contains "$(cat "$tmp/interactive")" 'sudo -n' 'interactive mode does not require NOPASSWD'

mkdir -p "$tmp/bin"
cat > "$tmp/bin/adb" <<'MOCK'
#!/usr/bin/env bash
printf 'adb start\n' >> "$DIAG_TEST_EVENTS"
sleep 0.3
printf 'mock phone UTC counters\n'
printf 'adb end\n' >> "$DIAG_TEST_EVENTS"
MOCK
cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf '%s' "${*: -1}" > "$DIAG_TEST_REMOTE"
printf 'ssh start\n' >> "$DIAG_TEST_EVENTS"
sleep 0.3
printf 'mock VPS UTC counters\n'
printf 'ssh end\n' >> "$DIAG_TEST_EVENTS"
MOCK
chmod +x "$tmp/bin/adb" "$tmp/bin/ssh"
export DIAG_TEST_EVENTS="$tmp/events" DIAG_TEST_REMOTE="$tmp/remote-command"
(cd "$tmp"; PATH="$tmp/bin:$PATH" bash "$collector" --duration 1) > "$tmp/result" 2>&1
assert_eq 0 "$?" 'mock collection succeeds'
if [[ -f "$tmp/events" ]]; then assert_contains "$(head -2 "$tmp/events")" 'start' 'collectors started'; else failtest 'collectors started'; fi
if [[ -f "$tmp/events" ]] && [[ "$(head -2 "$tmp/events")" != *end* ]]; then pass 'both sides run concurrently'; else failtest 'both sides run concurrently'; fi
archive=$(find "$tmp" -maxdepth 1 -name 'diag-*.tar.gz' -print)
assert_file_exists "$archive" 'single archive produced'
if [[ -f "$archive" ]]; then
 tar -tzf "$archive" > "$tmp/list"
 assert_contains "$(cat "$tmp/list")" 'phone-' 'phone log archived'
 assert_contains "$(cat "$tmp/list")" 'vps-' 'VPS log archived'
 assert_contains "$(cat "$tmp/list")" 'manifest-' 'UTC manifest archived'
fi

if [[ -f "$tmp/remote-command" ]]; then
 python3 - "$tmp/remote-command" "$tmp/remote.sh" <<'PYCODE'
import shlex,sys
args=shlex.split(open(sys.argv[1]).read())
assert args[:4]==['sudo','-n','sh','-c']
open(sys.argv[2],'w').write(args[4])
PYCODE
 bash -n "$tmp/remote.sh"; assert_eq 0 "$?" 'remote command quoting and shell syntax'
 if [[ -n "${SERVERINATOR_TEST_BUSYBOX:-}" ]]; then
  "$SERVERINATOR_TEST_BUSYBOX" ash -n "$tmp/remote.sh"; assert_eq 0 "$?" 'remote script BusyBox ash syntax'
 else echo 'SKIP: remote BusyBox syntax (SERVERINATOR_TEST_BUSYBOX unset)'; fi
 assert_not_contains "$(cat "$tmp/remote.sh")" 'pkill' 'remote cleanup uses exact child PIDs'
 # Execute the generated remote fallback locally with a restricted tool PATH.
 # No transport, tcpdump, wg or sshd is started; only local proc counters read.
 mkdir "$tmp/remote-bin"
 for tool in date cat sleep mktemp rm; do ln -s "$(command -v "$tool")" "$tmp/remote-bin/$tool"; done
 sed "s|^PATH=.*|PATH=$tmp/remote-bin|" "$tmp/remote.sh" > "$tmp/fallback.sh"
 TMPDIR="$tmp" bash "$tmp/fallback.sh" > "$tmp/fallback.log" 2>&1
 assert_eq 0 "$?" 'generated counter fallback executes'
 assert_contains "$(cat "$tmp/fallback.log")" 'FALLBACK /proc/net/dev + /proc/net/snmp' 'missing tcpdump selects fallback'
 assert_contains "$(cat "$tmp/fallback.log")" 'Ip:' 'actual SNMP counters collected'

fi

mkdir "$tmp/interactive-run"
: > "$tmp/events"
(cd "$tmp/interactive-run"; PATH="$tmp/bin:$PATH" bash "$collector" --duration 1 --interactive-sudo) \
    > "$tmp/interactive-result" 2>&1
assert_eq 0 "$?" 'mock interactive-sudo collection succeeds'
interactive_archive=$(find "$tmp/interactive-run" -maxdepth 1 -name 'diag-*.tar.gz' -print)
assert_file_exists "$interactive_archive" 'interactive-sudo archive produced'
assert_contains "$(cat "$tmp/interactive-result")" 'mock VPS UTC counters' \
    'interactive VPS output remains visible for sudo prompt'

exit "$TESTS_FAILED"
