# Todo list

## done

## testing

## next

### bugs
+ fixme: ubuntu: after hardreset, recovery is not selected as fallback
+ fixme: non-blocking: phase install: reboot
    + lvm-root busy (Logical volume vg0/lvm-root contains a filesystem in use)
    + fixme: rpool busy (can not export rpool)

### features
+ extend: connect.sh initrdluks|recoverymount --unsafe for extra safety for encryption key
    + checks after connecting if gatewaydev is emulated, aborts if emulated
    + use --unsafe if you know you're connecting to a vm
+ gitops: make target system also honor http_proxy on gitops install
+ recovery scripts to replace a faulty disk, to invalidate a disk
    + all: add script to replace a changed faulty disk: recovery-replace-mirror.sh
    + all: add script to deactivate (invalidate) one of two disks: storage-invalidate-mirror.sh
+ optional use of tmux for long running ssh connections of bootstrap.sh
+ make distrib_id=Nixos distrib_codename=19.09 working
    + make ./machine-bootstrap-configuration.nix in bootstrap-library
        + make all machine-bootstrap knowledge available there
    + make minimal configuration.nix on project create
+ desaster recovery from backup storage to new machine
    + install: make restore from backup: script bootstrap-1-restore and bootstrap-2-chroot-restore

## tested combinations

### virtual, 2 x 10g disks
+ distrib_codename=bionic,  recovery_autologin=true, storage_opts="--boot-fs=ext4 --root-fs=ext4 --root-lvm=vg0 --root-lvm-vol-size=4096 --root-crypt=true --swap=1024 --reuse"
+ http_proxy set, distrib_codename=focal, recovery_autologin=true, storage_opts="--boot=false --root-size=6000 --root-fs=ext4 --root-lvm=vg0 --root-lvm-vol-size=4096 --root-crypt=true --log=128 --cache=384 --swap=512"
### virtual, 2 x 15g disks
+ http_proxy="http://192.168.122.1:8123", distrib_id=Ubuntu, distrib_codename=focal, recovery_autologin=true, gitops_target="/home/wuxxin", gitops_user="wuxxin", storage_opts="--boot=false --efi-size=2048 --log=128 --cache=128 --root-fs=zfs --root-size=10240 --data-lvm=vgdata --data-fs=ext4 --data-lvm-vol-size=2048 --reuse"

## reasons for overlayfs on zfs for presentation in zfs-linux mailinglist

after integration of overlayfs in the kernel,
    adoption of overlayfs based solutions has been rapidly growing.
in 2020 many software projects assume to be able
    to use overlayfs on any underlying storage fs.
overlayfs runs on ext3/4,xfs,ramfs and even btrfs,
    you dont assume it doesn't on zfs.
overlayfs is the first and will probably keep beeing one of the few solutions
    that have or will have user namespace mount support, either eg.
    via ubuntu overlayfs that is patched for user ns,
    or via a fuseoverlayfs driver (developed by redhat),
    overlayfs in user ns has been adopted by eg. podman, k3s

examples of underlying storage expected to support overlayfs:
+ systemd.volatile https://github.com/systemd/systemd/blob/adca059d55fe0a126dbdd62911b0705ddf8e9b8a/NEWS#L119
+ ubuntu build script (find url again) which obviously uses anything but zfs as underlying storage for their build script by assuming the underlying storage layer has overlayfs support
+ http://bazaar.launchpad.net/~ubuntu-cdimage/ubuntu-cdimage/mainline/
    + https://git.launchpad.net/ubuntu/+source/casper/tree/debian/tests/prep-image?h=ubuntu/eoan

## snippets

+ vm on a xenial host
    + kvm qxl does not work (kernel faults) on suspend and hibernate, use virtio vga instead
    + virtio vga does not work in X11, use qxl instead

+ find and count lines,words
```
find . -name ".git" -prune -o -type f -print0 | wc --files0-from=- | sort -n
```

+ media mount
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
