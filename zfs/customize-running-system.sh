#!/bin/bash
set -eo pipefail
set -x
self_path=$(dirname $(readlink -e "$0"))

# parse args
if test "$1" != "--yes"; then
    cat <<EOF
Usage: $0 --yes

build and install a custom zfs version for:
+ the running system
+ the initrd of the running system
+ the recovery squashfs

for activation a reboot is needed after execution.

EOF
    exit 1
fi
shift

echo "build-custom-zfs"
$self_path/build-custom-zfs.sh /tmp/zfs/basedir
custom_archive=/usr/local/lib/bootstrap-custom-archive
if test -e $custom_archive; then rm -rf $custom_archive; fi
mkdir -p $custom_archive
mv -t $custom_archive /tmp/zfs/basedir/zfsbuild/buildresult/*
rm -rf /tmp/zfs/basedir
cat > /etc/apt/sources.list.d/local-bootstrap-custom.list << EOF
deb [ trusted=yes ] file:$custom_archive ./
EOF
DEBIAN_FRONTEND=noninteractive apt-get update --yes

echo "install/upgrade packages in running system"
zfs_packages="spl-dkms zfs-dkms zfsutils-linux"
DEBIAN_FRONTEND=noninteractive apt-get install --upgrade --yes $zfs_packages

echo "updating recovery.squashfs"
/etc/recovery/udpate-recovery-squashfs.sh --host
