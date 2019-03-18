#!/bin/bash
set -eo pipefail
set -x


usage() {
    cat <<EOF
Usage: cat diskkey | $0 hostname firstuser disklist --yes [optional args]

optional args:
--frankenstein
    backport and patch zfs-linux with no-d-revalidate.patch
--restore-from-backup
    partition+ format system, restore from backup, modify system

"http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"
EOF
    exit 1
}


create_zpool() {
    # call with create_zpool username zpool-create-args*
    
    # create zpool
    # XXX ashift 12 or 13 (4096/8192 byte sectors) depending disk
    zpool create \
        -o ashift=12 \
        -O mountpoint=/ \
        -O normalization=formD \
        -O compression=lz4 \
        -O xattr=sa \
        -O acltype=posixacl \
        -O relatime=on \
        -O canmount=off \
        -R /mnt \
        rpool "$@"

    # rpool/ROOT/ubuntu
    zfs create  -o canmount=off \
                -o mountpoint=none \
                rpool/ROOT
    zfs create  -o canmount=noauto \
                -o mountpoint=/ \
                rpool/ROOT/ubuntu
    zfs mount   rpool/ROOT/ubuntu
    # set bootfs default
    zpool set bootfs=rpool/ROOT/ubuntu rpool

    # rpool/home
    zfs create  -o setuid=off \
                -o mountpoint=/home \
                rpool/home
    zfs create  -o mountpoint=/root \
                rpool/home/root

    # rpool/log
    mkdir -p /mnt/var
    zfs create  -o exec=off \
                -o mountpoint=/var/log \
                rpool/log

    # rpool/data
    zfs create  -o setuid=off \
                -o exec=off \
                -o mountpoint=/data \
                rpool/data 

    # rpool/data/mail at /var/lib/mail
    mkdir -p /mnt/var/lib
    zfs create  -o mountpoint=/var/lib/mail \
                rpool/data/mail

    # rpool/data/postgresql
    zfs create  -o recordsize=16K \
                -o logbias=throughput \
                -o primarycache=metadata \
                rpool/data/postgresql

    # rpool/data/postgresql/__host__ at /var/lib/postgresql
    zfs create  -o mountpoint=/var/lib/postgresql \
                rpool/data/postgresql/__host__

    # ephemeral
    # rpool/volatile
    zfs create  -o com.sun:auto-snapshot:daily=false \
                -o com.sun:auto-snapshot:weekly=false \
                -o com.sun:auto-snapshot:monthly=false \
                -o custom.local:auto-backup=false \
                -o logbias=throughput \
                -o mountpoint=/volatile \
                rpool/volatile

    # rpool/volatile/base-tmp at /tmp
    zfs create  -o mountpoint=/tmp \
                rpool/volatile/base-tmp 
    chmod 1777 /mnt/tmp
    
    # rpool/volatile/var-tmp at /var/tmp
    zfs create  -o mountpoint=/var/tmp \
                rpool/volatile/var-tmp
    chmod 1777 /mnt/var/tmp

    # rpool/volatile/cache at /var/cache
    zfs create  -o exec=off \
                -o mountpoint=/var/cache \
                rpool/volatile/var-cache

    # rpool/volatile/lib-apt-lists at /var/lib/apt/lists
    mkdir -p /var/lib/apt/lists
    zfs create  -o exec=off \
                -o mountpoint=/var/lib/apt/lists \
                rpool/volatile/var-lib-apt-lists

}


create_zpool_swap()
{
    swapsize="$1"
    if "$swapsize" = ""; then 
        swapsize="1024"
    fi
    swapsize="${swapsize}M"
    zfs create  \
        -V $swapsize \
        -b "$(getconf PAGESIZE)" \
        -o compression=zle \
        -o logbias=throughput \
        -o sync=always \
        -o primarycache=metadata \
        -o secondarycache=none \
        -o com.sun:auto-snapshot=false \
        -o custom.local:auto-backup=false \
        rpool/swap
    mkswap -f /dev/zvol/rpool/swap
}


# ### main

# partition paths by label and partlabel
EFI=/dev/disk/by-partlabel/EFI
BOOT=/dev/disk/by-label/boot
LUKSROOT=/dev/disk/by-partlabel/LUKSROOT
LUKSSWAP=/dev/disk/by-partlabel/LUKSSWAP
DMROOT=/dev/disk/by-id/dm-name-luks-root
MDADM_BOOT_ARRAY="${BOOT}1 ${BOOT}2"
MDADM_SWAP_ARRAY="${LUKSSWAP}1 ${LUKSSWAP}2"


# parse args
if test "$4" != "--yes"; then usage; fi
hostname=$1
if test "$hostname" = "${hostname%%.*}"; then
    hostname="${hostname}.local"
fi
firstuser=$2
disklist=$3
shift 4
fulldisklist=$(for i in $disklist; do echo "/dev/disk/by-id/${i} "; done)
diskcount=$(echo "$disklist" | wc -w)
if test "$diskcount" -gt "2"; then
    echo "ERROR: script only works with one or two disks, but disks=$diskcount"
    exit 1
fi
diskpassword=$(cat -)
if test "$diskpassword" = ""; then
    echo "ERROR: script needs diskpassword from stdin, abort"
    exit 1
fi
option_frankenstein=false
option_restore_backup=false
if test "$1" = "--frankenstein"; then option_frankenstein=true; shift; fi
if test "$1" = "--restore-from-backup"; then option_restore_backup=true; shift; fi

# if http_proxy is set, reexport for sub-processes
if test "$http_proxy" != ""; then export http_proxy; fi

# show important settings to user
echo "hostname: $hostname, firstuser: $firstuser, fulldisklist=$fulldisklist, http_proxy: $http_proxy"


# ## execution
if which cloud-init > /dev/null; then
    echo -n "waiting for cloud-init finish..."
    cloud-init status --wait
fi

echo "set hostname to $hostname in active system"
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
hostnamectl set-hostname "$shortname"

# compile custom zfs-linux if requested
if $option_frankenstein; then
    echo "selected frankenstein option"
    if test ! -e /tmp/zfs/build-custom-zfs.sh -o ! -e /tmp/zfs/no-dops-snapdirs.patch; then
        echo "error: could not find needed files for frankenstein zfs-linux build, continue without custom build"
    else
        echo "build-custom-zfs"
        chmod +x /tmp/zfs/build-custom-zfs.sh
        /tmp/zfs/build-custom-zfs.sh /tmp/zfs/basedir
        if test -e /usr/local/lib/custom-apt-archive; then
            rm -rf /usr/local/lib/custom-apt-archive
        fi
        mkdir -p /usr/local/lib/custom-apt-archive
        mv -t /usr/local/lib/custom-apt-archive /tmp/zfs/basedir/zfsbuild/buildresult/*
        rm -rf /tmp/zfs/basedir
        cat > /etc/apt/sources.list.d/local-apt-archive.list << EOF
deb file:/usr/local/lib/custom-apt-archive ./
EOF
        DEBIAN_FRONTEND=noninteractive apt-get update --yes
    fi
fi

echo "install needed packages"
packages="cryptsetup gdisk mdadm grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed efibootmgr squashfs-tools curl ca-certificates bzip2 tmux zfsutils-linux haveged debootstrap libc-bin"
DEBIAN_FRONTEND=noninteractive apt-get install --yes $packages

echo "generate new zfs hostid (/etc/hostid) in active system"
if test -e /etc/hostid; then rm /etc/hostid; fi
zgenhostid

if test ! -e $BOOT; then
    echo "activate mdadm boot partition"
    mdadm --assemble /dev/md/mdadm-boot $MDADM_BOOT_ARRAY
fi

if test -e "$LUKSROOT"; then
    echo "create luks root partition"
    echo "$diskpassword" | cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 $LUKSROOT
    echo "open luks root partition"
    echo "$diskpassword" | cryptsetup luksOpen $LUKSROOT luks-root
    echo "create zfs pool"
    create_zpool "$DMROOT"
else
    echo "create luks root 1&2 partitions"
    echo "$diskpassword" | cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 ${LUKSROOT}1
    echo "$diskpassword" | cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 ${LUKSROOT}2
    echo "open luks root 1&2 partitions"
    echo "$diskpassword" | cryptsetup luksOpen ${LUKSROOT}1 luks-root1
    echo "$diskpassword" | cryptsetup luksOpen ${LUKSROOT}2 luks-root2
    echo "create zfs mirror pool"
    create_zpool mirror "${DMROOT}1" "${DMROOT}2"
fi
zfs create  "rpool/home/$firstuser"

if test -e $LUKSSWAP; then
    echo "create luks swap partition"
    # /lib/cryptsetup/scripts/decrypt_derived luks-root
    echo "$diskpassword" | cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 $LUKSSWAP
    echo "open and format as swap"
    # /lib/cryptsetup/scripts/decrypt_derived luks-root
    echo "$diskpassword" | cryptsetup luksOpen $LUKSSWAP luks-swap
    echo "format swap"
    mkswap /dev/mapper/luks-swap
elif test -e "${LUKSSWAP}1" -a -e "${LUKSSWAP}2"; then
    echo "create mdadm swap partition"
    mdadm --create /dev/md/mdadm-swap -v -f -R --level=mirror --raid-disks=2 --assume-clean --name=mdadm-swap $MDADM_SWAP_ARRAY
    echo "create luks swap partition"
    # /lib/cryptsetup/scripts/decrypt_derived luks-root
    echo "$diskpassword" | cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 /dev/md/mdadm-swap
    echo "open luks swap partition"
    # /lib/cryptsetup/scripts/decrypt_derived luks-root
    echo "$diskpassword" | cryptsetup luksOpen /dev/md/mdadm-swap luks-swap
    echo "format swap"
    mkswap /dev/mapper/luks-swap
fi

echo "mount boot"
mkdir -p /mnt/boot
mount $BOOT /mnt/boot

echo "mount efi*"
mkdir -p /mnt/boot/efi
if test -e "$EFI"; then
    mount $EFI /mnt/boot/efi
else
    mkdir -p /mnt/boot/efi2
    mount ${EFI}1 /mnt/boot/efi
    mount ${EFI}2 /mnt/boot/efi2
fi

if $option_restore_backup; then
    echo "call bootstrap-1-restore"
    chmod +x /tmp/bootstrap-1-restore.sh
    /tmp/bootstrap-1-restore.sh "$hostname" "$firstuser" --yes && err=$? || err=$?
    if test "$err" != "0"; then
        echo "Backup - Restore Error $err"
        exit $err
    fi
else
    echo "install minimal base system"
    debootstrap --verbose bionic /mnt
fi

# TODO explain
zfs set devices=off rpool

# https://github.com/zfsonlinux/zfs/issues/5754
echo "workaround zol < 0.8 missing zfs-mount-generator"
for i in volatile/base-tmp volatile/var-tmp volatile/var-cache volatile/var-lib-apt-lists log; do
    zfs set mountpoint=legacy rpool/$i
done
mkdir -p /mnt/etc/recovery

if test -e /mnt/etc/recovery/legacy.fstab -a "$option_restore_backup" = "true"; then
    echo "WARNING: --restore-from-backup: not overwriting /etc/recovery/legacy.fstab"
else
    cat > /mnt/etc/recovery/legacy.fstab <<EOF
rpool/volatile/base-tmp     /tmp        zfs  nodev,relatime,xattr,posixacl          0 0
rpool/volatile/var-tmp      /var/tmp    zfs  nodev,relatime,xattr,posixacl          0 0
rpool/volatile/var-cache    /var/cache  zfs  nodev,noexec,relatime,xattr,posixacl   0 0
rpool/log                   /var/log    zfs  nodev,noexec,relatime,xattr,posixacl   0 0
rpool/volatile/var-lib-apt-lists  /var/lib/apt/lists  zfs nodev,noexec,relatime,xattr,posixacl  0 0
EOF
fi
cat /mnt/etc/recovery/legacy.fstab | \
    sed -r "s/^([^ ]+)( +)([^ ]+)( +)(.+)/\1\2\/mnt\3\4\5/g" > /tmp/legacy.fstab
mount -a -T /tmp/legacy.fstab

echo "copy/overwrite hostid (/etc/hostid)"
cp -a /etc/hostid /mnt/etc/hostid

echo "copy authorized_keys"
install -m "0700" -d /mnt/root/.ssh
if test -e /mnt/root/.ssh/authorized_keys; then
    echo "WARNING: target /root/.ssh/authorized_keys exists, renaming to old"
    mv /mnt/root/.ssh/authorized_keys /mnt/root/.ssh/authorized_keys.old
fi
cp /tmp/authorized_keys /mnt/root/.ssh/authorized_keys
chmod "0600" /mnt/root/.ssh/authorized_keys

echo "copy network config"
if test -e /mnt/etc/netplan/80-lan.yaml; then
    echo "WARNING: target /etc/netplan/80-lan.yml exists, renaming to old"
    mv /mnt/etc/netplan/80-lan.yaml /mnt/etc/netplan/80-lan.yaml.old
fi
cp -a /tmp/netplan.yaml /mnt/etc/netplan/80-lan.yaml

echo "copy additional bootstrap files"
mkdir -p /mnt/usr/lib/dracut/modules.d/46sshd
cp -a -t /mnt/usr/lib/dracut/modules.d/46sshd /tmp/initrd/*
mkdir -p /mnt/etc/recovery
cp -a -t /mnt/etc/recovery /tmp/recovery/*
cp /tmp/recovery_hostkeys /mnt/etc/recovery
chmod 0600 /mnt/etc/recovery/recovery_hostkeys
cp /tmp/bootstrap-2-chroot-install.sh /mnt/tmp
chmod +x /mnt/tmp/bootstrap-2-chroot-install.sh

echo "mount dev proc sys run"
for i in dev proc sys run; do
    mount --rbind /$i /mnt/$i
done

if $option_restore_backup; then
    echo "call bootstrap-2-chroot-install in chroot with --restore-from-backup"
    chroot /mnt /tmp/bootstrap-2-chroot-install.sh "$hostname" "$firstuser" --yes --restore-from-backup
    echo "back in bootstrap-1-install"
    echo "call bootstrap-2-chroot-restore"
    cp -a /tmp/bootstrap-2-chroot-restore.sh /mnt/tmp
    chmod +x /mnt/tmp/bootstrap-2-chroot-restore.sh
    chroot /mnt /tmp/bootstrap-2-chroot-restore.sh "$hostname" "$firstuser" --yes && err=$? || err=$?
    echo "back in bootstrap-1-install"
    if test "$err" != "0"; then
        echo "Backup - Restore Error $err"
        exit $err
    fi
else
    echo "call bootstrap-2-chroot in chroot"
    chroot /mnt /tmp/bootstrap-2-chroot-install.sh "$hostname" "$firstuser" --yes
    echo "back in bootstrap-1-install"
fi

echo "unmount all"
for i in run sys proc dev boot/efi boot/efi2 boot; do
    if mountpoint -q "/mnt/$i"; then umount -lf "/mnt/$i"; fi
done

sleep 1
echo "export pool"
zpool export rpool
