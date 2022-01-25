# Notes

## TODO

### done

### testing

### next
+ native zfs encryption
+ manjaro installation with systemd-boot instead of grub

#### bugs
+ ubuntu: non-blocking: phase install: reboot: rpool busy (can not export rpool)
    + lvm-root busy (Logical volume vg0/lvm-root contains a filesystem in use)
+ ubuntu: after hardreset, recovery is not selected as fallback

#### features
+ recovery scripts to replace a faulty disk and to invalidate a disk
    + write script to replace a changed faulty disk: recovery-replace-mirror.sh
    + write cript to deactivate (invalidate) one of two disks: storage-invalidate-mirror.sh
+ extend: connect.sh initrdluks|recoverymount --unsafe for extra safety for encryption key
    + checks after connecting if gatewaydev is emulated, aborts if emulated
    + use --unsafe if you know you're connecting to a vm
+ gitops: make target system also honor http_proxy on gitops install
+ clevis integration
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

## snippets

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

+ compile custom zfs-linux if requested
```
if $option_frankenstein; then
    if test ! -e /tmp/zfs/build-custom-zfs.sh; then
        echo "error: could not find needed files for frankenstein zfs-linux build, continue without custom build"
    else
        echo "build-custom-zfs"
        chmod +x /tmp/zfs/build-custom-zfs.sh
        /tmp/zfs/build-custom-zfs.sh /tmp/zfs/basedir --source focal --dest $distrib_codename
        if test -e $custom_archive; then rm -rf $custom_archive; fi
        mkdir -p $custom_archive
        mv -t $custom_archive /tmp/zfs/basedir/build/buildresult/*
        rm -rf /tmp/zfs/basedir
        cat > $custom_sources_list << EOF
deb [ trusted=yes ] file:$custom_archive ./
EOF
        # needs additional apt-get update, done below
    fi
fi
```

```
if $option_frankenstein; then
    echo "copy custom archive files"
    if test -e "/mnt$custom_archive"; then
        if $option_restore_backup; then
            echo "WARNING: --restore-from-backup: not deleting existing target dir $custom_archive"
        else
            echo "WARNING: removing existing $custom_archive"
            rm -rf "/mnt$custom_archive"
        fi
    fi
    echo "insert distrib_codename($distrib_codename) into /etc/pbuilderrc"
    echo "DISTRIBUTION=$distrib_codename" >> /mnt/etc/pbuilderrc
    mkdir -p "/mnt$custom_archive"
    cp -t "/mnt$custom_archive" $custom_archive/*
    cat > "/mnt$custom_sources_list" << EOF
deb [ trusted=yes ] file:$custom_archive ./
EOF
    # remove archive from ramdisk, it is already installed in running system and copied to target
    rm -r $custom_archive
    rm $custom_sources_list
fi
```
