#!/bin/bash
set -eo pipefail
# set -x

self_path=$(dirname "$(readlink -e "$0")")

usage() {
    cat <<EOF
Usage: cat diskkey | $0 hostname firstuser disklist --yes [optional parameter]

+ optional parameter

--distrib-id <name>
    select a different distribution (default=$distrib_id)
--distrib-codename <name>
    select a different ubuntu/debian distribution version (default=$distrib_codename)
--distrib-branch <name>
    select a different manjaro distribution branch (default=$distrib_branch)
--distrib-profile <name>
    select a different manjaro distribution profile (default=$distrib_profile)

--root-lvm-vol-size <volsizemb>
    if lvm is used, define the capacity of the lvm root volume, defaults to 20480 (20gb)
--data-lvm-vol-size <volsizemb>
    if lvm is used, define the capacity of the lvm data volume, defaults to 20480 (20gb)

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

# parse mandatory args
if test "$4" != "--yes"; then usage; fi
hostname=$1
firstuser=$2
disklist=$3
shift 4
# if test "$hostname" = "${hostname%%.*}"; then hostname="${hostname}.local"; fi
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

# defaults
distrib_id="manjaro"
distrib_codename="focal"
distrib_branch="stable"
distrib_profile="manjaro/gnome"
root_lvm_vol_size="20480"
data_lvm_vol_size="$root_lvm_vol_size"
option_restore_backup=false

# parse optional args
OPTS=$(getopt -o "" -l restore-from-backup,root-lvm-vol-size:,data-lvm-vol-size:,distrib-id:,distrib-codename:,distrib-branch:,distrib-profile: -- "$@")
[[ $? -eq 0 ]] || usage
eval set -- "${OPTS}"
while true; do
    case $1 in
    --restore-from-backup) option_restore_backup="true" ;;
    --root-lvm-vol-size)
        root_lvm_vol_size="$2"
        shift
        ;;
    --data-lvm-vol-size)
        data_lvm_vol_size="$2"
        shift
        ;;
    --distrib-id)
        distrib_id="$2"
        shift
        ;;
    --distrib-codename)
        distrib_codename="$2"
        shift
        ;;
    --distrib-branch)
        distrib_branch="$2"
        shift
        ;;
    --distrib-profile)
        distrib_profile="$2"
        shift
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

# distrib_id can be one of "ubuntu", "debian", "manjaro"
# check for valid distrib_id and set defaults
distrib_id=$(echo "$distrib_id" | tr '[:upper:]' '[:lower:]')
if test "$distrib_id" != "ubuntu" -a \
    "$distrib_id" != "debian" -a \
    "$distrib_id" != "manjaro"; then
    echo "Error: Unknown distrib_id($distrib_id)"
    exit 1
fi
if test "$distrib_id" = "debian"; then
    if test "$distrib_codename" = "focal"; then distrib_codename="buster"; fi
    distrib_branch=""
    distrib_profile=""
elif test "$distrib_id" = "manjaro"; then
    distrib_codename=""
fi
# if http_proxy is set, reexport for sub-processes
if test "$http_proxy" != ""; then export http_proxy; fi

# include library
. "$self_path/bootstrap-library.sh"

# show important settings to user
cat <<EOF

Configuration:

hostname: $hostname, firstuser: $firstuser
fulldisklist: $(for i in $fulldisklist; do echo -n " $i"; done)
http_proxy: $http_proxy

distrib_id: $distrib_id , distrib_codename: $distrib_codename
distrib_branch: $distrib_branch , distrib_profile: $distrib_profile

option_restore_backup: $option_restore_backup
root_lvm_vol_size: $root_lvm_vol_size
data_lvm_vol_size: $data_lvm_vol_size

EOF

# ## main
cd /tmp
if which cloud-init &>/dev/null; then
    printf "waiting for cloud-init finish..."
    cloud-init status --wait || printf "exited with error: $?"
    printf "\n"
fi

echo "set target hostname in current system"
configure_hostname "$hostname"

if test ! -e /etc/machine-id; then
    echo "generate new systemd machineid (/etc/machine-id) in active system"
    uuidgen -r | tr -d "-" >/etc/machine-id
fi

packages="$(get_default_packages) $(get_zfs_packages)"
echo "install needed packages: $packages"
install_packages --refresh $packages

echo "generate new zfs hostid (/etc/hostid) in active system"
if test -e /etc/hostid; then rm /etc/hostid; fi
zgenhostid

# create & mount target filesystems
create_and_mount_root /mnt "$distrib_id" "$diskpassword" "$root_lvm_vol_size"
create_boot /mnt "$distrib_id"
create_data "$diskpassword" $data_lvm_vol_size
create_swap "$diskpassword"
create_homedir home $firstuser
mount_boot /mnt
mount_efi /mnt
mount_data /mnt

# copy machine-id, hostid, zpool-cache and authorized_keys before bootstraping
mkdir -p /mnt/etc
echo "copy/overwrite machine-id (/etc/machine-id)"
cp -a /etc/machine-id /mnt/etc/machine-id

echo "copy/overwrite hostid (/etc/hostid)"
cp -a /etc/hostid /mnt/etc/hostid

if test -e "/etc/zfs/zpool.cache"; then
    echo "copy zpool.cache"
    mkdir -p /mnt/etc/zfs
    cp -a /etc/zfs/zpool.cache /mnt/etc/zfs/
fi

echo "copy authorized_keys"
install -m "0700" -d /mnt/root/.ssh
warn_rename /mnt/root/.ssh/authorized_keys
cp /tmp/authorized_keys /mnt/root/.ssh/authorized_keys
chmod "0600" /mnt/root/.ssh/authorized_keys

if test "$option_restore_backup" = "true"; then
    echo "call bootstrap-1-restore"
    chmod +x /tmp/bootstrap-1-restore.sh
    /tmp/bootstrap-1-restore.sh "$hostname" "$firstuser" --yes && err=$? || err=$?
    if test "$err" != "0"; then
        echo "Backup - Restore Error $err"
        exit $err
    fi
else
    echo "install base system $distrib_id:$distrib_codename:$distrib_branch:$distrib_profile"
    if test "$distrib_id" = "ubuntu" -o "$distrib_id" = "debian"; then
        echo "install minimal base $distrib_codename system"
        debootstrap "$distrib_codename" /mnt
    elif test "$distrib_id" = "manjaro"; then
        bootstrap_manjaro /mnt $distrib_branch $distrib_profile
    else
        echo "Error: Unknown distrib_id: $distrib_id"
        exit 1
    fi
fi

# bootstrap-2 preperations
echo "copy bootstrap-2-${distrib_id}.sh bootstrap-2-restore.sh and bootstrap-library.sh to /root on target"
cp /tmp/bootstrap-library.sh /mnt/root
cp /tmp/bootstrap-2-restore.sh /mnt/root
cp /tmp/bootstrap-2-${distrib_id}.sh /mnt/root
chmod +x /mnt/root/bootstrap-2-restore.sh
chmod +x /mnt/root/bootstrap-2-${distrib_id}.sh

# network configuration
if test "$distrib_id" = "ubuntu"; then
    echo "copy network netplan config to 80-default.yaml"
    warn_rename /mnt/etc/netplan/80-default.yaml
    cp -a /tmp/netplan.yaml /mnt/etc/netplan/80-default.yaml
elif test "$distrib_id" = "manjaro"; then
    echo "copy systemd.network config to 80-default.network"
    warn_rename /mnt/etc/systemd/network/80-default.network
    cp -a /tmp/systemd.network /mnt/etc/systemd/network/80-default.network
fi

# bootstrap-2 execution
bootstrap2_chroot="chroot"
bootstrap2_postfix=""
if test "$option_restore_backup" = "true"; then bootstrap2_postfix="--restore-from-backup"; fi
if test "$distrib_id" = "manjaro"; then bootstrap2_chroot="manjaro-chroot"; fi
if test "$distrib_id" = "ubuntu" -o "$distrib_id" = "debian"; then
    echo "mount bind mounts"
    mount_bind_mounts /mnt
fi

echo "call bootstrap-2-${distrib_id}.sh $bootstrap2_postfix in chroot"
$bootstrap2_chroot /mnt /root/bootstrap-2-${distrib_id}.sh \
    "$hostname" "$firstuser" --yes $bootstrap2_postfix
if test "$option_restore_backup" = "true"; then
    echo "call bootstrap-2-restore.sh in chroot"
    $bootstrap2_chroot /mnt /root/bootstrap-2-restore.sh \
        "$hostname" "$firstuser" --yes && err=$? || err=$?
    if test "$err" != "0"; then
        echo "Backup - Restore Error $err"
        exit $err
    fi
fi

if test "$distrib_id" = "ubuntu" -o "$distrib_id" = "debian"; then
    echo "unmount bind mounts"
    unmount_bind_mounts /mnt
fi
echo "back in bootstrap-1-install"

# housekeeping: copy host ssh public keys to install pc
echo "copy initrd and system ssh host keys from install"
mkdir -p /tmp/ssh_hostkeys
for i in initrd_ssh_host_ed25519_key.pub ssh_host_ed25519_key.pub ssh_host_rsa_key.pub; do
    if test -e /mnt/etc/ssh/$i; then cp /mnt/etc/ssh/$i /tmp/ssh_hostkeys; fi
done

# unmount and deactivate all storage
echo "swap off"
swapoff -a || true
unmount_data /mnt
unmount_efi /mnt
unmount_boot /mnt
unmount_root /mnt
deactivate_zfs_pools
deactivate_lvm
deactivate_luks
deactivate_mdadm
