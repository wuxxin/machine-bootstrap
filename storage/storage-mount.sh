#!/bin/bash
set -e

usage() {
    cat <<EOF
Usage:
    $0 --yes [--password-from-stdin] [--force]
EOF
    exit 1
}

self_path=$(dirname "$(readlink -e "$0")")
force="false"
password=""
chroot_cmd="chroot"
if which pamac &> /dev/null; then chroot_cmd="manjaro-chroot"; fi

if test "$1" != "--yes"; then usage; fi
shift
if test "$1" = "--password-from-stdin"; then
    password=$(cat -)
    shift
fi
if test "$1" = "--force"; then force=true; shift; fi

. "$self_path/bootstrap-library.sh"

if which cloud-init 2> /dev/null; then
    printf "waiting for cloud-init finish..."
    cloud-init status --wait || printf "exited with error: $?"
    printf "\n"
fi

echo "update sources, install $zfs_packages"
zfs_packages="$(get_zfs_packages)"
configure_nfs
install_packages --refresh $zfs_packages

activate_mdadm
create_crypttab
activate_luks "$password"
activate_lvm
activate_zfs_pools /mnt "$password" "$force"
mount_root /mnt $force
mount_boot /mnt $force
mount_efi /mnt
mount_data /mnt $force
if ! which pamac &> /dev/null; then
    mount_bind_mounts /mnt
fi

cat << EOF
mounting complete.
+ use "$chroot_cmd /mnt /bin/bash --login" to chroot into system
+ once returned from the chroot system, and storage is no longer used
  + use 'recovery-unmount.sh --yes' to unmount disks, then reboot
EOF
