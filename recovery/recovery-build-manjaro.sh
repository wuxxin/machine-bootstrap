#!/bin/bash
set -e
# set -x

self_path=$(dirname "$(readlink -e "$0")")

# recovery version
distrib_id=manjaro
distrib_codename=stable
distrib_version=""
recovery_version=${distrib_id}-${distrib_codename}-${distrib_version}-live-system-recovery-1.0

usage() {
    local cmd
    cmd=$(basename $0)
    cat << EOF
$cmd download               <download_dir>
$cmd extract                <download_dir> <target_dir>
$cmd show grub.cfg          <grub_root> <livemedia> <uuid_volume>
$cmd show grub.d/recovery   <grub_root> <livemedia> <uuid_volume>
$cmd show kernel_version    <kernelimage_dir> # returns the kernel version found in kernelimage_dir
$cmd show recovery_version  # returns the image plus the recovery-script version for change detection
$cmd show imagename         # returns the expected source image name for recovery building
$cmd show imageurl          # returns the expected download url image name for recovery building
$cmd show keyfile           # returns the expected signingkeys file name for verifying downloads

$cmd --check-req            # confirm all needed requisites are present, exit 0 if true

Version: $recovery_version

EOF
    exit 1
}


as_root() {
    if test "$(id -u)" != "0"; then sudo -- "$@"; else $@; fi
}


deb_chroot() {
    chrootdir=$1
    shift
    as_root env LANG="POSIX" LANGUAGE="C" LC_MESSAGES="POSIX" \
        DEBIAN_FRONTEND=noninteractive chroot "$chrootdir" "$@"
}


show_grub_cfg() {
}


show_grub_d_recovery() {
}


# parse args
if test "$1" = "--check-req"; then shift; check_requisites "$@"; exit 0; fi
if test "$1" != "download" -a "$1" != "extract" \
    -a "$1" != "show" -a "$1" != "create"; then usage; fi
cmd="$1"
shift

# if http_proxy is set, reexport for sub-processes
if test "$http_proxy" != ""; then export http_proxy; fi

if test "$cmd" = "download"; then
    if test "$1" = ""; then usage; fi
    downloaddir="$1"
    shift
    check_requisites download
    download_casper_image "$downloaddir" "$baseurl" "$imagename"
elif test "$cmd" = "extract"; then
    if test "$2" = ""; then usage; fi
    downloaddir="$1"
    targetdir="$2"
    shift 2
    extract_casper_from_iso "$downloaddir/$imagename" "$downloaddir/isomount" "$targetdir"
elif test "$cmd" = "show"; then
    if test "$1" = "imagename"; then
        echo "$imagename"
    elif test "$1" = "imageurl"; then
        echo "$baseurl/$imagename"
    elif test "$1" = "keyfile"; then
        echo "$cdimage_keyfile"
    elif test "$1" = "kernel_version"; then
        targetdir=$2
        if test ! -e "$targetdir/$kernel_name"; then
            echo "error: $targetdir/$kernel_name not existing"
            usage
        fi
        kernel_version=$(file "$targetdir/$kernel_name" -b | sed -r "s/^.+version ([^ ]+) .+/\1/g")
        echo "$kernel_version"
    elif test "$1" = "recovery_version"; then
        echo "$recovery_version"
    elif test "$1" = "grub.cfg" -o "$1" = "grub.d/recovery"; then
        if test "$4" = ""; then usage; fi
        show_grub="$1"
        grub_root="$2"
        livemedia="$3"
        uuid_volume="$4"
        shift 4
        if test "$show_grub" = "grub.cfg"; then
            show_grub_cfg "$grub_root" "$livemedia" "$uuid_volume"
        elif test "$show_grub" = "grub.d/recovery"; then
            show_grub_d_recovery "$grub_root" "$livemedia" "$uuid_volume"
        fi
    else
        echo "error: show $1 is unknown"
        usage
    fi
fi
