#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")

. "$self_path/bootstrap-library.sh"

if test "$1" != "--yes"; then
    cat <<EOF
Usage: $0 --yes

syncs efi with efi2 in case there is more than one efi partition

EOF
    exit 1
fi
shift

cd /
