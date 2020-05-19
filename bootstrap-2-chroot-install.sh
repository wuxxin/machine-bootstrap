#!/bin/bash
set -eo pipefail
#set -x

self_path=$(dirname "$(readlink -e "$0")")


usage() {
    cat <<EOF
Usage: $0 hostname firstuser --yes [--restore-from-backup]

"http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"
EOF
    exit 1
}

restore_warning() {
    echo "WARNING: --restore-from-backup: $@"
}


# parse args
if test "$3" != "--yes"; then usage; fi
hostname=$1
firstuser=$2
shift 3
option_restore_backup=false
if test "$1" = "--restore-from-backup"; then
    option_restore_backup=true
    shift
fi

# include library
. "$self_path/bootstrap-library.sh"

export DEBIAN_FRONTEND=noninteractive

echo "configure locale & timezone"
export LC_MESSAGES="POSIX"
export LANG="en_US.UTF-8"
export LANGUAGE="en_US:en"
if $option_restore_backup; then
    restore_warning "not setting default locale and timezone"
else
    echo -e "LANG=$LANG\nLANGUAGE=$LANGUAGE\nLC_MESSAGES=$LC_MESSAGES\n" > /etc/default/locale
    locale-gen $LANG
    echo "Etc/UTC" > /etc/timezone
    timedatectl set-timezone "Etc/UTC"
fi

setup_hostname "$hostname"

echo "configure apt"
if $option_restore_backup; then
    restore_warning "not overwriting /etc/apt/sources.list"
else
    cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ $(lsb_release -c -s) main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ $(lsb_release -c -s)-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $(lsb_release -c -s)-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $(lsb_release -c -s)-backports main restricted universe multiverse
EOF
fi

if test ! -e /etc/mtab; then
    echo "symlink /etc/mtab to /proc/self/mounts"
    ln -s /proc/self/mounts /etc/mtab
fi
create_fstab
create_crypttab

echo "make grub accessable on /boot/grub"
if test -L /efi; then
    echo "noop: /efi is a symlink, grub will be found on target /boot/grub"
else
    echo "symlink /boot/grub to /efi/grub"
    if test -e /boot/grub; then
        echo "removing grub traces from /boot"
        rm -rf /boot/grub
    fi
    ln -s /efi/grub /boot/grub
fi
if test "$(findmnt -n -o FSTYPE /boot)" = "vfat"; then
    echo "Warning: disable do_symlinks in kernel-img.conf, because boot is on vfat"
    echo "do_symlinks = no" > /etc/kernel-img.conf
fi

echo "add grub casper recovery entry"
EFI_NR=$(cat "/sys/class/block/$(lsblk -no kname "$(by_partlabel EFI | first_of)")/partition")
efi_grub="hd0,gpt${EFI_NR}"
efi_fs_uuid=$(dev_fs_uuid "$(by_partlabel EFI | first_of)")
casper_livemedia=""
mkdir -p /etc/grub.d
/etc/recovery/build-recovery.sh show grub.d/recovery \
    "$efi_grub" "$casper_livemedia" "$efi_fs_uuid" > /etc/grub.d/40_recovery
chmod +x /etc/grub.d/40_recovery

echo "workaround plymouth default theme"
if $option_restore_backup; then
    restore_warning "not overwriting /usr/bin/plymouth-set-default-theme"
else
    cat > /usr/bin/plymouth-set-default-theme <<"EOF"
#!/bin/bash
default="/usr/share/plymouth/themes/default.plymouth"
if test -e $default; then
    basename $(dirname $(readlink -f $default))
else
    echo "text"
fi
EOF
    chmod +x /usr/bin/plymouth-set-default-theme
fi

echo "configure dracut; warning: dracut-network pulls in nfs-kernel-server, nfs-common and rpcbind"
configure_dracut

if $option_restore_backup; then
    restore_warning "not overwriting /etc/default/rpcbind and /etc/systemd/system/rpcbind.socket"
    restore_warning "not overwriting /etc/modprobe.d/zfs.conf"
    restore_warning "not overwriting /etc/modprobe.d/overlay.conf"
else
    configure_nfs
    configure_module_zfs
    configure_module_overlay
fi

echo "update installation"
apt-get update --yes
if $option_restore_backup; then
    restore_warning "not installing base packages"
else
    dpkg-divert --local --rename --divert /usr/sbin/update-initramfs.dpkg-divert \
        --add /usr/sbin/update-initramfs
    cat > /usr/sbin/update-initramfs << EOF
#!/bin/sh
echo "update-initramfs: diverted" >&2
exit 0
EOF
    chmod +x /usr/sbin/update-initramfs
    if systemd-detect-virt --vm --quiet; then flavor="virtual"; else flavor="generic"; fi
    if test "$(lsb_release -c -s)" = "bionic"; then flavor="${flavor}-hwe-18.04"; fi
    echo "install $flavor kernel, bootloader & tools needed for ubuntu-standard"
    apt upgrade --yes
    apt install --yes --no-install-recommends \
        linux-$flavor linux-headers-$flavor linux-image-$flavor linux-tools-$flavor \
        $(systemd-detect-virt --vm --quiet && echo "linux-image-extra-$flavor" || true)
    packages="$(get_default_packages)"
    zfs_packages="$(get_zfs_packages)"
    extra_packages=""
    # XXX workaround ubuntu-minimal, ubuntu-standard depending on initramfs-tools, friendly-recovery
    # while there, remove other unwanted pkgs (ubuntu-advantage-tools, popularity-contest)
    ubuntu_minimal=$(apt-cache depends ubuntu-minimal \
        | grep "Depends:" | sed -r "s/ +Depends: (.+)$/\1/g" \
        | grep -vE "(initramfs-tools|ubuntu-advantage-tools)")
    ubuntu_standard=$(apt-cache depends ubuntu-standard \
        | grep "Depends:" | sed -r "s/ +Depends: (.+)$/\1/g" \
        | grep -vE "(popularity-contest)")
    ubuntu_standard_rec=$(apt-cache depends ubuntu-standard \
        | grep "Recommends:" | sed -r "s/ +Recommends: (.+)$/\1/g" \
        | grep -vE "(friendly-recovery)")
    apt install --yes \
        $packages $zfs_packages $extra_packages \
        $ubuntu_minimal $ubuntu_standard $ubuntu_standard_rec
    # XXX force automatic not to overwrite dracut/10-debian.conf
    cat > /etc/apt/apt.conf.d/90bootstrap-force-existing << EOF
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
}
EOF
    rm -f /usr/sbin/update-initramfs
    dpkg-divert --local --rename --remove /usr/sbin/update-initramfs
    apt install --yes \
        ubuntu-minimal- initramfs-tools- ubuntu-advantage-tools- \
        popularity-contest- friendly-recovery- \
        dracut dracut-network nfs-common rpcbind zfs-dracut
    rm /etc/apt/apt.conf.d/90bootstrap-force-existing
    apt-get --yes clean
fi

echo "create missing system groups"
getent group lpadmin > /dev/null || addgroup --system lpadmin
getent group sambashare > /dev/null || addgroup --system sambashare

if $option_restore_backup; then
    restore_warning "not creating first user $firstuser"
else
    echo "add first user: $firstuser"
    adduser --gecos "" --disabled-password "$firstuser"
    cp -a /etc/skel/.[!.]* "/home/$firstuser/"
    mkdir -p  "/home/$firstuser/.ssh"
    cp /root/.ssh/authorized_keys "/home/$firstuser/.ssh/authorized_keys"
    chmod 700 "/home/$firstuser/.ssh"
    chown "$firstuser:$firstuser" -R "/home/$firstuser/."
    usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo "$firstuser"
fi

echo "configure sshd"
if $option_restore_backup; then
    restore_warning "not overwriting /etc/ssh/sshd"
else
    configure_sshd
fi

echo "rewrite recovery squashfs"
/etc/recovery/update-recovery-squashfs.sh --host "$hostname"

echo "setup dracut initrd"
echo "writing new dracut /etc/ssh/initrd_ssh_host_ed25519_key[.pub]"
if test -e /etc/ssh/initrd_ssh_host_ed25519_key; then
    echo "WARNING: removing old /etc/ssh/initrd_ssh_host_ed25519_key"
    rm /etc/ssh/initrd_ssh_host_ed25519_key
fi
mkdir -p /etc/ssh
ssh-keygen -q -t ed25519 -N '' -f "/etc/ssh/initrd_ssh_host_ed25519_key"
echo "create initrd using dracut"
for version in $(find /boot -maxdepth 1 -name "vmlinuz*" | sed -r "s#^/boot/vmlinuz-(.+)#\1#g"); do
    if test -e /lib/modules/$version; then
        dracut --force /boot/initrd.img-${version} "${version}"
    else
        echo "Warning: skipping kernel $version (found in /boot), because /lib/modules/$version is not existing"
    fi
done

echo "setup grub"
sed -r -i.bak 's/^(GRUB_CMDLINE_LINUX=).*/\1"quiet splash"/g' /etc/default/grub
# plymouth:debug
# plymouth.enable=0 initcall_debug no_console_suspend ignore_loglevel pm_test console=ttyS0,115200
if test -e "/dev/mapper/luks-swap"; then
    echo "hibernation support: add resume config to grub defaults"
    sed -r -i.bak 's/^(GRUB_CMDLINE_LINUX_DEFAULT=).*/\1"resume=UUID='$(dev_fs_uuid /dev/mapper/luks-swap)'"/g' /etc/default/grub
fi
if ! grep -q GRUB_RECORDFAIL_TIMEOUT /etc/default/grub; then
    echo "GRUB_RECORDFAIL_TIMEOUT=3" >> /etc/default/grub
fi


echo "install grub"
update-grub
if test ! -e /efi/grub/grubenv; then
    grub-editenv /efi/grub/grubenv create
fi
efi_disk=/dev/$(basename "$(readlink -f \
    "/sys/class/block/$(lsblk -no kname "$(by_partlabel EFI | first_of)")/..")")
install_grub /efi "$efi_disk"
if test "$(by_partlabel EFI | wc -w)" = "2"; then
    efi_disk=/dev/$(basename "$(readlink -f \
    "/sys/class/block/$(lsblk -no kname "$(by_partlabel EFI | x_of 2)")/..")")
    install_grub /efi2 "$efi_disk"
    install_efi_sync
    # efi_sync will be started on next reboot automatically, do a manual sync now
    efi_sync /efi /efi2
fi
echo "exit from chroot"
