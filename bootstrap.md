# Usage
+ $0 execute [all|plain|recovery|install|devop] hostname
+ $0 test
  
## Stages

+ all:      executes recovery,install,devop 
+ plain:    executes recovery,install
+ recovery: execute step recovery (expects debianish live system)
+ install:  execute step install (expects running recovery image)
+ devop:    execute step devop (expects installed and running base machine,
            will first try to connect to initrd and unlock storage)

+ parameter hostname: must be the same as in config/hostname for safety reasons

## Configuration Directory

+ config path used: `dirname($0)/../machine-config`
    +  or overwritten with env var `BOOTSTRAP_MACHINE_CONFIG_DIR`

+ mandatory config files:
    + File: `disk.passphrase.gpg`
    + File: `authorized_keys`
    + Base Configuration File: `config`, see `README.md` for detailed description
    
+ optional config files:
    + `netplan.yml` default created on step recovery install
    + `recovery_hostkeys` created automatically on step recovery install
    + `[temporary|recovery|initrd|system].known_hosts`: created on the fly

## Examples

+ a root server with one or two harddisks and static ip setup
    + add custom $config_path/netplan.yml
+ a Laptop with encrypted hibernation
    + storage_opts="--swap yes"
+ a vm
    + http_proxy="http://proxyip:port"
+ a home-nas with 1(internal)+2(external) harddisks
    + storage_opts="--log yes --cache 4096"
      put log and cache on install disk[s], should be of type ssd,nvme,...
