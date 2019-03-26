#!/bin/bash
set -eo pipefail
#set -x

self_path=$(dirname $(readlink -e "$0"))


usage() {
    cat << EOF
+ $0 execute [all|plain|recovery|install|devop] <hostname> [optional install parameter]
    + execute the requested stages of install on hostname
        all output from target host is displayed on screen and captured to "log" dir

    + all:      executes recovery,install,devop
    + plain:    executes recovery,install
    + recovery: execute step recovery (expects debianish live system)
    + install:  execute step install (expects running recovery image)
    + devop:    execute step devop (expects installed and running base machine,
                will first try to connect to initrd and unlock storage)

    <hostname>  must be the same value as in the config file config/hostname
    [optional install parameter]
        --restore-from-backup
                partition & format system, then restore from backup
+ $0 test
    + test the setup for mandatory files and settings, exits 0 if successful

+ $0 create-liveimage
    + build a livesystem for a bootstrap-0 ready system waiting to be installed
    + customized image will be placed in "run/liveimage" as "$bootstrap0liveimage"

Configuration:

+ config directory path: $config_path
    + can be overwritten with env var "BOOTSTRAP_MACHINE_CONFIG_DIR"
+ mandatory config files (see "README.md" for detailed description):
    + Base Configuration File: "config"
    + File: "disk.passphrase.gpg"
    + File: "authorized_keys"
+ optional config files:
    + "netplan.yml" default created on step recovery install
    + "recovery_hostkeys" created automatically on step recovery install
    + "[temporary|recovery|initrd|system].known_hosts": created on the fly
+ log directory path: $log_path
+ run directory path: $run_path

EOF
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


generate_hostkeys() {
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
    generated_hostkeys=$(cat <<EOF
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


with_proxy() {
    if test "$http_proxy" != ""; then http_proxy=$http_proxy $@; else $@; fi
}


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


# main
export LC_MESSAGES="POSIX"
config_path="$(readlink -m "$self_path/../machine-config")"
if test -n "$BOOTSTRAP_MACHINE_CONFIG_DIR"; then
    config_path="$BOOTSTRAP_MACHINE_CONFIG_DIR"
fi
config_file=$config_path/config
diskpassphrase_file=$config_path/disk.passphrase.gpg
authorized_keys_file=$config_path/authorized_keys
netplan_file=$config_path/netplan.yml
recovery_hostkeys_file=$config_path/recovery_hostkeys
log_path=$(readlink -m "$config_path/../log")
run_path=$(readlink -m "$config_path/../run")
base_path=$(readlink -m "$self_path/..")
base_name=$(basename "$base_path")
bootstrap0liveimage="bootstrap-0-liveimage.iso"

# parse args
if test "$1" != "test" -a "$1" != "execute" -a "$1" != "create-liveimage"; then usage; fi
command=$1
shift
if test "$command" = "execute"; then
    if [[ ! "$1" =~ ^(all|plain|recovery|install|devop)$ ]]; then
        echo "ERROR: Stage must be one of 'all|plain|recovery|install|devop'"
        usage
    fi
    if test "$2" = ""; then
        echo "ERROR: hostname must be set on commandline and match config entry 'hostname' for safety reasons"
        usage
    fi
    do_phase=$1
    safety_hostname=$2
    shift 2
fi

# check requisites
for i in nc ssh gpg scp; do
    if ! which $i > /dev/null; then
        echo "Error: needed program $i not found."
        echo "execute 'apt-get install netcat openssh-client gnupg'"
        exit 1
    fi
done
if test "$command" = "create-liveimage"; then
    "$self_path/recovery/build-recovery.sh" --check-req
fi

# parse config file
if test ! -e "$config_file"; then
    echo "ERROR: configfile $config_file does not exist"
    usage
fi
. "$config_file"
# check for mandatory settings
for i in sshlogin hostname firstuser storage_ids; do
    if test "${!i}" = ""; then
        echo "ERROR: mandatory config file parameter $i not set or empty"
        usage
    fi
done
# check for mandatory files
for i in $diskpassphrase_file $authorized_keys_file; do
    if test ! -e "$i"; then
        echo "ERROR: mandatory file $i not found"
        usage
    fi
done
diskphrase=$(cat $diskpassphrase_file | gpg --decrypt)
if test "$diskphrase" = ""; then
    echo "Error: diskphrase is empty, abort"
    exit 1
fi
# safety check that cmdline argument hostname = config file var hostname
if test "$command" = "execute"; then
    if test "$hostname" != "$safety_hostname"; then
        echo "ERROR: hostname on commandline ($safety_hostname) does not match hostname from configfile ($hostname)"
        exit 1
    fi
fi

# make defaults
if test -z "$distribution"; then distribution="bionic"; fi
if test -z "$devop_target"; then devop_target="/home/$firstuser"; fi
if test -z "$devop_user"; then devop_user="$firstuser"; fi
if test "$recovery_autologin" != "true"; then recovery_autologin="false"; fi
if test "$frankenstein" = "true"; then
    frankenstein=true
    select_frankenstein="--frankenstein"
else
    frankenstein=false
    select_frankenstein=""
fi

# all verified, exit if test was requested
if test "$command" = "test"; then exit 0; fi

# create log dir
if test ! -e "$log_path"; then mkdir -p "$log_path"; fi

# load or generate hostkeys, netplan
if test -e "$recovery_hostkeys_file"; then
    recovery_hostkeys=$(cat "$recovery_hostkeys_file")
else
    generate_hostkeys
    recovery_hostkeys="$generated_hostkeys"
    echo "$recovery_hostkeys" > "$recovery_hostkeys_file"
fi
if test -e "$netplan_file"; then
    netplan_data=$(cat "$netplan_file")
else
    netplan_data="$DEFAULT_netplan_data"
    echo "$netplan_data" > "$netplan_file"
fi


#
# create-liveimage
if test "$command" = "create-liveimage"; then
    echo "creating liveimage"
    download_path="$run_path/liveimage"
    mkdir -p "$download_path"
    # download image:
    #   optional but with a http proxy setting it will get downloaded from cache
    with_proxy "$self_path/recovery/build-recovery.sh" download "$download_path"
    # write recovery.squashfs with new hostkeys for bootstrap-0
    generate_hostkeys
    echo "$generated_hostkeys" > "$download_path/bootstrap-0.hostkeys"
    "$self_path/recovery/update-recovery-squashfs.sh" --custom \
        "$download_path/recovery.squashfs" "$hostname" "-" "$netplan_file" \
        "$download_path/bootstrap-0.hostkeys" "$authorized_keys_file" \
        "$self_path/recovery" - "$recovery_autologin" "-" "$http_proxy"
    # create liveimage
    "$self_path/recovery/build-recovery.sh" create-liveimage "$download_path" "$download_path/$bootstrap0liveimage" "$download_path/recovery.squashfs"
    exit 0
fi


# execute
# STEP recovery
if test "$do_phase" = "all" -o "$do_phase" = "plain" -o "$do_phase" = "recovery"; then
    echo "Step: recovery"
    sshopts="-o UserKnownHostsFile=$config_path/temporary.known_hosts"
    echo "copy ssh_authorized_keys, ssh_hostkeys, netplan, install script to target"
    scp $sshopts "$authorized_keys_file" "${sshlogin}:/tmp/authorized_keys"
    echo "$recovery_hostkeys" | ssh $sshopts "${sshlogin}" "cat - > /tmp/recovery_hostkeys"
    echo "$netplan_data" | ssh $sshopts "${sshlogin}" "cat - > /tmp/netplan.yaml"
    scp $sshopts "$self_path/bootstrap-0-recovery.sh" \
        "${sshlogin}:/tmp"
    scp $sshopts -rp "$self_path/recovery" "${sshlogin}:/tmp"
    baseimage=$($self_path/recovery/build-recovery.sh show imagename)
    if test -e "$run_path/liveimage/$baseimage"; then
        echo "copy $baseimage to target (assuming it is a physical install without http proxy)"
        ssh $sshopts "${sshlogin}" "mkdir -p /tmp/liveimage"
        scp $sshopts "$run_path/liveimage/$baseimage" "${sshlogin}:/tmp/liveimage/$baseimage"
    fi
    echo "write out recovery hostkeys to local config"
    echo "$recovery_hostkeys" | grep "rsa_public:" | sed -r "s/[^:]+: +(.+)/${sshlogin##*@} \1/" > "$config_path/recovery.known_hosts"
    echo "$recovery_hostkeys" | grep "ed25519_public:" | sed -r "s/[^:]+: +(.+)/${sshlogin##*@} \1/" >> "$config_path/recovery.known_hosts"
    echo "$recovery_hostkeys" > "$config_path/recovery_hostkeys"
    ssh-keygen -H -f "$config_path/recovery.known_hosts"
    if test -e "$config_path/recovery.known_hosts.old"; then
        rm "$config_path/recovery.known_hosts.old"
    fi

    echo "call bootstrap-0, wipe disks, install tools, create partitions write recovery"
    ssh $sshopts "${sshlogin}" "chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy; /tmp/bootstrap-0-recovery.sh $hostname \"$storage_ids\" --yes $storage_opts" 2>&1 | tee "$log_path/bootstrap-recovery.log"

    echo "reboot into recovery"
    ssh $sshopts "${sshlogin}" '{ sleep 1; reboot; } >/dev/null &' || true
    echo "sleep 10 seconds, for machine to stop responding to ssh"
    sleep 10
fi


# STEP install
if test "$do_phase" = "all" -o "$do_phase" = "plain" -o "$do_phase" = "install"; then
    waitfor_ssh "${sshlogin#*@}"
    echo "Step: install"
    sshopts="-o UserKnownHostsFile=$config_path/recovery.known_hosts"
    echo "copy ssh_authorized_keys, netplan, install script to target"
    scp $sshopts "$authorized_keys_file" "${sshlogin}:/tmp/authorized_keys"
    echo "$netplan_data" | ssh $sshopts ${sshlogin} "cat - > /tmp/netplan.yaml"
    scp $sshopts "$config_path/recovery_hostkeys" "${sshlogin}:/tmp/recovery_hostkeys"
    scp $sshopts \
        "$self_path/bootstrap-1-install.sh" \
        "$self_path/bootstrap-1-restore.sh" \
        "$self_path/bootstrap-2-chroot-install.sh" \
        "$self_path/bootstrap-2-chroot-restore.sh" \
        "$config_path/recovery_hostkeys" \
        "${sshlogin}:/tmp"
    scp $sshopts -rp \
        "$self_path/recovery" \
        "$self_path/zfs" \
        "$self_path/initrd" \
        "${sshlogin}:/tmp"

    echo "call bootstrap-1, add luks and zfs, debootstrap system or restore from backup"
    echo -n "$diskphrase" | ssh $sshopts ${sshlogin} "chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy; /tmp/bootstrap-1-install.sh $hostname $firstuser \"$storage_ids\" --yes $select_frankenstein --distribution $distribution $@" 2>&1 | tee "$log_path/bootstrap-install.log"

    echo "copy initrd and system ssh hostkeys from target"
    printf "%s %s\n" "${sshlogin#*@}" "$(ssh $sshopts ${sshlogin} 'cat /tmp/ssh_hostkeys/initrd_ssh_host_ed25519_key.pub')" > "$config_path/initrd.known_hosts"
    printf "%s %s\n" "${sshlogin#*@}" "$(ssh $sshopts ${sshlogin} 'cat /tmp/ssh_hostkeys/ssh_host_ed25519_key.pub')" > "$config_path/system.known_hosts"
    printf "%s %s\n" "${sshlogin#*@}" "$(ssh $sshopts ${sshlogin} 'cat /tmp/ssh_hostkeys/ssh_host_rsa_key.pub')" >> "$config_path/system.known_hosts"
    ssh-keygen -H -f "$config_path/initrd.known_hosts"
    ssh-keygen -H -f "$config_path/system.known_hosts"
    for i in initrd system; do
        old="$config_path/${i}.known_hosts.old"
        if test -e "$old"; then rm "$old"; fi
    done

    echo "reboot into target system (FIXME: needs reboot -f)"
    ssh $sshopts "${sshlogin}" '{ sleep 1; reboot -f; } >/dev/null &' || true
    echo "sleep 10 seconds, for machine to stop responding to ssh"
    sleep 10
fi


# STEP devop
if test "$do_phase" = "all" -o "$do_phase" = "devop"; then
    # initramfs luks open
    waitfor_ssh "${sshlogin#*@}"
    echo "Step: devop"
    if (ssh-keyscan -H "${sshlogin#*@}" | sed -r 's/.+(ssh-[^ ]+) (.+)$/\1 \2/g' | grep -q -F -f - "$config_path/initrd.known_hosts") ; then
        echo "initrd is waiting for luksopen, sending passphrase"
        sshopts="-o UserKnownHostsFile=$config_path/initrd.known_hosts"
        echo -n "$diskphrase" | ssh $sshopts "${sshlogin}" \
            'phrase=$(cat -); for s in /var/run/systemd/ask-password/sck.*; do echo -n "$phrase" | /lib/systemd/systemd-reply-password 1 $s; done'
        echo "done sending passphrase, waiting 6 seconds for system startup to continue"
        sleep 6
        waitfor_ssh "${sshlogin#*@}"
    fi

    echo "copy setup repository to target"
    sshopts="-o UserKnownHostsFile=$config_path/system.known_hosts"
    ssh $sshopts ${sshlogin} "mkdir -p $devop_target"
    tar -c --exclude "./run" --exclude "./log" -C "$base_path" | ssh $sshopts $sshlogin "mkdir -p $devop_target/$base_name; tar x -C $devop_target/$base_name"

    echo "call bootstrap-3, install saltstack and run state.highstate"
    ssh $sshopts ${sshlogin} "http_proxy=\"$http_proxy\"; export http_proxy; chown -R $devop_user:$devop_user $devop_target; chmod +x $devop_target/$base_name/bootstrap-machine/bootstrap-3-devop.sh; $devop_target/$base_name/bootstrap-machine/bootstrap-3-devop.sh --yes state.highstate" 2>&1 | tee "$log_path/bootstrap-devop.log"
fi
