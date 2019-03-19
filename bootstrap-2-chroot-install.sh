#!/bin/bash
set -eo pipefail
set -x

restore_not_overwrite() {
    test -e "$1" -a "$option_restore_backup" = "true"
}

restore_warning() {
    echo "WARNING: --restore-from-backup: $@"
}

usage() {
    cat <<EOF
Usage: $0 hostname firstuser --yes [--restore-from-backup]

"http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"
EOF
    exit 1
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

# partition paths by label and partlabel
EFI=/dev/disk/by-partlabel/EFI
BOOT=/dev/disk/by-label/boot
LUKSROOT=/dev/disk/by-partlabel/LUKSROOT
LUKSSWAP=/dev/disk/by-partlabel/LUKSSWAP
BIOS_NR="7"; EFI_NR="6"; LOG_NR="5"; CACHE_NR="4"; SWAP_NR="3"; BOOT_NR="2"; ROOT_NR="1"

export DEBIAN_FRONTEND=noninteractive


echo "setup locale, timezone"
export LC_MESSAGES="POSIX"
export LANG="en_US.UTF-8"
export LC_ALL=$LANG
export LANGUAGE="en_US:en"
if $option_restore_backup; then
    restore_warning "not setting default locale and timezone"
else
    echo -e "LANG=$LANG\nLANGUAGE=$LANGUAGE\nLC_MESSAGES=$LC_MESSAGES\n" > /etc/default/locale
    locale-gen $LANG
    echo "Etc/UTC" > /etc/timezone
    dpkg-reconfigure tzdata
fi

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

echo "configure apt"
if restore_not_overwrite /etc/apt/sources.list; then
    restore_warning "not overwriting /etc/apt/sources.list"
else
    cat > /etc/apt/sources.list <<"EOF"
deb http://archive.ubuntu.com/ubuntu/ bionic main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ bionic-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ bionic-updates main restricted universe multiverse
EOF
fi

# workaround dracut initramfs-tools clashes and keep whoopsie, apport from the disk
echo "pin whoopsie apport brltty initramfs-tools to unwanted"
for i in whoopsie apport brltty initramfs-tools; do
    cat > /etc/apt/preferences.d/${i}-preference << EOF
Package: $i
Pin: release o=Ubuntu
Pin-Priority: -1
EOF
done

echo "configure zfs options"
mkdir -p /etc/modprobe.d
if restore_not_overwrite /etc/modprobe.d/zfs.conf; then
    restore_warning "not overwriting /etc/modprobe.d/zfs.conf"
else
    echo "use cfq i/o scheduler for cgroup i/o quota support"
    echo "options zfs zfs_vdev_scheduler=cfq" > /etc/modprobe.d/zfs.conf
    arc_max_bytes=$(grep MemTotal /proc/meminfo | awk '{print $2*1024*25/100}')
    echo "use maximum of 25% of available memory for arc zfs_arc_max=$arc_max_bytes bytes"
    echo "options zfs zfs_arc_max=${arc_max_bytes}" >> /etc/modprobe.d/zfs.conf
fi
if restore_not_overwrite /etc/modprobe.d/overlay.conf; then
    restore_warning "not overwriting /etc/modprobe.d/overlay.conf"
else
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
fi

# symlink /etc/mtab to /proc/self/mounts
if test ! -e /etc/mtab; then ln -s /proc/self/mounts /etc/mtab; fi

echo "configure fstab"
echo "UUID=$(blkid -s UUID -o value $BOOT) /boot ext4 defaults 0 1" > /etc/fstab
if test -e "$EFI"; then
    cat >> /etc/fstab <<EOF
PARTUUID=$(blkid -s PARTUUID -o value $EFI) /boot/efi  vfat nofail,x-systemd.device-timeout=1 0 1
EOF
else
    cat >> /etc/fstab <<EOF
PARTUUID=$(blkid -s PARTUUID -o value ${EFI}1) /boot/efi  vfat nofail,x-systemd.device-timeout=1 0 1
PARTUUID=$(blkid -s PARTUUID -o value ${EFI}2) /boot/efi2 vfat nofail,x-systemd.device-timeout=1 0 1
EOF
fi
cat >> /etc/fstab <<EOF
rpool/ROOT/ubuntu / zfs defaults 0 0
EOF

# https://github.com/zfsonlinux/zfs/issues/5754
echo "workaround zol < 0.8 missing zfs-mount-generator"
cat /etc/recovery/legacy.fstab >> /etc/fstab

if test -e "/dev/mapper/luks-swap"; then
    echo "/dev/mapper/luks-swap swap swap defaults" >> /etc/fstab
fi

echo "configure crypttab for luksroot*"
if test -e "$LUKSROOT"; then
    cat > /etc/crypttab << EOF
luks-root UUID=$(blkid -s UUID -o value $LUKSROOT) none luks,discard
EOF
else
    cat > /etc/crypttab << EOF
luks-root1 UUID=$(blkid -s UUID -o value ${LUKSROOT}1) none luks,discard
luks-root2 UUID=$(blkid -s UUID -o value ${LUKSROOT}2) none luks,discard
EOF
fi
if test -e "/dev/mapper/luks-swap"; then
    echo "setup crypttab for luks-swap"
    if test -e "$LUKSSWAP"; then
        CRYPTSWAP="$LUKSSWAP"
    else
        CRYPTSWAP="/dev/md/mdadm-swap"
    fi
    cat >> /etc/crypttab << EOF
luks-swap UUID=$(blkid -s UUID -o value $CRYPTSWAP) none luks,discard
EOF
fi

echo "configure plymouth"
if restore_not_overwrite /usr/bin/plymouth-set-default-theme; then
    restore_warning "not overwriting /usr/bin/plymouth-set-default-theme"
else
    cat > /usr/bin/plymouth-set-default-theme <<"EOF"
#!/bin/bash
basename $(dirname $(readlink -f /usr/share/plymouth/themes/default.plymouth))
EOF
    chmod +x /usr/bin/plymouth-set-default-theme
fi
if restore_not_overwrite /etc/plymouth/plymouthd.conf; then
    restore_warning "not overwriting /etc/plymouth/plymouthd.conf"
else
    mkdir -p /etc/plymouth
    cat > /etc/plymouth/plymouthd.conf << EOF
[Daemon]
Theme=ubuntu-gnome-logo
ShowDelay=1
# DeviceTimeout=5
# DeviceScale=?
EOF
fi

echo "configure dracut"
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/90-custom.conf << EOF
do_prelink=no
hostonly=yes
omit_drivers+=" crc32c "
omit_dracutmodules+=" ifcfg "
$(test -e "/dev/mapper/luks-swap" && echo 'add_device+=" /dev/mapper/luks-swap"')
add_dracutmodules+=" kernel-network-modules systemd-networkd sshd rescue"
kernel_commandline=
#rd.debug rd.break=pre-shutdown rd.break=shutdown rd.shell
EOF
echo "fix /etc/dracut.conf.d/10-debian.conf (crc32 module)"
if test -e /etc/dracut.conf.d/10-debian.conf; then
    rm /etc/dracut.conf.d/10-debian.conf
fi
ln -s /dev/null /etc/dracut.conf.d/10-debian.conf

echo "add grub casper recovery entry"
mkdir -p /etc/grub.d
if test -e "/dev/md/mdadm-boot" -o -e "/dev/md127"; then
    grub_root="md/mdadm-boot"
    grub_hint="md/mdadm-boot"
    casper_livemedia="live-media=/dev/md127"
else
    grub_root="hd0,gpt${BOOT_NR}"
    grub_hint="hd0,gpt${BOOT_NR}"
    casper_livemedia=""
fi
cat > /etc/grub.d/40_recovery << EOF
#!/bin/sh
exec tail -n +3 \$0
# live system recovery 
menuentry "Ubuntu 18.04 Casper Recovery" --id "recovery" {    
    set root="$grub_root"
    search --no-floppy --fs-uuid --set=root --hint="$grub_hint" $(blkid -s UUID -o value /dev/disk/by-label/boot)
    linux  /casper/vmlinuz boot=casper toram textonly $casper_livemedia noeject noprompt ds=nocloud
    initrd /casper/initrd
}

fallback=recovery

EOF
chmod +x /etc/grub.d/40_recovery


echo "update installation"
apt-get update --yes
apt dist-upgrade --yes

if $option_restore_backup; then
    restore_warning "not installing base packages"
else
    if systemd-detect-virt --vm; then flavor="virtual"; else flavor="generic"; fi
    echo "install kernel, loader, tools needed for boot and ubuntu-standard"
    packages="linux-$flavor-hwe-18.04 linux-tools-generic-hwe-18.04 cryptsetup gdisk mdadm grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed efibootmgr squashfs-tools curl ca-certificates bzip2 tmux zfs-dkms zfsutils-linux haveged debootstrap libc-bin dracut dracut-network zfs-dracut openssh-server pm-utils wireless-tools plymouth-theme-ubuntu-gnome-logo ubuntu-standard"
    apt-get install --yes $packages
fi

echo "create missing system groups"
getent group lpadmin > /dev/null || addgroup --system lpadmin
getent group sambashare > /dev/null || addgroup --system sambashare

if $option_restore_backup; then
    restore_warning "not creating first user $firstuser"
else
    echo "add first user: $firstuer"
    adduser --gecos "" --disabled-password "$firstuser"
    cp -a /etc/skel/.[!.]* "/home/$firstuser/"
    mkdir -p  "/home/$firstuser/.ssh"
    cp /root/.ssh/authorized_keys "/home/$firstuser/.ssh/authorized_keys"
    chmod 700 "/home/$firstuser/.ssh"
    chown "$firstuser:$firstuser" -R "/home/$firstuser/."
    usermod -a -G adm,cdrom,dip,lpadmin,plugdev,sambashare,sudo "$firstuser"
fi

echo "ssh config, 2019-02-26 snapshot (but without ecsda) of https://infosec.mozilla.org/guidelines/openssh.html "
# only use >= 3072-bit-long moduli
awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.tmp && mv /etc/ssh/moduli.tmp /etc/ssh/moduli
# do not use ecdsa keys
for i in ssh_host_ecdsa_key ssh_host_ecdsa_key.pub; do
    if test -e /etc/ssh/$i; then rm /etc/ssh/$i; fi
done
cat >> /etc/ssh/sshd_config <<EOF
# Supported HostKey algorithms by order of preference.
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key

AuthenticationMethods publickey

KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256

Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com

EOF


echo "rewrite recovery squashfs"
/etc/recovery/update-recovery-squashfs.sh --host $hostname


echo "setup dracut"
echo "writing new dracut /etc/ssh/initrd_ssh_host_ed25519_key[.pub]"
if test -e /etc/ssh/initrd_ssh_host_ed25519_key; then
    echo "WARNING: removing old /etc/ssh/initrd_ssh_host_ed25519_key"
    rm /etc/ssh/initrd_ssh_host_ed25519_key
fi
mkdir -p /etc/ssh
ssh-keygen -q -t ed25519 -N '' -f "/etc/ssh/initrd_ssh_host_ed25519_key"
echo "create initrd using dracut"
for version in $(find /boot -maxdepth 1 -name "vmlinuz*" | sed -r "s#^/boot/vmlinuz-(.+)#\1#g"); do 
    dracut --force /boot/initrd.img-${version} "${version}"
done


echo "setup grub"
if test -e "${EFI}2"; then
    echo "Fixme: ERROR modify grub to use /boot/efi/EFI/grubenv as grubenv"
fi
sed -r -i.bak 's/^(GRUB_CMDLINE_LINUX=).*/\1"quiet splash"/g' /etc/default/grub
# plymouth:debug
# plymouth.enable=0 initcall_debug no_console_suspend ignore_loglevel pm_test console=ttyS0,115200
if test -e "/dev/mapper/luks-swap"; then
    echo "hibernation support: add resume config to grub defaults"
    sed -r -i.bak 's/^(GRUB_CMDLINE_LINUX_DEFAULT=).*/\1"resume=UUID='$(blkid -s UUID -o value /dev/mapper/luks-swap)'"/g' /etc/default/grub
fi
GRUB_EFI_PARAM=""
EFISTUB="EFI"
if test ! -e "/sys/firmware/efi"; then GRUB_EFI_PARAM="--no-nvram"; fi
if test ! -e "$EFI"; then EFISTUB="EFI1"; fi
EFIDISK=$(lsblk /dev/disk/by-partlabel/$EFISTUB -o kname -n | sed -r "s/([^0-9]+)([0-9]+)/\1/")
EFIPART=$(lsblk /dev/disk/by-partlabel/$EFISTUB -o kname -n | sed -r "s/([^0-9]+)([0-9]+)/\2/")
if test "$(grub-probe /)" != "zfs"; then
    echo "Warning: grub-probe didnt return zfs: $(grub-probe /)"
fi
update-grub
grub-install --target=x86_64-efi --boot-directory=/boot --efi-directory=/boot/efi --bootloader-id=Ubuntu --recheck --no-floppy $GRUB_EFI_PARAM 
grub-install --target=i386-pc --boot-directory=/boot --recheck --no-floppy /dev/$EFIDISK
if test -e "${EFI}2"; then
    echo "moving grubenv to efi,efi2"
    grub-editenv /boot/efi/EFI/grubenv create
    echo "Sync contents of efi"
    cp -a /boot/efi/. /boot/efi2
    if test -e /boot/efi2/EFI/grubenv; then rm /boot/efi2/EFI/grubenv; fi
    grub-editenv /boot/efi2/EFI2/grubenv create
    echo "write second boot entry"
    EFI2DISK=$(lsblk /dev/disk/by-partlabel/EFI2 -o kname -n | sed -r "s/([^0-9]+)([0-9]+)/\1/")
    EFI2PART=$(lsblk /dev/disk/by-partlabel/EFI2 -o kname -n | sed -r "s/([^0-9]+)([0-9]+)/\2/")
    if test -e "/sys/firmware/efi"; then
        efibootmgr -c --gpt -d /dev/$EFI2DISK -p $EFI2PART -w -L Ubuntu2 -l '\EFI\Ubuntu\grubx64.efi'
    fi
    grub-install --target=i386-pc --boot-directory=/boot --recheck --no-floppy /dev/$EFI2DISK
fi

echo "exit from chroot"
exit
