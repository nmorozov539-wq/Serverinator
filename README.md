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

2. **Run the installer** and answer its three questions (VPS address,
   a name for this device, an SSH alias):

   ```
   bash serverinator.sh
   ```

   > **Termux users:** if `su` drops you into a shell that can't find
   > `bash` by name, use the absolute path the first time —
   > `/system_ext/bin/bash serverinator.sh` (exact path may vary by
   > device; `find / -maxdepth 3 -name bash 2>/dev/null` will locate it).
   > Everything the script calls after that self-heals its own `PATH`.

3. **First run is expected to stop and ask you to authorize a key.** The
   phone generates its own identity for talking to the VPS and has no way
   to bootstrap trust on its own — it'll print a public key and ask you to
   add it to the VPS's `authorized_keys`. Do that, then run step 2 again
   with the same answers. This time it should complete all the way
   through, including a final connectivity check.

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

## Testing

```
bash tests/run_tests.sh
```

Runs the full local regression suite — no real phone or VPS required.
Everything is exercised against mocked chroots, systemd units, and SSH
calls. 19 test files, covering install/uninstall, address allocation,
handoff validation, the generated Magisk scripts' actual shell syntax,
and the client add/revoke flow including the VPS-side access restriction
above.

## Known limitations and roadmap

Nothing below is a secret gap found after the fact — this is genuinely
where the project stands today, kept here on purpose instead of only in
a private backlog.

### Works today, but with a sharp edge

- **Windows client setup needs WSL or Git Bash.** The generated
  `client-setup-*.sh` script is bash. It runs natively on Linux and
  Termux; on Windows there's no native `.ps1` equivalent yet, so you need
  one of those two compatibility layers in the meantime.
- **The first-time VPS authorization step is manual.** The installer
  can't bootstrap trust on its own (see Quickstart step 3) — you have to
  copy one key by hand, once, per VPS. If you already have *some* access
  to that VPS, this could in principle be automated; it isn't yet.
- **`/tmp` inside the phone's chroot is not tmpfs.** It's a normal
  directory on persistent storage, never cleaned — anything that writes
  temp files there (package managers, long-running processes) will slowly
  accumulate garbage with nothing to clear it. A size-capped tmpfs mount
  is the known fix; it isn't wired in yet, partly because the right
  default (RAM-backed vs. disk-backed-with-a-cleaner) depends on how much
  RAM you're willing to dedicate, and that should probably be a choice at
  install time rather than a silent default.
- **Everything is root-only.** There's no concept yet of a lower-privilege
  user inside the chroot, or of giving a client limited access instead of
  full root. Every added client gets the same level of access the owner
  has.

### Not yet built

- **No way to see who currently has access** short of reading
  `authorized_keys` by hand and looking for the `serverinator:client:`
  markers. A `--list-clients` command is the obvious fix and hasn't been
  written yet.
- **No alerting if the tunnel goes down.** The only way to find out the
  VPS died, or the tunnel dropped, is to try to connect and notice it
  failing. A lightweight watchdog pushing a notification on a missed
  handshake would close this gap.
- **No identity backup/restore.** If the phone is lost, factory reset, or
  replaced, its WireGuard key and persisted SSH host key go with it, and
  the VPS side needs to be reconfigured too. There's no single command to
  export "this installation's identity" and restore it onto a new device.
- **No dedicated VPS-migration workflow**, even though the pieces mostly
  exist: the phone's keys and chroot don't depend on which VPS they're
  talking to, so re-running the installer pointed at a different VPS
  address *should* just work. That path has not been deliberately tested
  end-to-end as a "my VPS died, now what" story, so it's not something to
  rely on yet without trying it first.
- **No optional custom domain / real TLS certificate.** The VPS currently
  presents a self-signed certificate on its WSS endpoint, and everything
  addresses the VPS by raw IP. Supporting a real domain (and certificate)
  at install time would make VPS migration a DNS change instead of a
  phone-side reconfiguration, and might make the traffic blend in better
  on networks that specifically distrust self-signed TLS.
- **Startup ordering inside the Magisk scripts is poll-based, not
  event-driven.** Each of the three autostart scripts waits on a
  dependency by checking every couple of seconds, up to a timeout, then
  proceeds regardless. It works, and each script's own crash-recovery
  loop papers over most of the awkwardness, but it's not elegant and
  could plausibly be replaced by leaning on that same recovery loop
  instead of a separate upfront wait.
- **Minimal visual feedback during install.** Right now you get plain
  `[INFO]`/`[1/5]`-style log lines. Nothing wrong with them, but a little
  more visual structure would make a multi-minute install feel less like
  staring at a log file.
- **No fast, low-overhead login diagnostics.** A short "here's your
  tunnel's health" banner on login would be nice, but needs to be built
  carefully — naive implementations that shell out to `grep`/`awk` per
  check can add many seconds to every single login on a phone, especially
  from inside a chroot.

If you want to pick any of these up, this list is intentionally specific
enough to start from.

## License

[GPLv3](LICENSE). You're free to use, modify, and redistribute this —
including commercially — but any distributed version, modified or not,
must stay open under the same terms.
