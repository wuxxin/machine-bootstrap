# bootstrap machine

Unattended ssh installer of Ubuntu 18.04/19.04 with luks encrypted zfs storage,
suitable for executing from a linux liveimage/recoveryimage system via ssh.

It is intended as a Desktop/Laptop or as a typical rootserver (2HD,headless)

Additionally, i really wanted to have a "cloud like" - little to no performance impact, encrypted, incremental, autorotating snapshot backup system, from and to redundant checksuming data storage on a single machine with the abbility to use common thirdparty storage for this backup. So far it is a very busy journey... https://xkcd.com/974/

## Features

+ unattended ssh install of Ubuntu 18.04 LTS (bionic) or 19.04 (disco)
+ one or two disks (will be setup as mirror if two)
+ root on luks encrypted zfs / zfs mirror pool
+ efi and legacy bios boot compatible hybrid grub setup with grubenv support
+ ssh in initial ramdisk for remote unlock luks on system startup using dracut
+ recovery system installation (based on casper ubuntu 18.04.01 liveserver) on boot partition
    + unattended cloud-init boot via custom squashfs with ssh ready to login
    + buildin scripts to mount/unmount root and update recovery boot parameter
+ loging of recovery and target system installation on calling machine in directory ./log
+ optional
    + luks encrypted hibernate compatible swap for desktop installation
    + patched zfs-linux for overlay fs support on zfs (frankenstein=true)
    + partitions for ondisk zfs log (zil) and ondisk zfs cache (l2arc)
    + saltstack run at devop phase with states from salt-shared (eg. desktop)
    + git & git-crypt repository setup to store machine configuration inside a git repository and encrypt all sensitive data with git-crypt
    + build a preconfigured bootstrap-0 livesystem image for physical bootstrap 
        + execute `./bootstrap-machine/bootstrap.sh create-liveimage` to build image
        + copy `run/liveimage/bootstrap-0-liveimage.iso` to usbstick
+ working on/planned
    + autorotating encrypted incremental snapshot backup to thirdparty storage with zfs and restic
    + desaster recovery from backup storage to new machine
    + recovery scripts to replace a faulty disk, to invalidate a disk

installation is done in 4 steps:

+ 1 initial live system: partition disk, recovery install to /boot, reboot into recovery
+ 2 recovery live system: build patches, create zpool, debootstrap, configure system, chroot into target
+ 3 chroot target: configure system, kernel, initrd, install standard software, reboot into target
+ 4 target system: install and run saltstack on target system

example configurations:

+ a root server with one or two harddisks and static ip setup
    + add custom `$config_path/netplan.yml`
+ a laptop with encrypted hibernation: `storage_opts="--swap yes"`
+ a vm: `http_proxy="http://proxyip:port"`
+ a home-nas with 1(internal:type ssd)+2(external:type spindle) harddisks
    + `storage_opts="--log yes --cache 4096"`

## Preparation

Requirements:
+ Minimum RAM:
  + frankenstein=yes: Minimum 4GB Ram (for compiling zfs in ram in recovery)
  + frankenstein=no : Minimum 2GB RAM
+ Minimum Storage:
  + 10GB-15GB (10 += if swap=yes then RAM-Size*1.25 as default)

### make a new project repository (eg. box)
```
mkdir box
cd box
git init
mkdir -p machine-config log run
printf "#\nlog/\nrun/\n" > .gitignore
git submodule add https://github.com/wuxxin/bootstrap-machine.git
git add .
git commit -v -m "initial config"
```

### optional: add an upstream
```
git remote add origin ssh://git@somewhere.on.the.net/username/box.git
```

### optional: add files for devop task
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
ln -s ../../bootstrap-machine/devop/bootstrap-pillar.sls \
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
sitemanager.xml filter=git-crypt diff=git-crypt
remmina.pref filter=git-crypt diff=git-crypt
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
# http_proxy="http://192.168.122.1:8123" # default = ""
# storage_opts="[--reuse] [--log yes|<logsizemb>]"
# storage_opts="[--cache yes|<cachesizemb] [--swap yes|<swapsizemb>]"
# storage_opts default=""
# recovery_autologin="true" # default = "false"
# frankenstein="true" # default = "false"
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

# create disk.passphrase.gpg (example)
(x=$(openssl rand -base64 9); echo -n "$x" | \
    gpg --encrypt -r username@email.address) \
    > machine-config/disk.passphrase.gpg

# optional: create a custom netplan.yml

```

## Install System

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

## Usage and Maintenance

### connect to machine

+ connect to running recovery / initrd or system
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
