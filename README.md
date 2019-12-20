# Machine bootstrap

Unattended ssh installer of Ubuntu 18.04/19.04/19.10 with buildin recovery image, 
    root storage on luks encrypted zfs or other specialized storage layouts,
    to be executed from a linux liveimage/recoveryimage system via ssh.

It serves two use case:
+ as an experimental Desktop/Laptop for getting experience with this setup
+ as a typical Rootserver (2xHD, headless)
    + this is still in the writing and not ready yet, see `TODO.md` for details

## Features

+ efi and legacy bios boot compatible hybrid grub setup with grubenv support
+ one or two disks (will be automatically setup as mirror if two disks)
+ root on luks encrypted zfs / zfs mirror pool (encrypted storage at rest)
+ other common and less common storage setups
+ dracut initial ramdisk with ssh for remote unlock luks on system startup
+ recovery system installation (based on casper ubuntu 18.04.x liveserver) on EFI partition
    + unattended cloud-init boot via custom squashfs with ssh ready to login
    + buildin scripts to mount/unmount root and update recovery boot parameter
+ logging of recovery and target system installation on calling machine in directory ./log

#### additional optional Features
+ luks encrypted hibernate compatible swap for eg. a desktop installation
+ overlay fs support on zfs by building patched zfs-linux (frankenstein=true)
+ saltstack run at devop phase with states from salt-shared (eg. desktop)
+ encrypt all sensitive data in setup repository with git-crypt
    + git & git-crypt repository setup to store machine configuration inside a git repository
+ build a preconfigured bootstrap-0 livesystem image usable for physical installation
    + resulting image is compatible as CD or USB-Stick with BIOS and EFI support
    + execute `./machine-bootstrap/bootstrap.sh create-liveimage` to build image
    + copy `run/liveimage/bootstrap-0-liveimage.iso` to usbstick

#### working on/todo/planned
+ recovery scripts to replace a faulty disk, to invalidate a disk
+ desaster recovery from backup storage to new machine
+ "cloud like" autorotating encrypted incremental snapshot backup to thirdparty storage with zfs and restic
    this should be a little to no performance impact, encrypted, incremental, autorotating snapshot backup system, from and to redundant checksuming data storage on a single machine with the abbility to use common thirdparty storage for this backup. So far it is a very busy journey... https://xkcd.com/974/
+ home-nas setup with 1 x internal:type:ssd + 2 x external:type:spindle harddisks
    + todo: research issues at least with 0.7* and shutdown platters on external hds
    
#### example configurations
+ a root server with one or two harddisks and static ip setup
    + add custom `netplan.yml`
+ a laptop with encrypted hibernation: 
    + add `storage_opts="--swap=yes"` to `machine-config.env`
+ a vm with a http proxy on its host:
    + add `http_proxy="http://proxyip:port"`to `machine-config.env`
+ install ubuntu eoan instead of bionic:
    + add `distribution=eoan` to `machine-config.env`

## Preparation

Requirements:

+ Minimum RAM: **currently 4GB**, may become less again, was
    + frankenstein=no : 2GB RAM
    + frankenstein=yes: 4GB Ram (for compiling zfs in ram in recovery)
+ Minimum Storage
    + 10GB (no swap, console) 
    + \+ ~5GB (with swap for 4gb memory)
    + \+ ~5GB (full desktop installation)

### make a new project repository (eg. box)
```
mkdir box
cd box
git init
mkdir -p config log run
printf "# machine-bootstrap ignores\n/log\n/run\n" > .gitignore
git submodule add https://github.com/wuxxin/machine-bootstrap.git
git add .
git commit -v -m "initial config"
```

### optional: add an upstream
```
git remote add origin ssh://git@some.where.net/path/box.git
```

### optional: add files for a devop task
```
mkdir -p salt/custom
cd salt
git submodule add https://github.com/wuxxin/salt-shared.git
cd ..
cat > config/top.sls << EOF
base:
  '*':
    - custom
EOF
for i in custom bootstrap; do
    cp machine-bootstrap/devop/${i}-pillar.sls config/${i}.sls
done
cp machine-bootstrap/devop/top-state.sls salt/custom/top.sls
touch salt/custom/custom.sls
git add .
git commit -v -m "add devop skeleton"
```

### optional: git-crypt config

```
git-crypt init
cat > .gitattributes <<EOF
**/secret/** filter=git-crypt diff=git-crypt
**/secrets/** filter=git-crypt diff=git-crypt
*secrets* filter=git-crypt diff=git-crypt
*secret* filter=git-crypt diff=git-crypt
*key filter=git-crypt diff=git-crypt
*keys filter=git-crypt diff=git-crypt
*id_rsa* filter=git-crypt diff=git-crypt
*id_ecdsa* filter=git-crypt diff=git-crypt
*id_ed25519* filter=git-crypt diff=git-crypt
*.sec* filter=git-crypt diff=git-crypt
*.key* filter=git-crypt diff=git-crypt
*.pem* filter=git-crypt diff=git-crypt
*.p12 filter=git-crypt diff=git-crypt
credentials* filter=git-crypt diff=git-crypt
csrftokens* filter=git-crypt diff=git-crypt
random_seed filter=git-crypt diff=git-crypt
EOF
git-crypt add-gpg-user user.email@address.org
git add .
git commit -v -m "add git-crypt config"
```

### configure machine

```
cat > config/machine-config.env <<EOF
# mandatory
sshlogin=root@1.2.3.4
hostname=box.local
firstuser=$(id -u -n)
# storage_ids=""

# optional
# http_proxy="http://192.168.122.1:8123" # default ""
# storage_opts=""
# [--reuse]
# [--log=        true|*false|<logsizemb,   default if true: 1024 mb>]
# [--cache=      true|*false|<cachesizemb, default if true: 59392 mb>]
# [--swap=       true|*false|<swapsizemb,  default if true: 1.25xRAM mb>]
# [--boot=       *true|false|<bootsizemb,  default if true: 600 mb>]
# [--boot-fs=    *zfs|ext4|xfs]
# [--root-fs=    *zfs|ext4|xfs]
# [--root-lvm=   *""|<vgname>]
# [--root-lvm-vol-size= <volsizemb, default if lvm is true: 20480 mb>]
# [--root-crypt= *true|false]
# [--root-size=  *all|<rootsizemb>]
# [--data-fs=    *""|zfs|ext4|xfs|other]
# [--data-crypt= *true|false]
# [--data-lvm=   *""|<vgname>]
# distribution="eoan" # default "bionic"
# recovery_autologin="true" # default "false"
# frankenstein="true" # default "false"
# devop_target="/home/$(id -u -n)"
# devop_user="$(id -u -n)"
EOF

# copy current user ssh public key as authorized_keys
cat ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub \
    > config/authorized_keys

# list serial(s) of harddisk(s)
./machine-bootstrap/connect.sh temporary "ls /dev/disk/by-id/"

# add serial(s) to config, eg. filter all virtio (but no partitions)
echo $(printf 'storage_ids="'; for i in \
    $(./machine-bootstrap/connect.sh temporary "ls /dev/disk/by-id/" | \
        grep -E "^virtio-[^-]+$"); do \
    printf "$i "; done; printf '"') >> config/machine-config.env

# create disk.passphrase.gpg
# example: create a random diskphrase and encrypted with user gpg key
(x=$(openssl rand -base64 12); echo -n "$x" | \
    gpg --encrypt -r username@email.address) \
    > config/disk.passphrase.gpg

# optional: create a custom netplan.yml

```

### optional: make physical bootstrap-0 liveimage

```
./machine-bootstrap/bootstrap.sh create-liveimage
# copy run/liveimage/bootstrap-0-liveimage.iso to usbstick
# boot target machine from usbstick
```

## Installation

installation is done in 4 steps:

+ 1 initial live system: partition disk, recovery install to EFI partition, reboot into recovery
+ 2 recovery live system: build patches, create boot & root, debootstrap, configure system, chroot into target
+ 3 recovery chroot target: configure system, kernel, initrd, install standard software, reboot into target
+ 4 target system: install and run saltstack

```
# test if everything needed is there
./machine-bootstrap/bootstrap.sh test
# if alls looks fine, run
./machine-bootstrap/bootstrap.sh execute all box.local
# logs of each step will be written to log/bootstrap-*.log 
# but log directory is in .gitignore and content won't be comitted
git add .
git commit -v -m "bootstrap run"
```

### optional: push committed changes to upstream

```
git push -u origin master

```

## Maintenance

### connect to machine

+ connect to target machine running in recovery, initrd or final system
```
./machine-bootstrap/connect.sh recovery|initrd|system
```

+ connect to initrd, open luks disks
```
./machine-bootstrap/connect.sh initrdluks
```

+ connect to recovery, open luks disks
```
./machine-bootstrap/connect.sh recoveryluks
```

### switch next boot to boot into recovery (from running target system)
```
grub-reboot recovery
reboot
```

## Notes

### Limits and Contraints

+ SWAP
    if using a SWAP partition, the swap partition will always be encrypted.
    Also ROOT should be encrypted in this case.
    This is because suspend to disk has all memory secrets written to disk,
    so any suspend would store all secrets in plaintext to disk.
    Any other usages of swap beside suspend to disk where encryption may not
    be desired, can be created as swap file using create_file_swap()

+ ZFS or LVM but not both (ROOT, DATA)
    currently only either of zfs or lvm can be used on a partition.
    if both are specified the script will probably fail.

### Examples

+ virtual machine with root on ext4
    + storage_opts="--boot=false --root-fs=ext4 --root-crypt=false"
+ virtual machine with encrypted root on ext4
    + storage_opts="--boot-fs=ext4 --root-fs=ext4"
+ virtual machine with encrypted lvm and root lv (30gb) on ext4
    + storage_opts="--boot-fs=ext4 --root-fs=ext4 --root-lvm=vgroot --root-lvm-vol-size=30720"
+ desktop: encrypted root and swap, boot and root on zfs, patched zfs for overlay support
    + storage_opts="--swap=true --frankenstein=true"
+ server: one or two encrypted disks, boot and root on zfs, patched zfs for overlay support
    + storage_opts="--frankenstein=true"
+ server: one or two encrypted disks with lvm storage (100gb) with root (25gb) and zfs on data (rest)
    + storage_opts="--boot-fs=ext4 --root-fs=ext4 --root-size=102400 --root-lvm=vgroot --root-lvm-vol-size=25600" --data-fs=zfs"

### GPT Layout
GPT Partitionnaming (max 36 x UTF16)

Nr |Name|Description|
---|---|---
7  | `BIOS,1,2`  | GRUB-BIOS boot binary partition, used to host grub code on gpt for bios boot
6  | `EFI,1,2`   | EFI vfat partition, dual efi & bios grub installation and recovery- fs,kernel,initrd
5  | `LOG,1,2`   | **optional** ZFS Log or other usages
4  | `CACHE,1,2` | **optional** ZFS Cache or other usages
3  | `[raid_]luks_SWAP,1,2`  | **optional** encrypted hibernation compatible swap
2  | `[raid_](zfs:ext4:xfs)_BOOT,1,2`  | **optional** boot partition, unencrypted, kernel,initrd
1  | `[raid_][luks_][lvm.vg0_](zfs:ext4:xfs)_ROOT,1,2` | root partition
8  | `[raid_][luks_][lvm.vgdata_](zfs:ext4:xfs:other)_DATA,1,2` | **optional** data partition
