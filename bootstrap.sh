#!/bin/bash
set -eo pipefail
#set -x
self_path=$(dirname $(readlink -e "$0"))


DEFAULT_netplan_data=$(cat <<"EOF"
network:
    version: 2
    ethernets:
        all-en:
            match:
                name: "en*"
            dhcp4: true
            optional: true
        all-eth:
            match:
                name: "eth*"
            dhcp4: true
            optional: true
EOF
)


usage() {
    cat "$self_path/bootstrap.md"
    exit 1
}


waitfor_ssh() {
    local retries maxretries retry sshhost
    retries=0
    maxretries=90
    retry=true
    sshhost=$1
    echo "wait up to 270 seconds for reconnection"
    while "$retry"; do
        ((retries+=1))
        if test "$retries" -ge "$maxretries"; then
            echo "Error, could not connect to $sshhost in $maxretries tries, giving up"
            exit 1
        fi
        nc -z -w 2 "$sshhost" 22 && err=$? || err=$?
        if test "$err" -eq "0"; then
            echo "got connection!"
            retry=false
        else
            sleep 1
        fi
    done
}


generate_recovery_hostkeys() {
    local rsa_private rsa_public ed25519_private ed25519_public t
    echo "generate rsa hostkey"
    rsa_private=$( \
        t="$(mktemp -d -p /run/user/$(id -u))" && \
        ssh-keygen -q -t rsa -N '' -f "$t/id_rsa" && \
        cat "$t/id_rsa" && rm -r "$t" \
    )
    rsa_public=$(echo "$rsa_private" | ssh-keygen -q -y -P '' -f /dev/stdin)
    echo "generate ed25519 hostkey"
    ed25519_private=$( \
        t="$(mktemp -d -p /run/user/$(id -u))" && \
        ssh-keygen -q -t ed25519 -N '' -f "$t/id_ed25519" && \
        cat "$t/id_ed25519" && rm -r "$t" \
    )
    ed25519_public=$(echo "$ed25519_private" | ssh-keygen -q -y -P '' -f /dev/stdin)
    recovery_hostkeys=$(cat <<EOF
ssh_keys:
  rsa_private: |
$(echo "${rsa_private}" | sed -e 's/^/      /')
  rsa_public: ${rsa_public}
  ed25519_private: |
$(echo "${ed25519_private}" | sed -e 's/^/      /')
  ed25519_public: ${ed25519_public}
EOF
    )
}


# main
config_path="$(readlink -e "$self_path/../machine-config")"
if test -z "$BOOTSTRAP_MACHINE_CONFIG_DIR"; then
    config_path="$BOOTSTRAP_MACHINE_CONFIG_DIR"
fi
config_file=$config_path/config
diskpassphrase_file=$config_path/disk.passphrase.gpg
authorized_keys_file=$config_path/authorized_keys
netplan_file=$config_path/netplan.yml
recovery_hostkeys_file=$config_path/recovery_hostkeys

# check requisites
for i in nc ssh gpg scp; do 
    if ! which $i > /dev/null; then echo "Error: needed program $i not found."; exit 1; fi
done

# parse args
if test "$1" = "test"; then 
    config_test
    exit 0
fi
if test "$1" != "execute"; then usage; fi
if [[ ! "$2" =~ ^(all|plain|recovery|install|devop)$ ]]; then 
    echo "ERROR: Stage must be one of 'all|plain|recovery|install|devop'"
    usage
fi
if test "$3" = ""; then 
    echo "ERROR: hostname must be set on commandline for safety reasons"
    usage
fi
do_phase=$2
safety_hostname=$3
shift 3

# parse config file
if test -e $config_file; then echo "ERROR: configfile $config_file does not exist"
. $config_file
for i in "sshlogin hostname firstuser storage_ids"; do
    if test "$[[i]]" = ""; then
        echo "ERROR: mandatory config file parameter $i not set or empty"
        usage
    fi
done
if test "$hostname" != "$safety_hostname"; then
    echo "ERROR: hostname on commandline ($safety_hostname) does not match hostname from configfile ($hostname)"
    exit 1
fi

diskphrase=$(cat $diskphrasegpg | gpg --decrypt)
if test "$diskphrase" = ""; then
    echo "Error: diskphrase is empty, abort"
    exit 1
fi

# optional
#http_proxy="http://192.168.122.1:8123"
#recovery_autologin="true"
#storage_opts=[--reuse] [--log yes|<logsizemb>] [--cache yes|<cachesizemb] [--swap yes|<swapsizemb>]
# optional config files:
# `netplan.yml` default created on step recovery install
# `recovery_hostkeys` created automatically on step recovery install
# `[temporary|recovery|initrd|system].known_hosts`: created on the fly


# parse args
diskphrasegpg="$5"
sshkeyfile="$6"
recovery_hostkeys=$(cat $2)
echo "create ssh hostkeys"
generate_recovery_hostkeys
netplan_data=$(cat $2)
netplan_data="$DEFAULT_netplan_data"
http_proxy=$2
passphrase_filename=disk.passphrase.gpg
authorized_keys_filename=authorized_keys
recovery_hostkeys_filename=recovery_hostkeys
netplan_filename=netplan.yml



# STEP recovery
if test "$do_phase" = "all" -o "$do_phase" = "plain" -o "$do_phase" = "recovery"; then
    echo "Step: recovery"
    sshopts="-o UserKnownHostsFile=$config_path/temporary.known_hosts"
    echo "copy ssh_authorized_keys, ssh_hostkeys, netplan, install script to target"
    scp $sshopts "$sshkeyfile" "${sshlogin}:/tmp/authorized_keys"
    echo "$recovery_hostkeys" | ssh $sshopts "${sshlogin}" "cat - > /tmp/recovery_hostkeys"
    echo "$netplan_data" | ssh $sshopts "${sshlogin}" "cat - > /tmp/netplan.yaml"
    scp $sshopts "$self_path/bootstrap-0-recovery.sh" \
        "${sshlogin}:/tmp"
    scp $sshopts -rp "$self_path/recovery" "${sshlogin}:/tmp"
    
    echo "write out recovery hostkeys to local config"
    echo "$recovery_hostkeys" | grep "rsa_public:" | sed -r "s/[^:]+: +(.+)/${sshlogin##*@} \1/" > "$config_path/recovery.known_hosts"
    echo "$recovery_hostkeys" | grep "ed25519_public:" | sed -r "s/[^:]+: +(.+)/${sshlogin##*@} \1/" >> "$config_path/recovery.known_hosts"
    echo "$recovery_hostkeys" > "$config_path/recovery_hostkeys"
    ssh-keygen -H -f "$config_path/recovery.known_hosts"
    if test -e "$config_path/recovery.known_hosts.old"; then
        rm "$config_path/recovery.known_hosts.old"
    fi

    echo "first remote part, wipe disks, install tools, create partitions write recovery"
    args="$@"
    ssh $sshopts "${sshlogin}" "chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy; /tmp/bootstrap-0-recovery.sh $hostname \"$storage_ids\" --yes $args"
    
    echo "reboot into recovery (FIXME: reboot -f)"
    ssh $sshopts "${sshlogin}" "reboot -f" || true
    echo "sleep 10 seconds, for machine to stop responding to ssh"
    sleep 10
fi


# STEP install
if test "$do_phase" = "all" -o "$do_phase" = "plain" -o "$do_phase" = "install"; then
    waitfor_ssh "${sshlogin#*@}"
    echo "Steps: install"
    sshopts="-o UserKnownHostsFile=$config_path/recovery.known_hosts"
    echo "copy ssh_authorized_keys, netplan, install script to target"
    scp $sshopts "$sshkeyfile" "${sshlogin}:/tmp/authorized_keys"
    echo "$netplan_data" | ssh $sshopts ${sshlogin} "cat - > /tmp/netplan.yaml"
    scp $sshopts "$config_path/recovery_hostkeys" "${sshlogin}:/tmp/recovery_hostkeys"
    scp $sshopts "$self_path/bootstrap-1-install.sh" \
        "$self_path/bootstrap-2-chroot-install.sh" \
        "$config_path/recovery_hostkeys" \
        "${sshlogin}:/tmp"
    scp $sshopts -rp \
        "$self_path/recovery" \
        "$self_path/backup" \
        "$self_path/initrd" \
        "${sshlogin}:/tmp"

    echo "second part, add luks and zfs, debootstrap system or restore from backup"
    echo -n "$diskphrase" | ssh $sshopts ${sshlogin} "chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy; /tmp/bootstrap-1-install.sh $hostname $firstuser \"$storage_ids\" --yes $@"

    echo "reboot"
    ssh $sshopts ${sshlogin} "reboot" || true
    echo "sleep 10 seconds, for machine to stop responding to ssh"
    sleep 10
fi


# STEP devop
if test "$do_phase" = "all" -o "$do_phase" = "devop"; then
    # phase initramfs luks open
    waitfor_ssh "${sshlogin#*@}"
    sshopts="-o UserKnownHostsFile=$config_path/initrd.known_hosts"
    check if initrd or system host keys
    if initrd hostkeys
        ssh paste diskphrase to initrd
        waitfor_ssh "${sshlogin#*@}"
    fi
    
    sshopts="-o UserKnownHostsFile=$config_path/system.known_hosts"
    scp $sshopts -rp \
        "$self_path" \
        "${sshlogin}:/home/$username/work/zap"
    printf "{% set bootstrap_basepath= '%s' %}" "bootstrap_"
    cat <<EOF > machine-config/bootstrap-basepath.sls
    {% set bootstrap_basepath= "" %}
    EOF
    
    echo "third part, install saltstack and run state.highstate"
    ssh $sshopts ${sshlogin} "http_proxy=\"$http_proxy\"; export http_proxy; /home/$username/work/zap/bootstrap-machine/bootstrap-3-devop.sh --yes state.highstate"
fi
