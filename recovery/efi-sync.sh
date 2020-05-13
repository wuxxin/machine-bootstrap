#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")

if test "$1" != "--yes"; then
    cat <<EOF
Usage: $0 --yes

sync files from /efi to /efi2 in case there is /efi2

+ rsync all except EFI/Ubuntu/grub.cfg, grub/grub.cfg, grub/grubenv
+ copy and modify EFI/Ubuntu/grub.cfg, grub/grub.cfg for fsuuid of efi2
+ dd (binary duplicate 1kb) grub/grubenv
EOF
    exit 1
fi
shift

if test -e "$self_path/bootstrap-library.sh"; then
    . "$self_path/bootstrap-library.sh"
elif test -e "$self_path/../bootstrap-library.sh"; then
    . "$self_path/../bootstrap-library.sh"
else
    echo "Error: bootstrap-library.sh not found!"
    usage
fi

if test "$(by_partlabel EFI | wc -w)" = "2"; then
    efi_sync /efi /efi2
else
    echo "no second EFI partition found, doing nothing"
fi
