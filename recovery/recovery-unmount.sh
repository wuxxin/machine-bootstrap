#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")

if test "$1" != "--yes"; then
    cat <<EOF
Usage: $0 --yes
EOF
    exit 1
fi
shift

. "$self_path/bootstrap-library.sh"

cd /
echo "swap off"; swapoff -a || true
unmount_bind_mounts /mnt
unmount_data /mnt
unmount_efi /mnt
unmount_boot /mnt
sleep 1
unmount_root /mnt

deactivate_crypt
deactivate_raid

echo "unmounted everything, it should be safe now to reboot"
