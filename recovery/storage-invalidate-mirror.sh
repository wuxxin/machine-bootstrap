#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")

cat <<"EOF"
storage-invalidate-mirror.sh --invalidate diskserial

+ disconnect rpool
  + remove disk from rpool
+ disconnect swap
+ disconnect luks *
+ disconnect mdadm *
+ update initramfs ?

EOF

. "$self_path/bootstrap-library.sh"

exit 1
