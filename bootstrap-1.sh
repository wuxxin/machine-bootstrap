#!/bin/bash
set -eo pipefail
# set -x

self_path=$(dirname "$(readlink -e "$0")")


usage() {
    cat <<EOF
Usage: cat diskkey | $0 hostname firstuser disklist --yes [optional parameter]

optional parameter (must be ordered as listed):

--root-lvm-vol-size <volsizemb>
    if lvm is used, define the capacity of the lvm root volume, defaults to 20480 (20gb)
--data-lvm-vol-size <volsizemb>
    if lvm is used, define the capacity of the lvm data volume, defaults to 20480 (20gb)
--distrib_id <name>
    select a different distribution (default=$distrib_id)
--distrib_codename <name>
    select a different distribution version (default=$distrib_codename)
--restore-from-backup
    partition and format system, restore from backup, adapt to new storage

"http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"
EOF
    exit 1
}

warn_rename() { # targetfile
    local targetfile=$1
    if test -e "$targetfile"; then
        echo "WARNING: target $targetfile exists, renaming to ${targetfile}.old"
        mv "$targetfile" "${targetfile}.old"
    fi
}


# defaults
distrib_id="ubuntu"
distrib_codename="focal"
root_lvm_vol_size="20480"
data_lvm_vol_size="$root_lvm_vol_size"
option_restore_backup=false

# parse args
if test "$4" != "--yes"; then usage; fi
hostname=$1; firstuser=$2; disklist=$3
shift 4
if test "$hostname" = "${hostname%%.*}"; then hostname="${hostname}.local"; fi
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
if test "$1" = "--root-lvm-vol-size"; then root_lvm_vol_size="$2"; shift 2; fi
if test "$1" = "--data-lvm-vol-size"; then data_lvm_vol_size="$2"; shift 2; fi
if test "$1" = "--distrib-id"; then distrib_id=$2; shift 2; fi
if test "$1" = "--distrib-codename"; then distrib_codename=$2; shift 2; fi
if test "$1" = "--restore-from-backup"; then option_restore_backup=true; shift; fi

# distrib_id can be one of "ubuntu", "debian", "nixos", "manjaro"
# check for valid distrib_id and set default distrib_codename if not ubuntu
# distrib_codename is nixos channel (eg. 19.09) in case of distrib_id=nixos
distrib_id=$(echo "$distrib_id" |  tr '[:upper:]' '[:lower:]')
if test "$distrib_id" != "ubuntu" -a \
        "$distrib_id" != "debian" -a \
        "$distrib_id" != "nixos"  -a \
        "$distrib_id" != "manjaro" ; then
    echo "Error: Unknown distrib_id($distrib_id)"
    exit 1
fi
if test "$distrib_id" != "ubuntu" -a "distrib_codename" = "focal"; then
    if test "$distrib_id" = "debian"; then distrib_codename="buster"; fi
    if test "$distrib_id" = "nixos"; then distrib_codename="19.09"; fi
    if test "$distrib_id" = "manjaro"; then distrib_codename="stable"; fi
fi

# if http_proxy is set, reexport for sub-processes
if test "$http_proxy" != ""; then export http_proxy; fi

# include library
. "$self_path/bootstrap-library.sh"

# show important settings to user
cat << EOF
Configuration:
hostname: $hostname, firstuser: $firstuser
fulldisklist: $(for i in $fulldisklist; do echo -n " $i"; done)
http_proxy: $http_proxy
distrib_id: $distrib_id
distrib_codename: $distrib_codename
option_restore_backup: $option_restore_backup
root_lvm_vol_size: $root_lvm_vol_size
data_lvm_vol_size: $data_lvm_vol_size
EOF

# ## main
cd /tmp
if which cloud-init > /dev/null; then
    echo -n "waiting for cloud-init finish..."
    cloud-init status --wait || true
fi

echo "set target hostname in current system"
setup_hostname "$hostname"

echo "FIXME: generate new systemd machineid (/etc/machine-id) in active system"
if test -e /etc/machine-id; then
    echo "fixme machine-id"
fi

echo "configuring nfs (which get pulled in by zfsutils) to be restricted to localhost"
configure_nfs

echo "install needed packages"
packages="$(get_default_packages) $(get_zfs_packages)"
install_packages --refresh $packages

echo "generate new zfs hostid (/etc/hostid) in active system"
if test -e /etc/hostid; then rm /etc/hostid; fi
zgenhostid

# create & mount target filesystems
create_and_mount_root /mnt "$diskpassword" $root_lvm_vol_size
create_boot
create_data "$diskpassword" $data_lvm_vol_size
create_swap "$diskpassword"
create_homedir home $firstuser
mount_boot /mnt
mount_efi /mnt
mount_data /mnt/mnt

if test "$option_restore_backup" = "true"; then
    echo "call bootstrap-1-restore"
    chmod +x /tmp/bootstrap-1-restore.sh
    /tmp/bootstrap-1-restore.sh "$hostname" "$firstuser" --yes && err=$? || err=$?
    if test "$err" != "0"; then echo "Backup - Restore Error $err"; exit $err; fi
else
    # install base system
    if test "$distrib_id" = "ubuntu" -o "$distrib_id" = "debian"; then
        echo "install minimal base $distrib_codename system"
        debootstrap --verbose "$distrib_codename" /mnt
    elif test "$distrib_id" = "manjaro"; then
        install_manjaro /mnt $distrib_codename
    elif test "$distrib_id" = "nixos"; then
        install_nixos /mnt $distrib_codename
    else
        echo "Error: Unknown distrib_id($distrib_id)"
        exit 1
    fi
fi
create_root_finished

if test "$distrib_id" != "ubuntu" -a "$distrib_id" != "debian"; then
    echo "swap off"; swapoff -a || true
    unmount_data /mnt/mnt
    unmount_efi /mnt
    unmount_boot /mnt
    unmount_root /mnt
    deactivate_lvm
    deactivate_luks
    deactivate_mdadm
    exit 0
fi

# chroot preperations
echo "copy/overwrite machine-id (/etc/machine-id)"
cp -a /etc/machine-id /mnt/etc/machine-id

echo "copy/overwrite hostid (/etc/hostid)"
cp -a /etc/hostid /mnt/etc/hostid

echo "copy authorized_keys"
install -m "0700" -d /mnt/root/.ssh
warn_rename /mnt/root/.ssh/authorized_keys
cp /tmp/authorized_keys /mnt/root/.ssh/authorized_keys
chmod "0600" /mnt/root/.ssh/authorized_keys

echo "copy network netplan config to 50-default.yaml"
warn_rename /mnt/etc/netplan/50-default.yaml
cp -a /tmp/netplan.yaml /mnt/etc/netplan/50-default.yaml

echo "copy bootstrap files for chroot install"
echo "copying dracut files to /usr/lib/dracut/modules.d/46sshd"
mkdir -p /mnt/usr/lib/dracut/modules.d/46sshd
cp -a -t /mnt/usr/lib/dracut/modules.d/46sshd /tmp/dracut/*

echo "copying recovery files to /etc/recovery"
mkdir -p /mnt/etc/recovery/zfs
cp -a -t /mnt/etc/recovery /tmp/recovery/*
if test -d /tmp/recovery/zfs; then
    echo "copying files to /etc/recovery/zfs"
    cp -a -t /mnt/etc/recovery/zfs /tmp/zfs/*
fi

echo "copy bootstrap-library.sh to /tmp and /etc/recovery"
cp /tmp/bootstrap-library.sh /mnt/etc/recovery

echo "copy ssh hostkeys to /etc/recovery"
cp /tmp/recovery_hostkeys /mnt/etc/recovery
chmod 0600 /mnt/etc/recovery/recovery_hostkeys

echo "copy bootstrap-2.sh and bootstrap-library.sh to /tmp"
cp /tmp/bootstrap-library.sh /mnt/tmp
cp /tmp/bootstrap-2.sh /mnt/tmp
chmod +x /mnt/tmp/bootstrap-2.sh

mount_bind_mounts /mnt

bootstrap2_postfix=""
if test "$option_restore_backup" = "true"; then
    bootstrap2_postfix="--restore-from-backup"
fi
echo "call bootstrap-2 $bootstrap2_postfix in chroot"
chroot /mnt /tmp/bootstrap-2.sh \
    "$hostname" "$firstuser" --yes $bootstrap2_postfix
echo "back in bootstrap-1-install"

if test "$option_restore_backup" = "true"; then
    echo "call bootstrap-2-restore"
    cp -a /tmp/bootstrap-2-restore.sh /mnt/tmp
    chmod +x /mnt/tmp/bootstrap-2-restore.sh
    chroot /mnt /tmp/bootstrap-2-restore.sh \
        "$hostname" "$firstuser" --yes && err=$? || err=$?
    echo "back in bootstrap-1-install"
    if test "$err" != "0"; then echo "Backup - Restore Error $err"; exit $err; fi
fi

echo "copy initrd and system ssh host keys from install"
mkdir -p /tmp/ssh_hostkeys
for i in initrd_ssh_host_ed25519_key.pub ssh_host_ed25519_key.pub ssh_host_rsa_key.pub; do
    cp /mnt/etc/ssh/$i /tmp/ssh_hostkeys
done

echo "swap off"; swapoff -a || true
unmount_bind_mounts /mnt
unmount_data /mnt/mnt
unmount_efi /mnt
unmount_boot /mnt
unmount_root /mnt
deactivate_lvm
deactivate_luks
deactivate_mdadm
