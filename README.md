# ServerInator

ServerInator turns a rooted Android phone into an always-on Linux server
that you reach over SSH through a VPS you own.

The phone gets a Debian or Ubuntu userspace (a chroot) and dials out to
the VPS. Nothing is opened on the phone or your router, and no third-party
relay is involved. The link between them is WireGuard carried inside a
WebSocket-over-TLS connection, so to a network in between it looks like
ordinary HTTPS. That matters on networks that block plain WireGuard.

## How it works

```
your laptop ──SSH (ProxyJump)──▶ VPS ──WireGuard──▶ phone: sshd in a chroot
                                  ▲                  │
                                  └── wstunnel (TLS) ┘
                                   the phone dials out
```

- **Chroot on the phone.** A Debian (via `debootstrap`) or Ubuntu 24.04
  base userspace running on the phone's own kernel. No custom ROM needed.
- **wstunnel** wraps WireGuard's UDP packets in a TLS WebSocket
  connection that the phone opens to the VPS on TCP port 9443.
- **WireGuard** is the private network between the VPS and the phone
  (`10.66.69.0/24`; the VPS is `.1`, phones get `.2` and up).
- **OpenSSH** inside the chroot listens on port 2222 of the phone's tunnel
  address only, never on its Wi-Fi or mobile interface.
- **Magisk `service.d` scripts** start everything at every boot and
  restart anything that crashes. When the phone moves between mobile data
  and Wi-Fi, the tunnel reconnects on the new network.

## Requirements

**Phone**
- Rooted with **Magisk** (the installer checks for `/data/adb/magisk`).
- A kernel with WireGuard support. The chroot uses `wg-quick` and there is
  no userspace WireGuard fallback.
- arm64, armv7 or x86_64.
- A root shell with `bash` (Termux plus `su` works) and internet access.

**VPS**
- Debian or Ubuntu with systemd (packages are installed with `apt-get`).
- SSH access as root, or as a user with `sudo`.
- TCP port **9443** reachable from the internet. The installer warns you
  if `ufw` or an `iptables` DROP policy would block it.
- Optional: a domain pointing at the VPS, and port 80 free for a few
  seconds while Let's Encrypt checks it (see [Domains](#domain-and-a-real-certificate)).

Your laptop (or any client) only needs an OpenSSH client.

## Install

1. **Copy this repo onto the phone** (`git clone` in Termux, or
   `adb push`) and open a root shell in it.

2. **Run the installer:**

   ```
   bash serverinator.sh
   ```

   It asks for the VPS address (`user@host`), a name for this phone, an
   SSH alias, whether the chroot's `/tmp` should live in RAM or on disk,
   and an optional domain. Every question also has a flag
   (`--vps`, `--device-name`, `--alias`, `--chroot-tmp tmpfs|disk`,
   `--domain`, `--acme-email`).

   > If `su` gives you a shell that can't find `bash`, call it by its
   > full path once, for example `/system_ext/bin/bash serverinator.sh`.
   > `find / -maxdepth 3 -name bash 2>/dev/null` shows where it is.

3. **Let it get into the VPS.** The phone makes its own SSH key for the
   VPS and installs it the easiest way that works: a key already on the
   phone, then a one-time password login. If neither works it offers
   three manual routes: an `adb` command from a computer, a `curl` over
   Wi-Fi, or typing the key into your provider's web console in short,
   checksummed chunks. Passwords are never stored, and login attempts are
   capped so fail2ban doesn't ban you. To do only this step, run
   `bash serverinator.sh --authorize-vps user@host`.

   The installer then sets up the chroot, the VPS side and the tunnel
   config, and finishes with a test connection.

4. **Reboot the phone.** The install only writes the autostart scripts;
   Magisk runs them at boot, along with the `si` command (see below).
   The tunnel usually comes up within seconds of the network.

5. **Check the tunnel.** On the phone, as root:

   ```
   si status    # this phone's side: supervisors, handshake, a ping to the VPS
   si verify    # end to end, run on the VPS
   ```

   `si verify` checks the WireGuard interface and handshake, the wstunnel
   service, a ping, and real SSH data through the tunnel. The last check
   matters because some networks let the handshake through but silently
   drop the data. On the VPS the same check is `si verify --device PHONE`.

6. **Set up your laptop and connect.** The VPS has a ready-made setup
   script for you. It installs a key and an SSH config entry with the
   phone's host key pinned:

   ```
   scp your-vps:/etc/wireguard/serverinator/ssh/client-setup-owner-PHONE.sh .
   bash client-setup-owner-PHONE.sh
   ssh PHONE-ALIAS
   ```

   On Windows, use the PowerShell version next to it:

   ```
   scp your-vps:/etc/wireguard/serverinator/ssh/client-setup-owner-PHONE.ps1 .
   powershell -ExecutionPolicy Bypass -File .\client-setup-owner-PHONE.ps1
   ```

The commands above and below assume you log in to the VPS as root. With a
sudo user, fetch files with `ssh your-vps 'sudo cat FILE' > FILE` instead
of `scp`; `si` on the VPS uses sudo by itself. At the end of the install
the installer prints the exact commands for your setup, so you can copy
them from there.

## The si command

The installer sets up `si`, one short command for everyday tasks, in three
places. It's there before the rest of the install starts, so it also works
when a later step fails. `si help` lists what works where.

| Where | How you get there | What it does |
|---|---|---|
| Phone (Android side) | `su` in Termux, or `adb shell su` | everything: `si status`, `si logs`, `si setup`, `si set-domain`, `si export-identity`, `si uninstall`, plus the VPS commands below, which it runs on the VPS for you |
| Phone (inside the chroot) | `ssh PHONE-ALIAS` | `si status` |
| VPS | any root or sudo login | `si verify`, `si devices`, `si add-client`, guests, `si uninstall` |

On the phone `si` appears after the first reboot (a small Magisk module
puts it in `/system/bin`), and needs root: `su -c 'si status'`. It uses a
copy of the scripts in `/data/adb/serverinator/bin`, so the folder you ran
the installer from can go. The phone remembers its VPS and its name, so
`si setup` re-runs the installer without asking for them again, and
`si add-client LABEL` on the phone adds the client for this phone.

`si logs [NAME] [-n LINES]` shows the last lines of the tunnel's logs
(wstunnel, wireguard, sshd). Every `si` command is a shortcut: the long
flags of `serverinator.sh`, `core-phone.sh` and `core-vps.sh` work as
before, and `si vps --any-flag` passes a flag straight to `core-vps.sh`.

## Managing access

These run on the VPS as written, or on the phone with the same `si`
command (it fills in `--device` for this phone).

### People and devices with full access (clients)

Each client gets its own key, which you can revoke on its own. A client
has the same root access to the phone as you do.

```
si add-client LABEL       # writes client-setup-LABEL-PHONE.sh and .ps1
si revoke-client LABEL
si clients
```

Hand the generated setup script to that person, and they run it as in
step 6. The tunnel must be up when you add a client.

### Guests: shared folders only

A guest gets files only: no shell, and only the folders you choose, each
read-only or read-write. They connect with an SFTP app (FileZilla, WinSCP,
an Android SFTP client) to the VPS's normal SSH port as user
`serverinator-files`, using a key file. The VPS forwards them to the
phone, so no new port is opened.

```
si add-guest anna                        # asks for folders (on the VPS)
si add-guest anna --folder photos        # /srv/files/photos on the phone
si add-guest anna --folder /root/music:ro
si add-guest anna --pubkey anna.pub      # use the guest's own ed25519 key
si guest-access anna --folder photos     # replaces anna's folder list
si revoke-guest anna                     # her files stay on the phone
si guests                                # includes folder sizes
si sync-guests                           # re-create guests after a phone reset
```

`si add-guest` prints what to type into the app and where the guest's key
file is. Fetch that key with your own admin login: a client key can only
jump through to the phone, not read files on the VPS.

### Several phones on one VPS

Run the installer on each phone with a different name. Each phone gets
its own tunnel address, clients and guests. With more than one phone,
add `--device PHONE` to the client, guest and `verify` commands on the
VPS (on a phone, `si` adds its own).

```
si devices
si remove-device PHONE
```

## Domain and a real certificate

By default the tunnel uses a self-signed certificate and the VPS's IP
address. If a domain or subdomain has a DNS A record pointing at the
VPS, give it to the installer (at the question, or with
`--domain vps.example.com [--acme-email you@example.com]`). The VPS then
gets a Let's Encrypt certificate and renews it automatically, the phone
connects by name, and client scripts jump through the domain.

Let's Encrypt checks the domain on port 80. If a web server running as
a systemd service (Caddy, nginx, ...) already uses that port, it is
stopped for the few seconds of each check and started again.

To switch an existing phone to a domain, or back, run on the phone:

```
si set-domain vps.example.com [--acme-email you@example.com]
si remove-domain
```

Other phones on the same VPS keep working by IP until you run the same
command on each. To use a certificate you already have, run this on the
VPS: `si --set-domain DOMAIN --tls-cert /abs/fullchain.pem --tls-key /abs/privkey.pem`.

## Moving to a new phone

Export the old phone's identity (WireGuard key, SSH host keys, its VPS
login key and extra authorized keys), import it on the new phone, then
run the installer there with the same VPS and phone name. The VPS and
all clients keep working without changes.

```
si export-identity /sdcard/si-identity.tar                          # old phone
bash core/core-phone.sh --import-identity /sdcard/si-identity.tar   # new phone, before the installer
```

The file contains private keys, so treat it like a password.

## Uninstall

On the phone, this removes the chroot, the autostart scripts and the `si`
command. The phone's WireGuard and SSH host keys are kept so a reinstall
keeps the same identity; `--purge` deletes them too.

```
si uninstall [--purge]
```

On the VPS, this removes ServerInator's services, config, client keys,
firewall rules and `si`, and leaves everything else alone:

```
ssh your-vps si uninstall
```

A VPS uninstall forgets the domain and the client keys. After installing
again, run `si set-domain DOMAIN` on the phone if you used one, and give
each client the new setup script (move its old `~/.ssh/si-ALIAS` key
aside first: the script keeps a key that already exists).

## Security model

- **The phone's sshd is only reachable through the tunnel.** It listens
  on the tunnel address only, and the installer refuses to continue if
  the effective sshd config says otherwise. It accepts keys only, no
  passwords.
- **Client keys can't open a shell on the VPS.** On the VPS each client
  key is limited to forwarding to the phone's SSH port
  (`restrict,port-forwarding,permitopen=...`), with a forced command that
  refuses a shell.
- **Guest keys can only reach their own files.** On the VPS a guest key
  runs one forced command, the hop to that guest's user on the phone.
  On the phone, guests are chrooted into a directory that holds only bind
  mounts of their folders, read-only is enforced by the mount, and the
  phone accepts a guest's key only from the VPS's tunnel address.
- **wstunnel isn't an open proxy.** The server runs with `--restrict-to`
  and only forwards to the local WireGuard port.
- **Host keys are pinned.** The phone's SSH host key is pinned on the VPS
  and in every client script, so connecting to the wrong machine fails
  instead of asking you to trust a new key.
- **Downloads are checked.** The Ubuntu base image and the `wstunnel`
  binary are checked against pinned SHA-256 hashes, and an interrupted
  rootfs extraction is detected and redone.
- **TLS verification is optional.** With a domain, the phone doesn't
  verify the tunnel certificate by default, because WireGuard already
  authenticates both ends. Set `SERVERINATOR_TLS_VERIFY=1` when installing
  to make it verify anyway.

What this does not protect against: anyone with root on the VPS can reach
the phone as root, and can read guest folders.

## Development and tests

```
bash tests/run_tests.sh
```

The test suite runs locally with no phone, VPS or network. It mocks the
chroot, systemd, SSH and certbot, and covers install and uninstall,
the generated boot scripts, clients, guests, several phones, VPS
authorization, domains, identity export and import, and the Windows
script (run under PowerShell only if `pwsh` is installed).
`SERVERINATOR_TEST_REAL_GUESTS=1` (as root, with `sshd` available) also
runs the guest chain end to end with two real sshd instances.

`dev-env.example.sh` sets up DEV mode (`SERVERINATOR_DEV=1`), which
points every path at `/tmp` so you can run the scripts on a normal Linux
machine without touching real system state. `tools/collect-tunnel-diag.sh`
captures read-only tunnel diagnostics from a laptop while a problem is
happening.

Repository layout:

```
serverinator.sh        installer, run on the phone; drives both sides
core/core-phone.sh     phone side: chroot, keys, sshd, Magisk scripts
core/core-vps.sh       VPS side: WireGuard, wstunnel, clients, guests, domains
core/vps-auth.sh       getting the phone's key onto the VPS
core/guest-helper.sh   guest accounts and folders inside the chroot
core/si                the si command (phone, chroot and VPS)
core/lib.sh, motd.bash shared helpers and the login banner
tests/                 local test suite
tools/                 diagnostics
```

## Limitations and roadmap

- **No access level between guest and root.** A client is root on the
  phone and a guest gets files only. A normal shell user without root
  doesn't exist yet.
- **No alert when the tunnel goes down.** You find out by trying to
  connect, or with `si status`. A watchdog that sends a notification on a
  missed handshake would fix this.
- **Moving to a new VPS isn't a tested workflow.** Re-running the
  installer against a new VPS should work, since the phone's keys don't
  depend on the VPS, but it hasn't been tested end to end. With a
  domain, a move could become mostly a DNS change.
- **Boot scripts wait by polling.** Each script checks its dependency
  every couple of seconds up to a timeout and then carries on. It works,
  but it is not event-driven.
- **Install output is plain log lines.** A more visual progress display
  would help during a multi-minute install.

## License

[GPLv3](LICENSE). You can use, change and redistribute this, including
commercially, but any version you distribute must stay open under the
same license.
