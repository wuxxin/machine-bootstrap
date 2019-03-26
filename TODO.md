# Todo

+ IMPORTANT: 
    + kvm qxl does not work (kernel faults) on suspend and hibernate, use virtio vga instead
    + virtio vga does not work in X11, use qxl instead

+ Reasons for overlay fs on zfs
    + software this days, expect overlay fs support on any normal storage on linux
    + systemd.volatile https://github.com/systemd/systemd/blob/adca059d55fe0a126dbdd62911b0705ddf8e9b8a/NEWS#L119

## done

## testing

+ FIXME: zfs-dkms installation (missing spl-dkms installed) on bootstrap-2-chroot dkms-zfs install
+ FIXME: bootstrap devop phase: copy files without run and log (everything in .gitignore)
+ FIXME: /var/log unmounting
```
var-log.mount: Mount process exited, code=exited status=32
Mär 01 00:03:18 box systemd[1]: Failed unmounting /var/log.
Mär 01 00:03:22 box systemd-cryptsetup[2952]: Failed to deactivate: Device or resource busy
Mär 01 00:03:22 box systemd[1]: systemd-cryptsetup@luks\x2droot.service: Control process exited, code=exited status=1
Mär 01 00:03:22 box systemd[1]: systemd-cryptsetup@luks\x2droot.service: Failed with result 'exit-code'.
```

## working on
+ FIXME: --recovery-autologin

## features to add/finish, known issues to fix

### recovery, install/restore stages
+ FIXME: step install reboot, recovery-unmount.sh reboot: reboot only working with --force
+ FIXME: recovery grub that does not succeed first time (while installing),
    + has no 3 seconds wait (as first time), but waits for user interaction the second time, but its the only option
+ FIXME: disco: module autofs4 not found (initrd, and other places)
+ FIXME: grub failsafe writing: does timeout different (25 seconds) but does not pre select recovery
+ FIXME: cosmetic: default.plymouth.grub should be blank and not follow plymouth.theme
+ FIXME: make "grub-reboot <entry>" working also on mdadm boot by using efi and efi2
    + modify grub to use /boot/efi/EFI/grubenv as grubenv if mirror setup
    + keep EFI synced
+ make replacement update-initramfs that mimics initramfs but calls dracut
+ server: add script to replace a changed faulty disk: recovery-replace-mirror.sh
+ server: add script to deactivate (invalidate) one of two disks: storage-invalidate-mirror.sh
+ make desaster recovery: script bootstrap-1-restore and bootstrap-2-chroot-restore
+ recovery image: 18.04.02 is released, but ubuntu 18.04.02 live-server image does not work as 18.04.1
    + cloud-init error: running module set-passwords failed
    + other errors (systemd services failed), ssh not working
+ server: optional use of tmux for long running ssh connections of bootstrap.sh

### devop stage
+ FIXME: proper saltcall logging
+ FIXME: add ppa snooper for ppa install to look if there is a In/Release file
+ desktop: switch to disco for desktop and make 2 other hops until next lts
+ install and configure zfs auto snapshot and ZFS Scrubbing
+ make ~/downloads extra dataset with no backup and only few snapshots
+ make backup working
+ desktop: install language, configure evolution to use caldav, carddav
+ desktop: make homesick configureable from pillar (checkout repo, git-crypt, a.s.o.)
