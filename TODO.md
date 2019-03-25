# Todo

+ IMPORTANT: 
    + kvm qxl does not work (kernel faults) on suspend and hibernate, use virtio vga instead
    + virtio vga does not work in X11, use qxl instead

## done

## testing

## working on
+ move initial casper download from bootstrap-0 to to recovery/recovery-build.sh
+ with build-recovery.sh in place we have the possibility to write a iso_hybrid image for a usb stick,
  + make ./bootstrap.sh support this: boostrap.sh create bootstrap-0-image
+ FIXME: --recovery-autologin

## features to add/finish, known issues to fix

### recovery, install/restore stages
+ FIXME: recovery-unmount.sh and bootstrap-2-chroot: reboot only working with --force
+ FIXME: /var/log unmounting
```
var-log.mount: Mount process exited, code=exited status=32
Mär 01 00:03:18 box systemd[1]: Failed unmounting /var/log.
Mär 01 00:03:22 box systemd-cryptsetup[2952]: Failed to deactivate: Device or resource busy
Mär 01 00:03:22 box systemd[1]: systemd-cryptsetup@luks\x2droot.service: Control process exited, code=exited status=1
Mär 01 00:03:22 box systemd[1]: systemd-cryptsetup@luks\x2droot.service: Failed with result 'exit-code'.
```
+ FIXME: disco: module autofs4 not found (initrd, and other places)
+ FIXME: grub failsafe writing: does timeout different (25 seconds) but does not pre select recovery
+ FIXME: cosmetic: default.plymouth.grub should be blank and not follow plymouth.theme
+ FIXME: make "grub-reboot <entry>" working also on mdadm boot by using efi and efi2
    + modify grub to use /boot/efi/EFI/grubenv as grubenv if mirror setup
    + keep EFI synced
+ make replacement update-initramfs that mimics initramfs but calls dracut
+ add script to replace a changed faulty disk: recovery-replace-mirror.sh
+ add script to deactivate (invalidate) one of two disks: storage-invalidate-mirror.sh
+ make script bootstrap-1-restore and bootstrap-2-chroot-restore
+ recovery image: 18.04.02 is released, but ubuntu 18.04.02 live-server image does not work as 18.04.1
    + cloud-init error: running module set-passwords failed
    + other errors (systemd services failed), ssh not working
+ OPTIONAL: use tmux for long running ssh connections of bootstrap.sh

### devop stage
+ FIXME: proper saltcall logging
+ FIXME: add ppa snooper for ppa install to look if there is a In/Release file
+ switch to disco for desktop and make 2 other hops until next lts
+ install and configure zfs auto snapshot and ZFS Scrubbing
+ make ~/downloads extra dataset with no backup and only few snapshots
+ install desktop, install language german with de_AT
    + configure evolution to use caldav, carddav
+ make backup working
+ make homesick configureable from pillar (checkout repo, git-crypt, a.s.o.)
