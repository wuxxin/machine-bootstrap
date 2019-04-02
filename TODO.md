# Todo

+ Info:
    + kvm qxl does not work (kernel faults) on suspend and hibernate, use virtio vga instead
    + virtio vga does not work in X11, use qxl instead

+ Reasons for overlay fs on zfs:
    + 2 years after integrating overlayfs in the kernel, people expect overlay fs support on any normal storage on linux
    + systemd.volatile https://github.com/systemd/systemd/blob/adca059d55fe0a126dbdd62911b0705ddf8e9b8a/NEWS#L119

## done

## testing

## working on
+ FIXME: --recovery-autologin
+ dev-disk-by\x2dpartuuid-f016b8e4\x2ddd6b\x2d46e5\x2d9851\x2dd5a0c2f49ead.device: Job dev-disk-by\x2dpartuuid-f016b8e4\x2ddd6b\x2d46e5\x2d9851\x2dd5a0c2f49ead.device/start timed out.
+ var-cache.mount: Directory /var/cache to mount over is not empty, mounting anyway

## features to add/finish, known issues to fix
+ FIXME: reboot after bootstrap-1&2-install not working
+ desktop: install language
+ if frankenstein=true, pin all custom packages with higher priority if something marks them as ours
    + this way, apt waiting updates should show updates that are not updated automatically,
    if we verion each custom version with <nr+1>~revalidate
+ FIXME: recovery failsafe: if grub that does not succeed first time (while installing) timeout changes from 3s to interactive
+ FIXME: grub failsafe writing: does timeout different (25 seconds) but does not pre select recovery
+ FIXME: cosmetic: default.plymouth.grub should be blank and not follow plymouth.theme
+ make replacement update-initramfs that mimics initramfs but calls dracut

### recovery, install/restore stages

+ FIXME: make "grub-reboot <entry>" working also on mdadm boot by using efi and efi2
    + modify grub to use /boot/efi/EFI/grubenv as grubenv if mirror setup
    + keep EFI synced
+ FIXME: step install reboot, recovery-unmount.sh reboot: reboot only working with --force
+ server: add script to replace a changed faulty disk: recovery-replace-mirror.sh
+ server: add script to deactivate (invalidate) one of two disks: storage-invalidate-mirror.sh
+ make restore from backup: script bootstrap-1-restore and bootstrap-2-chroot-restore
+ recovery image: 18.04.02 is released, but ubuntu 18.04.02 live-server image does not work as 18.04.1
    + cloud-init error: running module set-passwords failed
    + other errors (systemd services failed), ssh not working
+ server: optional use of tmux for long running ssh connections of bootstrap.sh

### devop stage
+ install and configure zfs auto snapshot and ZFS Scrubbing
+ make backup working
+ think if we want to use zram-config
+ desktop: make ~/downloads extra dataset with no backup and only few snapshots
+ desktop: configure evolution to use caldav, carddav
+ desktop: make homesick configureable from pillar (checkout repo, git-crypt, a.s.o.)
