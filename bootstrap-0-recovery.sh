#!/bin/bash
set -eo pipefail
#set -x


usage() {
    cat <<USAGEEOF
Usage: $0 hostname 'diskid+' --yes 
        [--reuse]
        [--log      yes|<logsizemb>]
        [--cache    yes|<cachesizemb]
        [--swap     yes|<swapsizemb>]
        [--recovery-autologin]

this script will overwrite all existing data of all disks matching diskid+

--reuse 
    will clean first sectors of data from disks before re-partitioning
--log       yes|<logsizemb>         
            # default=no, yes=1024
--cache     yes|<cachesizemb>       
            # default=no, yes=59392
            # system will use (<cachesizemb>/58) M of RAM to hold L2ARC references
            # eg. 58GB on disk L2ARC uses 1GB of ARC space in memory
--swap      yes|<swapsizemb>        
            # default=no, yes=1.25x RAM size
            # this enables encrypted hibernation
            # for "normal" swap use zfs swap (see bootstrap-1-install)

--recovery-autologin
    will set the first tty of the recovery boot process to autologin for physical recovery
    
"http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"

USAGEEOF
    exit 1
}


# defaults
option_reuse="no"
option_log="no"
option_swap="no"
option_cache="no"
option_autologin="no"
# hibernation swap size = mem*1.25
opt_swapsizemb=$(grep MemTotal /proc/meminfo | awk '{print $2*1.25/1024}' | sed -r 's/([0-9]+)(\.[0-9]*)?/\1/g')
# zil log should be ~= 5seconds io-write
opt_logsizemb="1024"
# memory arc space mb used for l2arc size =~ l2arcsize/58, 
# eg. around 1gb arc memory for a 58gb l2arc
l2arcramsizemb="1024"
opt_cachesizemb="$(( l2arcramsizemb * 1024 * 1024 / 70 * 4096 /1024 /1024))"


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
OPTS=$(getopt -o rlsca --long reuse,log:,swap:,cache:,recovery-autologin -- "$@")
[[ $? -eq 0 ]] || usage
eval set -- "${OPTS}"

while true; do
    case $1 in
    --reuse)
        option_reuse="yes"
        ;;
    --log)
        option_log="yes"
        if $(echo "$2" | grep -q -E "^[0-9]+$"); then
            opt_logsizemb="$2"
        else
            option_log="$2"
        fi
        shift
        ;;
    --swap)
        option_swap="yes"
        if $(echo "$2" | grep -q -E "^[0-9]+$"); then
            opt_swapsizemb="$2"
        else
            option_swap="$2"
        fi
        shift
        ;;
    --cache)
        option_cache="yes"
        if $(echo "$2" | grep -q -E "^[0-9]+$"); then
            opt_cachesizemb="$2"
        else
            option_cache="$2"
        fi
        shift
        ;;
    --recovery-autologin)
        option_autologin="yes"
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "error in params: $@"
        usage
        ;;
    esac
    shift
done


if test "$http_proxy" != ""; then
    export http_proxy
fi

echo "hostname: $hostname, fulldisklist=$fulldisklist, http_proxy: $http_proxy"
echo "options: reuse=$option_reuse , log=$option_log ($opt_logsizemb), swap=$option_swap ($opt_swapsizemb), cache=$option_cache ($opt_cachesizemb),  autologin=$option_autologin"

packages="cryptsetup gdisk mdadm grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed efibootmgr squashfs-tools curl socat ca-certificates bzip2 tmux"

if which apt-get > /dev/null; then    
    echo "install required utils"
    DEBIAN_FRONTEND=noninteractive apt-get install --yes $packages
else
    echo "Warning: no debian system, packages ($packages) must be installed manually or program will fail"
fi

if test "$option_reuse" = "yes"; then
    echo "--reuse: delete disk data before partitioning"
    echo "stop old mdadm and luksdisks"
    mdadm --stop /dev/md127 || true
    mdadm --stop /dev/md126 || true
    for luks in /dev/mapper/luks-*; do
        cryptsetup remove "$luks" || true
    done
    for disk in $fulldisklist; do
        echo "Wiping all disk data of ${disk}"
        for i in $disk-part*; do
            mdadm --zero-superblock --force "${i}"
        done
        sgdisk --zap-all "${disk}"
        sync
        partprobe "${disk}"
        sleep 1
    done
fi

echo "partition disks"
BIOS_NR="7"; EFI_NR="6"; LOG_NR="5"; CACHE_NR="4"; SWAP_NR="3"; BOOT_NR="2"; ROOT_NR="1"

disknr=1
if test "$diskcount" = "1"; then
    disknr=""
    singledisk=$fulldisklist
fi

for disk in $fulldisklist; do
    echo "partition disk $disk"
    sgdisk  "${disk}" \
        -n "$BIOS_NR:1M:+1M" \
        -t "$BIOS_NR:EF02" 
        # -c "$BIOS_NR:BIOS${disknr}"
        # legacy boot support: additional data for grub bios boot
    sgdisk  "${disk}" \
        -n "$EFI_NR:0:+263M" \
        -t "$EFI_NR:EF00" \
        -c "$EFI_NR:EFI${disknr}"
        # efi support: minimum size for valid EFI is 260MiB
    if test "$option_log" = "yes"; then
        sgdisk  "${disk}" \
        -n "$LOG_NR:0:+${opt_logsizemb}M" \
        -t "$LOG_NR:8300" \
        -c "$LOG_NR:LUKSLOG${disknr}"
    fi
    if test "$option_cache" = "yes"; then
        sgdisk  "${disk}" \
        -n "$CACHE_NR:0:+${opt_cachesizemb}M" \
        -t "$CACHE_NR:8300" \
        -c "$CACHE_NR:LUKSCACHE${disknr}"
    fi
    if test "$option_swap" = "yes"; then
        sgdisk  "${disk}" \
        -n "$SWAP_NR:0:+${opt_swapsizemb}M" \
        -t "$SWAP_NR:8300" \
        -c "$SWAP_NR:LUKSSWAP${disknr}"
    fi
    sgdisk  "${disk}" \
        -n "$BOOT_NR:0:+2807M" \
        -t "$BOOT_NR:FD00" \
        -c "$BOOT_NR:BOOT${disknr}"
    sgdisk  "${disk}" \
        -n "$ROOT_NR:0:0" \
        -t "$ROOT_NR:8300" \
        -c "$ROOT_NR:LUKSROOT${disknr}"
    sync
    partprobe "${disk}"
    sleep 1
    disknr=$((disknr+1))
done

echo "format efi* with vfat"
for disk in $fulldisklist; do
    mkfs.fat -F 32 "${disk}-part${EFI_NR}"
done

mkdir -p /mnt/boot
if test "$diskcount" -ge "2"; then
    echo "create mdadm-boot"
    boot_disks=$(for disk in $fulldisklist; do echo "${disk}-part${BOOT_NR} "; done)
    mdadm --create /dev/md/mdadm-boot -v -f -R --level=mirror "--raid-disks=${diskcount}" --assume-clean --name=mdadm-boot $boot_disks
    echo "format boot on mdadm-boot with ext4"
    mkfs.ext4 -q -F -L boot /dev/md/mdadm-boot
    echo "mount boot"
    mount /dev/md/mdadm-boot /mnt/boot
else
    echo "format boot on ${singledisk}-part${BOOT_NR} with ext4"
    mkfs.ext4 -q -F -L boot "${singledisk}-part${BOOT_NR}"
    echo "mount boot"
    mount "${singledisk}-part${BOOT_NR}" /mnt/boot
fi

echo "mount efi[2-9]*"
disknr=1
for disk in $fulldisklist; do
    x=efi$(if test "$disknr" != "1"; then echo $disknr;fi)
    mkdir "/mnt/boot/$x"
    mount "$disk-part$EFI_NR" "/mnt/boot/$x"
    disknr=$((disknr+1))
done

/tmp/recovery/update-recovery-squashfs.sh --custom /tmp/recovery.squashfs "$hostname" "-" /tmp/netplan.yaml /tmp/recovery_hostkeys /tmp/authorized_keys /tmp/recovery $option_autologin "$http_proxy"

echo "download live server iso image for casper"
isohash="7b37dfcd082726303528e47c82f88f29c1dc9232f8fd39120d13749ae83cc463"
isourl="http://releases.ubuntu.com/bionic/ubuntu-18.04.1.0-live-server-amd64.iso"
#isohash="ea6ccb5b57813908c006f42f7ac8eaa4fc603883a2d07876cf9ed74610ba2f53"
#isourl="http://releases.ubuntu.com/bionic/ubuntu-18.04.2-live-server-amd64.iso"
curl -f -# -L -s "$isourl"  -o /tmp/${isourl##*/}
echo "checksum image"
echo "$isohash */tmp/${isourl##*/}" | sha256sum --check

echo "copy casper kernel,initrd,filesystem"
mkdir -p /mnt/iso
mount -o loop /tmp/${isourl##*/} /mnt/iso
mkdir -p /mnt/boot/casper /mnt/boot/grub /mnt/boot/efi/EFI/BOOT
cp -a -t /mnt/boot/casper /mnt/iso/casper/filesystem* 
cp -a -t /mnt/boot/casper /mnt/iso/casper/initrd
cp -a -t /mnt/boot/casper /mnt/iso/casper/vmlinuz
cp -a -t /mnt/boot/       /mnt/iso/.disk
umount /mnt/iso

echo "copy recovery.squashfs for casper"
cp /tmp/recovery.squashfs /mnt/boot/casper/

echo "install grub"
disk=$(echo $fulldisklist | head -1 | sed -r "s/^ *([^ ]+)( .*)?/\1/g")
grub_efi_param=""
if test ! -e "/sys/firmware/efi"; then
    grub_efi_param="--no-nvram"
fi
grub-install --target=x86_64-efi --boot-directory=/mnt/boot --efi-directory=/mnt/boot/efi --bootloader-id=Ubuntu --recheck --no-floppy $grub_efi_param "$disk"
grub-install --target=i386-pc --boot-directory=/mnt/boot --recheck --no-floppy "$disk"

echo "write grub.cfg"
if test "$diskcount" -ge "2"; then
    grub_root="md/mdadm-boot"
    grub_hint="md/mdadm-boot"
    casper_livemedia="live-media=/dev/md127"
else
    grub_root="hd0,gpt${BOOT_NR}"
    grub_hint="hd0,gpt${BOOT_NR}"
    casper_livemedia=""
fi
cat > /mnt/boot/grub/grub.cfg << EOF
if loadfont /grub/font.pf2 ; then
	set gfxmode=auto
    insmod efi_gop
	insmod efi_uga
	insmod gfxterm
	terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
set timeout=2

insmod part_gpt
insmod diskfilter
insmod mdraid1x
insmod ext2

# casper recovery 
menuentry "Ubuntu 18.04 Casper Recovery" {
    set root="$grub_root"
    search --no-floppy --fs-uuid --set=root --hint="$grub_hint" $(blkid -s UUID -o value /dev/disk/by-label/boot)
    linux  /casper/vmlinuz boot=casper toram textonly $casper_livemedia noeject noprompt ds=nocloud
    initrd /casper/initrd
}
EOF

echo "unmount all mounted"
for i in $(for j in $(seq 2 "$diskcount"); do echo "/mnt/boot/efi$j"; done) /mnt/boot/efi /mnt/boot; do
    umount "$i"
done
