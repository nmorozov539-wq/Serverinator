#!/system/bin/sh
# ServerInator — mount filesystems into chroot
# Managed by ServerInator Core, do not edit manually

CHROOT="@CHROOT@"

for fs in proc sys dev dev/pts; do
    mountpoint -q "${CHROOT}/${fs}" || mount --bind "/${fs}" "${CHROOT}/${fs}"
done
@CHROOT_TMP_MOUNT_LINES@
