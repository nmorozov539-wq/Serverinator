# ServerInator — example DEV environment (source, do not execute).
# DEV mode must not touch real system state.

export SERVERINATOR_DEV=1

# ── Phone side ────────────────────────────────
# Use throwaway paths so nothing is written under /data.
export SERVERINATOR_ARCH_OVERRIDE=aarch64
export SERVERINATOR_CHROOT=/tmp/serverinator-root
export SERVERINATOR_SERVICE_D=/tmp/serverinator-service.d
export SERVERINATOR_DEVICE_NAME=dev-phone
# SSH access to the phone is enabled by default. Disable with --no-ssh or:
# export SERVERINATOR_NO_SSH=1
# Persisted phone SSH host keys (survives chroot rebuilds):
export SERVERINATOR_SSH_HOSTKEY_DIR=/tmp/serverinator-ssh-hostkeys

# ── VPS side ──────────────────────────────────
export SERVERINATOR_VPS_IP=127.0.0.1
# VPS DEV defaults everything under ${TMPDIR:-/tmp}/serverinator-dev.
# Override individually only if needed:
# export SERVERINATOR_DEV_ROOT=/tmp/serverinator-dev
# export SERVERINATOR_WG_DIR=/tmp/serverinator-dev/etc/wireguard
# export SERVERINATOR_SYSTEMD_DIR=/tmp/serverinator-dev/etc/systemd/system
# export SERVERINATOR_WSTUNNEL_BIN=/tmp/serverinator-dev/usr/local/bin/wstunnel
# export SERVERINATOR_BACK_HANDOFF_PATH=/tmp/serverinator-dev/back-handoff.json
# SSH client-key handling during VPS setup:
# export SERVERINATOR_SSH_AUTH_KEYS_FILE=/path/to/authorized_keys
# export SERVERINATOR_SSH_CLIENT_KEY=existing   # or: new
# export SERVERINATOR_SSH_ALIAS=serverinated
# export SERVERINATOR_SSH_KEY_DIR=/tmp/serverinator-dev/etc/wireguard/ssh
