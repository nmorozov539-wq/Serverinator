# ServerInator

[![tests](https://github.com/nmorozov539-wq/Serverinator/actions/workflows/tests.yml/badge.svg)](https://github.com/nmorozov539-wq/Serverinator/actions/workflows/tests.yml)

ServerInator turns a rooted Android phone into an always-on Linux server
that you reach over SSH through a VPS you own.

The phone gets a Debian or Ubuntu userspace (a chroot) and dials out to
the VPS. Nothing is opened on the phone or your router, and no third-party
relay is involved. The link between them is WireGuard carried inside a
WebSocket-over-TLS connection, so to a network in between it looks like
ordinary HTTPS. That matters on networks that block plain WireGuard.

**Status: early.** Tested on a Redmi Note 9 Pro and a Redmi Note 11 Pro
(Android 16), with a Debian/Ubuntu VPS.

## How it works

```
your laptop ──SSH (ProxyJump)──▶ VPS ──WireGuard──▶ phone: sshd in a chroot
                                  ▲                  │
                                  └── wstunnel (TLS) ┘
                                   the phone dials out
```

### Quick start

On the phone, in Termux:

```
pkg install git
git clone https://github.com/nmorozov539-wq/Serverinator
cd Serverinator
su    # then:
bash serverinator.sh
```

Answer its questions (your VPS as `user@host`, a name for the phone). At
the end it prints one command to run on your computer, which sets up
`ssh PHONE-ALIAS`. The details are under [Install](#install).

- **Chroot on the phone.** A Linux userspace running on the phone's own
  kernel. No custom ROM needed. You don't pick the distribution: it is
  Debian when `debootstrap` is on the phone, and the Ubuntu 24.04 base
  otherwise.
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

1. **Copy this repo onto the phone** and open a root shell in it. In
   Termux:

   ```
   pkg install git
   git clone https://github.com/nmorozov539-wq/Serverinator
   cd Serverinator
   su
   ```

   (`adb push` of the folder works too.)

2. **Run the installer.** It first checks the phone (Magisk, CPU type,
   free space, RAM, and whether the kernel can make a WireGuard
   interface) and stops with the reason if something is missing:

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
   config, finishes with a test connection, and starts the tunnel. No
   reboot is needed; after one, Magisk starts it by itself.

4. **The `si` command** (see below) appears in `/system/bin` after the
   first reboot. Until then, run it as `sh /data/adb/modules/serverinator/system/bin/si`.

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

   On Windows, fetch the same script and let
   [`tools/client-setup-windows.ps1`](tools/client-setup-windows.ps1) from
   this repo apply it with Windows' built-in OpenSSH. The tool hasn't run
   on a real Windows machine yet, so treat it as untested:

   ```
   scp your-vps:/etc/wireguard/serverinator/ssh/client-setup-owner-PHONE.sh .
   powershell -ExecutionPolicy Bypass -File client-setup-windows.ps1 client-setup-owner-PHONE.sh
   ```

The commands above and below assume you log in to the VPS as root. With a
sudo user, fetch files with `ssh your-vps 'sudo cat FILE' > FILE` instead
of `scp`; `si` on the VPS uses sudo by itself. At the end of the install
the installer prints the exact commands for your setup, so you can copy
them from there.

## Freeing up the phone

A phone running as a server has Android's own apps and services running
too. Turning off the ones you don't need frees RAM, saves battery and
keeps the phone cooler. ServerInator doesn't do this for you: phones
differ too much, and a wrong choice can break the phone. You can do it by
hand, reversibly.

- **Find the heavy ones.** Settings → Battery shows what uses power;
  `dumpsys meminfo` (as root) lists apps by memory, largest first.
  `pm list packages -3` lists apps you installed, and `pm list packages`
  everything.
- **Turn one off:** `pm disable-user --user 0 PACKAGE`. It stops running
  and disappears from the launcher, but stays installed.
- **Undo it:** `pm enable PACKAGE`.

Leave system-critical packages alone: anything named `android`,
`com.android.systemui`, `com.android.phone`, the launcher, Settings,
Google Play services if other apps need it, and Magisk. If the phone
misbehaves after a change, enable the last package again. A factory reset
undoes everything, including ServerInator.

## The si command

The installer sets up `si`, one short command for everyday tasks, in three
places. It's there before the rest of the install starts, so it also works
when a later step fails. `si help` lists what works where.

| Where | How you get there | What it does |
|---|---|---|
| Phone (Android side) | `su` in Termux, or `adb shell su` | everything: `si status`, `si logs`, `si start/stop/restart`, `si setup`, `si set-domain`, `si export-identity`, `si report`, `si uninstall`, plus the VPS commands below, which it runs on the VPS for you |
| Phone (inside the chroot) | `ssh PHONE-ALIAS` | `si status` |
| VPS | any root or sudo login | `si verify`, `si devices`, `si add-client`, guests, `si uninstall` |

On the phone `si` appears after the first reboot (a small Magisk module
puts it in `/system/bin`), and needs root: `su -c 'si status'`. It uses a
copy of the scripts in `/data/adb/serverinator/bin`, so the folder you ran
the installer from can go. The phone remembers its VPS and its name, so
`si setup` re-runs the installer without asking for them again, and
`si add-client LABEL` on the phone adds the client for this phone.

`si logs [NAME] [-n LINES]` shows the last lines of the tunnel's logs
(wstunnel, wireguard, sshd). `si restart [NAME]` (also `start`, `stop`)
restarts the tunnel's services without a reboot. `si status` and the login
banner also show the battery and warn about heat, a battery kept at 100%
while plugged in, and a nearly full disk. `si report` prints one line about
the phone and the install to paste into a bug report; `si version` the
release. Every `si` command is a shortcut: the long
flags of `serverinator.sh`, `core-phone.sh` and `core-vps.sh` work as
before, and `si vps --any-flag` passes a flag straight to `core-vps.sh`.

## Managing access

These run on the VPS as written, or on the phone with the same `si`
command (it fills in `--device` for this phone).

### People and devices with full access (clients)

Each device gets a key of its own, which you can revoke on its own. A
client has the same root access to the phone as you do. The private key is
made on the device and never leaves it:

```
si add-client laptop          # a pairing script, with no key in it
```

On the laptop, fetch and run that script (the command is printed; on
Windows, run it through `tools/client-setup-windows.ps1`, which is
untested). It makes the laptop's key, adds
`ssh PHONE-ALIAS-laptop` to its ssh config, pins the host keys, and prints
the command that approves it:

```
si add-client laptop --pubkey 'ssh-ed25519 AAAA...'
```

Until then the laptop is refused. Once approved, the script only works on
the device that holds that key, so a copy of it grants nothing.

```
si add-client LABEL --pubkey KEY|FILE    # a key you already have
si add-client LABEL --generate-key       # the VPS makes the key instead (see below)
si add-client LABEL ... --expires 30d    # or a date: 2026-12-31
si client-script LABEL                   # print a setup script again
si revoke-client LABEL                   # works with the phone offline too
si clients                               # with each key's last login and address
```

With `--generate-key` the setup script carries the private key. It can be
fetched once (`si client-script`); after that the VPS deletes the private
key. The owner key the installer makes works the same way and never
expires. The tunnel must be up when you add or revoke a client.

### Guests

A guest is a key you add, in one of two modes:

- **Files only:** one folder on the phone, read-only or read-write, and
  nothing else. The guest connects with an SFTP app (FileZilla, WinSCP,
  an Android SFTP client) to the VPS's normal SSH port as user
  `serverinator-files`, using a key file. The VPS forwards them to the
  phone, where they are locked into that folder.
- **Shell user:** a normal Linux user in the phone's chroot, with a home
  folder and a shell. They see the whole system, limited by ordinary file
  permissions, with no root and no sudo. They get a setup script like a
  client's, and connect with `ssh` through the VPS.

Either way no new port is opened, and guest keys don't expire.

```
si add-guest anna --folder photos        # /srv/files/photos on the phone, read-write
si add-guest anna --folder /root/music:ro
si add-guest anna                        # asks which mode and folder (on the VPS)
si add-guest bob --shell                 # a shell user with a home folder
si add-guest bob --shell --pubkey bob.pub   # use the guest's own ed25519 key (either mode)
si guests                                # with folder sizes
si revoke-guest anna                     # the shared folder and its files stay
si sync-guests                           # re-create guests after a phone reset
```

To change a guest's folder or mode, revoke it and add it again.
`si add-guest` prints what to type into the app and where the key file is
(files only), or where the setup script is (shell user). Fetch it with your
own admin login: a client key can only jump through to the phone, not read
files on the VPS. Revoking a shell user deletes its home folder.

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
command, and stops and removes add-ons that run in the chroot. The phone's
WireGuard and SSH host keys are kept so a reinstall keeps the same
identity; `--purge` deletes them too. It lists what it will delete (the
chroot with its size) and asks first; `--yes` answers for scripts.

```
si uninstall [--purge] [--yes]
```

On the VPS, this removes ServerInator's services, config, client keys,
firewall rules and `si`, and leaves everything else alone:

```
ssh your-vps si uninstall
```

A VPS uninstall forgets the domain and the client keys. After installing
again, run `si set-domain DOMAIN` on the phone if you used one, and give
each client the new setup script. It moves the client's old
`~/.ssh/si-ALIAS` key aside (to `si-ALIAS.old-DATE`) and installs the new one.

## Security model

- **The phone's sshd is only reachable through the tunnel.** It listens
  on the tunnel address only, and the installer refuses to continue if
  the effective sshd config says otherwise. It accepts keys only, no
  passwords.
- **Client keys can't open a shell on the VPS.** On the VPS each client
  key is limited to forwarding to the phone's SSH port
  (`restrict,port-forwarding,permitopen=...`), with a forced command that
  refuses a shell.
- **Files-only guests can only reach their folder.** On the VPS such a
  key runs one forced command, the hop to that guest's user on the phone.
  On the phone, the guest is chrooted into a directory that holds only a
  bind mount of the folder, read-only is enforced by the mount, and the
  phone accepts the hop only from the VPS's tunnel address.
- **Shell guests are ordinary users.** On the VPS their key can only
  forward to the phone's SSH port, like a client's. On the phone they are
  normal accounts with no root or sudo, the phone accepts their key only
  from the VPS's tunnel address, and only the key you added logs them in.
  They can read whatever ordinary permissions allow, so keep private files
  out of world-readable places.
- **wstunnel isn't an open proxy, and runs locked down.** The server runs
  with `--restrict-to` and only forwards to the local WireGuard port. It
  runs as a throwaway systemd user with no privileges in a tight sandbox,
  and only answers a random path made at install (phones get it during
  setup), so a scanner can't tell what it is.
- **Private keys stay on their devices.** Client keys are made on the
  client by default, and the VPS keeps only public keys once a generated
  key has been handed out.
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

**The VPS must be trusted.** Anyone with root on the VPS can add their own
key to the phone (it has a key for exactly that, used by `si add-client`),
reach the phone as root, and read guest folders and home folders. Pick a VPS provider and
an admin login you trust, keep its SSH locked down, and treat a VPS you no
longer control as a compromised phone: reinstall with `--purge`.

## Development and tests

```
bash tests/run_tests.sh
```

The test suite runs locally with no phone, VPS or network. It mocks the
chroot, systemd, SSH and certbot, and covers install and uninstall,
the generated boot scripts, clients, guests, several phones, VPS
authorization, domains, identity export and import, and the Windows
tool (run under PowerShell only if `pwsh` is installed).
`SERVERINATOR_TEST_REAL_GUESTS=1` (as root, with `sshd` available) also
runs both guest modes end to end with two real sshd instances. CI runs
the suite, as a normal user and as root, and `shellcheck` on every push.

`dev-env.example.sh` sets up DEV mode (`SERVERINATOR_DEV=1`), which
points every path at `/tmp` so you can run the scripts on a normal Linux
machine without touching real system state. `tools/collect-tunnel-diag.sh`
captures read-only tunnel diagnostics from a laptop while a problem is
happening.

Repository layout:

```
serverinator.sh        installer, run on the phone; drives both sides
core/core-phone.sh     phone side: settings and the install steps, in order
core/phone/            ...one file per feature: chroot, tunnel, sshd, guests, ...
core/core-vps.sh       VPS side: settings, flags and the setup steps
core/vps/              ...one file per feature: wireguard, wstunnel, tls, clients, guests, ...
core/templates/        the files the scripts write (Magisk scripts, sshd and
                       systemd config, the client setup script), with @MARKERS@
core/vps-auth.sh       getting the phone's key onto the VPS
core/guest-helper.sh   guest accounts and folders inside the chroot
core/si                the si command (phone, chroot and VPS)
core/lib.sh, motd.bash shared helpers and settings, and the login banner
tests/                 local test suite (tests/fakes/ stands in for wg and downloads)
tools/                 diagnostics, and the Windows client setup
```

## Limitations and roadmap

- **No alert when the tunnel goes down, by design.** The phone reconnects
  by itself when WireGuard goes 5 minutes without a handshake, or when it
  moves between mobile data and Wi-Fi, but ServerInator doesn't depend on
  an outside service to notify you; `si status` shows the state.
- **Moving to a new VPS isn't a tested workflow yet (later).** Re-running
  the installer against a new VPS should work, since the phone's keys
  don't depend on the VPS, but it hasn't been tested end to end. With a
  domain, a move could become mostly a DNS change.
- **Boot scripts wait by polling (later).** Each script checks its
  dependency every couple of seconds up to a timeout and then carries on.
  It works, but it is not event-driven.
- **The Windows client setup is untested.** `tools/client-setup-windows.ps1`
  has only run under PowerShell on Linux so far.

## License

[GPLv3](LICENSE). You can use, change and redistribute this, including
commercially, but any version you distribute must stay open under the
same license.
