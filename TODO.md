# Todo

+ IMPORTANT: 
    + kvm qxl does not work (kernel faults) on suspend and hibernate, use virtio vga instead
    + virtio vga does not work in X11, use qxl instead

## done

## testing

+ frankenstein support

## working on

+ overlayfs compatible backport build of spl-linux and zfs-linux
```
cat > /etc/apt/sources.list.d/local-boot.list << EOF
deb file:/tmp/zfs/zfsbuild/buildresult ./
EOF
# from recovery: copy all debs and make apt-archive in /boot/apt-archive/
# from the chroot system
dpkg -i lib* zfs-dkms*  zfs-dracut* zfs-doc* zfsutils-* zfs-zed*
remake dracut initrd
```

+ /var/log unmounting
```
var-log.mount: Mount process exited, code=exited status=32
Mär 01 00:03:18 box systemd[1]: Failed unmounting /var/log.
Mär 01 00:03:22 box systemd-cryptsetup[2952]: Failed to deactivate: Device or resource busy
Mär 01 00:03:22 box systemd[1]: systemd-cryptsetup@luks\x2droot.service: Control process exited, code=exited status=1
Mär 01 00:03:22 box systemd[1]: systemd-cryptsetup@luks\x2droot.service: Failed with result 'exit-code'.
```

## features to add/finish, known issues to fix

### recovery, install/restore stages
+ FIXME: overlayfs compatible backport build of spl-linux and zfs-linux
+ FIXME: /var/log unmounting
+ FIXME: --recovery-autologin
+ FIXME: default.plymouth.grub
+ FIXME: grub failsafe writing: does timeout different (25 seconds) but does not pre select recovery
+ FIXME: make "grub-reboot <entry>" working also on mdadm boot by using efi and efi2
    + modify grub to use /boot/efi/EFI/grubenv as grubenv if mirror setup
    + keep EFI synced
+ FIXME: reboot only working with force after recovery-unmount.sh and bootstrap-2-chroot 

+ FEATURE: write logs of recovery,install,chroot,devop phase to /var/log/bootstrap-phase.log except recovery which writes to /boot/casper/bootstrap-recovery.log
+ FEATURE: print error before exit if download of recovery image fails
+ FEATURE: make replacement update-initramfs that mimics initramfs but calls dracut
+ FEATURE: add script to replace a changed faulty disk: recovery-replace-mirror.sh
+ FEATURE: add script to deactivate (invalidate) one of two disks: storage-invalidate-mirror.sh
+ FEATURE: make script bootstrap-1-restore and bootstrap-2-chroot-restore
+ FEATURE: recovery image: 18.04.02 is released, but ubuntu 18.04.02 live-server image does not work as 18.04.1
    + cloud-init error: running module set-passwords failed
    + other errors (systemd services failed), ssh not working
+ OPTIONAL FEATURE: use tmux for long running ssh connections of bootstrap.sh

### devop stage
+ install and configure zfs auto snapshot and ZFS Scrubbing
+ make ~/downloads extra dataset with no backup and only few snapshots
+ install desktop, install language german with de_AT
    + configure evolution to use caldav, carddav
+ make backup working
+ make optional homesick configure if ./home exists (symlink to ~/.homesick/repos/$hostname)
+ make repository data only available under a different group (not normally readable by user) and allow homeshick and others using a special command to operate on this file
