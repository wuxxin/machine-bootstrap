# Todo

+ Info: if using this in a vm on a xenial host
    + kvm qxl does not work (kernel faults) on suspend and hibernate, use virtio vga instead
    + virtio vga does not work in X11, use qxl instead

## features to add/finish, known issues to fix

## target system
+ FIXME: disco: dracut: network (and therefore ssh daemon) is (?sometimes) only started after first password ask timeout, but will get started
+ FIXME: initrd: sometimes race conditions prohibit mouting rpool, dropping to dracut shell. Workaround if their already: mount rpool; exit
+ FIXME: boot/efi mounting/unmounting is somehow broken: eg.: dev-disk-by\x2dpartuuid-caffee.device: Job dev-disk-by\x2dpartuuid-caffee.device/start timed out.
+ FIXME: var-cache.mount: at some point (but not on fresh install) Directory /var/cache is mount over not empty basename
+ FIXME: grub: recovery failsafe and target system failsafe
    + on recovery: if grub that does not succeed first time (while installing) timeout changes from 3s to interactive
    + on target: does timeout different (25 seconds) but does not pre select recovery

### recovery, install/restore
+ FIXME: step install reboot, recovery-unmount.sh reboot: reboot only working with --force
+ FIXME: cosmetic: default.plymouth.grub should be blank and not follow plymouth.theme
+ FIXME: make "grub-reboot <entry>" working also on mdadm boot by using efi and efi2
    + modify grub to use /boot/efi/EFI/grubenv as grubenv if mirror setup
    + keep EFI synced
+ apt waiting updates should show updates that are not updated automatically, if package origin = local
+ server: add script to replace a changed faulty disk: recovery-replace-mirror.sh
+ server: add script to deactivate (invalidate) one of two disks: storage-invalidate-mirror.sh
+ make restore from backup: script bootstrap-1-restore and bootstrap-2-chroot-restore
+ recovery image: 18.04.02 is released, but ubuntu 18.04.02 live-server image does not work as 18.04.1
    + cloud-init error: running module set-passwords failed
    + other errors (systemd services failed), ssh not working
+ maybe: make replacement update-initramfs that mimics initramfs but calls dracut (some utilities make use of update-initramfs, but others call update-initramfs if they find it, including a crontab file from update-initramfs, which is already on disk from start)
+ server: optional use of tmux for long running ssh connections of bootstrap.sh

### devop stage
+ install and configure zfs auto snapshot and ZFS Scrubbing
+ make backup working

## write reasons for overlayfs on zfs for presentation in zfs-linux mailinglist
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
