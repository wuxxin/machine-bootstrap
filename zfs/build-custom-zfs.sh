#!/bin/bash
set -eo pipefail
set -x
self_path=$(dirname $(readlink -e "$0"))

# parse args
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
need_install=false
for i in pull-lp-source cowbuilder backportpackage quilt debchange apt-ftparchive; do
    if ! which $i > /dev/null; then need_install=true; break; fi
done
if $need_install; then
    DEBIAN_FRONTEND=noninteractive apt-get update --yes
    DEBIAN_FRONTEND=noninteractive apt-get install --yes cowbuilder ubuntu-dev-tools
fi
if ! grep -q "disco" /usr/share/distro-info/ubuntu.csv; then
    echo "19.04,Disco Dingo,disco,2018-10-18,2019-04-18,2020-01-18" >> /usr/share/distro-info/ubuntu.csv
fi
if test ! -e /var/cache/pbuilder/base.cow; then
    cowbuilder --create
else
    cowbuilder --update
fi

# backport spl-linux
pull-lp-source spl-linux disco
backportpackage -B cowbuilder --dont-sign -b -w zfsbuild spl-linux*.dsc

# patch and backport zfs-linux
pull-lp-source zfs-linux disco
cd zfs-linux-*
quilt import "$self_path/no-dops-snapdirs.patch"
quilt push
current_version=$(head -1 debian/changelog | sed -r "s/[^(]+\(([^)]+)\).+/\1/g")
new_version=${current_version:0:-1}$(( ${current_version: -1} +1 ))nodrevalidate
debchange -v "$new_version" --distribution disco "enable overlayfs on zfs: no-d-revalidate.patch"
dpkg-source -b .
cd ..
backportpackage -B cowbuilder --dont-sign -b -w zfsbuild zfs-linux*nodrevalidate*.dsc

# generate local apt archive files
cd zfsbuild/buildresult
apt-ftparchive packages . > Packages
gzip -c < Packages > Packages.gz
apt-ftparchive -o "APT::FTPArchive::Release::Origin=local" release . > Release
gzip -c < Release > Release.gz
cd ../..
