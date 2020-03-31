#!/bin/bash
set -eo pipefail
set -x

self_path=$(dirname "$(readlink -e "$0")")
source=focal
dest="$(lsb_release -c -s)"
nobuild=false

usage() {
    cat <<EOF
Usage: $0 <basedir> [--source distro] [--dest distro]

basedir         = directory to be used as basedir for compiling
--source distro = defines the launch-pad branch to use, will default to "$source"
--dest   distro = build zfs for distribution codename eg. "bionic", default=running system ($dest)

successful run will put resulting packages in $basedir/build/buildresult

EOF
    exit 1
}


# parse args
if test "$1" = "" -o "$1" = "--help" -o "$1" = "-h"; then usage; fi
basedir=$1
shift
if test "$1" = "--source"; then source=$2; shift 2; fi
if test "$1" = "--dest"; then dest=$2; shift 2; fi
if test "$1" = "--nobuild"; then nobuild=true; shift; fi
BASEPATH="/var/cache/pbuilder/base-$dest.cow"

# setup builder
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
if ! grep -q "eoan" /usr/share/distro-info/ubuntu.csv; then
    echo "19.10,Eoan Ermine,eoan,2019-04-18,2019-10-17,2020-07-17" >>  /usr/share/distro-info/ubuntu.csv
fi
if ! grep -q "focal" /usr/share/distro-info/ubuntu.csv; then
    echo "20.04 LTS,Focal Fossa,focal,2019-10-17,2020-04-23,2025-04-23,2025-04-23,2030-04-23" >>  /usr/share/distro-info/ubuntu.csv
fi
if test "$nobuild" != "true"; then
    if test ! -e "$BASEPATH"; then
        cowbuilder --create --distribution "$dest" --basepath "$BASEPATH"
    else
        cowbuilder --update --basepath "$BASEPATH"
    fi
fi

# create build directories
mkdir -p "$basedir/build"
cd "$basedir"

# backport spl-linux (was merged into zfs-linux after disco)
if test "$source" = "disco"; then
    $(which python2) $(which pull-lp-source) spl-linux "$source"
    BASEPATH="$BASEPATH" backportpackage -B cowbuilder -d "$dest" --dont-sign -b -w build spl-linux*.dsc
fi

# patch and backport zfs-linux
$(which python2) $(which pull-lp-source) zfs-linux "$source"
cd $(find . -type d -name "zfs-linux-*" -print -quit)
quilt import $(find $self_path -name "*.patch" | sort -n)
quilt push
current_version=$(head -1 debian/changelog | sed -r "s/[^(]+\(([^)]+)\).+/\1/g")
new_version=${current_version:0:-1}$(( ${current_version: -1} +1 ))vpsfreecz
debchange -v "$new_version" --distribution "$dest" "enable overlayfs on zfs, enable namespace functionality, all pulled from vpsfreecz/zfs"
dpkg-source -b .
cd ..
if test "$nobuild" = "true"; then
    exit 0
fi
BASEPATH="$BASEPATH" backportpackage -B cowbuilder -d "$dest" --dont-sign -b -w build zfs-linux*vpsfreecz*.dsc

# generate local apt archive files
cd build/buildresult
apt-ftparchive packages . > Packages
gzip -c < Packages > Packages.gz
apt-ftparchive -o "APT::FTPArchive::Release::Origin=local" release . > Release
gzip -c < Release > Release.gz
cd ../..
