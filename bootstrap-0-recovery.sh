#!/bin/bash
set -eo pipefail
# set -x

self_path=$(dirname "$(readlink -e "$0")")


usage() {
    cat << EOF
Usage: $0 hostname 'diskid+' --yes [optional parameter]

install a recovery system and overwrite all existing data of all disks matching 'diskid+'

+ <diskid+> can be one or two diskids (serialnr), will setup mirroring if two disks

+ "http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"

+ optional parameter
  --recovery-autologin
    # will set the tty4 of the recovery boot process to autologin for physical recovery
  --reuse
    # will clean first sectors of data from disks before re-partitioning

  --swap=       true|*false|<swapsizemb, if true: default= 1.25 x RAM mb>
    # enable swap usable for hibernation (suspend to disk)

  --boot=       *true|false|<bootsizemb, if true: default=$boot_size mb>
  --boot-fs=    *zfs|ext4|xfs
    # set boot partition filesystem

  --root-fs=    *zfs|ext4|xfs
    # set root partition filesystem
  --root-lvm=   *""|<vgname>
    # create a lvm volume group and create root volume as logical volume
  --root-crypt= *true|false
    # enable or disable encryption for root
  --root-size=  *all|<rootsizemb>
    # default is that root partition takes all available space
    # if using data partition, or for other reasons, set a specified size for root

  --data-fs=    *""|zfs|ext4|xfs|other
    # if not empty create and configure filesystem for a data partition,
    # will be created last and take all still available space.
    # set a size to root partition, to give the rest to data.
    # filesystem "other": creates partition[s], but no raid if two disks,
    #   encrypt if true, but dont configure any filesystem
  --data-crypt= *true|false
    # enable or disable encryption for data
  --data-lvm=   *""|<vgname>
    # create a lvm volume group, do not create a logical volume

  --log=       true|*false|<logsizemb, if true: logsizemb=1024mb>
  --cache=     true|*false|<cachesizemb, if true: cachesizemb=59392mb>
    # zfs cache system will use (<cachesizemb>/58)mb of RAM to hold L2ARC references
    # eg. 58GB on disk L2ARC uses 1GB of ARC space in memory

EOF

    exit 1
}


# defaults
option_reuse="false"
option_log="false"
option_cache="false"
option_swap="false"
option_boot="true"
recovery_autologin="false"
# default hibernation swap_size = ram-mem*1.25
swap_size=$(grep MemTotal /proc/meminfo \
            | awk '{print $2*1.25/1024}' | sed -r 's/([0-9]+)(\.[0-9]*)?/\1/g')
swap_crypt="true"
# default zil log_size ~= 5seconds io-write
log_size="1024"
# default l2arc RAM size = 1gb corresponds to ~= 58gb l2arc disk cache_size
l2arcramsizemb="1024"
cache_size="$(( l2arcramsizemb * 1024 * 1024 / 70 * 4096 /1024 /1024))"
# default efi size to = 1600mb corresponds to 2 times casper livemedia (~800mb)
efi_size=1600
boot_fs=zfs
boot_size=400
root_fs=zfs
root_lvm=""
root_crypt="true"
root_size="all"
data_fs=""
data_crypt="true"
data_lvm=""


# parse param
if test "$3" != "--yes"; then usage; fi
hostname=$1
disklist=$2
shift 3
fulldisklist=$(for i in $disklist; do echo "/dev/disk/by-id/${i}"; done)
diskcount=$(echo "$disklist" | wc -w)
if test "$diskcount" -gt "2"; then
    echo "ERROR: script only works with one or two disks, but disks=$diskcount"
    exit 1
fi
for i in $fulldisklist; do
    if test ! -e "$i"; then echo "ERROR: disk $i does not exist"; exit 1; fi
done

OPTS=$(getopt -o "" -l reuse,recovery-autologin,log:,swap:,cache:,boot:,boot-fs:,root-fs:,root-lvm:,root-lvm-vol-size:,root-crypt:,root-size:,data-fs:,data-lvm:,data-crypt: -- "$@")
[[ $? -eq 0 ]] || usage
eval set -- "${OPTS}"

while true; do
    case $1 in
    --log)
        option_log="true"; shift
        if (echo "$1" | grep -q -E "^[0-9]+$"); then log_size="$1"; else option_log="$1"; fi
        ;;
    --swap)
        option_swap="true"; shift
        if (echo "$1" | grep -q -E "^[0-9]+$"); then swap_size="$1"; else option_swap="$1"; fi
        ;;
    --cache)
        option_cache="true"; shift
        if (echo "$1" | grep -q -E "^[0-9]+$"); then cache_size="$1"; else option_cache="$1"; fi
        ;;
    --boot)
        option_boot="true"; shift
        if (echo "$1" | grep -q -E "^[0-9]+$"); then boot_size="$1"; else option_boot="$1"; fi
        ;;
    --reuse)              option_reuse="true" ;;
    --recovery-autologin) recovery_autologin="true" ;;
    --boot-fs)      boot_fs="$2";   shift ;;
    --root-fs)      root_fs="$2";   shift ;;
    --root-lvm)     root_lvm="$2";  shift ;;
    --root-lvm-vol-size)            shift ;;
    # accept but ignore root-lvm-vol-size in bootstrap-0, because it's only needed in bootstrap-1
    --root-crypt)   root_crypt="$2";shift ;;
    --root-size)    root_size="$2"; shift ;;
    --data-fs)      data_fs="$2";   shift ;;
    --data-lvm)     data_lvm="$2";  shift ;;
    --data-crypt)   data_crypt="$2";shift ;;
    --)             shift; break ;;
    *)              echo "error in params: $@"; usage ;;
    esac
    shift
done

# include library
. "$self_path/bootstrap-library.sh"

if test "$http_proxy" != ""; then
    export http_proxy
fi

cat << EOF
Configuration:
hostname: $hostname, http_proxy: $http_proxy
fulldisklist=$(for i in $fulldisklist; do echo -n " $i"; done)
reuse=$option_reuse, autologin=$recovery_autologin
swap=$option_swap ($swap_size), log=$option_log ($log_size), cache=$option_cache ($cache_size)
boot=$option_boot ($boot_size), boot_fs: $boot_fs
root_fs: $root_fs, root_crypt: $root_crypt, root_lvm: $root_lvm, root_size: $root_size
data_fs: $data_fs, data_crypt: $data_crypt, data_lvm: $data_lvm
EOF

if which cloud-init > /dev/null; then
    echo -n "waiting for cloud-init finish..."
    cloud-init status --wait || true
fi

# go to an existing directory
cd /tmp

packages="$(get_default_packages) $(/tmp/recovery/build-recovery.sh --check-req list)"
if which apt-get > /dev/null; then
    echo "install required utils"
    DEBIAN_FRONTEND=noninteractive apt-get update --yes
    DEBIAN_FRONTEND=noninteractive apt-get install --yes $packages
else
    echo "Warning: no debian system, packages ($packages) must be installed manually or program will fail"
fi

if test "$option_reuse" = "true"; then
    echo "--reuse: delete disk data before partitioning"
    for i in /dev/mapper/luks-*; do
        echo "stop old luks $i"
        cryptsetup remove "$i" || true
    done
    for i in 127 126 125; do
        echo "stop old mdadm $i"
        mdadm --stop /dev/md$i || true
    done
    for disk in $fulldisklist; do
        echo "Wiping all disk data of ${disk}"
        for i in $disk-part*; do
            mdadm --zero-superblock --force "${i}" || true
        done
        sgdisk --zap-all "${disk}"
        sync
        partprobe "${disk}"
        sleep 1
    done
fi

echo "partition disks"
DATA_NR="8"; BIOS_NR="7"; EFI_NR="6"; LOG_NR="5"
CACHE_NR="4"; SWAP_NR="3"; BOOT_NR="2"; ROOT_NR="1"
MIRROR_TYPE="FD00"; ZFS_TYPE="BF01"; LINUX_TYPE="8300"
BOOT_TYPE="$LINUX_TYPE"; ROOT_TYPE="$LINUX_TYPE"; DATA_TYPE="$LINUX_TYPE"
if test "$diskcount" != "1"; then
    BOOT_TYPE="$MIRROR_TYPE"; ROOT_TYPE="$MIRROR_TYPE"; DATA_TYPE="$MIRROR_TYPE"
fi
if test "$boot_fs" = "zfs"; then BOOT_TYPE="$ZFS_TYPE"; fi
if test "$root_fs" = "zfs"; then ROOT_TYPE="$ZFS_TYPE"; fi
if test "$data_fs" = "zfs"; then DATA_TYPE="$ZFS_TYPE"; fi
if test "$root_size" = "all"; then root_size="0"; else root_size="+${root_size}M"; fi
disknr=1
if test "$diskcount" = "1"; then
    disknr=""
fi

for disk in $fulldisklist; do
    echo "partition disk $disk"
    # legacy boot support: additional data for grub bios boot
    sgdisk  "${disk}" \
        -n "$BIOS_NR:1M:+1M" \
        -t "$BIOS_NR:EF02" \
        -c "$BIOS_NR:BIOS${disknr}"
    # efi and recovery support: minimum size for valid EFI is 260MiB
    sgdisk  "${disk}" \
        -n "$EFI_NR:0:+${efi_size}M" \
        -t "$EFI_NR:EF00" \
        -c "$EFI_NR:EFI${disknr}"
    if test "$option_log" = "true"; then
        # optional (ZFS)-Log Partition, use case: 1 ssd, 2hdd, log on ssd
        sgdisk  "${disk}" \
        -n "$LOG_NR:0:+${log_size}M" \
        -t "$LOG_NR:$LINUX_TYPE" \
        -c "$LOG_NR:LOG${disknr}"
    fi
    if test "$option_cache" = "true"; then
        # optional (ZFS)-Cache Partition, use case: 1 ssd, 2hdd, cache on ssd
        sgdisk  "${disk}" \
        -n "$CACHE_NR:0:+${cache_size}M" \
        -t "$CACHE_NR:$LINUX_TYPE" \
        -c "$CACHE_NR:CACHE${disknr}"
    fi
    if test "$option_swap" = "true"; then
        # optional swap partition, for (encrypted) suspend to disk (laptop)
        sgdisk  "${disk}" \
        -n "$SWAP_NR:0:+${swap_size}M" \
        -t "$SWAP_NR:$LINUX_TYPE" \
        -c "$SWAP_NR:$(mk_partlabel "$diskcount" "$swap_crypt" false "" SWAP${disknr})"
    fi
    if test "$option_boot" = "true"; then
        # boot volume, always unencrypted
        sgdisk  "${disk}" \
        -n "$BOOT_NR:0:+${boot_size}M" \
        -t "$BOOT_NR:$BOOT_TYPE" \
        -c "$BOOT_NR:$(mk_partlabel "$diskcount" false false "$boot_fs" BOOT${disknr})"
    fi
    # root volume
    sgdisk  "${disk}" \
        -n "$ROOT_NR:0:$root_size" \
        -t "$ROOT_NR:$ROOT_TYPE" \
        -c "$ROOT_NR:$(mk_partlabel "$diskcount" "$root_crypt" "$root_lvm" "$root_fs" ROOT${disknr})"
    if test "$data_fs" != ""; then
        # optional data partition
        sgdisk  "${disk}" \
        -n "$DATA_NR:0:0" \
        -t "$DATA_NR:$DATA_TYPE" \
        -c "$DATA_NR:$(mk_partlabel "$diskcount" "$data_crypt" "" "$data_fs" DATA${disknr})"
    fi
    sync
    partprobe "${disk}"
    sleep 1
    disknr=$((disknr+1))
done

create_efi
mount_efi /mnt

echo "build recovery to /mnt/efi"
mkdir -p /tmp/liveimage
/tmp/recovery/build-recovery.sh download /tmp/liveimage
/tmp/recovery/build-recovery.sh extract /tmp/liveimage /mnt/efi

#echo "build installer.squashfs to /mnt/efi/casper"
#kernel_version=$(/tmp/recovery/build-recovery.sh show kernel_version /mnt/efi/casper)
#/tmp/recovery/build-recovery.sh create installer-addon \
#    /mnt/efi/casper/filesystem.squashfs \
#    /mnt/efi/casper/installer.squashfs \
#    /tmp/liveimage \
#    $kernel_version

echo "create recovery.squashfs to /mnt/efi/casper"
cp "$self_path/bootstrap-library.sh" /tmp/recovery
/tmp/recovery/update-recovery-squashfs.sh --custom \
    /tmp/recovery.squashfs "$hostname" "-" /tmp/netplan.yaml \
    /tmp/recovery_hostkeys /tmp/authorized_keys /tmp/recovery \
    - "$recovery_autologin" "default" "$http_proxy"
cp /tmp/recovery.squashfs /mnt/efi/casper/

# install on first disk only, 2-chroot-install will reinstall grub and sync if two disks
echo "write /mnt/efi/grub/grub.cfg"
efi_grub="hd0,gpt${EFI_NR}"
efi_fs_uuid=$(dev_fs_uuid "$(by_partlabel EFI | first_of)")
casper_livemedia=""
mkdir -p /mnt/efi/grub
/tmp/recovery/build-recovery.sh show grub.cfg \
    "$efi_grub" "$casper_livemedia" "$efi_fs_uuid" > /mnt/efi/grub/grub.cfg

echo "install grub"
efi_disk=/dev/$(basename "$(readlink -f \
    "/sys/class/block/$(lsblk -no kname "$(by_partlabel EFI | first_of)")/..")")
install_grub /mnt/efi "$efi_disk"

unmount_efi
