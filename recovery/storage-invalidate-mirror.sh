#!/bin/sh
set -e

cat <<"EOF"
storage-invalidate-mirror.sh --invalidate diskserial

EOF

exit 1
