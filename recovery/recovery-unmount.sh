#!/bin/sh
set -e
cd /

echo "unmount bind mounts"
for i in run sys proc dev; do
    if mountpoint -q "/mnt/$i"; then umount -lf "/mnt/$i"; fi
done

echo "unmount legacy"
for mountname in $(cat /mnt/etc/recovery/legacy.fstab | \
    sed -r "s/^([^ ]+)( +)([^ ]+)( +)(.+)/\/mnt\3/g" | sort -r); do
    umount -lf "$mountname" || echo "Warning: could not unmount legacy volume $mountname !"
done

echo "unmount boot, efi*"
for i in boot/efi boot/efi2 boot; do
    if mountpoint -q "/mnt/$i"; then umount -lf "/mnt/$i"; fi
done

echo "swap off"
swapoff -a || true

sleep 1
echo "export rpool (unmount pool)"
zpool export rpool

echo "FIXME: force reboot with systemctl reboot --force if reboot hangs"
