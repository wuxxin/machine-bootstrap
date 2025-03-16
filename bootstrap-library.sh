#!/bin/bash

# ### encryption options
# How long is a secure passphrase ?
#   https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions#5-security-aspects
#   LUKS1 and LUKS2: Use > 65 bit. That is e.g. 14 random chars from a-z
#   or a random English sentence of > 108 characters length.

luks_encryption_options() {
    echo "-c aes-xts-plain64 -s 512 -h sha256"
    # LUKS chiper recommendation:
    #   For LUKS, the key size chosen is 512 bits.
    #   However, XTS mode requires two keys, so the LUKS key is split in half.
    #   Thus, -s 512 means AES-256
}


zfs_encryption_options() {
    echo "-O encryption=aes-256-gcm -O keyformat=passphrase"
    # ZFS chiper recommendation:
    #   ZFS native encryption defaults to aes-256-ccm, but the default has
    #   changed upstream to aes-256-gcm. AES-GCM seems to be generally preferred
    #   over AES-CCM, is faster now, and will be even faster in the future.
    #   https://crypto.stackexchange.com/questions/6842/how-to-choose-between-aes-ccm-and-aes-gcm-for-storage-volume-encryption
}


# ### default packages

get_default_packages() {
    if which apt-get &> /dev/null; then
        echo "cryptsetup gdisk mdadm lvm2 grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed efibootmgr squashfs-tools openssh-server curl gnupg gpgv ca-certificates bzip2 libc-bin rsync tmux haveged debootstrap"
    elif which pamac &> /dev/null; then
        echo "cryptsetup gptfdisk mdadm lvm2 grub openssh curl gnupg ca-certificates bzip2 rsync tmux manjaro-tools-iso git"
    else
        echo "Error: unknown platform, add list for other platforms in get_default_packages"
        exit 1
    fi
}


get_zfs_packages() {
    if which apt-get &> /dev/null; then
        echo "zfsutils-linux"
    elif which pamac &> /dev/null; then
        echo "zfs-utils"
    else
        echo "Error: unknown platform, add cmds for other platforms in get_zfs_packages"
        exit 1
    fi
}



# ### tool functions
# mk_partlabel, by_partlabel, x_of, first_of, is_substr, substr_fstype, substr_vgname
# dev_fs_uuid, dev_part_uuid, is_enczfs, is_zfs, is_lvm, is_mdadm, is_luks
# get_efi1_mountpath, get_efi2_mountpath

mk_partlabel() { # diskcount crypt=true/false/native lvm=vgname/""/false fs=""/ext4/xfs/zfs partname
    local diskcount crypt lvm fs partname label
    diskcount=$1; crypt=$2; lvm=$3; fs=$4; partname=$5; label=""
    if test "$diskcount" != "1" -a "$fs" != "zfs"; then
        label="raid_"
    fi
    if test "$crypt" = "true" -o "$crypt" = "native"; then
        if test "$crypt" = "true" -o "$fs" != "zfs"; then
            label="${label}luks_"
        else
            label="enc${label}"
        fi
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


is_enczfs() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "enczfs_"
}


is_zfs() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "zfs_"
}


is_lvm() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "lvm."
}


is_mdadm() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "raid_"
}


is_luks() { # devpathlist
    is_substr "$(basename "$(echo "$@" | first_of)")" "luks_"
}


dev_fs_uuid() { # devpath
    blkid -s UUID -o value "$1"
}


dev_part_uuid() { # devpath
    blkid -s PARTUUID -o value "$1"
}


get_efi1_mountpath() {
    local mountpath bootcount
    mountpath=/boot
    bootcount="$(by_partlabel BOOT | wc -w)"
    if test "$bootcount" = 1 -o "$bootcount" = 2; then mountpath=/efi; fi
    echo "$mountpath"
}


get_efi2_mountpath() {
    echo "/efi2"
}



# ### Create and format partitions
# create_efi, create_swap, create_boot, create_boot_zpool
# create_and_mount_root, create_root_zpool, create_data, create_data_zpool
# create_lvm_volume, create_zfs_childfs, create_homedir, create_file_swap
# create_fstab, create_crypttab, create_zpool_cachefile

create_efi() {
    local devlist devcount
    devlist=$(by_partlabel EFI)
    devcount=$(echo "$devlist" | wc -w)

    for disk in $devlist; do
        echo "format $disk with fat"
        mkfs.fat -F 32 "$disk"
    done
}


create_swap() { # diskpassword
    local diskpassword devlist devcount targetdev
    diskpassword="$1"
    devlist=$(by_partlabel SWAP)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        if test "$devcount" != "1"; then
            echo "create mdadm swap partition $devlist"
            echo "y" | mdadm --create /dev/md/$(hostname):mdadm-swap -v \
                --symlinks=yes --assume-clean \
                --level=mirror "--raid-disks=${devcount}" \
                $devlist
            targetdev="/dev/md/$(hostname):mdadm-swap"
        else
            targetdev="$devlist"
        fi
        echo "create luks swap partition $targetdev"
        echo "$diskpassword" \
            | cryptsetup luksFormat $(luks_encryption_options) "$targetdev"
        echo "$diskpassword" \
            | cryptsetup open --type luks "$targetdev" luks-swap
        udevadm settle --exit-if-exists=/dev/mapper/luks-swap
        echo "format swap"
        mkswap -L swap /dev/mapper/luks-swap
    fi
}


create_boot() { # basedir distrib_id
    local basedir distrib_id devlist devcount
    basedir="$1"
    distrib_id="$2"
    devlist=$(by_partlabel BOOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        if is_zfs "$devlist"; then
            echo "create zfs boot pool (bpool for $distrib_id) $devlist"
            create_boot_zpool "$basedir" "$distrib_id" \
                "$(if test "$devcount" != 1; then echo "mirror"; fi)" $devlist
        else
            if test "$devcount" != 1; then
                echo "create mdadm-boot $devlist"
                echo "y" | mdadm --create /dev/md/$(hostname):mdadm-boot -v \
                    --symlinks=yes --assume-clean \
                    --level=mirror "--raid-disks=${devcount}" \
                    $devlist
                actlist="/dev/md/$(hostname):mdadm-boot"
            else
                actlist="$devlist"
            fi
            echo "format boot"
            "mkfs.$(substr_fstype "$devlist")" -q -L boot "$actlist"
        fi
    fi
}


create_boot_zpool() { # basedir distrib_id zpool-create-parameter (eg. mirror sda1 sda2)
    local basedir distrib_id
    basedir="$1"
    distrib_id="$2"
    shift 2
    # -d = no default options, because boot pool must be accessable from bootloader
    zpool create \
        -d \
        -o ashift=12 \
        -o autotrim=on \
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
        -O normalization=formD \
        -O xattr=sa \
        -O acltype=posixacl \
        -O relatime=on \
        -O compression=lz4 \
        -O devices=off \
        -O canmount=off \
        -O mountpoint=/boot \
        -R "$basedir" \
        bpool "$@"

    zfs create \
        -o canmount=off \
        -o mountpoint=none \
        bpool/BOOT

    zfs create \
        -o canmount=noauto \
        -o mountpoint=/boot \
        bpool/BOOT/$distrib_id

    # Set the bootfs property so the boot loader knows where to find the operating system
    zpool set bootfs=bpool/BOOT/$distrib_id bpool
}


create_and_mount_root() { # basedir distrib_id diskpassword root_lvm_vol_size
    local basedir distrib_id diskpassword root_lvm_vol_size
    local devlist devcount devindex devtarget actlist templist vgname luksdev
    basedir="$1"; distrib_id="$2"; diskpassword="$3"; root_lvm_vol_size="$4"
    devlist=$(by_partlabel ROOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" != "1" -a "$devcount" != "2"; then
        echo "error: 0 or > 2 ($devcount) devices found. only 1 or 2 are Supported"
        exit 1
    fi
    actlist=$devlist
    if (test "$devcount" != "1" && ! is_zfs "$devlist"); then
        echo "create mdadm-root $actlist"
        echo "y" | mdadm --create /dev/md/$(hostname):mdadm-root -v \
            --symlinks=yes --assume-clean \
            --level=mirror "--raid-disks=${devcount}" \
            $actlist
        actlist=/dev/md/$(hostname):mdadm-root
    fi
    if is_luks "$devlist"; then
        devindex=1
        templist=$actlist
        actlist=""
        for luksdev in $templist; do
            devtarget=luks-root$(if (test "$devcount" != "1" && is_zfs "${luksdev}"); then echo "${i##*ROOT}"; fi)
            echo "setup luks-root $devtarget $luksdev"
            echo "$diskpassword" \
                | cryptsetup luksFormat $(luks_encryption_options) ${luksdev}
            echo "$diskpassword" \
                | cryptsetup open --type luks ${luksdev} "$devtarget"
            actlist="$(if test -n $actlist; then echo "$actlist "; fi)/dev/mapper/$devtarget"
            dmsetup info
            dmsetup mknodes
            flock -s /dev/mapper/$devtarget partprobe /dev/mapper/$devtarget
            devindex=$((devindex+1))
        done
        sleep 5
        dmsetup info
    fi
    if is_lvm "$devlist"; then
        if is_zfs "$devlist"; then
            echo "error: device(s) $devlist are configured for ROOT on lvm *and* zfs which is not supported"
            exit 1
        fi
        vgname="$(substr_vgname "$devlist")"
        echo "setup lvm pv $actlist and vg $vgname"
        lvm pvcreate -f -y $actlist
        lvm vgcreate -y "$vgname" $actlist
        echo "create format and mount lv lvm-root"
        lvm lvcreate -y --size "${root_lvm_vol_size}" "$vgname" --name lvm-root
        "mkfs.$(substr_fstype "$devlist")" -q -L root "/dev/$vgname/lvm-root"
        mount "/dev/$vgname/lvm-root" "$basedir"
    elif is_zfs "$devlist"; then
        if is_enczfs "$devlist"; then
            echo "create native encrypted zfs root pool (rpool for $distrib_id) $actlist"
            create_root_zpool --password "$diskpassword" "$basedir" "$distrib_id" \
                "$(if test "$devcount" != 1; then echo "mirror"; fi)" $actlist
        else
            echo "create zfs root pool (rpool for $distrib_id) $actlist"
            create_root_zpool "$basedir" "$distrib_id" \
                "$(if test "$devcount" != 1; then echo "mirror"; fi)" $actlist
        fi
    else
        echo "format and mount root $actlist"
        "mkfs.$(substr_fstype "$devlist")" -q -L root "$actlist"
        mount "$actlist" "$basedir"
    fi
}



create_root_zpool() { # [--password password] basedir distrib_id zpool-create-args* (eg. mirror sda1 sda2)
    local basedir distrib_id diskpassword option_encrypt diskpassword_file
    diskpassword=""; option_encrypt=""; diskpassword_file="/dev/shm/diskpassword"
    if test "$1" = "--password"; then
        diskpassword=$2; shift 2
        printf "$diskpassword" > ${diskpassword_file}
        option_encrypt="$(zfs_encryption_options) -O keylocation=file://${diskpassword_file}"
    fi
    basedir="$1"
    distrib_id="$2"
    shift 2

    # XXX ashift 12 or 13 (4096/8192 byte sectors) depending disk
    # -O compression=on|off|gzip|gzip-N|lz4|lzjb|zle|zstd|zstd-N|zstd-fast|zstd-fast-N
    zpool create \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl \
        -O xattr=sa \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=on \
        -O compression=lz4 \
        $option_encrypt \
        -O canmount=off \
        -O mountpoint=/ \
        -R "$basedir" \
        rpool "$@"

    if test -e "${diskpassword_file}"; then
        # remove temporary password file from ram
        rm "${diskpassword_file}"
        # set default keylocation back to prompt
        zfs set keylocation=prompt rpool
    fi

    zfs create \
        -o canmount=off \
        -o mountpoint=none \
        -o devices=off \
        rpool/ROOT

    # "/" from ROOT/$distrib_id
    zfs create \
        -o canmount=noauto \
        -o mountpoint=/ \
        -o com.sun:auto-snapshot:frequent=true \
        -o com.sun:auto-snapshot:hourly=false \
        -o com.sun:auto-snapshot:daily=true \
        -o com.sun:auto-snapshot:weekly=false \
        -o com.sun:auto-snapshot:monthly=false \
        rpool/ROOT/$distrib_id

    # Set the bootfs property on the descendant root filesystem
    # so the boot loader knows where to find the operating system
    zpool set bootfs=rpool/ROOT/$distrib_id rpool

    # mount future root ("/") to $basedir/
    zfs mount rpool/ROOT/$distrib_id

    # ephemeral parts of /var
    zfs create \
        -o canmount=off \
        -o com.sun:auto-snapshot:frequent=true \
        -o com.sun:auto-snapshot:hourly=false \
        -o com.sun:auto-snapshot:daily=false \
        -o com.sun:auto-snapshot:weekly=false \
        -o com.sun:auto-snapshot:monthly=false \
        -o local.custom:auto-backup=false \
        -o logbias=throughput \
        rpool/var

    # make /var/lib an unmountable container, so subcontainer have automatic mountpoint
    zfs create \
        -o canmount=off \
        rpool/var/lib
    # create /var/lib (which is part of /var) and other needed base directories
    mkdir -p "$basedir/var/lib"

    # important data to keep: rpool/data
    zfs create \
        -o setuid=off \
        -o exec=off \
        -o canmount=off \
        -o mountpoint=none \
        -o com.sun:auto-snapshot:frequent=true \
        -o com.sun:auto-snapshot:hourly=true \
        -o com.sun:auto-snapshot:daily=true \
        -o com.sun:auto-snapshot:weekly=true \
        -o com.sun:auto-snapshot:monthly=true \
        rpool/data

    # keep in sync with salt-shared/zfs/defaults.jinja/zfs_rpool_defaults, see README.md for snippet
    zfs create -o "mountpoint=/home" -o "setuid=off" -o "exec=on" rpool/data/home
    zfs create -o "mountpoint=/root" rpool/data/home/root
    zfs create -o "mountpoint=/tmp" rpool/var/basedir-tmp
    zfs create rpool/var/tmp
    zfs create rpool/var/spool
    zfs create -o "exec=off" rpool/var/log
    zfs create -o "exec=off" rpool/var/cache

    zfs create -o "recordsize=16K" -o "logbias=throughput" -o "primarycache=metadata" rpool/data/postgresql
    zfs create -o "mountpoint=/var/lib/postgresql" rpool/data/postgresql/localhost
    zfs create -o "mountpoint=/var/lib/mail" rpool/data/mail

    if test "$distrib_id" = "ubuntu" -o "$distrib_id" = "debian"; then
        # for apt based systems
        zfs create rpool/var/backups
        mkdir -p "$basedir/var/lib/apt"
        zfs create -o "exec=off" -o "mountpoint=/var/lib/apt/lists" rpool/var/lib/apt-lists
        # for pbuilder
        zfs create -o "exec=on" -o "devices=on" rpool/var/cache/pbuilder
        # for snaps
        zfs create rpool/var/lib/snapd
    fi
    # for GNOME
    #- name: var/lib/AccountsService
    # for Docker
    # - name: var/lib/docker
    # for NFS
    # - name: var/lib/nfs
    # for LXC
    # - name: var/lib/lxc
    # for LibVirt
    # - name: var/lib/libvirt
    # for podman
    # - name: var/lib/containers
    # for containerd
    # - name: var/lib/containerd

    # keep in sync end

    # correct filepermission for temp directories
    chmod 1777 "$basedir/tmp"
    chmod 1777 "$basedir/var/tmp"
}


create_data() { # diskpassword data_lvm_vol_size
    local diskpassword root_lvm_vol_size
    local devlist devcount devindex devtarget actlist templist vgname luksdev
    diskpassword="$1"; data_lvm_vol_size="$2"
    devlist=$(by_partlabel DATA)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        actlist=$devlist
        if (test "$devcount" != "1" && ! is_zfs "$devlist"); then
            echo "create mdadm-data $actlist"
            echo "y" | mdadm --create /dev/md/$(hostname):mdadm-data -v \
                --symlinks=yes --assume-clean \
                --level=mirror "--raid-disks=${devcount}" \
                $actlist
            actlist=/dev/md/$(hostname):mdadm-data
        fi
        if is_luks "$devlist"; then
            devindex=1
            templist=$actlist
            actlist=""
            for luksdev in $templist; do
                devtarget=luks-data$(if (test "$devcount" != "1" && is_zfs "${luksdev}"); then echo "${i##*DATA}"; fi)
                echo "setup luks $devtarget ${luksdev}"
                echo "$diskpassword" \
                    | cryptsetup luksFormat $(luks_encryption_options) ${luksdev}
                echo "$diskpassword" \
                    | cryptsetup open --type luks ${luksdev} "$devtarget"
                actlist="$actlist /dev/mapper/$devtarget"
                while test ! -L /dev/mapper/$devtarget; do
                    udevadm settle --exit-if-exists=/dev/mapper/$devtarget
                    sleep 1
                done
                devindex=$((devindex+1))
            done
            sleep 2
        fi
        if is_lvm "$devlist"; then
            if is_zfs "$devlist"; then
                echo "error: device(s) $devlist are configured for DATA using lvm *and* zfs which is not supported"
                exit 1
            fi
            vgname="$(substr_vgname "$devlist")"
            echo "setup lvm pv $actlist and vg $vgname"
            lvm pvcreate -f -y $actlist
            lvm vgcreate -y "$vgname" $actlist
            echo "format lv lvm_data"
            lvm lvcreate -y --size "${data_lvm_vol_size}" "$vgname" --name lvm_data
            "mkfs.$(substr_fstype "$devlist")" -q -L data "/dev/$vgname/lvm_data"
        elif is_zfs "$devlist"; then
            if is_enczfs "$devlist"; then
                echo "create native encrypted data zpool $actlist"
                create_data_zpool --password "$diskpassword" "$basedir" \
                    "$(if test "$devcount" != 1; then echo "mirror"; fi)" $actlist
            else
                echo "create data zpool $actlist"
                create_data_zpool "$basedir" \
                    "$(if test "$devcount" != 1; then echo "mirror"; fi)" $actlist
            fi
        else
            if test "$(substr_fstype "$devlist")" = "other"; then
                echo "not touching $actlist as fstype=other"
            else
                echo "format data $actlist"
                "mkfs.$(substr_fstype "$devlist")" -q -L data "$actlist"
            fi
        fi
    fi
}


create_data_zpool() { # [--password password] basedir zpool-create-args* (eg. mirror sda1 sda2)
    local basedir diskpassword option_encrypt diskpassword_file
    diskpassword=""; option_encrypt=""; diskpassword_file="/dev/shm/diskpassword"
    if test "$1" = "--password"; then
        diskpassword=$2; shift 2
        printf "$diskpassword" > ${diskpassword_file}
        option_encrypt="$(zfs_encryption_options) -O keylocation=file://${diskpassword_file}"
    fi
    basedir="$1"
    shift

    # XXX ashift 12 or 13 (4096/8192 byte sectors) depending disk
    zpool create \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl \
        -O xattr=sa \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=on \
        -O compression=lz4 \
        "$option_encrypt" \
        -O canmount=off \
        -O mountpoint=/ \
        -R "$basedir" \
        dpool "$@"

    if test -e "${diskpassword_file}"; then
        # remove temporary password file from ram
        rm "${diskpassword_file}"
        # set default keylocation back to prompt
        zfs set keylocation=prompt dpool
    fi

    zfs create \
        -o setuid=off \
        -o exec=off \
        -o mountpoint=/data \
        -o com.sun:auto-snapshot:frequent=true \
        "dpool/data"
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
            -o compression=lz4 \
            -o logbias=throughput \
            -o sync=always \
            -o primarycache=metadata \
            -o secondarycache=none \
            -o com.sun:auto-snapshot=false \
            -o local.custom:auto-backup=false \
            "$(get_zfs_pool ROOT)/swap"
        mkswap -y "/dev/zvol/$(get_zfs_pool ROOT)/swap"
    else
        echo "ERROR: swap file generation on ext4/xfs is requested but not implemented!"
        exit 1
    fi
}


create_fstab() { # distrib_id
    local devlist devcount devtarget devpath hasboot distrib_id efi_mount_opts
    if test -e /etc/fstab; then rm /etc/fstab; fi
    devlist=$(by_partlabel BOOT)
    devcount=$(echo "$devlist" | wc -w)
    hasboot="false"
    distrib_id="ubuntu"
    efi_mount_opts="x-systemd.idle-timeout=1min,x-systemd.automount,noauto,umask=0022,fmask=0022,dmask=0022 0 1"
    if test "$1" != ""; then distrib_id="$1"; shift; fi

    if test "$devcount" = "1" -o "$devcount" = "2"; then
        hasboot="true"
        if is_zfs "$devlist"; then
            cat >> /etc/fstab << EOF
bpool/BOOT/$distrib_id   /boot   zfs     defaults 0 0
EOF
        else
            devtarget="$devlist"
            if is_mdadm "$devlist"; then devtarget="/dev/md/$(hostname):mdadm-boot"; fi
            cat >> /etc/fstab << EOF
UUID=$(dev_fs_uuid "$devtarget") /boot $(substr_fstype "$devlist") defaults,nofail 0 1
EOF
        fi
    fi

    devlist=$(by_partlabel EFI)
    devcount=$(echo "$devlist" | wc -w)
    if test "$hasboot" = "true"; then devpath=/efi; else devpath=/boot; fi
    if test "$devcount" = "1"; then
        cat >> /etc/fstab << EOF
PARTUUID=$(dev_part_uuid "$devlist") $devpath vfat $efi_mount_opts
EOF
    else
        cat >> /etc/fstab << EOF
PARTUUID=$(dev_part_uuid "$(echo "$devlist" | x_of 1)") $devpath vfat $efi_mount_opts
PARTUUID=$(dev_part_uuid "$(echo "$devlist" | x_of 2)") /efi2  vfat $efi_mount_opts
EOF
    fi

    devlist=$(by_partlabel SWAP)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        devtarget="$devlist"
        if is_mdadm "$devlist"; then devtarget="/dev/md/$(hostname):mdadm-swap"; fi
        if is_luks "$devlist"; then devtarget="/dev/mapper/luks-swap"; fi
        cat >> /etc/fstab << EOF
$devtarget swap swap defaults
EOF
    fi

    devlist=$(by_partlabel ROOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        if is_zfs "$devlist"; then
            cat >> /etc/fstab << EOF
rpool/ROOT/$distrib_id   /   zfs     defaults 0 0
EOF
        else
            devtarget="$devlist"
            if is_mdadm "$devlist"; then devtarget="/dev/md/$(hostname):mdadm-root"; fi
            if is_luks "$devlist"; then devtarget="/dev/mapper/luks-root"; fi
            if is_lvm "$devlist"; then
                devtarget="/dev/$(substr_vgname "$devlist")/lvm-root"
            fi
            cat >> /etc/fstab << EOF
UUID=$(dev_fs_uuid "$devtarget")    /   $(substr_fstype "$devlist")   defaults 0 1
EOF
        fi
    fi
    devlist=$(by_partlabel DATA)
    devcount=$(echo "$devlist" | wc -w)
    if test "$devcount" = "1" -o "$devcount" = "2"; then
        if is_zfs "$devlist"; then
            cat >> /etc/fstab << EOF
dpool/data   /data   zfs     defaults 0 0
EOF
        else
            devtarget="$devlist"
            if is_mdadm "$devlist"; then devtarget="/dev/md/$(hostname):mdadm-data"; fi
            if is_luks "$devlist"; then devtarget="/dev/mapper/luks-data"; fi
            if is_lvm "$devlist"; then
                devtarget="/dev/$(substr_vgname "$devlist")/lvm_data"
            fi
            cat >> /etc/fstab << EOF
UUID=$(dev_fs_uuid "$devtarget")    /data   $(substr_fstype "$devlist")   defaults 0 1
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

        if is_luks "$devlist"; then
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
                    thisdev="/dev/disk/by-uuid/$(dev_fs_uuid /dev/md/$(hostname):mdadm-${p})"
                fi
                cat >> /etc/crypttab << EOF
luks-${p} $thisdev none luks,discard
EOF
            fi
        fi
    done
}


create_zpool_cachefile() {
    local p poolname
    for p in ROOT DATA BOOT; do
        if is_zfs "$(by_partlabel $p)"; then
            poolname=$(printf "${p:0:1}" | tr "[[:upper:]]" "[[:lower:]]"; printf "pool")
            zpool set cachefile=/etc/zfs/zpool.cache $poolname
        fi
    done
}



# ### Activate/Deactivate mdadm, luks, lvm, zfs_pools

activate_mdadm() {
    local p all_mdadm this_md
    all_mdadm=$(mdadm --examine --brief --scan --config=partitions)
    for p in BOOT SWAP ROOT DATA; do
        if is_mdadm "$(by_partlabel $p)"; then
            if test ! -e /dev/md/$(hostname):mdadm-${p,,}; then
                this_md=$(echo "$all_mdadm" \
                    | grep -E "ARRAY.+name=[^:]+:mdadm-${p,,}" \
                    | sed -r "s/ARRAY ([^ ]+) .+/\1/g")
                if test "$this_md" != "" -a "$this_md" != "/dev/md/$(hostname):mdadm-${p,,}"; then
                    echo "deactivate mdadm raid on $this_md because name is different"
                    mdadm --manage --stop $this_md
                fi
                echo "activate mdadm raid on $p"
                mdadm --assemble /dev/md/$(hostname):mdadm-${p,,} $(by_partlabel $p)
            else
                echo "warning: mdadm raid on ${p,,} already activated"
            fi
        fi
    done
}


deactivate_mdadm() {
    local p
    for p in BOOT SWAP ROOT DATA; do
        if is_mdadm "$(by_partlabel $p)"; then
            if test -e /dev/md/$(hostname):mdadm-${p,,}; then
                echo "deactivate mdadm raid on $p"
                mdadm --manage --stop /dev/md/$(hostname):mdadm-${p,,} || echo "failed!"
            fi
        fi
    done
}


luks_start_one() { # luksname passphrase
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


activate_luks() { # passphrase
    local devlist devcount actlist passphrase p
    passphrase="$1"
    for p in SWAP ROOT DATA; do
        if is_luks "$(by_partlabel $p)"; then
            devlist=$(by_partlabel "$p")
            devcount=$(echo "$devlist" | wc -w)
            actlist="luks-${p,,}"
            echo "activate luks on $actlist"
            if (test "$devcount" = "2" && is_zfs "$devlist"); then
                luks_start_one ${actlist}1 "$passphrase"
                luks_start_one ${actlist}2 "$passphrase"
            else
                luks_start_one ${actlist} "$passphrase"
            fi
        fi
    done
}


deactivate_luks() {
    local p
    for p in SWAP ROOT DATA; do
        if is_luks "$(by_partlabel $p)"; then
            if test -e /dev/mapper/luks-${p,,}; then
                echo "deactivate luks on luks-${p,,}"
                cryptdisks_stop "luks-${p,,}" || echo "failed!"
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
            lvm vgchange --activate y "$(substr_vgname "$(by_partlabel $p)")"
        fi
    done
}


deactivate_lvm() {
    local lv vg
    for lv in $(lvm lvs -o vg_name,lv_name,lv_device_open --no-headings \
        | grep -E ".+open[[:space:]]*$" \
        | sed -r "s/[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+.+/\1\/\2/g"); do
        lvchange -a n $lv || echo "deactivate of lv $lv failed!"
    done
    for vg in $(lvm vgs -o vg_name --no-headings); do
        vgchange -a n $vg || echo "deactivate of vg $vg failed!"
    done
}


activate_zfs_pools() { # basedir passphrase force:true|false
    local basedir passphrase p poolname import_opts altroot
    basedir="$1"
    passphrase="$2"
    if test "$3" = "true"; then import_opts="-f"; else import_opts=""; fi

    for p in ROOT DATA BOOT; do
        if is_zfs "$(by_partlabel $p)"; then
            altroot="$basedir"
            if test "$p" != "ROOT"; then
                altroot="$basedir/$(echo $p | tr '[[:upper:]]' '[[:lower:]]')"
            fi
            poolname=$(printf "${p:0:1}" | tr "[[:upper:]]" "[[:lower:]]"; printf "pool")
            echo "zpool import $import_opts -N -R $altroot $poolname"
            zpool import $import_opts -N -R "$altroot" "$poolname"
            if is_enczfs "$(by_partlabel $p)"; then
                echo "zfs load-key -r $poolname"
                printf "%s" "$passphrase" | zfs load-key -r $poolname
            fi
        fi
    done
}


deactivate_zfs_pools() {
    local p poolname
    for p in BOOT DATA ROOT; do
        if is_zfs "$(by_partlabel $p)"; then
            poolname=$(printf "${p:0:1}" | tr "[[:upper:]]" "[[:lower:]]"; printf "pool")
            if is_enczfs "$(by_partlabel $p)"; then
                echo "zfs unload-key -r $poolname"
                zfs unload-key -r $poolname || echo "Warning, zfs unload-key -r $poolname exited with error"
            fi
            echo "zpool export $poolname"
            zpool export $poolname || echo "Warning, zpool export $poolname exited with error"
        fi
    done
}


# ### Mounting / Unmounting root, boot, data, efi, bindmounts

mount_root() { # basedir force:true|false
    local basedir devlist devcount import_opts bootfs
    basedir=$1
    devlist=$(by_partlabel ROOT)
    devcount=$(echo "$devlist" | wc -w)
    if test "$2" = "true"; then import_opts="-f"; else import_opts=""; fi

    mkdir -p "$basedir"
    if is_zfs "$devlist"; then
        bootfs=$(zpool get -H -o value bootfs rpool)
        echo "mount root ($bootfs) at $basedir"
        zfs mount $bootfs
        zfs mount -a || echo "Error: could not mount all zfs volumes!"
    elif is_lvm "$devlist"; then
        echo "mount $(substr_vgname "$devlist")/lvm-root at $basedir"
        mount "/dev/$(substr_vgname "$devlist")/lvm-root" "$basedir"
    else
        echo "mount root at $basedir"
        mount /dev/disk/by-label/root "$basedir"
    fi
}


mount_boot() { # basedir force:true|false
    local basedir import_opts bootfs
    basedir=$1
    import_opts=""
    if test "$2" = "true"; then import_opts="-f"; fi

    if test "$(by_partlabel BOOT)" != ""; then
        mkdir -p "$basedir/boot"
        if is_zfs "$(by_partlabel BOOT)"; then
            bootfs=$(zpool get -H -o value bootfs bpool)
            echo "mount boot ($bootfs) at $basedir/boot"
            zfs mount $bootfs
        else
            echo "mount boot at $basedir/boot"
            mount /dev/disk/by-label/boot "$basedir/boot"
        fi
    fi
}


mount_data() { # basedir force:true|false
    local basedir devlist devcount import_opts
    devlist=$(by_partlabel DATA)
    devcount=$(echo "$devlist" | wc -w)
    basedir=$1
    if test "$2" = "true"; then import_opts="-f"; else import_opts=""; fi

    if test "$devlist" != ""; then
        mkdir -p "$basedir/data"
        if is_zfs "$devlist"; then
            zfs mount dpool
        else
            mount /dev/disk/by-label/data "$basedir/data"
        fi
    fi
}


mount_efi() { # basedir
    local basedir devlist devcount efi1path efi2path
    basedir=$1;
    devlist=$(by_partlabel EFI)
    devcount=$(echo "$devlist" | wc -w)
    efi1path=$(get_efi1_mountpath)
    efi2path=$(get_efi2_mountpath)
    mkdir -p "${basedir}${efi1path}"
    if test "$devcount" = "1"; then
        echo "mount efi at ${basedir}${efi1path}"
        mount "/dev/disk/by-partlabel/EFI" "${basedir}${efi1path}"
    elif test "$devcount" = "2"; then
        mkdir -p "${basedir}${efi2path}"
        echo "mount efi and efi2 at ${basedir}${efi1path} ${basedir}${efi2path}"
        mount "/dev/disk/by-partlabel/EFI1" "${basedir}${efi1path}"
        mount "/dev/disk/by-partlabel/EFI2" "${basedir}${efi2path}"
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


unmount_efi() { # basedir (unused)
    local basedir actdev
    basedir=$1
    for actdev in $(by_partlabel EFI | tr " " "\n" | sort -r | tr "\n" " "); do
        if mountpoint --quiet --devno $actdev; then
            echo "unmount $actdev"
            umount "$actdev"
        fi
    done
}


unmount_boot() { # basedir
    local basedir=$1
    if is_zfs "$(by_partlabel BOOT)"; then
        zfs unmount "$basedir/boot"
    else
        if mountpoint -q "$basedir/boot"; then umount "$basedir/boot"; fi
    fi
}


unmount_data() { # basedir
    local basedir=$1
    if is_zfs "$(by_partlabel DATA)"; then
        zfs unmount "$basedir/data"
    else
        if mountpoint -q "$basedir/data"; then umount "$basedir/data"; fi
    fi
}


unmount_root() { # basedir
    local basedir=$1
    if is_zfs "$(by_partlabel ROOT)"; then
        zfs unmount -a
    else
        if mountpoint -q "$basedir"; then umount "$basedir"; fi
    fi
}



# ### configure zfs, nfs, sshd, hostname

configure_module_zfs() {
    mkdir -p /etc/modprobe.d
    echo "configure zfs fs options"
    arc_max_bytes=$(grep MemTotal /proc/meminfo | awk '{printf("%u",$2*25/100*1024)}')
    echo "use maximum of 25% of available memory for arc zfs_arc_max=$arc_max_bytes bytes"
    echo "options zfs zfs_arc_max=${arc_max_bytes}" >> /etc/modprobe.d/zfs.conf
}


configure_nfs() {
    if which apt-get &> /dev/null; then
        echo "dracut-network pulls in nfs-common which pulls in rpcbind"
        echo "configuring nfs (which get pulled in by zfsutils)"
        echo "restrict to nfs 4 and localhost, disable rpcbind"
        echo "overwriting /etc/default/rpcbind"
        cat > /etc/default/rpcbind << EOF
# restrict rpcbind to localhost only for UDP requests
OPTIONS="-w -l -h 127.0.0.1 -h ::1"
EOF
        mkdir -p /etc/systemd/system/
        echo "mask (disable) rpcbind.service and rpbind.socket, because nfs4 only setup"
        ln -s -f /dev/null /etc/systemd/system/rpcbind.service
        ln -s -f /dev/null /etc/systemd/system/rpcbind.socket
        echo "overwriting /etc/default/nfs-common"
        mkdir -p /etc/default
        cat > /etc/default/nfs-common << EOF
# nfs4 only configuration (-N 2 -N 3, NEED_STATD=no,NEED_IDMAPD=yes)
# Options for rpc.statd, see rpc.statd(8) or http://wiki.debian.org/SecuringNFS
STATDOPTS="--port 32765 --outgoing-port 32766 --name 127.0.0.1 --name ::1"
# If you do not set values for the NEED_ options, they will be attempted
# autodetected; Valid alternatives for the NEED_ options are "yes" and "no".
# Do you want to start the gssd daemon? It is required for Kerberos mounts.
NEED_GSSD=
NEED_STATD="no"
NEED_IDMAPD="yes"
EOF
        echo "overwriting /etc/default/nfs-kernel-server"
        cat > /etc/default/nfs-kernel-server << EOF
# nfs4 only configuration (-N 2 -N 3)
# Number of servers to start up
RPCNFSDCOUNT=8
# Runtime priority of server (see nice(1))
RPCNFSDPRIORITY=0
# Options for rpc.mountd.
RPCMOUNTDOPTS="-N 2 -N 3 --no-udp --manage-gids --port 32767"
# Options for rpc.nfsd.
RPCNFSDOPTS="-N 2 -N 3 --no-udp --host 127.0.0.1 --host ::1"
# Do you want to start the svcgssd daemon? It is only required for Kerberos
# exports. Valid alternatives are "yes" and "no"; the default is "no".
NEED_SVCGSSD=""
# Options for rpc.svcgssd.
RPCSVCGSSDOPTS=""
EOF
    fi
}


configure_sshd() {
    echo "setup sshd, config taken at 2022-01-20 (exkl. ecsda) from https://infosec.mozilla.org/guidelines/openssh.html "
    echo "only use >= 3072-bit-long moduli"
    awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.tmp && mv /etc/ssh/moduli.tmp /etc/ssh/moduli
    echo "do not use and remove all present ecdsa keys"
    for i in ssh_host_ecdsa_key ssh_host_ecdsa_key.pub; do
        if test -e /etc/ssh/$i; then rm /etc/ssh/$i; fi
    done
    cat >> /etc/ssh/sshd_config <<EOF
# ### MACHINE-BOOTSTRAP BEGIN ###
# Supported HostKey algorithms by order of preference.
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
AuthenticationMethods publickey
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com
# ### MACHINE-BOOTSTRAP END ###
EOF
}


configure_hostname() { # hostname
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


# ### install
# install_packages, install_efi_sync, efi_sync, install_grub
# bootstrap_manjaro, bootstrap_nixos

install_packages() { # --refresh package*
    local refresh
    if test "$1" = "--refresh"; then refresh="true"; shift; else refresh="false"; fi
    if which apt-get &> /dev/null; then
        if test "$refresh" = "true"; then
            DEBIAN_FRONTEND=noninteractive apt-get update --yes
        fi
        if test "$1" != ""; then
            DEBIAN_FRONTEND=noninteractive apt-get install --yes $@
        fi
    elif which pamac &> /dev/null; then
        if test "$refresh" = "true"; then
            pacman --sync -yy
        fi
        if test "$1" != ""; then
            pamac install --no-confirm --no-upgrade $@
        fi
    else
        echo "Error: unknown platform, add cmds for other platforms in install_packages"
        exit 1
    fi
}



install_efi_sync() { # efi_src efi_dest bootstrap-library.sh-path
    local efi_src efi_dest bootstrap_library_path
    efi_src="$1"; efi_dest="$2"; bootstrap_library_path="$3"
    cat - > /etc/systemd/system/efi-sync.path << EOF
[Unit]
Description=Copy EFI to EFI2 System Partition
Requires=efi2.mount
After=efi2.mount

[Path]
PathChanged=${efi_src}

[Install]
WantedBy=multi-user.target
EOF
    cat - > /etc/systemd/system/efi-sync.service << EOF
[Unit]
Description=Copy EFI to EFI2 System Partition
RequiresMountsFor=${efi_src}
RequiresMountsFor=${efi_dest}

[Service]
Type=oneshot
ExecStart=/usr/local/lib/machine-bootstrap/storage-efi-sync.sh ${efi_src} ${efi_dest} --yes
EOF
    mkdir -p /usr/local/lib/machine-bootstrap
    cp $bootstrap_library_path /usr/local/lib/machine-bootstrap/bootstrap-library.sh
    cat - > /usr/local/lib/machine-bootstrap/storage-efi-sync.sh <<"EOF"
#!/bin/bash
set -e
self_path=$(dirname "$(readlink -e "$0")")
. "$self_path/bootstrap-library.sh"
efi_src="$1"; efi_dest="$2"
if test "$3" != "--yes"; then
    printf "Usage: $0 <efi_src> <efi_dest> --yes
if both <efi_src> and <efi_dest> are mountpoints, sync files from <efi_src> to <efi_dest>
rsync all files, copy and modify grub related files, binary duplicate  grub/grubenv
"
    exit 1
fi
if ! mountpoint -q "${efi_src}"; then
    echo "did NOT sync efi: no efi_src mount at ${efi_src}"
    exit 0
fi
if ! mountpoint -q "${efi_dest}"; then
    echo "did NOT sync efi: no efi_dest mount at ${efi_dest}"
    exit 0
fi
efi_sync "${efi_src}" "${efi_dest}"
EOF
    chmod +x /usr/local/lib/machine-bootstrap/storage-efi-sync.sh
    systemctl enable efi-sync.service efi-sync.path
}


efi_sync() { # efi_src efi_dest
    local efi_src efi_dest efi_fs_uuid efi2_fs_uuid
    efi_src="$1"; efi_dest="$2"
    efi_fs_uuid=$(dev_fs_uuid "$(by_partlabel EFI | first_of)")
    efi2_fs_uuid=$(dev_fs_uuid "$(by_partlabel EFI | x_of 2)")

    echo "Sync contents of $efi_src to $efi_dest"
    rsync -a --delete-during \
        --exclude grub/grub.cfg \
        --exclude grub/grubenv \
        --exclude "EFI/*/grub.cfg" \
        --exclude "/backup/" --backup --backup-dir "$efi_dest/backup" \
        "$efi_src/" "$efi_dest/"

    if test -e "$efi_src/grub/grub.cfg"; then
        echo "Grub config found"
        mkdir -p $efi_dest/grub

        echo "copy and modify grub/grub.cfg for fsuuid of efi2"
        cat "$efi_src/grub/grub.cfg" \
            | sed -r "s/$efi_fs_uuid/$efi2_fs_uuid/g" \
            > "$efi_dest/grub/grub.cfg"

        if test ! -e "$efi_dest/grub/grubenv"; then
            echo "create empty grub/grubenv"
            grub-editenv "$efi_dest/grub/grubenv" create
        fi
        if test -e "$efi_src/grub/grubenv"; then
            echo "copy grubenv of $efi_src to $efi_dest"
            dd if="$efi_src/grub/grubenv" of="$efi_dest/grub/grubenv" bs=1024 count=1
        fi
    fi
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


bootstrap_manjaro() { # basedir distrib_branch distrib_profile
    local basedir distrib_branch distrib_profile linux_latest
    basedir=$1; distrib_branch=$2; distrib_profile=$3
    if test "$distrib_branch" = ""; then distrib_branch="stable"; fi
    if test "$distrib_profile" = ""; then distrib_profile="manjaro/gnome"; fi

    systemctl enable --now systemd-timesyncd
    pacman-mirrors --api --set-branch "$distrib_branch" --continent
    pacman -Syy --noconfirm archlinux-keyring manjaro-keyring
    pacman-key --init
    pacman-key --populate archlinux manjaro
    # pacman-key --refresh-keys

    echo "cloning profiles"
    git clone https://gitlab.manjaro.org/profiles-and-settings/iso-profiles.git ~/iso-profiles
    cd ~/iso-profiles/$distrib_profile

    # get latest available kernel with zfs support
    linux_latest=$(pamac search -r -q "linux[0-9]+-zfs$" | \
        sort -n -k 1.6 | \tail -1 | sed -r "s/([^-]+)-zfs/\1/g")
    remove_packages="(snapd|zfs-dkms|grub.*)"
    add_packages="${linux_latest}-zfs zfs-utils systemd-resolvconf systemd-boot-manager"
    echo "basestrap profile: $distrib_profile , add: $remove_packages , remove: $add_packages"
    echo "$add_packages" | tr " " "\n" | \
        cat Packages-Root Packages-Mhwd Packages-Desktop - | \
        grep -v "^#" | sed -r "s/(#.+)$//g" | \
        sed -r "s/>(basic|extra|multilib|office) //g" | \
        sed -r "s/KERNEL/$linux_latest/g" | \
        grep -Ev "$remove_packages" | \
        grep -v ">" | sort | uniq | xargs basestrap /mnt
}


bootstrap_nixos() { # basedir distrib_branch
    local basedir distrib_branch
    basedir=$1; distrib_branch=$2
    # add nix build group and user
    groupadd -g 30000 nixbld
    useradd -u 30000 -g nixbld -G nixbld nixbld
    # install nix
    curl https://nixos.org/nix/install | sh
    . /root/.nix-profile/etc/profile.d/nix.sh
    # change channel
    nix-channel --add https://nixos.org/channels/nixos-$distrib_branch nixpkgs
    nix-channel --update
    # install nix bootstrap utilities
    nix-env -iE "_: with import <nixpkgs/nixos> { configuration = {}; }; with config.system.build; [ nixos-generate-config nixos-install nixos-enter manual.manpages ]"

    # generate nix config
    nixos-generate-config --root $basedir

    # make machine-bootstrap.nix config
    efi1="/dev/$(basename "$(readlink -f "/sys/class/block/$(lsblk -no kname "$(by_partlabel EFI | first_of)")/..")")"
    if test "$(by_partlabel EFI | wc -w)" = "2"; then
        efi2="/dev/$(basename "$(readlink -f "/sys/class/block/$(lsblk -no kname "$(by_partlabel EFI | x_of 2)")/..")")"
        cat >> $basedir/configuration.nix << EOF
boot.loader.grub.mirroredBoots = [ { devices = ["$efi1"] ; path = "/efi"; } { devices = ["$efi2"] ; path = "/efi2"; }]
EOF
    else
        cat >> $basedir/configuration.nix << EOF
boot.loader.grub.device = "$efi1"
EOF
    fi
    # casper recovery entry to grub
    EFI_NR=$(cat "/sys/class/block/$(lsblk -no kname "$(by_partlabel EFI | first_of)")/partition")
    efi_grub="hd0,gpt${EFI_NR}"
    efi_fs_uuid=$(dev_fs_uuid "$(by_partlabel EFI | first_of)")
    casper_livemedia=""
    cat >> $basedir/configuration.nix << EOF
boot.loader.grub.extraEntries = ''
$(build-recovery.sh show grub.nix.entry "$efi_grub" "$casper_livemedia" "$efi_fs_uuid")
'';
EOF
    # install Nixos
    PATH="$PATH" NIX_PATH="$NIX_PATH" `which nixos-install` --root $basedir
}
