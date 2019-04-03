#!/bin/bash
set -eo pipefail
#set -x


usage() {
    cat <<EOF
Usage: $0 hostname firstuser --yes [--restore-from-backup]

"http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"
EOF
    exit 1
}

restore_not_overwrite() {
    test -e "$1" -a "$option_restore_backup" = "true"
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
    cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ $(lsb_release -c -s) main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ $(lsb_release -c -s)-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ $(lsb_release -c -s)-updates main restricted universe multiverse
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
    arc_max_bytes=$(grep MemTotal /proc/meminfo | awk '{printf("%u",$2*25/100*1024)}')
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

echo "workaround zol < 0.8 missing zfs-mount-generator"
echo "https://github.com/zfsonlinux/zfs/issues/5754"
cat /etc/recovery/legacy.fstab >> /etc/fstab

echo "workaround /var stays busy at shutdown due to journald"
echo "https://github.com/systemd/systemd/issues/867"
mkdir -p /etc/systemd/system/var.mount.d
cat > /etc/systemd/system/var.mount.d/override.conf << EOF
[Mount]
LazyUnmount=yes
EOF

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
default="/usr/share/plymouth/themes/default.plymouth"
if test -e $default; then
    basename $(dirname $(readlink -f $default))
else
    echo "text"
fi
EOF
    chmod +x /usr/bin/plymouth-set-default-theme
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
touch /etc/dracut.conf.d/10-debian.conf

echo "add grub casper recovery entry"
mkdir -p /etc/grub.d
uuid_boot="$(blkid -s UUID -o value /dev/disk/by-label/boot)"
grub_root="hd0,gpt${BOOT_NR}"
casper_livemedia=""
if test -e "/dev/md/mdadm-boot" -o -e "/dev/md127"; then
    grub_root="md/mdadm-boot"
    casper_livemedia="live-media=/dev/md127"
fi
/etc/recovery/build-recovery.sh show grub.d/recovery \
    "$grub_root" "$casper_livemedia" "$uuid_boot" > /etc/grub.d/40_recovery
chmod +x /etc/grub.d/40_recovery


echo "update installation"
apt-get update --yes

if $option_restore_backup; then
    restore_warning "not installing base packages"
else
    if systemd-detect-virt --vm --quiet; then flavor="virtual"; else flavor="generic"; fi
    if test "$(lsb_release -c -s)" = "bionic"; then flavor="${flavor}-hwe-18.04"; fi
    echo "install $flavor kernel, bootloader & tools needed for ubuntu-standard"
    apt upgrade --yes
    apt install --yes --no-install-recommends linux-$flavor linux-headers-$flavor linux-image-$flavor linux-tools-$flavor $(systemd-detect-virt --vm --quiet && echo "linux-image-extra-$flavor" || true)

    packages="cryptsetup gdisk mdadm grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed efibootmgr squashfs-tools curl gnupg gpgv ca-certificates bzip2 libc-bin tmux haveged debootstrap"
    zfs_packages="spl-dkms zfs-dkms zfsutils-linux"
    extra_packages="openssh-server"
    ubuntu_minimal=$(apt-cache depends ubuntu-minimal | grep "Depends:" | sed -r "s/ +Depends: (.+)$/\1/g" | grep -vE "(initramfs-tools|ubuntu-advantage-tools)")
    ubuntu_standard=$(apt-cache depends ubuntu-standard | grep "Depends:" | sed -r "s/ +Depends: (.+)$/\1/g" | grep -vE "(popularity-contest)")
    ubuntu_standard_rec=$(apt-cache depends ubuntu-standard | grep "Recommends:" | sed -r "s/ +Recommends: (.+)$/\1/g" | grep -vE "(friendly-recovery)")
    # XXX workaround ubuntu-minimal, ubuntu-standard depending on initramfs-tools, friendly-recovery
    # XXX while there, remove other unwanted pkgs (ubuntu-advantage-tools, popularity-contest)
    apt install --yes \
        $packages $zfs_packages $extra_packages \
        $ubuntu_minimal $ubuntu_standard $ubuntu_standard_rec
    # XXX force automatic not to overwrite dracut/10-debian.conf
    cat > /etc/apt/apt.conf.d/90bootstrap-dracut << EOF
Dpkg::Options {
   "--force-confdef";
   "--force-confold";
}
EOF
    apt install --yes \
        ubuntu-minimal- initramfs-tools- ubuntu-advantage-tools- \
        popularity-contest- friendly-recovery- \
        dracut dracut-network zfs-dracut
    rm /etc/apt/apt.conf.d/90bootstrap-dracut
    apt-get --yes clean
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
echo "only use >= 3072-bit-long moduli"
awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.tmp && mv /etc/ssh/moduli.tmp /etc/ssh/moduli
echo "do not use and remove ecdsa keys"
for i in ssh_host_ecdsa_key ssh_host_ecdsa_key.pub; do
    if test -e /etc/ssh/$i; then rm /etc/ssh/$i; fi
done
if restore_not_overwrite /etc/ssh/sshd_config; then
    restore_warning "but overwriting sshd_config to a minimal secure version, original renamed to .old"
    mv /etc/ssh/sshd_config /etc/ssh/sshd_config.old
fi
cat >> /etc/ssh/sshd_config <<EOF
# ### BOOTSTRAP-MACHINE BEGIN ###
# Supported HostKey algorithms by order of preference.
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
AuthenticationMethods publickey
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com
# ### BOOTSTRAP-MACHINE END ###
EOF

echo "rewrite recovery squashfs"
/etc/recovery/update-recovery-squashfs.sh --host $hostname


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
if test -e "${EFI}2"; then
    echo "Fixme: ERROR finish writing modify grub to use /boot/efi/EFI/grubenv as grubenv"
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
grub-install --target=i386-pc --boot-directory=/boot --recheck --no-floppy "/dev/$EFIDISK"

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
    grub-install --target=i386-pc --boot-directory=/boot --recheck --no-floppy "/dev/$EFI2DISK"
fi

echo "exit from chroot"
exit
