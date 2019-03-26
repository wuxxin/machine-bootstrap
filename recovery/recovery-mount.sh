#!/bin/sh
set -e

usage() {
    cat <<EOF
Usage: $0 --yes [--force] [--from-rpool|--until-rpool]
EOF
    exit 1
}

force=no
what=all
if test "$1" != "--yes"; then usage; fi
shift
if test "$1" = "--force"; then force=yes; shift; fi
if test "$1" = "--from-rpool"; then what=from_rpool; shift; fi
if test "$1" = "--until-rpool"; then what=until_rpool; shift; fi

EFI=/dev/disk/by-partlabel/EFI
BOOT=/dev/disk/by-label/boot
MDADM_BOOT_ARRAY=$(for i in 1 2; do echo "/dev/disk/by-partlabel/MDADMBOOT$i "; done)
LUKSROOT=/dev/disk/by-partlabel/LUKSROOT
LUKSSWAP=/dev/disk/by-partlabel/LUKSSWAP
MDADM_SWAP_ARRAY="${LUKSSWAP}1 ${LUKSSWAP}2"

if which cloud-init > /dev/null; then
    printf "waiting for cloud-init finish..."
    cloud-init status --wait
fi

if test "$what" != "from_rpool"; then
    zfs_packages="spl-dkms zfs-dkms zfsutils-linux"
    echo "update sources, install $zfs_packages"
    DEBIAN_FRONTEND=noninteractive apt-get update --yes
    DEBIAN_FRONTEND=noninteractive apt-get install --yes $zfs_packages

    cryptdisks=""

    echo "create crypttab for luks-root*"
    if test -e "$LUKSROOT"; then
        cat > /etc/crypttab << EOF
luks-root UUID=$(blkid -s UUID -o value $LUKSROOT) none luks,discard
EOF
        cryptdisks="luks-root"
    else
        cat > /etc/crypttab << EOF
luks-root1 UUID=$(blkid -s UUID -o value ${LUKSROOT}1) none luks,discard
luks-root2 UUID=$(blkid -s UUID -o value ${LUKSROOT}2) none luks,discard
EOF
        cryptdisks="luks-root1 luks-root2"
    fi

    if test -e $LUKSSWAP; then
        echo "create crypttab for luks-swap"
        cat >> /etc/crypttab << EOF
luks-swap UUID=$(blkid -s UUID -o value $LUKSSWAP) none luks,discard
EOF
        cryptdisks="$cryptdisks luks-swap"
    elif test -e "${LUKSSWAP}1" -a -e "${LUKSSWAP}2"; then
        echo "create crypttab for luks-swap*"
        cat >> /etc/crypttab << EOF
luks-swap UUID=$(blkid -s UUID -o value /dev/md/mdadm-swap) none luks,discard
EOF
        cryptdisks="$cryptdisks luks-swap"
        echo "activate mdadm swap partition"
        mdadm --assemble /dev/md/mdadm-swap $MDADM_SWAP_ARRAY
    fi

    if test ! -e $BOOT; then
        echo "activate mdadm boot partition"
        mdadm --assemble /dev/md/mdadm-boot $MDADM_BOOT_ARRAY
    fi

    echo "start cryptdisks $cryptdisks"
    for i in $cryptdisks; do 
        cryptdisks_start $i
    done
fi

if test "$what" = "until_rpool"; then exit 0; fi

echo "mount zfs rpool"
zpool export -a
import_opts="-N -R /mnt"
if test "$force" = "yes"; then 
    import_opts="$import_opts -f"
fi
zpool import $import_opts rpool

echo "mount root"
zfs mount rpool/ROOT/ubuntu

echo "mount zfs volumes"
zfs mount -a || echo "Warning: could not mount all zfs volumes!"

echo "mount legacy mounts"
cat /mnt/etc/recovery/legacy.fstab | \
    sed -r "s/^([^ ]+)( +)([^ ]+)( +)(.+)/\1\2\/mnt\3\4\5/g" > /tmp/legacy.fstab
mount -a -T /tmp/legacy.fstab || echo "Warning: could not mount all legacy volumes!"

echo "mount boot"
mkdir -p /mnt/boot
mount $BOOT /mnt/boot

echo "mount efi*"
mkdir -p /mnt/boot/efi
if test -e "$EFI"; then
    mount $EFI /mnt/boot/efi
else
    mkdir -p /mnt/boot/efi2
    mount ${EFI}1 /mnt/boot/efi
    mount ${EFI}2 /mnt/boot/efi2
fi

echo "mount dev proc sys run"
for i in dev proc sys run; do mount --rbind /$i /mnt/$i; done

echo "chroot to system, use exit to exit"
chroot /mnt /bin/bash --login

echo "exited from chroot, to chroot again type 'chroot /mnt /bin/bash --login'"
echo "when finished, use recovery-unmount.sh to unmount disks before reboot"
echo "force reboot with systemctl reboot --force if reboot hangs"