# bootstrap machine

Unattended ssh installer of Ubuntu 18.04 with luks encrypted zfs storage,
suitable for executing from a linux liveimage/recoveryimage system via ssh.

It is intended as a Desktop/Laptop or as a typical rootserver (2HD,headless)

Additionally, i really wanted to have a "cloud like" - little to no performance impact, encrypted, incremental, autorotating snapshot backup system, from and to redundant checksuming data storage on a single machine with the abbility to use common thirdparty storage for this backup. So far it is a very busy journey... https://xkcd.com/974/

## Features

+ unattended ssh install of Ubuntu 18.04 (bionic)
+ one or two disks (will be setup as mirror if two)
+ root on luks encrypted zfs / zfs mirror pool
+ efi and legacy bios boot compatible hybrid grub setup with grubenv support
+ ssh in initramdisk for remote unlock luks on system startup using dracut
+ recovery system installation (casper based) on boot partition
    + unattended cloud-init boot via custom squashfs with ssh ready to login
    + buildin scripts to mount/unmount root and update recovery boot parameter
+ loging of recovery and target system installation on calling machine in directory ./log
+ optional
    + luks encrypted hibernate compatible swap for desktop installation
    + patched zfs-linux for overlay fs support on zfs (frankenstein=true)
    + partitions for ondisk zfs log (zil) and ondisk zfs cache (l2arc)
    + saltstack run at devop phase with states from salt-shared (eg. desktop)
    + git & git-crypt repository setup to store machine configuration inside a git repository and encrypt all sensitive data with git-crypt
+ working on/planned
    + autorotating encrypted incremental snapshot backup to thirdparty storage with zfs and restic
    + desaster recovery from backup storage to new machine
    + recovery scripts to replace a faulty disk, to invalidate a disk

installation on target is done in 4 steps:

+ 1 partition disk, recovery install to /boot, reboot into recovery
+ 2 base installation, frankenstein, create zpool, debootstrap, configure system
+ 3 chroot inside base installation, configure system, reboot into target
+ 4 saltstack run on installed target system

example configurations:

+ a root server with one or two harddisks and static ip setup
    + add custom `$config_path/netplan.yml`
+ a laptop with encrypted hibernation: `storage_opts="--swap yes"`
+ a vm: `http_proxy="http://proxyip:port"`
+ a home-nas with 1(internal:type ssd)+2(external:type spindle) harddisks
    + `storage_opts="--log yes --cache 4096"`

## Preparation

### make a new project repository (eg. box)
```
mkdir box
cd box
git init
mkdir -p machine-config log
printf "#\nlog/\n" > .gitignore
git submodule add https://github.com/wuxxin/bootstrap-machine.git
git add .
git commit -v -m "initial commit"
```

### optional: add an upstream
```
git remote add origin ssh://git@somewhere.on.the.net/username/box.git
```

### optional: add files for devop task
```
mkdir -p salt/custom _run
cd salt
git submodule add https://github.com/wuxxin/salt-shared.git
cd ..
cat <<EOF > machine-config/top.sls
base:
  '*':
    - custom
EOF
cp bootstrap-machine/devop/custom-pillar.sls machine-config/custom.sls
ln -s ../../bootstrap-machine/devop/bootstrap-pillar.sls \
  machine-config/bootstrap.sls
cp bootstrap-machine/devop/top-state.sls salt/custom/top.sls
touch salt/custom/custom.sls
echo "_run/" >> .gitignore
git add .
git commit -v -m "added devop skeleton"
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
git commit -v -m "added git-crypt config"
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
# recovery_autologin="true" # default = "false"
# storage_opts="[--reuse] [--log yes|<logsizemb>]"
# storage_opts="[--cache yes|<cachesizemb] [--swap yes|<swapsizemb>]" 
# storage_opts default=""
# frankenstein="false" # default = "true"
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
# test if everything is ready to go, but dont execute the call
./bootstrap-machine/bootstrap.sh test
# if everything looks fine, run
./bootstrap-machine/bootstrap.sh execute all box.local
git add .
git commit -v -m "bootstrap run"
```

### optional: push committed changed to upstream

```
git push -u origin master

```

## Usage and Maintenance

### reboot into recovery from target system
```
grub-reboot recovery
```