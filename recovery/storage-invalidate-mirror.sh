#!/bin/bash
set -e

cat <<"EOF"
storage-invalidate-mirror.sh --invalidate diskserial

EOF

if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then
    echo "error: looks like we are inside a chroot, refusing to continue"
    exit 1
fi

exit 1
