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

echo "create fstab and crypttab"
create_fstab "manjaro"
create_crypttab

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

echo "setup sshd"
if $restore_backup; then
    restore_warning "not overwriting /etc/ssh/sshd"
else
    configure_sshd
fi
systemctl enable --now sshd

echo "setup initrd ramdisk"
mkinitcpio -P

echo "setup bootloader"
bootctl install
