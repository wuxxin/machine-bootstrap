#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")
force=false
what=all
password=""

if test "$1" != "--yes"; then
    cat <<EOF
Usage:
    $0 --yes [--only-raid-luks|--without-raid-luks] [--password-from-stdin] [--force]
EOF
    exit 1
fi
shift
if test "$1" = "--only-raid-luks"; then what=until_luks; shift; fi
if test "$1" = "--without-raid-luks"; then what=after_luks; shift; fi
if test "$1" = "--password-from-stdin"; then password=$(cat -); shift; fi
if test "$1" = "--force"; then force=true; shift; fi

. "$self_path/bootstrap-library.sh"

if which cloud-init > /dev/null; then
    printf "waiting for cloud-init finish..."
    cloud-init status --wait || printf "exited with error: $?"
    printf "\n"
fi

if test "$what" != "after_luks"; then
    configure_nfs
    zfs_packages="$(get_zfs_packages)"
    echo "update sources, install $zfs_packages"
    install_packages --refresh $zfs_packages
    activate_mdadm
    create_crypttab
    activate_luks "$password"
fi
if test "$what" = "until_luks"; then exit 0; fi

activate_lvm
mount_root /mnt $force
mount_boot /mnt $force
mount_efi /mnt
mount_data /mnt/mnt $force
mount_bind_mounts /mnt

cat << EOF
mounting complete.
+ use 'chroot /mnt /bin/bash --login' to chroot into system
+ once returned from the chroot system, and storage is no longer used
  + use 'recovery-unmount.sh --yes' to unmount disks, then reboot
EOF
