#!/bin/bash

get_default_packages() {
    echo "cryptsetup gdisk mdadm lvm2 grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed efibootmgr squashfs-tools openssh-server curl gnupg gpgv ca-certificates bzip2 libc-bin tmux haveged debootstrap"
}

get_zfs_packages() {
    # echo "spl-dkms zfs-dkms zfsutils-linux"
    echo "zfsutils-linux"
}

configure_module_zfs() {
    mkdir -p /etc/modprobe.d
    echo "configure zfs fs options"
    echo "use cfq i/o scheduler for cgroup i/o quota support"
    echo "options zfs zfs_vdev_scheduler=cfq" > /etc/modprobe.d/zfs.conf
    arc_max_bytes=$(grep MemTotal /proc/meminfo | awk '{printf("%u",$2*25/100*1024)}')
    echo "use maximum of 25% of available memory for arc zfs_arc_max=$arc_max_bytes bytes"
    echo "options zfs zfs_arc_max=${arc_max_bytes}" >> /etc/modprobe.d/zfs.conf
}

configure_module_overlay() {
    mkdir -p /etc/modprobe.d
    echo "configure overlay fs options"
    cat > /etc/modprobe.d/overlay.conf << EOF
options overlay redirect_dir=on
options overlay xino_auto=on
options overlay metacopy=off
EOF
    mkdir -p /etc/modules-load.d
    cat > /etc/modules-load.d/overlay.conf << EOF
overlay
EOF
}

setup_hostname() { # hostname
    local hostname shortname domainname intip intip_re
    hostname="$1"
    echo "configure hostname ($hostname)"
    shortname="${hostname%%.*}"
    domainname="${hostname#*.}"
    intip="127.0.1.1"
    intip_re="127\.0\.1\.1"
    if ! grep -E -q "^${intip_re}[[:space:]]+${hostname}[[:space:]]+${shortname}" /etc/hosts; then
        if grep -q "^${intip_re}" /etc/hosts; then
            sed -i -r "s/^(${intip_re}[ \t]+).*/\1${hostname} ${shortname}/" /etc/hosts
        else
            sed -i -r "$ a${intip} ${hostname} ${shortname}\n" /etc/hosts
        fi
    fi
    echo "$shortname" > /etc/hostname
    hostnamectl set-hostname "$shortname"
}

install_grub() { # efi_dir efi_disk
    local efi_dir efi_disk efi_grub_param
    efi_dir="$1"; efi_disk="$2"
    if test ! -e "/sys/firmware/efi"; then
        efi_grub_param="--no-nvram"
    else
        efi_grub_param="--auto-nvram"
    fi
    grub-install    --target=x86_64-efi \
                    --boot-directory="$efi_dir" \
                    --efi-directory="$efi_dir" \
                    --bootloader-id=Ubuntu \
                    --recheck --no-floppy $efi_grub_param
    grub-install    --target=i386-pc \
                    --boot-directory="$efi_dir" \
                    --recheck --no-floppy \
                    "$efi_disk"
}

mk_partlabel() { # diskcount luks=true/false lvm=vgname/""/false fs=""/ext4/xfs/zfs partname
    local diskcount luks lvm fs partname label
    diskcount=$1; luks=$2; lvm=$3; fs=$4; partname=$5; label=""
    if test "$diskcount" != "1" -a "$fs" != "zfs"; then
        label="raid_"
    fi
    if test "$luks" = "true"; then
        label="${label}luks_"
    fi
    if test "$lvm" != "" -a "$lvm" != "false"; then
        label="${label}lvm.${lvm}_"
    fi
    if test "$fs" != ""; then
        label="${label}${fs}_"
    fi
    label="${label}$partname"
    echo "$label"
}

by_partlabel() { # partname_postfix [default_value=""]
    # eg. "ROOT" /invalid
    # may return 0, 1 or 2 entries
    local partname default devlist
    partname="$1"
    default="$2"
    devlist=$(find /dev/disk/by-partlabel/ -type l | sort | grep -E "${partname}[12]?$")
    if test "$devlist" = ""; then
        devlist="$default"
    fi
    echo "$devlist"
}

x_of() { # x | x_of 2
    tr "\n" " " | awk '{print $'$1';}'
}

first_of() {
    x_of 1
}

is_substr() { # string substr
    (echo "$1" | grep -q "$2")
}

substr_fstype() { # devpathlist
    # take first entry of list, parse and also return swap for swap
    local entry partname fstype
    entry=$(basename "$(echo "$@" | first_of)")
    partname=$(echo "$entry" | sed -r "s/(^|.+_)([A-Z]+)([12]?)$/\2/g")
    if test "$partname" = "SWAP"; then
        fstype="swap"
    elif test "$partname" = "EFI"; then
        fstype="vfat"
    else
        fstype=$(echo "$entry" | sed -r "s/.*(ext4|xfs|zfs|other)_([A-Z]+)([12]?)$/\1/g")
        if test "$fstype" = "$entry"; then
            fstype="unknown"
        fi
    fi
    echo "$fstype"
}

substr_vgname() { # devpathlist
    # take first entry of list, parse and return lvm volume group name
    local entry vgname
    entry=$(basename "$(echo "$@" | first_of)")
    vgname=$(echo "$entry" | sed -r "s/.*lvm\.([^_]+)_.*([A-Z]+[12]?)$/\1/g")
    echo "$vgname"
}

is_zfs() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "zfs_"
}

is_lvm() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "lvm."
}

is_raid() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "raid_"
}

is_crypt() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "luks_"
}

dev_fs_uuid() { # devpath
    blkid -s UUID -o value "$1"
}

dev_part_uuid() { # devpath
    blkid -s PARTUUID -o value "$1"
}


# ### Create and format Partitions

create_efi() {
    local devlist devcount
    devlist=$(by_partlabel EFI)
    devcount=$(echo "$devlist" | wc -w)

    for disk in $devlist; do
        echo "format $disk with fat"
        mkfs.fat -F 32 "$disk"
    done
}

create_boot() {
    local devlist devcount
    devlist=$(by_partlabel BOOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        if is_zfs "$devlist"; then
            echo "create zfs boot pool (bpool)"
            create_boot_pool \
                "$(if test "$devcount" != 1; then echo "mirror"; fi)" $devlist
        else
            if test "$devcount" != 1; then
                echo "create mdadm-boot"
                echo "y" | mdadm --create /dev/md/mdadm-boot -v \
                    --symlinks=yes --assume-clean \
                    --level=mirror "--raid-disks=${devcount}" \
                    $devlist
                actlist="/dev/md/mdadm-boot"
            else
                actlist="$devlist"
            fi
            echo "format boot"
            "mkfs.$(substr_fstype "$devlist")" -q -L boot "$actlist"
        fi
    fi
}

create_swap() { # diskpassword
    local diskpassword targetdev devlist devcount
    diskpassword="$1"
    devlist=$(by_partlabel SWAP)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        if test "$devcount" != "1"; then
            echo "create mdadm swap partition"
            echo "y" | mdadm --create /dev/md/mdadm-swap -v \
                --symlinks=yes --assume-clean \
                --level=mirror "--raid-disks=${devcount}" \
                $devlist
            targetdev="/dev/md/mdadm-swap"
        else
            targetdev="$devlist"
        fi
        echo "create luks swap partition"
        echo "$diskpassword" \
            | cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 \
                "$targetdev"
        echo "$diskpassword" \
            | cryptsetup open --type luks "$targetdev" luks-swap
        echo "format swap"
        mkswap -L swap /dev/mapper/luks-swap
    fi
}

create_data() { # diskpassword
    local diskpassword targetdev devlist devcount
    diskpassword="$1"
    devlist=$(by_partlabel DATA)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        FIXME: create_data and make luks but no raid and no fs format, if fs =other
    fi
}

create_and_mount_root() { # basedir diskpassword root_lvm_vol_size
    local basedir diskpassword devlist devcount devindex devtarget actlist templist vgname
    basedir="$1"; diskpassword="$2"; root_lvm_vol_size="$3"
    devlist=$(by_partlabel ROOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" != "1" -a "$devcount" != "2"; then
        echo "error: 0 or > 2 ($devcount) devices found. only 1 or 2 are Supported"
        exit 1
    fi
    actlist=$devlist
    if (test "$devcount" != "1" && ! is_zfs "$devlist"); then
        echo "create mdadm-root"
        echo "y" | mdadm --create /dev/md/mdadm-root -v \
            --symlinks=yes --assume-clean \
            --level=mirror "--raid-disks=${devcount}" \
            $actlist
        actlist=/dev/md/mdadm-root
    fi
    if is_crypt "$devlist"; then
        devindex=1
        templist=$actlist
        actlist=""
        for i in $templist; do
            devtarget=luks-root$(if (test "$devcount" != "1" && is_zfs "${i}"); then echo "${i}"; fi)
            echo "$diskpassword" \
                | cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 ${i}
            echo "$diskpassword" \
                | cryptsetup open --type luks ${i} "$devtarget"
            actlist="$actlist /dev/mapper/$devtarget"
            devindex=$((devindex+1))
        done
    fi
    if is_lvm "$devlist"; then
        echo "setup lvm pv and vg"
        vgname="$(substr_vgname "$devlist")"
        lvm pvcreate -f -y $actlist
        lvm vgcreate -y "$vgname" $actlist
        echo "create format and mount lv lvm-root"
        lvm lvcreate -y --size "${root_lvm_vol_size}" "$vgname" --name lvm-root
        "mkfs.$(substr_fstype "$devlist")" -q -L root "/dev/$vgname/lvm-root"
        mount "/dev/$vgname/lvm-root" "$basedir"
    elif is_zfs "$devlist"; then
        echo "create root zpool"
        create_root_zpool "$basedir" \
            "$(if test "$devcount" != 1; then echo "mirror"; fi)" $actlist
    else
        echo "format and mount root"
        "mkfs.$(substr_fstype "$devlist")" -q -L root "$actlist"
        mount "$actlist" "$basedir"
    fi
}

create_root_finished() {
    if is_zfs "$(by_partlabel ROOT)"; then
        # TODO explain
        zfs set devices=off "rpool/ROOT"
    fi
}

create_lvm_volume() { # volpath volname volsize
    # eg. vgroot/data username 20gb
    local volpath volname volsize
    volpath="$1"; volname="$2"; volsize="$3"
    echo "create lvm volume $volpath/$volname"
    lvcreate -y --size "$volsize" "$volpath" --name "$volname"
}

create_zfs_childfs() { # volpath volname
    # eg. rpool/data/home username
    local volpath volname mountpath
    volpath=$1; volname=$2; mountpath="";
    shift 2
    if test "$1" = "--mount" -a "$2" != ""; then
        mountpath="$2"
        shift 2
    fi
    echo "create zfs volume $volpath/$volname"
    zfs create "$volpath/$volname"
}

create_homedir() { # relativbase username
    if is_zfs "$(by_partlabel ROOT)"; then
        create_zfs_childfs "rpool/data/$1" "$2"
    fi
}

create_file_swap() { # <swap_size-in-mb:default=1024>
    local swap_size
    swap_size="$1"
    if "$swap_size" = ""; then swap_size="1024"; fi
    swap_size="${swap_size}M"

    if is_zfs "$(by_partlabel ROOT)"; then
        zfs create  \
            -V $swap_size \
            -b "$(getconf PAGESIZE)" \
            -o compression=zle \
            -o logbias=throughput \
            -o sync=always \
            -o primarycache=metadata \
            -o secondarycache=none \
            -o com.sun:auto-snapshot=false \
            -o local.custom:auto-backup=false \
            "$(get_zfs_pool ROOT)/swap"
        mkswap -y "/dev/zvol/$(get_zfs_pool ROOT)/swap"
    else
        echo "ERROR: FIXME swap file generation on ext4/xfs is requested but not implemented!"
    fi
}


# ### Activate/Deactivate raid,crypt,lvm, write out storage configuration

activate_raid() {
    local p all_mdadm this_md
    all_mdadm=$(mdadm --examine --brief --scan --config=partitions)
    for p in BOOT SWAP ROOT DATA; do
        if is_raid "$(by_partlabel $p)"; then
            if test ! -e /dev/md/mdadm-${p,,}; then
                this_md=$(echo "$all_mdadm" \
                    | grep -E ".+name=[^:]+:mdadm-${p,,}$" \
                    | sed -r "s/ARRAY ([^ ]+) .+/\1/g")
                if test "$this_md" != ""; then
                    echo "deactivate mdadm raid on $this_md because name is different"
                    mdadm --manage --stop $this_md
                fi
                echo "activate mdadm raid on $p"
                mdadm --assemble /dev/md/mdadm-${p,,} $(by_partlabel $p)
            else
                echo "warning: mdadm raid on ${p,,} already activated"
            fi
        fi
    done
}

deactivate_raid() {
    local p
    for p in BOOT SWAP ROOT DATA; do
        if is_raid "$(by_partlabel $p)"; then
            if test -e /dev/md/mdadm-${p,,}; then
                echo "deactivate mdadm raid on $p"
                mdadm --manage --stop /dev/md/mdadm-${p,,}
            fi
        fi
    done
}

crypt_start_one() { # luksname passphrase
    local luksname passphrase device
    luksname="$1"
    passphrase="$2"
    device="$(cat /etc/crypttab | grep "^$1" | sed -r "s/$1 ([^ ]+)( .+)/\1/g")"
    if test -e /dev/mapper/$luksname; then
        echo "warning: luks mapper $luksname already activated"
    else
        if test "$passphrase" = ""; then
            cryptsetup open --type luks "$device" "$luksname"
        else
            printf "%s" "$passphrase" \
                | cryptsetup -q open --type luks  "$device" "$luksname" --key-file=-
        fi
    fi
}

activate_crypt() { # passphrase
    local devlist devcount actlist passphrase p
    passphrase="$1"
    for p in SWAP ROOT DATA; do
        if is_crypt "$(by_partlabel $p)"; then
            devlist=$(by_partlabel "$p")
            devcount=$(echo "$devlist" | wc -w)
            actlist="luks-${p,,}"
            echo "activate luks on $actlist"
            if (test "$devcount" = "2" && is_zfs "$devlist"); then
                crypt_start_one ${actlist}1 "$passphrase"
                crypt_start_one ${actlist}2 "$passphrase"
            else
                crypt_start_one ${actlist} "$passphrase"
            fi
        fi
    done
}

deactivate_crypt() {
    local p
    for p in SWAP ROOT DATA; do
        if is_crypt "$(by_partlabel $p)"; then
            if test -e /dev/mapper/luks-${p,,}; then
                echo "deactivate luks on luks-${p,,}"
                cryptdisks_stop "luks-${p,,}"
            fi
        fi
    done
}

activate_lvm() {
    local p
    if (is_lvm "$(by_partlabel ROOT)" || is_lvm "$(by_partlabel DATA)"); then
        lvm vgscan -v
    fi
    for p in ROOT DATA; do
        if is_lvm "$(by_partlabel $p)"; then
            lvm vgchange --activate y "$(substr_vgname "$devlist")"
        fi
    done
}

deactivate_lvm() {
    local lv vg
    for lv in $(lvm lvs -o vg_name,lv_name,lv_device_open --no-headings \
        | grep -E ".+open[[:space:]]*$" \
        | sed -r "s/[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+.+/\1\/\2/g"); do
        lvchange -a n $lv
    done
    for vg in $(lvm vgs -o vg_name --no-headings); do
        vgchange -a n $vg
    done
}

create_fstab() {
    local devlist devcount devtarget
    if test -e /etc/fstab; then rm /etc/fstab; fi

    devlist=$(by_partlabel BOOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        if is_zfs "$devlist"; then
            cat >> /etc/fstab << EOF
bpool/BOOT/ubuntu   /boot   zfs     defaults 0 0
EOF
        else
            devtarget="$devlist"
            if is_raid "$devlist"; then devtarget="/dev/md/mdadm-boot"; fi
            cat >> /etc/fstab << EOF
UUID=$(dev_fs_uuid "$devtarget") /boot $(substr_fstype "$devlist") defaults 0 1
EOF
        fi
    fi

    devlist=$(by_partlabel EFI)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1"; then
        cat >> /etc/fstab << EOF
PARTUUID=$(dev_part_uuid "$devlist") /efi vfat 0 1
EOF
    else
        cat >> /etc/fstab << EOF
PARTUUID=$(dev_part_uuid "$(echo "$devlist" | x_of 1)") /efi   vfat defaults 0 1
PARTUUID=$(dev_part_uuid "$(echo "$devlist" | x_of 2)") /efi2  vfat defaults 0 1
EOF
    fi

    devlist=$(by_partlabel SWAP)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        devtarget="$devlist"
        if is_raid "$devlist"; then devtarget="/dev/md/mdadm-swap"; fi
        if is_crypt "$devlist"; then devtarget="/dev/mapper/luks-swap"; fi
        cat >> /etc/fstab << EOF
$devtarget swap swap defaults
EOF
    fi

    devlist=$(by_partlabel ROOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        if is_zfs "$devlist"; then
            cat >> /etc/fstab << EOF
rpool/ROOT/ubuntu   /boot   zfs     defaults 0 0
EOF
        else
            devtarget="$devlist"
            if is_raid "$devlist"; then devtarget="/dev/md/mdadm-root"; fi
            if is_crypt "$devlist"; then devtarget="/dev/mapper/luks-root"; fi
            if is_lvm "$devlist"; then
                devtarget="/dev/$(substr_vgname "$devlist")/lvm-root"
            fi
            cat >> /etc/fstab << EOF
UUID=$(dev_fs_uuid "$devtarget")    /   $(substr_fstype "$devlist")   defaults 0 1
EOF
        fi
    fi
}


create_crypttab() {
    local devlist devcount thisdev p
    if test -e /etc/crypttab; then rm /etc/crypttab; fi
    for p in root data swap; do
        devlist=$(by_partlabel "${p^^}")
        devcount=$(echo "$devlist" | wc -w)

        if is_crypt "$devlist"; then
            echo "configure crypttab for $p"
            if (test "$devcount" = "2" && is_zfs "$devlist"); then
                    cat >> /etc/crypttab << EOF
luks-${p}1 /dev/disk/by-partuuid/$(dev_part_uuid "$(echo "$devlist" | x_of 1)") none luks,discard
luks-${p}2 /dev/disk/by-partuuid/$(dev_part_uuid "$(echo "$devlist" | x_of 2)") none luks,discard
EOF
            else
                if test "$devcount" = "1"; then
                    thisdev="/dev/disk/by-partuuid/$(dev_part_uuid "$devlist")"
                else
                    thisdev="/dev/disk/by-uuid/$(dev_fs_uuid /dev/md/mdadm-${p})"
                fi
                cat >> /etc/crypttab << EOF
luks-${p} $thisdev none luks,discard
EOF
            fi
        fi
    done
}


# ### Mounting / Unmounting

mount_root() { # basedir force:true|false
    local basedir import_opts devlist devcount
    basedir=$1
    import_opts=""
    devlist=$(by_partlabel ROOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$2" = "true"; then import_opts="-f"; fi

    mkdir -p "$basedir"
    if is_zfs "$devlist"; then
        echo "import rpool"
        zpool import $import_opts -N -R "$basedir" rpool
        echo "mount root at $basedir"
        zfs mount rpool/ROOT/ubuntu
        zfs mount -a || echo "Warning: could not mount all zfs volumes!"
    elif is_lvm "$devlist"; then
        echo "mount $(substr_vgname "$devlist")/lvm-root at $basedir"
        mount "/dev/$(substr_vgname "$devlist")/lvm-root" "$basedir"
    else
        echo "mount root at $basedir"
        mount /dev/disk/by-label/root "$basedir"
    fi
}

mount_boot() { # basedir force:true|false
    local basedir import_opts
    basedir=$1
    import_opts=""
    if test "$2" = "true"; then import_opts="-f"; fi

    if test "$(by_partlabel BOOT)" != ""; then
        mkdir -p "$basedir/boot"
        if is_zfs "$(by_partlabel BOOT)"; then
            echo "import bpool"
            zpool import $import_opts -N -R "$basedir/boot" bpool
            echo "mount bpool/BOOT/ubuntu at $basedir/boot"
            zfs mount bpool/BOOT/ubuntu
        else
            echo "mount boot at $basedir/boot"
            mount /dev/disk/by-label/boot "$basedir/boot"
        fi
    fi
}

mount_data() { # basedir force:true|false
    local basedir import_opts devlist devcount
    basedir=$1
    import_opts=""
    devlist=$(by_partlabel DATA)
    devcount=$(echo "$devlist" | wc -w)
    if test "$2" = "true"; then import_opts="-f"; fi

    if test "$devlist" != ""; then
        if is_zfs "$devlist"; then
            echo "import dpool"
            mkdir -p "$basedir/data"
            zpool import $import_opts -N -R "$basedir/data" dpool
        elif is_lvm "$devlist"; then
            echo "doing nothing, as lvm VG of DATA has no default volumes"
        fi
    fi
}

mount_efi() { # basedir
    local basedir devlist devcount
    basedir=$1;
    devlist=$(by_partlabel EFI)
    devcount=$(echo "$devlist" | wc -w)
    mkdir -p "$basedir/efi"
    if test "$devcount" = "1"; then
        echo "mount efi at $basedir/efi"
        mount "/dev/disk/by-partlabel/EFI" "$basedir/efi"
    elif test "$devcount" = "2"; then
        mkdir -p "$basedir/efi2"
        echo "mount efi and efi2 at $basedir/efi $basedir/efi2"
        mount "/dev/disk/by-partlabel/EFI1" "$basedir/efi"
        mount "/dev/disk/by-partlabel/EFI2" "$basedir/efi2"
    fi
}

mount_bind_mounts() { # basedir
    local basedir=$1
    echo "mount dev run proc sys"
    mount --rbind /dev "$basedir/dev"
    mount --make-rslave "$basedir/dev"
    mount --rbind /run  "$basedir/run"
    mount --make-rslave "$basedir/run"
    mount proc-live -t proc "$basedir/proc"
    mount sysfs-live -t sysfs "$basedir/sys"
}

unmount_bind_mounts() { # basedir
    local basedir=$1
    echo "unmount sys proc run dev"
    for i in sys proc run dev; do
        if mountpoint -q "$basedir/$i"; then
            mount --make-private "$basedir/$i"
            umount -R "$basedir/$i"
        fi
    done
}

unmount_efi() { # basedir
    local basedir=$1
    echo "unmount efi*"
    for i in efi efi2; do
        if mountpoint -q "$basedir/$i"; then umount -l "$basedir/$i"; fi
    done
}

unmount_boot() { # basedir
    local basedir=$1
    if is_zfs "$(by_partlabel BOOT)"; then
        zfs unmount bpool
        zpool export bpool
    else
        if mountpoint -q "$basedir/boot"; then umount -l "$basedir/boot"; fi
    fi
}

unmount_data() { # basedir
    local basedir=$1
    if is_zfs "$(by_partlabel DATA)"; then
        zfs unmount dpool
        zpool export dpool
    else
        if mountpoint -q "$basedir/data"; then umount -l "$basedir/data"; fi
    fi
}

unmount_root() { # basedir
    local basedir=$1
    if is_zfs "$(by_partlabel ROOT)"; then
        zfs unmount rpool
        zpool export rpool
    else
        if mountpoint -q "$basedir"; then umount -l "$basedir"; fi
    fi
}


# ### ZFS Pool generation

create_boot_zpool() { # basedir zpool-create-parameter (eg. mirror sda1 sda2)
    local basedir=$1
    shift
    zpool create \
        -o ashift=12 \
        -d \
        -o feature@async_destroy=enabled \
        -o feature@bookmarks=enabled \
        -o feature@embedded_data=enabled \
        -o feature@empty_bpobj=enabled \
        -o feature@enabled_txg=enabled \
        -o feature@extensible_dataset=enabled \
        -o feature@filesystem_limits=enabled \
        -o feature@hole_birth=enabled \
        -o feature@large_blocks=enabled \
        -o feature@lz4_compress=enabled \
        -o feature@spacemap_histogram=enabled \
        -o feature@userobj_accounting=enabled \
        -O normalization=formD \
        -O compression=lz4 \
        -O xattr=sa \
        -O acltype=posixacl \
        -O relatime=on \
        -O devices=off \
        -O canmount=off \
        -O mountpoint=/ \
        -R "$basedir" \
        bpool "$@"

    # bpool/BOOT
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT
    zfs create -o canmount=noauto -o mountpoint=/boot bpool/BOOT/ubuntu
}


create_data_zpool() { # basedir zpool-create-args* (eg. mirror sda1 sda2)
    local basedir=$1
    shift
    # XXX ashift 12 or 13 (4096/8192 byte sectors) depending disk
    zpool create \
        -o ashift=12 \
        -O normalization=formD \
        -O compression=lz4 \
        -O xattr=sa \
        -O acltype=posixacl \
        -O relatime=on \
        -O canmount=off \
        -O mountpoint=/data \
        -R "$basedir" \
        dpool "$@"

    zfs create \
        -o setuid=off \
        -o exec=off \
        -o canmount=off \
        -o mountpoint=none \
        -o com.sun:auto-snapshot=true \
        "dpool/data"
}


create_root_zpool() { # basedir zpool-create-args* (eg. mirror sda1 sda2)
    local basedir=$1
    shift
    # XXX ashift 12 or 13 (4096/8192 byte sectors) depending disk
    zpool create \
        -o ashift=12 \
        -O normalization=formD \
        -O compression=lz4 \
        -O xattr=sa \
        -O acltype=posixacl \
        -O relatime=on \
        -O canmount=off \
        -O mountpoint=/ \
        -R "$basedir" \
        rpool "$@"

    # root=rpool/ROOT/ubuntu
    zfs create  -o canmount=off \
                -o mountpoint=none \
                rpool/ROOT
    zfs create  -o canmount=noauto \
                -o mountpoint=/ \
                -o com.sun:auto-snapshot:frequent=true \
                -o com.sun:auto-snapshot:hourly=false \
                -o com.sun:auto-snapshot:daily=true \
                -o com.sun:auto-snapshot:weekly=false \
                -o com.sun:auto-snapshot:monthly=false \
                rpool/ROOT/ubuntu

    # mount future root ("/") to $basedir/
    zfs mount rpool/ROOT/ubuntu

    # data to be saved: rpool/data
    zfs create  -o setuid=off \
                -o exec=off \
                -o canmount=off \
                -o mountpoint=none \
                -o com.sun:auto-snapshot:frequent=true \
                -o com.sun:auto-snapshot:hourly=true \
                -o com.sun:auto-snapshot:daily=true \
                -o com.sun:auto-snapshot:weekly=true \
                -o com.sun:auto-snapshot:monthly=true \
                rpool/data

    # rpool/data/home at /home
    zfs create  -o setuid=off \
                -o exec=on \
                -o mountpoint=/home \
                rpool/data/home

    # rpool/data/home/root at /root
    zfs create  -o mountpoint=/root \
                rpool/data/home/root

    # rpool/data/mail at /var/lib/mail
    mkdir -p "$basedir/var/lib"
    zfs create  -o mountpoint=/var/lib/mail \
                rpool/data/mail

    # rpool/data/postgresql
    zfs create  -o recordsize=16K \
                -o logbias=throughput \
                -o primarycache=metadata \
                rpool/data/postgresql

    # rpool/data/postgresql/localhost at /var/lib/postgresql
    zfs create  -o mountpoint=/var/lib/postgresql \
                rpool/data/postgresql/localhost

    # ephemeral rpool/var
    zfs create  -o com.sun:auto-snapshot:frequent=true \
                -o com.sun:auto-snapshot:hourly=false \
                -o com.sun:auto-snapshot:daily=false \
                -o com.sun:auto-snapshot:weekly=false \
                -o com.sun:auto-snapshot:monthly=false \
                -o local.custom:auto-backup=false \
                -o logbias=throughput \
                -o canmount=off \
                rpool/var
    zfs create  -o canmount=off \
                rpool/var/lib

    zfs create  -o mountpoint=/tmp \
                rpool/var/basedir-tmp
    chmod 1777 "$basedir/tmp"
    zfs create  rpool/var/tmp
    chmod 1777 "$basedir/var/tmp"

    zfs create  rpool/var/spool
    zfs create  rpool/var/backups
    zfs create -o exec=off \
                rpool/var/log
    zfs create -o exec=off \
                rpool/var/cache
    zfs create  -o exec=on \
                -o devices=on \
                rpool/var/cache/pbuilder

    mkdir -p "$basedir/var/lib/apt/lists"
    zfs create  -o exec=off \
                -o mountpoint=/var/lib/apt/lists
                rpool/var/lib/apt-lists
    mkdir -p "$basedir/var/lib/snapd"
    zfs create  rpool/var/lib/snapd
    mkdir -p "$basedir/var/lib/libvirt"
    zfs create  rpool/var/lib/libvirt
}
