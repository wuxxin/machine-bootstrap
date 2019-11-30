# machine-bootstrap work list

+ Info: if using this in a vm on a xenial host
    + kvm qxl does not work (kernel faults) on suspend and hibernate, use virtio vga instead
    + virtio vga does not work in X11, use qxl instead

## to fix, to finish

+ FIXME: make snapd on recovery working again (currently timeouts)
+ FIXME: dkms install spl zfs (maybe only 0.7.5 ?)
configure: error: Failed to find spl_config.h in any of the following:
	/usr/src/spl-0.7.5/5.0.0-23-generic
	/usr/src/spl-0.7.5
Error! Bad return status for module build on kernel: 5.0.0-23-generic (x86_64)
Consult /var/lib/dkms/zfs/0.7.5/build/make.log for more information.

    + this is the list of target install of kernel packages, do we install to little in recovery ?
  linux-headers-5.0.0-37 linux-headers-5.0.0-37-generic
  linux-headers-generic-hwe-18.04 linux-headers-virtual-hwe-18.04
  linux-hwe-tools-5.0.0-37 linux-image-5.0.0-37-generic
  linux-image-extra-virtual-hwe-18.04 linux-image-generic-hwe-18.04
  linux-image-virtual-hwe-18.04 linux-modules-5.0.0-37-generic
  linux-modules-extra-5.0.0-37-generic linux-tools-5.0.0-37-generic
  linux-tools-common linux-tools-virtual-hwe-18.04 linux-virtual-hwe-18.04

## todo

### todo recovery, install, restore
+ grub: recovery failsafe and target system failsafe
    + on recovery: if grub that does not succeed first time (while installing) timeout changes from 3s to interactive
    + on target: does timeout different (25 seconds) but does not pre select recovery
+ keep EFI synced
+ server: optional use of tmux for long running ssh connections of bootstrap.sh
+ server: add script to replace a changed faulty disk: recovery-replace-mirror.sh
+ server: add script to deactivate (invalidate) one of two disks: storage-invalidate-mirror.sh
+ make restore from backup: script bootstrap-1-restore and bootstrap-2-chroot-restore

### todo devop
+ install and configure ZFS Scrubbing
+ make backup working

### write reasons for overlayfs on zfs for presentation in zfs-linux mailinglist
+ after integration of overlayfs in the kernel,
    adoption of overlayfs based solutions is rapidly growing.
    in 2019 many software projects expect to simply mount a overlayfs
    on any underlying storage and expects overlayfs to work.
+ overlayfs runs on ext3/4,xfs and even btrfs, you dont assume it doesn't on zfs
+ overlayfs is the first and possible one of few solutions,
    that will have user namespace mount support, either eg.
    via ubuntu overlayfs that is patched for user ns,
    or via a fuseoverlayfs driver (developed by redhat),
    overlayfs will be adopted in these cases (eg. podman, k3s, docker)
+ other examples of underlying storage is expected to support overlayfs to support a specific feature, i found during my journey of installing zfs on linux:
    + systemd.volatile https://github.com/systemd/systemd/blob/adca059d55fe0a126dbdd62911b0705ddf8e9b8a/NEWS#L119
    + ubuntu build script (find url again) which obviously uses anything but zfs as underlying storage for their build script by assuming the underlying storage layer has overlayfs support
    + http://bazaar.launchpad.net/~ubuntu-cdimage/ubuntu-cdimage/mainline/
        + https://git.launchpad.net/ubuntu/+source/casper/tree/debian/tests/prep-image?h=ubuntu/eoan

## snippets

find . -name ".git" -prune -o -type f -print0 | wc --files0-from=- | sort -n

```
/lib/systemd/system/media-filesystem.mount
[Mount]
What=/cdrom/casper/filesystem.squashfs
Where=/media/filesystem
Type=squashfs
Options=ro
/lib/systemd/system/local-fs.target.wants/@media-filesystem.mount
```

+ testing apt.conf for usage with -c=apt.conf
```
Debug
{
  pkgProblemResolver "true";
  pkgProblemResolver::ShowScores "true";
  pkgDepCache::AutoInstall "true"; // what packages apt installs to satisfy dependencies
  pkgDPkgPM "true";
  pkgOrderList "true";
  pkgPackageManager "true"; // OrderList/Configure debugging
  pkgAutoRemove "true";   // show information about automatic removes
  BuildDeps "true";
  pkgPolicy "true";
  EDSP::WriteSolution "true";
  InstallProgress::Fancy "true";
};
pkgProblemResolver::FixByInstall "true";
```

+ ask for passwords on initramfs shell

  + interactive: `systemd-tty-ask-password-agent`
  + unattended: `for s in /var/run/systemd/ask-password/sck.*; do echo -n "password" | /lib/systemd/systemd-reply-password 1 $s; done`

+ mount a inactive vm qcow image

```
sudo guestmount -a /var/lib/libvirt/images/xenserver.qcow2 -m /dev/sda1 /mnt/test
```

+ grub gfx mode
```
set gfxmode=auto
insmod gfxterm
terminal_output gfxterm
```

+ debug dracut on shutdown, add to already booted system

```
mkdir -p /run/initramfs/etc/cmdline.d
echo "rd.debug rd.break=pre-shutdown rd.break=shutdown" > /run/initramfs/etc/cmdline.d/debug.conf
```

+ workaround zol<0.8 mount races: /var/log

```
mkdir -p /etc/systemd/system/systemd-journald.service.d
cat > /etc/systemd/system/systemd-journald.service.d/override.conf << EOF
[Unit]
Requires=zfs-mount.service
After=zfs-mount.service
EOF
```

+ keep EFI synced

```
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
```

/etc/systemd/system/efistub-update.path
```
[Unit]
Description=Copy EFISTUB Kernel to EFI System Partition

[Path]
PathChanged=/boot/initramfs-linux-fallback.img

[Install]
WantedBy=multi-user.target
WantedBy=system-update.target

/etc/systemd/system/efistub-update.service

[Unit]
Description=Copy EFISTUB Kernel to EFI System Partition

[Service]
Type=oneshot
ExecStart=/usr/bin/cp -af /boot/vmlinuz-linux esp/EFI/arch/
ExecStart=/usr/bin/cp -af /boot/initramfs-linux.img esp/EFI/arch/
ExecStart=/usr/bin/cp -af /boot/initramfs-linux-fallback.img esp/EFI/arch/
```
