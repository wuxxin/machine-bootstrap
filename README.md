# Machine bootstrap

Unattended ssh based linux operating system installer
with customizable storage layout and remote unlock.

**Target Systems:**

+ Ubuntu 20.04 LTS (Focal)
+ Manjaro Stable

**Usage and Use Cases:**

+ to be executed on an linux liveimage/recoveryimage system connected via ssh
+ can be configured to fit different use cases, eg.
    + as a Desktop or Laptop with hibernate compatible swap
    + as a typical Rootserver (2xHD, headless)
    + as a home-nas/home-io headless server
        + with one or two ssd and two ore more attached big spindle disks

## Features

* easy to use one file setup that configures machine
+ **one or two disks** (will be automatically setup as mdadm \&/ zfs mirror if two disks)
+ **root** and other **on luks or native encrypted zfs** (mirror) pool
    + and **other common and less common**, easy to configure **storage setups**
+ **logging** of recovery and system installation on the calling machine in ./run/log
+ **ubuntu**
    + **efi and legacy bios** boot compatible hybrid grub setup with grubenv support
    + initial ramdisk based on **dracut with openssh and crypt remote unlock**
+ **manjaro**
    + modern **amd64 uefi systemd-boot** setup

### optional Features

+ luks encrypted **hibernate compatible swap** for eg. a laptop installation
+ **gitops stage using saltstack** with states from salt-shared (eg. desktop)
+ **encrypt sensitive data** in setup repository with git-crypt
    + git & git-crypt repository setup to store machine configuration inside a git repository
+ **ubuntu**
    + buildin **recovery system installation** on EFI partition
        + based on casper of ubuntu 20.04
        + unattended cloud-init boot via custom squashfs with ssh ready to login
        + buildin scripts to mount/unmount root and update recovery boot parameter
    + build a **preconfigured livesystem image** usable for headless physical installation
        + resulting image is compatible as CD or USB-Stick with BIOS and EFI support
        + optional netplan for static or other non dhcp based ip configurations
        + execute `./machine-bootstrap/bootstrap.sh create-liveimage` to build image
        + use ssh with preconfigured key or physical terminal/console of livesystem for interaction

#### Example Configurations

+ a root server with custom network (eg. static ip)
    + add custom `netplan.yaml`
+ a laptop with encrypted hibernation:
    + add `storage_opts="--swap=yes"` to `node.env`
+ a vm with a http proxy on its host:
    + add `http_proxy="http://proxyip:port"`to `node.env`
+ install ubuntu eoan instead of focal:
    + add `distrib_codename=eoan` to `node.env`
+ install manjaro stable:
    + add `distrib_id=manjaro; distrib_codename=stable` to `node.env`

##### Storage Examples

+ virtual machine with root on ext4
    + `storage_opts="--boot=false --root-fs=ext4 --root-crypt=false"`
+ virtual machine with encrypted root on ext4
    + `storage_opts="--root-fs=ext4"`
+ virtual machine with encrypted lvm and root lv (30gb) on ext4
    + `storage_opts="--root-fs=ext4 --root-lvm=vgroot --root-lvm-vol-size=30720"`
+ laptop: encrypted root and swap, root on zfs
    + `storage_opts="--swap=true"`
+ server: one or two disks, encrypted root on zfs
    + `storage_opts=""`
+ server: one or two disks, encrypted
    with lvm storage (100gb) where root (25gb) is placed and zfs is used on data (rest of disk)
    + `storage_opts="--root-fs=ext4 --root-size=102400 --root-lvm=vgroot --root-lvm-vol-size=25600" --data-fs=zfs"`
+ server: one or two encrypted disks, root on zfs (100g), with data lvm storage vgdata
    + `storage_opts="--root-size=102400 --data-lvm=vgdata --data-lvm-vol-size=25600" --data-fs=ext4"`
+ manjaro, desktop: systemd-boot and native zfs encryption, no swap
    + `distrib_id=manjaro; storage_opts="root_crypt=native"`

## Setup

Requirements:

+ Minimum RAM: 2GB RAM
+ Minimum Storage
    + 10GB (no swap, console)
    + \+ ~5GB (with swap for 4gb memory)
    + \+ ~5GB (full desktop installation)

### make a new project repository (eg. box)

```bash
targethostname=box
mkdir ${targethostname}
cd ${targethostname}
git init
mkdir -p config doc run/log
printf "# machine-bootstrap ignores\n\n/run\n" > .gitignore
git submodule add https://github.com/wuxxin/machine-bootstrap.git
git add .
git commit -v -m "initial commit for host ${targethostname}"
```

### optional: add an upstream

```bash
git remote add origin ssh://git@some.where.net/path/${targethostname}.git
git push -u origin master
```

### configure machine

```bash
cat > config/node.env << EOF
# # mandatory
sshlogin=root@1.2.3.4
hostname=${targethostname}
firstuser=$(id -u -n)
# storage_ids=""

# # optional

# storage_opts=""
# [--reuse]
# [--efi-size=   <efisizemb, default: 2200 mb>]
# [--boot=       true|*false|<bootsizemb,  default if true: 400 mb>]
# [--boot-fs=    *zfs|ext4|xfs]
# [--swap=       true|*false|<swapsizemb,  default if true: 1.25xRAM mb>]
# [--log=        true|*false|<logsizemb,   default if true: 1024 mb>]
# # default zil log_size ~= 5seconds io-write , eg. 200mb per sec *5 = 1024
# [--cache=      true|*false|<cachesizemb, default if true: 59918 mb (eq. 1gb RAM)>]
# # zfs cache system will use (<cachesizemb>/58)mb of RAM to hold L2ARC references
# # eg. 58GB on disk L2ARC uses 1GB of ARC space in memory

# [--root-fs=    *zfs|ext4|xfs]
# [--root-size=  *all|<rootsizemb>]
# [--root-crypt= *true|false|native]
# [--root-lvm=   *""|<vgname>]
# [--root-lvm-vol-size= <volsizemb, default if lvm is true: 20480 mb>]

# [--data-fs=    *""|zfs|ext4|xfs|other, if not empty: --root-size must be set]
# [--data-crypt= *true|false]
# [--data-lvm=   *""|<vgname>]
# [--data-lvm-vol-size= <volsizemb, default if lvm is true: 20480 mb>]

# # if set, cpu_model_name and network_mac will be used in remote attestation in connect.sh
# cpu_model_name="AMD Ryzen 7 PRO 5750G with Radeon Graphics"
# network_mac="01:02:03:04:05:06"

# # if set http_proxy will be used to install system
# http_proxy="http://192.168.122.1:8123" # default ""

# distrib_id="manjaro" # default "ubuntu"
# distrib_codename="stable" # default "focal" on ubuntu, "stable" on manjaro
# distrib_profile="manjaro/kde" # default "manjaro/gnome" on manjaro, else empty

# recovery_id="manjaro" # default "ubuntu" if not manjaro, else "manjaro"
# recovery_install="false" # default "true"
# recovery_autologin="true" # default "false"

# gitops_user="$firstuser" # default $firstuser
# gitops_target="/home/$firstuser" # default /home/$firstuser
# gitops_source=""
# gitops_branch=""

EOF
git add config/node.env
git commit -v -m "add node config"
```

### copy current user ssh public key as authorized_keys

```bash
cat ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub > config/authorized_keys
git add config/authorized_keys
git commit -v -m "add authorized_keys"
```

### optional: add files for a gitops run

```bash
mkdir -p salt/local
pushd salt
git submodule add https://github.com/wuxxin/salt-shared.git
popd
printf "base:\n  '*':\n    - main\n" > config/top.sls
cp salt/salt-shared/gitops/template/pillar.template.sls config/main.sls
cp salt/salt-shared/gitops/template/node.template.sls config/node.sls
cp salt/salt-shared/gitops/template/state.template.sls salt/local/top.sls
printf "  '*':\n    - machine-bootstrap\n\n" >> salt/local/top.sls
touch salt/local/main.sls
ln -s "../../machine-bootstrap" salt/local/machine-bootstrap
git add .
git commit -v -m "add saltstack skeleton"
```

### optional: git-crypt config

```bash
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
authorized_keys !filter !diff
.gitattributes !filter !diff
EOF
git-crypt add-gpg-user user.email@address.org
git add .
git commit -v -m "add git-crypt config and first git-crypt user"
```

### optional: add machine git-crypt user

+ if git-crypt is used on repository files, the additional files
gitops@node-secret-key.gpg and gitops@node-public-key.gpg are needed in config dir

```bash
gpgdir="$(mktemp -d -p /run/user/$(id -u))"
base="--homedir $gpgdir --batch --yes"
if test -d $gpgdir; then
    gpg $base --gen-key << EOF
%echo generating
%no-protection
Key-Type: RSA
Key-Length: 2560
Key-Usage: encrypt,sign
Name-Real: ${targethostname}
Name-Email: gitops@node
Expire-Date: 0
%commit
%echo done
EOF
    gpg $base --armor --export --output config/gitops@node-public-key.gpg
    gpg $base --armor --export-secret-keys --output config/gitops@node-secret-key.gpg
    rm -r $gpgdir
    # FIXME add gpg user to git-crypt
    git add .
    git commit -v -m "add gitops@node git-crypt user"
fi
```

### optional: add ssh credentials for git repository cloning on target

+ if gitops_source is empty, rsync will be used to transfer the files to the target
+ if gitops_source is set, the script will clone the repository files on target
+ if gitops_source is a ssh git url, the following additional files are needed in config dir
    + gitops.id_ed25519, gitops.id_ed25519.pub, gitops_known_hosts

```bash
ssh-keygen -q -t ed25519 -N '' -C 'gitops@${targethostname}' -f config/gitops.id_ed25519
ssh-keyscan -H -p 10023 git.server.domain > config/gitops.known_hosts
```

### create disk.passphrase.gpg

```bash
# example: create a random diskphrase and encrypted with user gpg key
(x=$(openssl rand -base64 16); echo -n "$x" | \
    gpg --encrypt -r username@email.address) \
    > config/disk.passphrase.gpg
```

### add storage serials to node.env

```bash
# list serial(s) of harddisk(s)
./machine-bootstrap/connect.sh temporary "ls /dev/disk/by-id/"

# add serial(s) to config, eg. filter all virtio (but no partitions)
echo $(printf 'storage_ids="'; for i in \
    $(./machine-bootstrap/connect.sh temporary "ls /dev/disk/by-id/" | \
        grep -E "^virtio-[^-]+$"); do \
    printf "$i "; done; printf '"') >> config/node.env
```

### optional: create a custom netplan.yaml file

```bash
cat > config/netplan.yaml << EOF
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
    all-eth:
      match:
        name: "eth*"
      dhcp4: true
EOF
```

### optional: create a custom systemd network file

```bash
cat > config/systemd.network << EOF
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
EOF
```

### optional: create a minimal Nixos configuration.nix

```bash
cat > config/configuration.nix << EOF
# Help is available in the configuration.nix(5) man page
{ config, pkgs, ... }:
{
  imports =
    [ # Include the results of the hardware scan and machine-bootstrap scripts
      ./hardware-configuration.nix
      ./machine-bootstrap-configuration.nix
    ];
}
EOF
```

### optional: make physical bootstrap-0 liveimage

create-liveimage creates an iso hybrid image usable as CD or usb-stick,
bootable via efi or bios.

this can be useful eg. if the target is headless,
or inside an emulator supplied with a live image preconfigured with ssh and other keys.

```bash
./machine-bootstrap/bootstrap.sh create-liveimage
# copy run/liveimage/bootstrap-0-liveimage.iso to usbstick
# boot target machine from usbstick
```

## Installation

installation is done in 4 steps:

+ 1 initial live system
    + partition disk
    + optional recovery install to EFI partition
    + optional reboot into recovery
+ 2 recovery or target live system
    + build patches
    + format partitions
    + bootstrap system
    + configure system
    + chroot into target
+ 3 recovery or target live system chroot
    + configure system
    + install kernel and initrd
    + install standard software
    + install bootloader
    + reboot into target
+ 4 target system
    + install and run saltstack

```bash
# test if everything needed is there
./machine-bootstrap/bootstrap.sh test

# if alls looks fine, commit config
git add .
git commit -v -m "bootstrap run"

# run all steps (recovery, install, gitops) combined
./machine-bootstrap/bootstrap.sh install all ${targethostname}

# or each step seperate
./machine-bootstrap/bootstrap.sh install recovery ${targethostname}
./machine-bootstrap/bootstrap.sh install system ${targethostname} [--no-reboot]
./machine-bootstrap/bootstrap.sh install gitops ${targethostname}

# logs of each step will be written to log/bootstrap-*.log
# but log directory is in .gitignore and content won't be comitted
```

### optional: push committed changes upstream

```bash
git push -u origin master

```

## Maintenance

### connect to machine

+ connect to target machine running in the temporary liveimage, in the recovery system, in the initrd of the productiton system, or the production system
```bash
./machine-bootstrap/connect.sh temporary|recovery|initrd|system
```

+ connect to initrd, open encrypted storage, exit, machine will continue to boot
```bash
./machine-bootstrap/connect.sh initrd-unlock
```

+ connect to recovery, open encrypted storage, mount storage, prepare chroot, shell
```bash
./machine-bootstrap/connect.sh recovery-unlock
```

### switch next boot to boot into recovery (from running target system)
```bash
grub-reboot recovery
reboot
```

## Notes

### Partition (GPT) Layout

Nr |Name(max 36 x UTF16)|Description|
---|---|---
6  | `BIOS,1,2`  | GRUB-BIOS boot binary partition, used to host grub code on gpt for bios boot
5  | `EFI,1,2`   | EFI vfat partition, unencrypted, /boot if no boot partition
4  | `LOG,1,2`   | **optional** ZFS Log (SLOG) for pools of other storage devices
3  | `CACHE,1,2` | **optional** ZFS Cache (L2ARC) for pools of other storage devices
2  | `[raid_]luks_SWAP,1,2`  | **optional** encrypted hibernation compatible swap
1  | `[raid_](zfs:ext4:xfs)_BOOT,1,2`  | **optional**,**legacy** boot partition, unencrypted, kernel,initrd
0  | `[raid_][luks_][lvm.vg0_](enczfs:zfs:ext4:xfs)_ROOT,1,2` | root partition
7  | `[raid_][luks_][lvm.vgdata_](enczfs:zfs:ext4:xfs:other)_DATA,1,2` | **optional** data partition

+ Ubuntu/Debian
    + hybrid efi & bios grub installation
    + EFI contains recovery system: kernel,initrd,fs
    + EFI contains /boot for system: kernel,initrd if no boot partition
+ Manjaro
    + efi only systemd-boot installation
    + EFI contains /boot for system, kernel,initrd if no boot partition

### Limits, Automatics, Contraints, Safety, Security

+ one or two disks only, if machine has more disks they have to be setup later

+ ZFS on two disks will get two separate devices to let zfs manage the mirroring,
    any other filesystem will get an mdadm-mirror device.

+ SWAP
    + if using a SWAP partition, the swap partition will always be encrypted.
        Suspend to disk has all memory secrets written to disk,
        so a suspend would store these secrets in plaintext to disk.

    + to make encrypted swap useful,
        ROOT should also be encrypted, this can be set via --root-crypt

    + if encryption of swap is not desired, a swap file can be created using
        create_file_swap() which is feature equal to the swap partition
        beside the suspend to disk functionality.

+ ZFS and LVM can not be specified on the same partition.
    + on partittions ROOT and DATA, either zfs or lvm can be used.
        if both are specified at the same time, the script will fail.

+ GPT Name Scheme information leakage
    + be aware that, the way gpt labels are setup in this script, they leak metadata of encrypted data, eg. raid_luks_lvm.vg0_ext4_ROOT leaks the information that behind the luks encrypted data is a lvm partition with a volume group named vg0 and the root file system is ext4 (but not how to read this data).

+ ZFS SLOG and L2ARC encryption
    + a Log and a Cache Partition can be created for pools outside the two
    primary storage devices. its data encryption state is corresponding to
    the target pool, meaning, if the target pool is encrypted, so will be the SLOG and the L2ARC
