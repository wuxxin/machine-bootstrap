#!/bin/bash
set -e

usage() {
    cat <<EOF
Usage:
    $0 --yes [--password-from-stdin] [--no-pkg-install] [--force]

--password-from-stdin
    read password from stdin and use it to unlock encrypted storage,
    if not set, script will prompt for password if needed
--no-pkg-install
    does not update/install storage related packages before trying to mount storage
--force
    use force paraemter for activate_zfs_pools and mount_(root|boot|efi|data)
EOF
    exit 1
}

self_path=$(dirname "$(readlink -e "$0")")
password=""
pkg_install="true"
force="false"
chroot_cmd="chroot"
if which pamac &>/dev/null; then chroot_cmd="manjaro-chroot"; fi

if test "$1" != "--yes"; then usage; fi
shift
if test "$1" = "--password-from-stdin"; then
    password=$(cat -)
    shift
fi
if test "$1" = "--no-pkg-install"; then
    pkg_install="false"
    shift
fi
if test "$1" = "--force"; then
    force=true
    shift
fi

. "$self_path/bootstrap-library.sh"

if mountpoint -q "/mnt"; then
    echo "error: /mnt already in use as mountpoint, abort"
    exit 1
fi

if which cloud-init 2>/dev/null; then
    printf "waiting for cloud-init finish..."
    cloud-init status --wait || printf "exited with error: $?"
    printf "\n"
fi

if test "$pkg_install" = "true"; then
    zfs_packages="$(get_zfs_packages)"
    echo "update sources, install $zfs_packages"
    install_packages --refresh $zfs_packages
fi

activate_mdadm
create_crypttab
activate_luks "$password"
activate_lvm
activate_zfs_pools /mnt "$password" "$force"
mount_root /mnt $force
mount_boot /mnt $force
mount_efi /mnt
mount_data /mnt $force
if ! which pamac &>/dev/null; then
    mount_bind_mounts /mnt
fi

cat <<EOF
mounting complete. use:
$chroot_cmd /mnt /bin/bash --login
to chroot into system. once returned from the chroot system, and storage is no
longer used use: 'recovery-unmount.sh --yes' to unmount disks, then reboot
EOF
