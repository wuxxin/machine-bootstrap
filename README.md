# bootstrap machine

repository based ubuntu 18.04 liveimage shell installer
with (luks) encrypted zfs storage and low IO/CPU
continous incremental snapshot backups

## Features

+ Ubuntu 18.04 (Bionic) 
+ install via ssh, no console access needed
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
    + desaster recovery from backup storage to new machine
    + continous incremental snapshot backups with zfs and restic
    + homesick (homeshick) integration

installation is done in 4 steps:

+ 0 partition disk, recovery install to /boot
+ 1 base installation running from the recovery image
+ 2 chroot inside base installation to configure system
+ 3 saltstack run on installed base system

## Usage

### make a new project repository (eg. box)
```
mkdir box
cd box
git init
mkdir -p config salt/custom home home-subdirs
ln -s config pillar
git submodule add https://github.com/wuxxin/bootstrap-machine.git
git submodule add https://github.com/wuxxin/restic-zfs-backup.git
cd salt
git submodule add https://github.com/wuxxin/salt-shared.git
cd ..
cp salt/salt-shared/salt-top.example salt/custom/top.sls
touch salt/custom/custom.sls
cat <<EOF >> salt/custom/top.sls
  # any
  '*':
    - bootstrap
    - custom
EOF
ln -s ../../bootstrap-machine/devop/bootstrap.sls salt/custom/bootstrap.sls
cat <<EOF > pillar/top.sls
base:
  '*':
    - custom
EOF
touch pillar/custom.sls
git add .
git commit -v -m "initial commit"
```

### optional add an upstream
```
git remote add origin ssh://git@somewhere.on.the.internet/username/box.git
```

### optional git-crypt config

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
# initial config
cat > machine-config/config.env <<EOF
ssh_host=root@1.2.3.4
hostname=box.local
firstusername=myuser
authorized_keys_file=authorized_keys
http_proxy="http://192.168.122.1:8123"
EOF

# get serial(s) of harddisk(s)
./bootstrap-machine/connect.sh temporary "ls /dev/disk/by-id/"

# get serial(s), filter and add to config (example)
$(printf 'diskids="';for i in $(./bootstrap-machine/connect.sh temporary "ls /dev/disk/by-id/" | grep "^virtio-[^-]+$"); do printf "$i "; done; printf '"') >> machine-config/config.env

# create diskphrase.gpg (example)
(x=$(openssl rand -base64 9); echo "$x" | opengpg --encrypt) > machine-config/diskphrase.gpg

# bootstrap machine
./bootstrap-machine/bootstrap.sh execute --phase all
git add .
git commit -v -m "bootstrap run"
```

### optional homesick setup

```
dont name it dot, name it host-shortname
```

### optional push committed changed to upstream

```
git push -u origin master

```
