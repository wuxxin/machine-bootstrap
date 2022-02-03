#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")

if test "$1" != "--yes"; then
    cat <<EOF
Usage: $0 --yes [--ignore-fail]
FIXME  implement ignore-fail

EOF
    exit 1
fi
shift

. "$self_path/bootstrap-library.sh"

if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then
    echo "error: looks like we are inside a chroot, refusing to continue as a safety measure."
    echo "  try 'exit' to exit from the chroot first, before executing $(basename $0)."
    exit 1
fi

cd /
echo "swap off"; swapoff -a || true
if ! which pamac &> /dev/null; then
    unmount_bind_mounts /mnt
fi
unmount_data /mnt
unmount_efi /mnt
unmount_boot /mnt
unmount_root /mnt
deactivate_zfs_pools
deactivate_lvm
deactivate_luks
deactivate_mdadm

echo "unmounted everything, it should be safe now to reboot"
