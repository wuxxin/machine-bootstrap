#!/bin/sh
set -e
cd /

echo "unmount bind mounts"
for i in run sys proc dev; do
    if mountpoint -q "/mnt/$i"; then umount -lf "/mnt/$i"; fi
done

echo "unmount legacy"
cat /mnt/etc/recovery/legacy.fstab | \
    sed -r "s/^([^ ]+)( +)([^ ]+)( +)(.+)/\1\2\/mnt\3\4\5/g" > /tmp/legacy.fstab
umount -a -T /tmp/legacy.fstab || echo "Warning: could not unmount all legacy volumes!"

echo "unmount boot, efi*"
for i in boot/efi boot/efi2 boot; do
    if mountpoint -q "/mnt/$i"; then umount -lf "/mnt/$i"; fi
done

echo "swap off"
swapoff -a

sleep 1
echo "export rpool (unmount pool)"
zpool export rpool
