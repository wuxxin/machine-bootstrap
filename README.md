# bootstrap machine

repository based ubuntu 18.04 liveimage shell installer
with luks encrypted zfs storage and low IO/CPU
continous incremental snapshot backups

## Features

+ Ubuntu 18.04 (bionic) install via ssh
+ for one or two disks (will be setup as mirror if two)
+ fulldiskencryption with luks
+ root on luks encrypted zfs / zfs mirror pool
+ legacy boot and efi compatible hybrid grub setup with grubenv support
+ casper based recovery installation on boot partition
    + unattended cloud-init boot via custom squashfs with ssh ready to login
    + update-recovery-squashfs.sh, recovery-mount/unmount/replace-mirror.sh scripts
+ optional
    + hibernate compatible luks encrypted separate swap partition
    + partitions for ondisk zfs log (zil) and ondisk zfs cache (l2arc)
    + continous encrypted incremental snapshot backup streams to thirdparty storage with zfs and restic
    + desaster recovery from backup storage to new machine
    + devop tool states from salt-shared (eg. desktop )
    + custom devop tool states
    + git + git-crypt repository setup to store machine configuration inside a git repository and crypt all sensitive data with git-crypt

installation on target is done in 4 steps:

+ 0 partition disk, recovery install to /boot, reboot into recovery
+ 1 base installation, create zpool, debootstrap, configure system
+ 2 chroot inside base installation, configure system, reboot into target
+ 3 saltstack run on installed target system

## Preparation

### make a new project repository (eg. box)
```
mkdir box
cd box
git init
mkdir -p machine-config
git submodule add https://github.com/wuxxin/bootstrap-machine.git
git add .
git commit -v -m "initial commit"
```

### optional: add an upstream
```
git remote add origin ssh://git@somewhere.on.the.internet/username/box.git
```

### optional: add files for devop task
```
mkdir -p salt/custom _run
cd salt
git submodule add https://github.com/wuxxin/salt-shared.git
cd ..
cp salt/salt-shared/salt-top.example salt/custom/top.sls
cat <<EOF >> salt/custom/top.sls
  # any
  '*':
    - custom
EOF
touch salt/custom/custom.sls
ln -s ../../bootstrap-machine/devop/bootstrap-pillar.sls \
  machine-config/bootstrap.sls
cat <<EOF > machine-config/top.sls
base:
  '*':
    - custom
EOF
touch machine-config/custom.sls
cat << EOF > .gitignore
#
_run/
EOF
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
# devop_target="/home/$(id -u -n)/$(basename $(readlink -f .))"
# devop_user="$(id -u -n)"
EOF

# copy current user ssh public key as authorized_keys
cat ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub > machine-config/authorized_keys

# list serial(s) of harddisk(s)
./bootstrap-machine/connect.sh temporary "ls /dev/disk/by-id/"

# add serial(s) to config, eg. filter all virtio (but no partitions)
echo $(printf 'storage_ids="'; for i in \
    $(./bootstrap-machine/connect.sh temporary "ls /dev/disk/by-id/" | \
        grep -E "^virtio-[^-]+$"); do \
    printf "$i "; done; printf '"') >> machine-config/config

# create disk.passphrase.gpg (example)
(x=$(openssl rand -base64 9); echo -n "$x" | gpg --encrypt -r username@email.address) \
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