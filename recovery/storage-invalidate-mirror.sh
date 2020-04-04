#!/bin/bash
set -e

cat <<"EOF"
storage-invalidate-mirror.sh --invalidate diskserial

+ disconnect rpool
  + remove disk from rpool
+ disconnect swap
+ disconnect luks *
+ disconnect mdadm *
+ update initramfs ?

EOF


exit 1
