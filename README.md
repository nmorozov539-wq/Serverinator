# ServerInator

Turn a rooted Android phone into an always-on Linux server, reachable
through a VPS — even on networks where WireGuard alone gets blocked.

## Why this exists

A phone makes a surprisingly capable low-power server, but it has two
problems: it has no public IP (it's behind NAT, like almost every mobile
or home connection), and on some networks a bare WireGuard tunnel gets
fingerprinted and blocked by DPI. ServerInator solves both by giving the
phone a real Linux userspace (a chroot) and routing WireGuard's traffic
inside a WebSocket-Secure (WSS) tunnel to a VPS you control — so from the
outside it just looks like ordinary HTTPS traffic to your own server.

The phone always makes the *outbound* connection to the VPS. You never
need to open a port on the phone itself, forward anything through your
home router, or trust a third-party relay.

## How it works

```
SSH client (you)
    │  ProxyJump via the VPS
    ▼
Public VPS
    │  TCP to the phone's virtual IP, port 2222
    ▼
WireGuard (VPS) ⇄ WireGuard (phone)
    │  encrypted UDP, wrapped inside...
    ▼
wstunnel server (VPS) ⇄ wstunnel client (phone, outbound)
    │
    ▼
sshd inside a Linux chroot on the phone
```

- **Chroot** (Debian/Ubuntu userspace on the phone's own Android kernel) —
  gives you a real Linux environment without needing a custom ROM or a
  second kernel.
- **WireGuard** — the actual private network between VPS and phone.
- **wstunnel** — wraps WireGuard's UDP traffic in a WSS (TLS-over-WebSocket)
  connection the phone initiates outbound, so it survives NAT and most
  DPI-based blocking.
- **OpenSSH**, running inside the chroot, listening only on the WireGuard
  tunnel's virtual IP — never on the phone's real network interface.
- **Magisk `service.d`** — brings all of the above up automatically on
  every boot, with no manual steps after the first install.

## Requirements

- A rooted Android phone (Magisk) with a terminal — Termux works.
- A VPS you control, reachable by SSH, running a systemd-based Linux
  (Ubuntu/Debian tested).
- `bash` on both ends (already present on most Android systems — if not,
  see the Termux note below).

## Quickstart

1. **Get the files onto the phone** (e.g. `adb push`, or clone the repo
   inside Termux) and get a root shell there.

2. **Run the installer** and answer its questions (VPS address,
   a name for this device, an SSH alias, whether the chroot's `/tmp`
   lives in RAM or on disk, and optionally a domain for the VPS):

   ```
   bash serverinator.sh
   ```

   > **Termux users:** if `su` drops you into a shell that can't find
   > `bash` by name, use the absolute path the first time —
   > `/system_ext/bin/bash serverinator.sh` (exact path may vary by
   > device; `find / -maxdepth 3 -name bash 2>/dev/null` will locate it).
   > Everything the script calls after that self-heals its own `PATH`.

3. **Let it authorize itself on the VPS.** The phone generates its own
   key for talking to the VPS and gets it into `authorized_keys` the
   cheapest way that works: a key already on the phone that the VPS
   accepts, then a password login if the server allows one. If neither
   works, it offers manual routes: `adb` from a computer, a short `curl`
   over Wi-Fi, or typing the key in short checked chunks into your
   provider's web console. Passwords are never stored, and failed logins
   are capped so fail2ban-style bans aren't tripped. Once the key works,
   the install carries on through to a final connectivity check.

4. **Reboot the phone.** The installer only *writes* the autostart
   scripts — Magisk only runs them at boot. Give it a minute or two after
   boot for everything to come up.

5. **Verify it worked, from anywhere with SSH access to the VPS:**

   ```
   ssh your-vps 'bash /root/.serverinator/bin/core-vps.sh --verify /tmp/back-handoff.json'
   ```

   This checks the WireGuard interface, the handshake, the wstunnel
   service, a ping, and — the check that actually matters — real SSH data
   transfer through the tunnel (a tunnel can pass a handshake and still
   have its data silently dropped by a network in between; this is the
   one that would catch it).

6. **Connect.** The installer also generates a personal setup script on
   the VPS. Download and run it on whatever device you want to connect
   from:

   ```
   scp your-vps:/etc/wireguard/serverinator/ssh/client-setup-owner-DEVICE.sh . \
       && bash client-setup-owner-DEVICE.sh
   ssh DEVICE-alias
   ```

## Usage

**Add access for someone else** (a friend, a second device of your own —
each gets their own distinct, revocable key; the tunnel must already be up):

```
ssh your-vps 'bash /root/.serverinator/bin/core-vps.sh --add-client LABEL'
scp your-vps:/etc/wireguard/serverinator/ssh/client-setup-LABEL-DEVICE.sh . \
    && bash client-setup-LABEL-DEVICE.sh
```

**Revoke it again:**

```
ssh your-vps 'bash /root/.serverinator/bin/core-vps.sh --revoke-client LABEL'
```

**See who has access:**

```
ssh your-vps 'bash /root/.serverinator/bin/core-vps.sh --list-clients'
```

**Several phones on one VPS.** Run the installer on each phone with its
own device name; each gets its own tunnel address and client entries.
Client commands act on the only phone, or on the one you name with
`--device NAME` once there are several:

```
ssh your-vps 'bash /root/.serverinator/bin/core-vps.sh --list-devices'
ssh your-vps 'bash /root/.serverinator/bin/core-vps.sh --add-client LABEL --device NAME'
ssh your-vps 'bash /root/.serverinator/bin/core-vps.sh --remove-device NAME'
```

**Use a domain and a real certificate.** If a domain or subdomain points
at the VPS (a DNS A record), give it to the installer, either at the
survey question or as `--domain vps.example.com [--acme-email you@example.com]`.
The VPS gets a Let's Encrypt certificate for the tunnel and renews it on
its own, phones connect by name, and client scripts jump through the
domain. Let's Encrypt checks the domain over port 80. If a web server
running as a systemd service (Caddy, nginx, ...) already uses that port,
it is stopped for the few seconds of each check and started again. To use
a certificate you already have, run on the VPS:
`core-vps.sh --set-domain D --tls-cert /abs/fullchain.pem --tls-key /abs/privkey.pem`.

An existing install by IP moves over without reinstalling. Run this on
the phone:

```
bash serverinator.sh --vps root@VPS --set-domain vps.example.com
```

Other phones on the same VPS keep working by IP until you run the same
command on each of them. `--remove-domain` goes back to the self-signed
certificate.

**Connect from Windows.** Every client setup script has a PowerShell twin
next to it (`client-setup-*.ps1`) for the OpenSSH client built into
Windows:

```
scp your-vps:/etc/wireguard/serverinator/ssh/client-setup-owner-DEVICE.ps1 .
powershell -ExecutionPolicy Bypass -File .\client-setup-owner-DEVICE.ps1
```

**Move to a new phone.** Export the old phone's identity (its WireGuard
and SSH host keys, the VPS login key and extra authorized keys), import it
on the new phone, then run the installer with the same VPS and device
name. The VPS and every client keep working unchanged.

```
bash core/core-phone.sh --export-identity /sdcard/si-identity.tar   # old phone
bash core/core-phone.sh --import-identity /sdcard/si-identity.tar   # new phone
```

The file holds private keys, so treat it like a password.

**Uninstall.** On the phone (removes the chroot and autostart scripts;
`--purge` also deletes the persisted SSH host key, giving you a fully
fresh identity on the next install):

```
bash core/core-phone.sh --uninstall [--purge]
```

On the VPS (leaves unrelated services and firewall rules untouched):

```
ssh your-vps 'bash /root/.serverinator/bin/core-vps.sh --uninstall'
```

## Security model

- sshd inside the chroot listens **only** on the WireGuard tunnel's
  virtual IP — it is never reachable from the phone's real network
  interface, let alone the public internet.
- Key-only authentication everywhere; password login is disabled.
- Every additional client (`--add-client`) gets its own distinct key, not
  a shared one — revoking one person's access never touches anyone
  else's.
- A client's key is only ever trusted for two things: logging into the
  phone, and forwarding *through* the VPS to reach the phone. The VPS
  itself grants that key a `command=...,restrict,port-forwarding,
  permitopen=` entry — it can jump through, but it cannot open a shell on
  the VPS itself, even though the key is technically "authorized" there.
- `wstunnel`'s server is started with `--restrict-to`, so it only ever
  forwards to the local WireGuard listener — without it, anyone who found
  the port could use it as an open proxy.
- The phone's SSH host key travels with the install and is pinned on the
  VPS and in every generated client script, so a client that reaches the
  wrong machine refuses to connect instead of asking you to trust it.
- With a domain, the tunnel serves a real certificate. The phone doesn't
  verify it by default, since WireGuard already authenticates both ends
  and a wrong certificate can't take over the tunnel. Set
  `SERVERINATOR_TLS_VERIFY=1` when installing to make it verify anyway.
- The Ubuntu base image and the `wstunnel` binary are checked against
  pinned SHA-256 hashes before use, and an interrupted rootfs extraction
  is detected and redone rather than half-used.

## Testing

```
bash tests/run_tests.sh
```

Runs the full local regression suite — no real phone or VPS required.
Everything is exercised against mocked chroots, systemd units, and SSH
calls. 33 test files, covering install/uninstall, address allocation,
handoff validation, the generated Magisk scripts' actual shell syntax,
the client add/revoke/list flow including the VPS-side access
restriction above, VPS authorization, several phones per VPS, host key
pinning, domains and certificates (with a fake certbot), identity
export/import, and the Windows client script (run under PowerShell when
`pwsh` is installed).

## Known limitations and roadmap

Nothing below is a secret gap found after the fact — this is genuinely
where the project stands today, kept here on purpose instead of only in
a private backlog.

### Works today, but with a sharp edge

- **Everything is root-only.** There's no concept yet of a lower-privilege
  user inside the chroot, or of giving a client limited access instead of
  full root. Every added client gets the same level of access the owner
  has.

### Not yet built

- **No alerting if the tunnel goes down.** The only way to find out the
  VPS died, or the tunnel dropped, is to try to connect and notice it
  failing. A lightweight watchdog pushing a notification on a missed
  handshake would close this gap.
- **No dedicated VPS-migration workflow**, even though the pieces mostly
  exist: the phone's keys and chroot don't depend on which VPS they're
  talking to, so re-running the installer pointed at a different VPS
  address *should* just work. That path has not been deliberately tested
  end-to-end as a "my VPS died, now what" story, so it's not something to
  rely on yet without trying it first. With a domain, the phones already
  connect by name, so a migration could become mostly a DNS change.
- **Startup ordering inside the Magisk scripts is poll-based, not
  event-driven.** Each of the autostart scripts waits on a
  dependency by checking every couple of seconds, up to a timeout, then
  proceeds regardless. It works, and each script's own crash-recovery
  loop papers over most of the awkwardness, but it's not elegant and
  could plausibly be replaced by leaning on that same recovery loop
  instead of a separate upfront wait.
- **Minimal visual feedback during install.** Right now you get plain
  `[INFO]`/`[1/5]`-style log lines. Nothing wrong with them, but a little
  more visual structure would make a multi-minute install feel less like
  staring at a log file.

## License

[GPLv3](LICENSE). You're free to use, modify, and redistribute this —
including commercially — but any distributed version, modified or not,
must stay open under the same terms.
