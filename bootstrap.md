# Usage

+ $0 test
    + test the setup for mandatory files and settings, exits 0 if successful

+ $0 execute [all|plain|recovery|install|devop] <hostname>
    + execute the requested stages of install on hostname

Stage:
+ all:      executes recovery,install,devop 
+ plain:    executes recovery,install
+ recovery: execute step recovery (expects debianish live system)
+ install:  execute step install (expects running recovery image)
+ devop:    execute step devop (expects installed and running base machine,
            will first try to connect to initrd and unlock storage)

<hostname>  must be to the same value as in the config file config/hostname
            as safety measure

## Configuration Directory

+ config path used: `dirname($0)/../machine-config`
    +  or overwritten with env var `BOOTSTRAP_MACHINE_CONFIG_DIR`

+ mandatory config files (see `README.md` for detailed description):
    + File: `disk.passphrase.gpg`
    + File: `authorized_keys`
    + Base Configuration File: `config`
    
+ optional config files:
    + `netplan.yml` default created on step recovery install
    + `recovery_hostkeys` created automatically on step recovery install
    + `[temporary|recovery|initrd|system].known_hosts`: created on the fly

## Examples

+ a root server with one or two harddisks and static ip setup
    + add custom $config_path/netplan.yml
+ a Laptop with encrypted hibernation
    + storage_opts="--swap yes"
+ a vm, overwriting previous storage
    + http_proxy="http://proxyip:port"
    + storage_opts="--reuse"
+ a home-nas with 1(internal)+2(external) harddisks
    + storage_opts="--log yes --cache 4096"
      put log and cache on install disk[s], should be of type ssd,nvme,...
