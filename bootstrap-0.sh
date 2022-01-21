#!/bin/bash
set -eo pipefail
# set -x

self_path=$(dirname "$(readlink -e "$0")")


usage() {
    cat << EOF
Usage: $0 hostname 'diskid+' --yes [optional parameter]

**overwrites** all existing data of all disks matching 'diskid+'
    repartition disks and optionally install a recovery system

+ <diskid+> can be one or two diskids (serialnr), will setup mirroring if two disks

+ "http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"

+ optional parameter
  --root-fs=    *zfs|ext4|xfs
    # set root partition filesystem
  --root-lvm=   *""|<vgname>
    # create a lvm volume group and create root volume as logical volume
  --root-crypt= *true|false|native
    # enable or disable encryption for root
    # if root-fs=zfs and root-crypt=native, zfs encryption is used instead luks
  --root-size=  *all|<rootsizemb>
    # default is that root partition takes all available space
    # if using data partition, or for other reasons, set a specified size for root

  --data-fs=    *""|zfs|ext4|xfs|other
    # if not empty create and configure filesystem for a data partition,
    # will be created last and take all still available space.
    # set a size to root partition, to give the rest to data.
    # filesystem "other": creates partition[s], but no raid if two disks,
    #   encrypt if true, but dont configure any filesystem
  --data-crypt= *true|false|native
    # enable or disable encryption for data
    # if data-fs=zfs and data-crypt=native, zfs encryption is used instead luks
  --data-lvm=   *""|<vgname>
    # create a lvm volume group, and create data volume as logical volume

  --efi-size=   <efisizemb, default $efi_size mb>
  --boot-loader=*grub|systemd
    # grub (the default) will use a hybrid bios & efi booting setup with grub
    # systemd will use systemd.boot on an efi only setup
  --boot=       true|*false|<bootsizemb, if true: default=$boot_size mb>
  --boot-fs=    *zfs|ext4|xfs
    # legacy boot partition filesystem, usually not needed, boot related files are on efi

  --swap=       true|*false|<swapsizemb, if true: default= 1.25 x RAM mb>
    # enable swap usable for hibernation (suspend to disk)

  --log=        true|*false|<logsizemb, if true: logsizemb=$log_size mb>
    # default zil log_size ~= 5seconds io-write , eg. 200mb per sec *5 = 1024

  --cache=      true|*false|<cachesizemb, if true: cachesizemb=$cache_size mb>
    # zfs cache system will use (<cachesizemb>/58)mb of RAM to hold L2ARC references
    # eg. 58GB on disk L2ARC uses 1GB of ARC space in memory

  --no-recovery
    # only partition the disks, but do not install a recovery system
  --recovery-autologin
    # will set the tty4 of the recovery boot process to autologin for physical recovery
  --reuse
    # will clean first sectors of data from disks before re-partitioning

EOF

    exit 1
}


# defaults
option_reuse="false"
option_log="false"
option_cache="false"
option_swap="false"
option_boot="false"
recovery_install="true"
recovery_autologin="false"
# default hibernation swap_size = ram-mem*1.25
swap_size=$(grep MemTotal /proc/meminfo \
            | awk '{print $2*1.25/1024}' | sed -r 's/([0-9]+)(\.[0-9]*)?/\1/g')
swap_crypt="true"
# default zil log_size ~= 5seconds io-write , eg. 200mb per sec *5 = 1024
log_size="1024"
# default l2arc RAM size = 1gb corresponds to ~= 58gb l2arc disk cache_size
l2arcramsizemb="1024"
cache_size="$(( l2arcramsizemb * 1024 * 1024 / 70 * 4096 /1024 /1024))"
# default efi size to = 2200mb corresponds to 2 times casper livemedia (~800mb)+ reserve
efi_size=2200
boot_loader="grub"
boot_fs=zfs
boot_size=400
root_fs=zfs
root_lvm=""
root_crypt="true"
root_size="all"
data_fs=""
data_crypt="true"
data_lvm=""
from_download="false"


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

OPTS=$(getopt -o "" -l reuse,no-recovery,recovery-autologin,from-download,boot-loader:,log:,swap:,cache:,efi-size:,boot:,boot-fs:,root-fs:,root-lvm:,root-lvm-vol-size:,root-crypt:,root-size:,data-fs:,data-lvm:,data-lvm-vol-size:,data-crypt: -- "$@")
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
    --reuse)        option_reuse="true" ;;
    --no-recovery)  recovery_install="false" ;;
    --recovery-autologin) recovery_autologin="true" ;;
    --boot-loader)  boot_loader="$2"; shift ;;
    --efi-size)     efi_size="$2";    shift ;;
    --boot-fs)      boot_fs="$2";     shift ;;
    --root-fs)      root_fs="$2";     shift ;;
    --root-lvm)     root_lvm="$2";    shift ;;
    --root-lvm-vol-size)              shift ;;
    # accept but ignored in bootstrap-0, because only needed in bootstrap-1
    --root-crypt)   root_crypt="$2";  shift ;;
    --root-size)    root_size="$2";   shift ;;
    --data-fs)      data_fs="$2";     shift ;;
    --data-lvm)     data_lvm="$2";    shift ;;
    --data-crypt)   data_crypt="$2";  shift ;;
    --data-lvm-vol-size)              shift ;;
    # accepted but ignored in bootstrap-0, because only needed in bootstrap-1
    --from-download) from_download="true"; ;;
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
reuse=$option_reuse, autologin=$recovery_autologin, efi-size=$efi_size
swap=$option_swap ($swap_size), log=$option_log ($log_size), cache=$option_cache ($cache_size)
boot_loader=$boot_loader, boot=$option_boot ($boot_size), boot_fs: $boot_fs
root_fs: $root_fs, root_crypt: $root_crypt, root_lvm: $root_lvm, root_size: $root_size
data_fs: $data_fs, data_crypt: $data_crypt, data_lvm: $data_lvm
EOF

if which cloud-init > /dev/null; then
    echo -n "waiting for cloud-init finish..."
    cloud-init status --wait || true
fi

# go to an existing directory
cd /tmp

packages="$(get_default_packages)"
if test "$recovery_install" = "true"; then
    packages="$packages $(/tmp/recovery/recovery-build-ubuntu.sh --check-req list)"
fi
echo "install required utils ($packages)"
install_packages --refresh $packages

if test "$from_download" != "true"; then
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

    # https://wiki.archlinux.org/title/GPT_fdisk#Partition_type
    # https://systemd.io/DISCOVERABLE_PARTITIONS/
    BIOSGRUB_TYPE="EF02";   BIOSGRUB_GPT="21686148-6449-6E6F-744E-656564454649"
    EFI_TYPE="EF00";        EFI_GPT="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    LINUX_TYPE="8300";      LINUX_GPT="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    ROOT_AMD64_TYPE="8304"; ROOT_AMD64_GPT="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"
    SWAP_TYPE="8200";       SWAP_GPT="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
    LVM_TYPE="8E00";        LVM_GPT="E6D6D379-F507-44C2-A23C-238F2A3DF928"
    RAID_TYPE="FD00";       RAID_GPT="A19D880F-05FC-4D3B-A006-743F0F84911E"
    LUKS_TYPE="8309";       LUKS_GPT="CA7D7CCB-63ED-4C53-861C-1742536059CC"
    ZFS_TYPE="BF01";        ZFS_GPT="6A898CC3-1DD2-11B2-99A6-080020736631"
    RESERVED_TYPE="8301";   RESERVED_GPT="8DA63339-0007-60C0-C436-083AC8230908"
                            BOOT_GPT="BC13C2FF-59E6-4262-A352-B275FD6F7172"

    BOOT_TYPE="$LINUX_TYPE"; ROOT_TYPE="$ROOT_AMD64_TYPE"; DATA_TYPE="$LINUX_TYPE"
    if test "$diskcount" != "1"; then
        BOOT_TYPE="$RAID_TYPE"; ROOT_TYPE="$RAID_TYPE"; DATA_TYPE="$RAID_TYPE"
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
        # legacy boot support: additional data for optional grub bios boot
        sgdisk  "${disk}" \
            -n "$BIOS_NR:1M:+1M" \
            -t "$BIOS_NR:$BIOSGRUB_TYPE" \
            -c "$BIOS_NR:BIOS${disknr}"
        # efi, linux boot and recovery support: minimum size for valid EFI is 260MiB
        sgdisk  "${disk}" \
            -n "$EFI_NR:0:+${efi_size}M" \
            -t "$EFI_NR:$EFI_TYPE" \
            -c "$EFI_NR:EFI${disknr}"
        # optional ZFS-Log (SLOG) Partition, use case: 1 ssd, 2hdd, log on ssd
        if test "$option_log" = "true"; then
            sgdisk  "${disk}" \
            -n "$LOG_NR:0:+${log_size}M" \
            -t "$LOG_NR:$RESERVED_TYPE" \
            -c "$LOG_NR:LOG${disknr}"
        fi
        # optional ZFS-Cache (L2ARC) Partition, use case: 1 ssd, 2hdd, cache on ssd
        if test "$option_cache" = "true"; then
            sgdisk  "${disk}" \
            -n "$CACHE_NR:0:+${cache_size}M" \
            -t "$CACHE_NR:$RESERVED_TYPE" \
            -c "$CACHE_NR:CACHE${disknr}"
        fi
        # optional swap partition, for (encrypted) suspend to disk, usecase: laptop
        if test "$option_swap" = "true"; then
            sgdisk  "${disk}" \
            -n "$SWAP_NR:0:+${swap_size}M" \
            -t "$SWAP_NR:$LINUX_TYPE" \
            -c "$SWAP_NR:$(mk_partlabel "$diskcount" "$swap_crypt" false "" SWAP${disknr})"
        fi
        # optional boot volume, always unencrypted
        if test "$option_boot" = "true"; then
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
        # optional data partition
        if test "$data_fs" != ""; then
            sgdisk  "${disk}" \
            -n "$DATA_NR:0:0" \
            -t "$DATA_NR:$DATA_TYPE" \
            -c "$DATA_NR:$(mk_partlabel "$diskcount" "$data_crypt" "$data_lvm" "$data_fs" DATA${disknr})"
        fi
        sync
        partprobe "${disk}"
        sleep 1
        disknr=$((disknr+1))
    done

    create_efi
    mount_efi /mnt
fi

if test "$recovery_install" != "true"; then
    unmount_efi /mnt
    exit 0
fi

echo "build ubuntu recovery to /mnt/efi"
mkdir -p /tmp/liveimage
/tmp/recovery/recovery-build-ubuntu.sh download /tmp/liveimage
/tmp/recovery/recovery-build-ubuntu.sh extract /tmp/liveimage /mnt/efi

echo "create ubuntu recovery config to /mnt/efi/casper"
cp "$self_path/bootstrap-library.sh" /tmp/recovery
/tmp/recovery/recovery-config-ubuntu.sh --custom \
    /tmp/recovery.squashfs "$hostname" "-" /tmp/netplan.yaml \
    /tmp/recovery_hostkeys /tmp/authorized_keys /tmp/recovery \
    - "$recovery_autologin" "default" "$http_proxy"
cp /tmp/recovery.squashfs /mnt/efi/casper/

# install on first disk only, bootstrap-2 will reinstall grub and sync if two disks
echo "write /mnt/efi/grub/grub.cfg"
efi_grub="hd0,gpt${EFI_NR}"
efi_fs_uuid=$(dev_fs_uuid "$(by_partlabel EFI | first_of)")
casper_livemedia=""
mkdir -p /mnt/efi/grub
/tmp/recovery/recovery-build-ubuntu.sh show grub.cfg \
    "$efi_grub" "$casper_livemedia" "$efi_fs_uuid" > /mnt/efi/grub/grub.cfg

echo "install grub"
# workaround grub-install error searching for canonical path of '/cow'
dd if=/dev/zero bs=1M count=1 of=/cowfile
mkfs -t vfat /cowfile
mv /cowfile /cow
efi_disk=/dev/$(basename "$(readlink -f \
    "/sys/class/block/$(lsblk -no kname "$(by_partlabel EFI | first_of)")/..")")
install_grub /mnt/efi "$efi_disk"

unmount_efi /mnt
