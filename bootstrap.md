Usage: 
  $0 execute [--phase all|recovery|install|devop] [<recovery phase parameter>*]
  $0 --help-recovery

--phase all
    executes all phases (expects debianish live system as first phase)
--phase recovery [<recovery phase parameter>*]
    only execute recovery phase (expects debianish live system)
    parameter passed to bootstrap-0-recovery.sh
    execute `$0 --help-recovery` to get a parameter list
--phase install 
    only execute install phase (expects running recovery image)
--phase devop
    only execute devop phase (expects installed and running base machine)
    will first connect to initrd and unlock storage

default configpath: dirname($0)/../machine-config
default config file: config 
config file used: `dirname($0)/../config` 
    or if environment variable `BOOTSTRAP_MACHINE_CONFIG_DIR` is set
    `$BOOTSTRAP_MACHINE_CONFIG_DIR/config`

configuration file:
```
sshhost=root@1.2.3.4
hostname=box.local
firstusername=myuser
authorized_keys_file=authorized_keys
http_proxy="http://192.168.122.1:8123"
diskids=""
```

Examples:

+ a root server with one or two harddisks and static ip setup
    + add custom $config_path/netplan.yml
+ a Laptop with encrypted hibernation
    + use recovery phase parameter: `--swap yes`
+ a vm
    + use http_proxy="http://proxyip:port" in configfile
+ a home-nas with 1(internal)+2(external) harddisks
    + use bootstrap0 parameter --log yes --cache 4096
      put log and cache on install disk[s], should be of type ssd,nvme,...

