# bootstrap machine

Unattended ssh installer of Ubuntu 18.04/19.04 with luks encrypted zfs storage,
    executed to a linux liveimage/recoveryimage system via ssh.

It serves two use case:
+ as a experimental Desktop/Laptop Setup for getting handson experience of the setup
+ as a typical rootserver (2xHD,headless)
    + this is still in the writing and not ready yet, see `TODO.md` for details

## Features

+ unattended ssh install of Ubuntu 18.04 LTS (bionic) or 19.04 (disco)
+ root on luks encrypted zfs / zfs mirror pool (encrypted storage at rest)
+ one or two disks (will be setup as mirror if two)
+ efi and legacy bios boot compatible hybrid grub setup with grubenv support
+ ssh in initial ramdisk for remote unlock luks on system startup using dracut
+ recovery system installation (based on casper ubuntu 18.04.01 liveserver) on boot partition
    + unattended cloud-init boot via custom squashfs with ssh ready to login
    + buildin scripts to mount/unmount root and update recovery boot parameter
+ loging of recovery and target system installation on calling machine in directory ./log

#### additional optional Features
+ luks encrypted hibernate compatible swap for eg. a desktop installation
+ overlay fs support on zfs by building patched zfs-linux (frankenstein=true)
+ saltstack run at devop phase with states from salt-shared (eg. desktop)
+ encrypt all sensitive data with git-crypt
    + git & git-crypt repository setup to store machine configuration inside a git repository
+ build a preconfigured bootstrap-0 livesystem image usable for physical installation
    + resulting image is compatible as CD or USB-Stick with BIOS and EFI support
    + execute `./bootstrap-machine/bootstrap.sh create-liveimage` to build image
    + copy `run/liveimage/bootstrap-0-liveimage.iso` to usbstick

#### working on/planned
+ mirroring has some issues (eg. efi cloning) and needs some fixing
+ desaster recovery from backup storage to new machine
+ recovery scripts to replace a faulty disk, to invalidate a disk
+ "cloud like" autorotating encrypted incremental snapshot backup to thirdparty storage with zfs and restic
    this should be a little to no performance impact, encrypted, incremental, autorotating snapshot backup system, from and to redundant checksuming data storage on a single machine with the abbility to use common thirdparty storage for this backup. So far it is a very busy journey... https://xkcd.com/974/
+ home-nas setup with 1 x internal:type:ssd + 2 x external:type:spindle harddisks
    + some issues at least with 0.7* and shutdown platters on external hds
    
#### example configurations

+ a root server with one or two harddisks and static ip setup
    + add custom `$config_path/netplan.yml`
+ a laptop with encrypted hibernation: 
    + `storage_opts="--swap yes"`
+ a vm: `http_proxy="http://proxyip:port"`
+ install ubuntu disco instead of bionic:
    + `distribution=disco`

## Preparation

Requirements:

+ Minimum RAM
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
mkdir -p machine-config log run
printf "#\n/log\n/run\n" > .gitignore
git submodule add https://github.com/wuxxin/bootstrap-machine.git
git add .
git commit -v -m "initial config"
```

### optional: add an upstream
```
git remote add origin ssh://git@some.where.net/username/box.git
```

### optional: add files for a devop task
```
mkdir -p salt/custom
cd salt
git submodule add https://github.com/wuxxin/salt-shared.git
cd ..
cat > machine-config/top.sls << EOF
base:
  '*':
    - custom
EOF
cp bootstrap-machine/devop/custom-pillar.sls machine-config/custom.sls
ln -s ../bootstrap-machine/devop/bootstrap-pillar.sls \
  machine-config/bootstrap.sls
cp bootstrap-machine/devop/top-state.sls salt/custom/top.sls
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
cat > machine-config/config <<EOF
# mandatory
sshlogin=root@1.2.3.4
hostname=box.local
firstuser=$(id -u -n)
# storage_ids=""

# optional
# http_proxy="http://192.168.122.1:8123" # default ""
# storage_opts="[--reuse] [--log yes|<logsizemb>]"
# storage_opts="[--cache yes|<cachesizemb] [--swap yes|<swapsizemb>]"
# storage_opts default=""
# distribution="disco" # default "bionic"
# recovery_autologin="true" # default "false"
# frankenstein="true" # default "false"
# devop_target="/home/$(id -u -n)"
# devop_user="$(id -u -n)"
EOF

# copy current user ssh public key as authorized_keys
cat ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub \
    > machine-config/authorized_keys

# list serial(s) of harddisk(s)
./bootstrap-machine/connect.sh temporary "ls /dev/disk/by-id/"

# add serial(s) to config, eg. filter all virtio (but no partitions)
echo $(printf 'storage_ids="'; for i in \
    $(./bootstrap-machine/connect.sh temporary "ls /dev/disk/by-id/" | \
        grep -E "^virtio-[^-]+$"); do \
    printf "$i "; done; printf '"') >> machine-config/config

# create disk.passphrase.gpg
# example: create a random diskphrase and encrypted with user gpg key
(x=$(openssl rand -base64 9); echo -n "$x" | \
    gpg --encrypt -r username@email.address) \
    > machine-config/disk.passphrase.gpg

# optional: create a custom netplan.yml

```

### optional: make physical bootstrap-0 liveimage

```
./bootstrap-machine/bootstrap.sh create-liveimage
# copy run/liveimage/bootstrap-0-liveimage.iso to usbstick
# boot target machine from usbstick
```

## Installation

installation is done in 4 steps:

+ 1 initial live system: partition disk, recovery install to /boot, reboot into recovery
+ 2 recovery live system: build patches, create zpool, debootstrap, configure system, chroot into target
+ 3 recovery chroot target: configure system, kernel, initrd, install standard software, reboot into target
+ 4 target system: install and run saltstack

```
# test if everything needed is there
./bootstrap-machine/bootstrap.sh test
# if alls looks fine, run
./bootstrap-machine/bootstrap.sh execute all box.local
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
./bootstrap-machine/connect.sh recovery|initrd|system
```

+ connect to initrd, open luks disks
```
./bootstrap-machine/connect.sh luksopen
```

### switch next boot to boot into recovery (from running target system)
```
grub-reboot recovery
reboot
```
