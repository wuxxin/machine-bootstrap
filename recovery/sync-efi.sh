#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")

if test "$1" != "--yes"; then
    cat <<EOF
Usage: $0 --yes

syncs efi with efi2 in case there is more than one efi partition

EOF
    exit 1
fi
shift

. "$self_path/bootstrap-library.sh"

if test "$(by_partlabel EFI | wc -w)" = "2"; then
    sync_efi /efi /efi2
else
    echo "no second EFI partition found, doing nothing"
fi
