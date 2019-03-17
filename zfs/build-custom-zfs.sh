#!/bin/bash
set -eo pipefail
#set -x
self_path=$(dirname $(readlink -e "$0"))

if test "$1" = "" -o "$1" = "--help" -o "$1" = "-h"; then
    cat <<EOF
Usage: $0 basedir

basedir = directory to be used as basedir for compiling
successful run will put resulting packages in $basdir/zfsbuild/buildresult

EOF
    exit 1
fi

basedir=$1
shift
# create directories
mkdir -p "$basedir/zfsbuild"
cd "$basedir"

# setup cowbuilder
apt-get update
apt-get install cowbuilder ubuntu-dev-tools
if ! grep -q "disco" /usr/share/distro-info/ubuntu.csv; then
    echo "19.04,Disco Dingo,disco,2018-10-18,2019-04-18,2020-01-18" >> /usr/share/distro-info/ubuntu.csv
fi
cowbuilder create

# backport spl-linux
pull-lp-source spl-linux disco
backportpackage -B cowbuilder --dont-sign -b -w zfsbuild spl-linux*.dsc

# patch and backport zfs-linux
pull-lp-source zfs-linux disco
cd zfs-linux*
quilt import ../no-dops-snapdirs.patch
quilt push
current_version=$(head -1 debian/changelog | sed -r "s/[^(]+\(([^)]+)\).+/\1/g")
new_version=${current_version:0:-1}$(( ${current_version: -1} +1 ))nodrevalidate
changelogheader="enable overlayfs on zfs: debian/patches/no-d-revalidate.patch"
changelog=$(cat << EOF
cat << EOF
    - disable snapshot dir auto mount support (.zfs/snapshot directory)
    - disable code for 'rollback of a mounted filesystem to a snapshot'
      - this breaks zfs ability to rollback over a mounted active filesystem
      - do not attempt to rollback to a mounted filesystem
    - use at your own risk
EOF
)
debchange -v "$new_version" --distribution disco "enable overlayfs on zfs debian/patches/no-d-revalidate.patch"
sed -i -r "s#(.*$changelogheader)$#\1\n$changelog\n#g" debian/changelog
dpkg-source -b .
cd ..
backportpackage -B cowbuilder --dont-sign -b -w zfsbuild zfs-linux*nodrevalidate*.dsc

# generate local apt archive files
cd zfsbuild/buildresult
apt-ftparchive packages . > Packages
gzip -c < Packages > Packages.gz
apt-ftparchive release . > Release
gzip -c < Release > Release.gz
cd ../..

