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
hostname=$1; firstuser=$2; shift 3
restore_backup=false
if test "$1" = "--restore-from-backup"; then restore_backup=true; shift; fi

# if http_proxy is set, reexport for sub-processes
if test "$http_proxy" != ""; then export http_proxy; fi

# include library
. "$self_path/bootstrap-library.sh"

export LANG="en_US.UTF-8"
export LC_MESSAGES="POSIX"
export LANGUAGE="en_US:en"
export KEYMAP="us"
export TIMEZONE="Etc/UTC"

if $restore_backup; then
    restore_warning "not setting locale, locale-messages, keymap, timezone and hostname"
else
    echo "calling systemd-firstboot to set locale, locale-messages, keymap, timezone and hostname"
    systemd-firstboot --locale="$LANG" --locale-messages="$LC_MESSAGES" \
        --keymap="$KEYMAP" --timezone="$TIMEZONE" --hostname="$hostname"
fi

echo "create fstab, crypttab, zpool cache"
create_fstab "manjaro"
create_crypttab
create_zpool_cachefile

if $restore_backup; then
    restore_warning "not overwriting /etc/modprobe.d/zfs.conf"
else
    configure_module_zfs
fi

if $restore_backup; then
    restore_warning "not creating first user $firstuser"
else
    echo "create first user: $firstuser"
    useradd -m -G lp,network,power,sys,wheel -s /bin/bash $firstuser
    cp -a /etc/skel/.[!.]* "/home/$firstuser/"
    mkdir -p  "/home/$firstuser/.ssh"
    cp /root/.ssh/authorized_keys "/home/$firstuser/.ssh/authorized_keys"
    chmod 700 "/home/$firstuser/.ssh"
    chown "$firstuser:$firstuser" -R "/home/$firstuser/."
fi

echo "setup sudo for wheel group"
tee /etc/sudoers.d/wheel << EOF
## allow members of group wheel to execute any command
%wheel ALL=(ALL) ALL
EOF

echo "setup sshd"
if $restore_backup; then
    restore_warning "not overwriting /etc/ssh/sshd"
else
    configure_sshd
fi
systemctl enable sshd

if is_zfs "$(by_partlabel ROOT)"; then
    echo "setup zfs mounts"
    systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target
fi

echo "setup initrd ramdisk"
initrd_hooks="base udev autodetect modconf keyboard keymap block"
if is_mdadm "$(by_partlabel ROOT)"; then initrd_hooks="$initrd_hooks mdadm_udev"; fi
if is_luks "$(by_partlabel ROOT)"; then initrd_hooks="$initrd_hooks encrypt"; fi
if is_lvm "$(by_partlabel ROOT)"; then initrd_hooks="$initrd_hooks lvm2"; fi
if is_zfs "$(by_partlabel ROOT)"; then
    initrd_hooks="$initrd_hooks zfs filesystems"
else
    initrd_hooks="$initrd_hooks fsck filesystems"
fi
if grep -E -q "^HOOKS=" /etc/mkinitcpio.conf 2> /dev/null; then
    sed -i -r "s/^HOOKS=.+/HOOKS=($initrd_hooks)/g" /etc/mkinitcpio.conf
else
    echo "HOOKS=($initrd_hooks)" >> /etc/mkinitcpio.conf
fi
mkinitcpio -P

echo "setup bootloader"
sdboot_options="quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0"
if grep -E -q "^LINUX_OPTIONS=" /etc/sdboot-manage.conf 2> /dev/null; then
    sed -i -r "s/^LINUX_OPTIONS=.+/LINUX_OPTIONS=\"$sdboot_options\"/g" /etc/sdboot-manage.conf
else
    echo "LINUX_OPTIONS=\"$sdboot_options\"" >> /etc/sdboot-manage.conf
fi
bootctl install
sdboot-manage gen

if test "$(by_partlabel EFI | wc -w)" = "2"; then
    efi_src=$(get_efi1_mountpath)
    efi_dest=$(get_efi2_mountpath)
    echo "setup efi-sync from $efi_src to $efi_dest"
    install_efi_sync $efi_src $efi_dest "$self_path/bootstrap-library.sh"
    efi_sync $efi_src $efi_dest
fi

unit_files=$(systemctl --no-pager --no-legend list-unit-files)
printf "%s" "$unit_files"  | grep -q "^gdm.service" && err=$? || err=$?
if test "$err" -eq "0"; then
    echo "enable Gnome Display Service"
    systemctl enable gdm.service
fi
