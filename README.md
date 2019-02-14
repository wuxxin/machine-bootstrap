# bootstrap machine

Ubuntu 18.04 with encrypted storage at rest, autosnapshots, incremental snapshot backups

## Features

+ Ubuntu 18.04 (Bionic) 
+ one or two disks (will be mirrored if two)
+ legacy boot and efi compatible hybrid grub setup with grubenv support
+ fulldiskencryption with luks
+ root on luks encrypted zfs / zfs mirror pool
+ casper recovery on boot partition
    + unattended cloud-init boot via custom squashfs with ssh ready to login
    + update-recovery-squashfs.sh, recovery-mount/unmount/replace-mirror.sh scripts
+ desaster recovery from backup storage to new machine
+ optional hibernate compatible luks encrypted separate swap partition
+ optional partitions for ondisk zfs log (zil) and ondisk zfs cache (l2arc)


## setup and install 

Usage: $0   user@targethost hostname firstusername 
            "diskids" diskphrase_gpg_file authorized_keys_file 
            [--recovery_hostkeys hostkeys_yaml_file]
            [--netplan netplan_file]
            [--http_proxy "http://proxyip:port"]
            --yes [--phase-2] [optional parameter for bootstrap-*]

Arguments:

+ user@targethost: ssh login to the target machine executing a linux in ram 
+ hostname: the new target hostname
+ firstusername: first user name on new target host
+ "diskids": disk serial ids, as string seperated by space
+ diskphrase_gpg_file: file containing the diskphrase for the target host disk encryption 
+ authorized_keys_file: file containing ssh user public keys, which will be allowed to login into target host

+ --recovery_hostkeys hostkeys_yaml_file
    the recovery ssh hostkeys are generated on the client machine if not specified
    using --recovery_hostkeys.
    In any case the public keys are written out to ./recovery.known_hosts
+ ssh hostkeys:
    the target hostkeys are generated on the target machine from a recovery live
    sessio. the public key part is written out to ./target.known_hosts
+ --netplan netplan_file
    if not specified a default netplan file is generated that activates 
    all en*,eth* devices via dhcp
+ --http_proxy "http://proxyip:port"
+ --yes       to wipe target hardisk
+ --phase-2   start executing from running recovery image

Examples:

+ a root server with one or two harddisks
    + use --netplan netplan_file
+ a Laptop with encrypted hibernation
    + use bootstrap0 parameter --swap yes
+ a vm
    + use --http_proxy "http://proxyip:port"
+ a home-nas with 1(internal)+2(external) harddisks
    + use bootstrap0 parameter --log yes --cache 4096
      (put log and cache on install disk[s], should be of type ssd,nvme,...)

Install Steps:

+ 1 partition and recovery install using a debianish recovery image from the hoster
+ 2 base installation running from the recovery Image
+ 3 chroot inside base installation configure system
