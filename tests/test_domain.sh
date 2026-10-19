#!/usr/bin/env bash
# Domains and real certificates: Let's Encrypt (with a fake certbot), your
# own certificate, moving an existing IP install to a domain and back, and
# the phone connecting by name.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

D=vps.example.org
devroot="$tmp/vps"
le="$devroot/etc/letsencrypt"
key_dir="$devroot/etc/wireguard/serverinator/ssh"
unit="$devroot/etc/systemd/system/wstunnel-serverinator.service"
tls_state="$devroot/etc/wireguard/serverinator/tls.json"
record="$devroot/etc/wireguard/serverinator/devices/rn9p.json"

ssh-keygen -q -t ed25519 -N '' -f "$tmp/hostkey"
host_pub="$(cut -d' ' -f1,2 "$tmp/hostkey.pub")"
host_fp="$(ssh-keygen -lf "$tmp/hostkey.pub" | awk '{print $2}')"
cat > "$tmp/handoff.json" <<JSON
{"version":1,"device_name":"rn9p","wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","wstunnel_port":9443,"wg_port":51822,
 "ssh_enabled":1,"ssh_user":"root","ssh_port":2222,"ssh_host_fingerprint":"$host_fp","ssh_host_pubkey":"$host_pub"}
JSON

# A fake certbot: logs its arguments and issues a self-signed certificate
# for the -d name where real certbot would put the Let's Encrypt one.
cat > "$tmp/certbot" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
d=""; while [[ $# -gt 0 ]]; do [[ "$1" == -d ]] && d="$2"; shift; done
mkdir -p "$FAKE_LE/live/$d"
openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=$d" -addext "subjectAltName=DNS:$d" \
    -keyout "$FAKE_LE/live/$d/privkey.pem" -out "$FAKE_LE/live/$d/fullchain.pem" 2>/dev/null
FAKE
chmod +x "$tmp/certbot"
export FAKE_LOG="$tmp/certbot.log" FAKE_LE="$le"
: > "$FAKE_LOG"

# vps ARGS... : runs core-vps.sh in DEV with DNS, local addresses and port 80
# mocked by DNS_ANSWER, MY_IPS and PORT80 (1 = busy).
DNS_ANSWER=203.0.113.9 MY_IPS=203.0.113.9 PORT80=0 PORT80_UNIT=""
vps() {
    SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$devroot" SERVERINATOR_VPS_IP=203.0.113.9 \
    SERVERINATOR_CERTBOT="$tmp/certbot" DNS_ANSWER="$DNS_ANSWER" MY_IPS="$MY_IPS" PORT80="$PORT80" PORT80_UNIT="$PORT80_UNIT" \
    bash -c 'source "$1"; shift
        [[ "${DNS_REAL:-}" == 1 ]] || resolve_domain() { [[ -z "$DNS_ANSWER" ]] || printf "%s\n" $DNS_ANSWER; }
        local_ipv4s() { printf "%s\n" $MY_IPS; }
        port80_in_use() { [[ "$PORT80" == 1 ]]; }
        port80_service() { printf "%s" "$PORT80_UNIT"; }
        port80_programs() { printf "%s" "${PORT80_UNIT%.service}"; }
        ssh() { local cmd="${!#}"; HOME="'"$tmp/phone_home"'" bash -c "$cmd"; }
        main "$@"' _ "$VPS_SCRIPT" "$@" 2>&1
}
mkdir -p "$tmp/phone_home"
u="${SUDO_USER:-$(id -un)}"   # the VPS login the client scripts jump as

echo "Test: domain and e-mail validation"
( source "$REPO_ROOT/core/lib.sh"
  for good in vps.example.org a-b.c.example.co xn--80ak6aa92e.com; do
      ( validate_domain "$good" ) > /dev/null 2>&1 && pass "accepts $good" || failtest "rejects $good"
  done
  for bad in localhost 203.0.113.9 'a b.com' 'x.com;rm' 'Ex.COM' example.123 '-a.com' ''; do
      ( validate_domain "$bad" ) > /dev/null 2>&1 && failtest "accepts '$bad'" || pass "rejects '$bad'"
  done
  ( validate_email me@example.org ) > /dev/null 2>&1 && pass 'accepts an e-mail' || failtest 'rejects an e-mail'
  ( validate_email "me@x.org;id" ) > /dev/null 2>&1 && failtest 'accepts a bad e-mail' || pass 'rejects a bad e-mail'
)

echo "Test: core-vps.sh refuses bad flag combinations"
out="$(vps "$tmp/handoff.json" --vps-ip 203.0.113.9 --alias rn9p --tls-cert /x.pem)"
assert_contains "$out" 'go together' '--tls-cert without --tls-key'
out="$(vps "$tmp/handoff.json" --vps-ip 203.0.113.9 --alias rn9p --tls-cert /x.pem --tls-key /k.pem)"
assert_contains "$out" 'needs --domain' '--tls-cert without a domain'
out="$(vps "$tmp/handoff.json" --vps-ip 203.0.113.9 --alias rn9p --domain 203.0.113.9)"
assert_contains "$out" 'Invalid domain' 'an IP is not a domain'

echo "Test: install by IP (no domain) stays on the self-signed certificate"
vps "$tmp/handoff.json" --vps-ip 203.0.113.9 --alias rn9p > "$tmp/ip.log"
assert_file_exists "$unit" 'wstunnel unit written'
assert_not_contains "$(cat "$unit")" '--tls-certificate' 'no certificate options'
assert_file_missing "$tls_state" 'no tls.json'
assert_eq "" "$(jq -r '.vps_domain // ""' "$record")" 'device record has no domain'
assert_contains "$(client_setup_result "$key_dir/client-setup-owner-rn9p.sh")" 'HostName 203.0.113.9' 'client script jumps through the IP'

echo "Test: --set-domain refuses a domain that doesn't resolve"
DNS_ANSWER=""
out="$(vps --set-domain "$D")"
assert_contains "$out" "doesn't resolve yet" 'says the name does not resolve'
assert_contains "$out" "$D -> 203.0.113.9" 'and which A record to create'
assert_eq "" "$(cat "$FAKE_LOG")" 'certbot not called'
DNS_ANSWER=203.0.113.9

echo "Test: a name getent can't resolve (exit 2) still gets the message"
mkdir -p "$tmp/nodns"
printf '#!/bin/sh\nexit 2\n' > "$tmp/nodns/getent"; chmod +x "$tmp/nodns/getent"
out="$(PATH="$tmp/nodns:$PATH" DNS_REAL=1 vps --set-domain "$D")"
assert_contains "$out" "doesn't resolve yet" 'says the name does not resolve instead of stopping silently'
assert_eq "" "$(cat "$FAKE_LOG")" 'certbot not called'

echo "Test: --set-domain refuses while something that isn't a service holds port 80"
PORT80=1
out="$(vps --set-domain "$D")"
assert_contains "$out" 'TCP port 80' 'explains the port 80 conflict'
assert_contains "$out" '--tls-cert' 'and offers bringing your own certificate'
PORT80_UNIT='evil;rm -rf /.service'
out="$(vps --set-domain "$D")"
assert_contains "$out" "can't be paused automatically" 'an odd unit name is not put into a hook'
assert_eq "" "$(cat "$FAKE_LOG")" 'certbot not called'
PORT80=0 PORT80_UNIT=""

echo "Test: moving the IP install to a domain (Let's Encrypt)"
out="$(vps --set-domain "$D" --acme-email me@example.org)"
assert_contains "$out" "$D points to this VPS" 'DNS checked'
assert_contains "$(cat "$FAKE_LOG")" "certonly --standalone --non-interactive --agree-tos" 'certbot standalone, non-interactive'
assert_contains "$(cat "$FAKE_LOG")" "-d $D --cert-name $D --email me@example.org" 'for the domain, with the e-mail'
assert_contains "$(cat "$unit")" "LoadCredential=tls-cert:$le/live/$D/fullchain.pem" 'wstunnel gets the certificate'
assert_contains "$(cat "$unit")" "LoadCredential=tls-key:$le/live/$D/privkey.pem" 'and its key'
assert_contains "$(cat "$unit")" '--tls-certificate %d/tls-cert' 'served from the credentials folder'
assert_eq "$D letsencrypt" "$(jq -r '"\(.domain) \(.source)"' "$tls_state" 2>/dev/null)" 'choice saved in tls.json'
assert_eq "$D" "$(jq -r '.vps_domain // ""' "$record")" 'device record now carries the domain'
assert_eq 203.0.113.9 "$(jq -r '.vps_ip' "$record")" 'and still the IP'
hook="$le/renewal-hooks/deploy/serverinator-wstunnel.sh"
assert_file_exists "$hook" 'renewal hook written'
assert_contains "$(cat "$hook" 2>/dev/null)" 'systemctl try-restart wstunnel-serverinator.service' 'hook restarts wstunnel'
assert_contains "$(client_setup_result "$key_dir/client-setup-owner-rn9p.sh")" "HostName $D" 'owner script rewritten to jump through the domain'
assert_contains "$out" "bash serverinator.sh --set-domain $D" 'tells you what to run on each phone'

echo "Test: a web server on port 80 is paused during the check"
rm -rf "$le/live" "$le/renewal-hooks"; : > "$FAKE_LOG"
PORT80=1 PORT80_UNIT=caddy-naive.service
out="$(vps --set-domain "$D")"
assert_contains "$out" 'Port 80 is used by caddy-naive.service' 'says which service gets paused'
assert_contains "$(cat "$FAKE_LOG")" '--pre-hook systemctl stop caddy-naive.service --post-hook systemctl start caddy-naive.service' 'certbot stops and restarts it (saved for renewals)'
assert_file_exists "$le/live/$D/fullchain.pem" 'certificate issued'
PORT80=0 PORT80_UNIT=""

echo "Test: re-running keeps a valid certificate and the domain"
: > "$FAKE_LOG"
out="$(vps --set-domain "$D")"
assert_contains "$out" 'valid for at least 30 more days' 'says it keeps the certificate'
assert_eq "" "$(cat "$FAKE_LOG")" 'certbot not called again (rate limits)'
vps "$tmp/handoff.json" --vps-ip 203.0.113.9 --alias rn9p > "$tmp/rerun.log"
assert_contains "$(cat "$unit")" '--tls-certificate' 'a plain re-install keeps the domain'
assert_eq "$D" "$(jq -r '.vps_domain // ""' "$record")" 'and the record keeps it'

echo "Test: --add-client after the move jumps through the domain"
vps --add-client laptop --generate-key > "$tmp/add.log"
assert_contains "$(client_setup_result "$key_dir/client-setup-laptop-rn9p.sh")" "HostName $D" 'jump block for the domain'

echo "Test: --remove-domain goes back to the self-signed certificate"
out="$(vps --remove-domain)"
assert_not_contains "$(cat "$unit")" '--tls-certificate' 'certificate options gone'
assert_file_missing "$tls_state" 'tls.json removed'
assert_eq "" "$(jq -r '.vps_domain // ""' "$record")" 'record back on the IP'
assert_contains "$(client_setup_result "$key_dir/client-setup-owner-rn9p.sh")" 'HostName 203.0.113.9' 'client script back on the IP'
assert_contains "$out" 'bash serverinator.sh --remove-domain' 'tells you what to run on each phone'

echo "Test: your own certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$D" -addext "subjectAltName=DNS:$D" \
    -keyout "$tmp/own.key" -out "$tmp/own.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=other.example.org" \
    -addext "subjectAltName=DNS:other.example.org" -keyout "$tmp/other.key" -out "$tmp/other.pem" 2>/dev/null
: > "$FAKE_LOG"
out="$(vps --set-domain "$D" --tls-cert "$tmp/own.pem" --tls-key "$tmp/other.key")"
assert_contains "$out" 'is not the private key for' 'refuses a key that does not match'
out="$(vps --set-domain "$D" --tls-cert "$tmp/other.pem" --tls-key "$tmp/other.key")"
assert_contains "$out" "is not valid for $D" 'refuses a certificate for another name'
out="$(vps --set-domain "$D" --tls-cert "$tmp/own.pem" --tls-key "$tmp/own.key" --acme-email me@example.org)"
assert_contains "$out" "doesn't go with --tls-cert" 'no e-mail with your own certificate'
out="$(vps --set-domain "$D" --tls-cert relative.pem --tls-key "$tmp/own.key")"
assert_contains "$out" 'absolute' 'paths must be absolute'
out="$(vps --set-domain "$D" --tls-cert "$tmp/own.pem" --tls-key "$tmp/own.key")"
assert_contains "$(cat "$unit")" "LoadCredential=tls-cert:$tmp/own.pem" 'wstunnel serves your certificate'
assert_eq custom "$(jq -r .source "$tls_state" 2>/dev/null)" 'saved as custom'
assert_eq "" "$(cat "$FAKE_LOG")" 'certbot not involved'
assert_contains "$out" 'your own certificate' 'says whose certificate it is'

echo "Test: the phone connects by name"
export SERVERINATOR_CHROOT="$tmp/root" SERVERINATOR_SERVICE_D="$tmp/service" SERVERINATOR_STATE_DIR="$tmp/state"
mkdir -p "$tmp/root/etc/wireguard" "$tmp/service" "$tmp/state/backups"
printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= > "$tmp/root/etc/wireguard/client.key"
printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= > "$tmp/root/etc/wireguard/client.pub"
phone() { # BACK_JSON [ENV...] -> runs apply_back_handoff
    local back="$1"; shift
    env SERVERINATOR_DEV=1 SERVERINATOR_DEV_ROOT="$tmp/phonedev" "$@" \
        bash -c 'source "$1"; BACK_HANDOFF_FILE="$2"; apply_back_handoff' _ "$PHONE_SCRIPT" "$back" 2>&1
}
make_back() { # DOMAIN_FIELD
    cat > "$tmp/back.json" <<JSON
{"version":1,"device_name":"rn9p","vps_ip":"203.0.113.9"$1,"phone_wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","vps_wg_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","phone_wg_ip":"$TEST_PHONE_IP","vps_wg_ip":"10.66.69.1","ssh_enabled":0}
JSON
}
script="$tmp/service/10-serverinator-wstunnel.sh"
make_back ",\"vps_domain\":\"$D\""
out="$(phone "$tmp/back.json")"
assert_contains "$(cat "$script")" "wss://$D:9443" 'tunnel endpoint is the domain'
assert_contains "$(cat "$script")" 'ip route get 203.0.113.9' 'readiness still probes the IP (no DNS needed)'
assert_not_contains "$(cat "$script")" 'tls-verify-certificate' 'no verification unless asked'
assert_contains "$out" "VPS domain  : $D" 'summary shows the domain'
sh -n "$script"; assert_eq 0 "$?" 'generated script parses'
phone "$tmp/back.json" SERVERINATOR_TLS_VERIFY=1 > /dev/null
assert_contains "$(cat "$script")" $'--tls-verify-certificate \\\n' 'SERVERINATOR_TLS_VERIFY=1 verifies the certificate'
sh -n "$script"; assert_eq 0 "$?" 'still parses'
make_back ',"vps_domain":"bad domain;x"'
out="$(phone "$tmp/back.json")"
assert_contains "$out" 'Invalid domain' 'a bad domain in the record is refused'
make_back ""
phone "$tmp/back.json" > /dev/null
assert_contains "$(cat "$script")" 'wss://203.0.113.9:9443' 'without a domain: back to the IP'
out="$(phone "$tmp/back.json" SERVERINATOR_TLS_VERIFY=1)"
assert_contains "$out" 'needs a domain' 'verification needs a domain'

echo "Test: orchestrator flags"
orch() { SERVERINATOR_DEV=1 bash -c 'source "$1"; shift; parse_args "$@"; printf "%s|%s|%s|" "$MODE" "$DOMAIN" "$REMOVE_DOMAIN"; domain_args' \
    _ "$REPO_ROOT/serverinator.sh" "$@" 2>&1; }
assert_eq "install|$D|0| --domain $D --acme-email me@example.org" "$(orch --vps root@203.0.113.9 --domain VPS.Example.ORG --acme-email me@example.org)" 'install with a domain (lower-cased)'
assert_eq "set-domain|$D|0| --set-domain $D" "$(orch --set-domain "$D")" '--set-domain'
assert_eq "set-domain||1| --remove-domain" "$(orch --remove-domain)" '--remove-domain'
assert_contains "$(orch --acme-email me@example.org)" 'goes with --domain' 'e-mail needs a domain'
assert_contains "$(orch --remove-domain --set-domain "$D")" "doesn't take" 'remove and set together refused'
assert_contains "$(orch --domain 'x.org;id')" 'Invalid domain' 'shell characters refused'

exit "$TESTS_FAILED"
