#!/bin/bash
set -eo pipefail
# set -x

self_path=$(dirname "$(readlink -e "$0")")


usage() {
    cat << EOF

$0 install recovery|system|gitops|all|plain <hostname> [optional parameter]

execute the requested stages of installation on host <hostname>,
output from target host is displayed on screen and captured to "run/log"
for safety, <hostname>  must be the same value as in the config file config/hostname

+ recovery
    **wipe disks**, partition storage and optional recovery install
        expects debian (apt-get) or manjaro (pamac) like live system, running at target host
        will reboot into recovery if recovery installed, otherwise exit and wait for next step

+ system [--no-reboot] [--restore-from-backup]
    format storage partitionas and install system
        expects running recovery image, or a target distribution live image

    --no-reboot
        dont reboot on final step, for further inspection

    --restore-from-backup
        partition & format system, then restore from backup

+ gitops
    execute gitops high state
        expects installed and running base machine,
        will first try to connect to initrd and unlock storage

+ plain:    executes steps recovery, system
+ all:      executes steps recovery, system, gitops

$0 test
    + test the setup for mandatory files and settings, exits 0 if successful

$0 create liveimage
    + build a livesystem for a bootstrap-0 ready system waiting to be installed
    + customized image will be placed in "run/liveimage" as "$bootstrap0liveimage"

Configuration:

+ config directory path: $config_path
    + can be overwritten with env var "MACHINE_BOOTSTRAP_CONFIG_DIR"
+ mandatory config files (see "README.md" for detailed description):
    + Base Configuration File: "node.env"
    + File: "authorized_keys"
    + if storage_opts:swap!=false or root-crypt!=false or (data-fs!='' and data-crypt!=false)
        + File: "disk.passphrase.gpg"
    + if distrib_id=nixos
        + File: "configuration.nix"
+ optional ssh config files for gitops step:
    + File: gitops.id_ed25519
    + File: gitops.known_hosts
    + File: gitops@node-secret-key.gpg
+ optional config files:
    + network config using either "netplan.yaml" or "systemd.network"
    + "recovery_hostkeys" created automatically on step recovery install
    + "[temporary|recovery|initrd|system].known_hosts": created on the fly
+ run directory path: $run_path
    + log directory path: $log_path

EOF
    exit 1
}


ssh_uri() { # sshlogin ("",scp,host,port,user,known)
    local sshlogin user userprefix port host known
    sshlogin=$1; user=""; userprefix=""; port="22"; host="${sshlogin#ssh://}"
    if test "$host" != "${host#*@}"; then
        user="${host%@*}"; userprefix="${user}@"
    fi
    host="${host#*@}"
    if test "${host}" != "${host%:*}"; then
        port="${host##*:}"
    fi
    host="${host%:*}"
    known="$(echo "$host" | sed -r 's/^([0-9.]+)$/[\1]/g')"
    if test "$port" != "22"; then
        known="${known}:${port}"
    fi
    if test "$2" = "host"; then     echo "$host"
    elif test "$2" = "port"; then   echo "$port"
    elif test "$2" = "user"; then   echo "$user"
    elif test "$2" = "scp"; then    echo "scp://${userprefix}${host}:${port}/"
    elif test "$2" = "known"; then  echo "$known"
    elif test "$2" = "rsync"; then  echo "${userprefix}${host}"
    else echo "ssh://${userprefix}${host}:${port}"
    fi
}


waitfor_ssh() {
    local retries maxretries retry sshlogin hostname port
    retries=0; maxretries=90; retry=true; sshlogin=$1
    hostname=$(ssh_uri "$sshlogin" host)
    port=$(ssh_uri "$sshlogin" port)
    while "$retry"; do
        ((retries+=1))
        if test "$retries" -ge "$maxretries"; then
            echo "Error, could not connect to $hostname in $maxretries tries, giving up"
            exit 1
        fi
        nc -z -w 2 "$hostname" "$port" && err=$? || err=$?
        if test "$err" -eq "0"; then
            retry=false
        else
            echo -n "."
            sleep 1
        fi
    done
}


generate_hostkeys() {
    local rsa_private rsa_public ed25519_private ed25519_public t
    echo "generate rsa hostkey"
    rsa_private=$( \
        t="$(mktemp -d -p /run/user/$(id -u))" && \
        ssh-keygen -q -t rsa -C "$base_name" -N '' -f "$t/id_rsa" && \
        cat "$t/id_rsa" && rm -r "$t" \
    )
    rsa_public=$(echo "$rsa_private" | ssh-keygen -q -y -P '' -f /dev/stdin)
    echo "generate ed25519 hostkey"
    ed25519_private=$( \
        t="$(mktemp -d -p /run/user/$(id -u))" && \
        ssh-keygen -q -t ed25519 -C "$base_name" -N '' -f "$t/id_ed25519" && \
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

DEFAULT_systemd_network=$(cat <<"EOF"
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
EOF
)


# main
export LC_MESSAGES="POSIX"
config_path="$(readlink -m "$self_path/../config")"
if test -n "$MACHINE_BOOTSTRAP_CONFIG_DIR"; then
    config_path="$MACHINE_BOOTSTRAP_CONFIG_DIR"
fi
config_file=$config_path/node.env
diskpassphrase_file=$config_path/disk.passphrase.gpg
need_diskpassphrase_file="false"
diskphrase=""
authorized_keys_file=$config_path/authorized_keys
nixos_configuration_file=$config_path/configuration.nix
netplan_file=$config_path/netplan.yaml
systemd_network_file=$config_path/systemd.network
recovery_hostkeys_file=$config_path/recovery_hostkeys
ssh_id_file=$config_path/gitops.id_ed25519
ssh_known_hosts_file=$config_path/gitops.known_hosts
gpg_id_file=$config_path/gitops@node-secret-key.gpg
run_path=$(readlink -m "$config_path/../run")
log_path=$(readlink -m "$config_path/../run/log")
base_path=$(readlink -m "$self_path/..")
base_name=$(basename "$base_path")
bootstrap0liveimage="bootstrap-0-liveimage.iso"
distrib_id="ubuntu"
distrib_codename="focal"
distrib_branch="stable"
distrib_profile="manjaro/gnome"

# parse args
if test "$1" != "test" -a "$1" != "install" -a "$1" != "create"; then usage; fi
command=$1
shift
if test "$command" = "install"; then
    if [[ ! "$1" =~ ^(all|plain|recovery|system|gitops)$ ]]; then
        echo "ERROR: Stage must be one of 'all|plain|recovery|system|gitops'"
        usage
    fi
    if test "$2" = ""; then
        echo "ERROR: hostname must be set on commandline and match config entry 'hostname' for safety reasons"
        usage
    fi
    do_phase=$1
    safety_hostname=$2
    shift 2
elif test "$command" = "create"; then
    if test "$1" != "liveimage"; then usage; fi
    command="create-liveimage"
    shift
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
    "$self_path/recovery/recovery-build-ubuntu.sh" --check-req
fi

# parse config file
if test ! -e "$config_file"; then
    echo "Error: mandatory configfile $config_file does not exist"
    exit 1
fi
. "$config_file"
# check for mandatory settings
for i in sshlogin hostname firstuser storage_ids; do
    if test "${!i}" = ""; then
        echo "ERROR: mandatory config file parameter $i not set or empty"
        exit 1
    fi
done

# set defaults for distrib_id
if test "$distrib_id" = "debian"; then
    if test "$distrib_codename" = "focal"; then distrib_codename="buster"; fi
    distrib_branch=""; distrib_profile=""
elif test "$distrib_id" = "nixos"; then
    if test "$distrib_branch" = "stable"; then distrib_branch="19.09"; fi
    distrib_codename=""; distrib_profile=""
elif test "$distrib_id" = "manjaro"; then
    distrib_codename=""
fi

# extract and save (root|data)_lvm_vol_size from storage_opts if present for bootstrap-1
select_root_lvm_vol_size=""
select_data_lvm_vol_size=""
if (echo "$storage_opts" | grep -q -- "--root-lvm-vol-size"); then
    lvm_vol_size=$(echo "$storage_opts" | sed -r "s/.*--root-lvm-vol-size=([^ ]+).*/\1/g")
    select_root_lvm_vol_size="--root-lvm-vol-size $lvm_vol_size"
fi
if (echo "$storage_opts" | grep -q -- "--data-lvm-vol-size"); then
    lvm_vol_size=$(echo "$storage_opts" | sed -r "s/.*--data-lvm-vol-size=([^ ]+).*/\1/g")
    select_data_lvm_vol_size="--data-lvm-vol-size $lvm_vol_size"
fi

# check for mandatory files
if test ! -e "$authorized_keys_file"; then
    echo "ERROR: mandatory file $authorized_keys_file not found"
    exit 1
fi

# check if a diskpassphrase_file is needed
option_swap="false"
if (echo "$storage_opts" | grep -q -- "--swap"); then
    option_swap=$(echo "$storage_opts" | sed -r "s/.*--swap=([^ ]+).*/\1/g")
fi
root_crypt="true"
if (echo "$storage_opts" | grep -q -- "--root-crypt"); then
    root_crypt=$(echo "$storage_opts" | sed -r "s/.*--root-crypt=([^ ]+).*/\1/g")
fi
data_crypt="true"
if (echo "$storage_opts" | grep -q -- "--data-fs"); then
    if (echo "$storage_opts" | grep -q -- "--data-crypt"); then
        data_crypt=$(echo "$storage_opts" | sed -r "s/.*--root-crypt=([^ ]+).*/\1/g")
    fi
else
    data_crypt="false"
fi
if test "$option_swap" != "false" -o "$root_crypt" != "false" -o "$data_crypt" != "false"; then
    need_diskpassphrase_file="true"
fi

if test "$command" = "install"; then
    # safety check that cmdline argument hostname = config file var hostname
    if test "$hostname" != "$safety_hostname"; then
        echo "ERROR: hostname on commandline ($safety_hostname) does not match hostname from configfile ($hostname)"
        exit 1
    fi

    # warn on phase gitops, but bail out if step system involved and no diskpassphrase_file
    if test "$need_diskpassphrase_file" = "true"; then
        if test "$do_phase" = "gitops"; then
            if test ! -e "$diskpassphrase_file"; then
                echo "WARNING: probably need $diskpassphrase_file, but none existing, skipping"
            fi
        elif test "$do_phase" = "all" -o "$do_phase" = "plain" -o "$do_phase" = "system"; then
            if test ! -e "$diskpassphrase_file"; then
                echo "Error: mandatory file $diskpassphrase_file not found, abort"
                exit 1
            fi
            diskphrase=$(cat $diskpassphrase_file | gpg --decrypt)
            if test "$diskphrase" = ""; then
                echo "Error: diskphrase is empty, abort"
                exit 1
            fi
        fi
    fi
fi

if test "$distrib_id" = "nixos"; then
    if test ! -e "$nixos_configuration_file"; then
        echo "Error: distrib_id=nixos but mandatory config file $nixos_configuration_file is missing"
        exit 1
    fi
fi
if test -z "$gitops_target"; then gitops_target="/home/$firstuser"; fi
if test -z "$gitops_user"; then gitops_user="$firstuser"; fi
if test -z "$recovery_install"; then recovery_install="true"; fi
if test "$recovery_install" != "true"; then
    recovery_install="false"; select_no_recovery="--no-recovery"
else
    select_no_recovery=""
fi
if test "$recovery_autologin" != "true"; then
    recovery_autologin="false"; select_autologin=""
else
    select_autologin="--recovery-autologin"
fi

# display all options
cat << EOF

Configuration:

hostname: $hostname, http_proxy: $http_proxy
storage_ids: $storage_ids
storage_opts: $storage_opts
select_root_lvm_vol_size: $select_root_lvm_vol_size , select_data_lvm_vol_size: $select_data_lvm_vol_size
recovery_install: $recovery_install , recovery_id: $recovery_id , recovery_autologin: $recovery_autologin
distrib_id: $distrib_id , distrib_codename: $distrib_codename
distrib_branch: $distrib_branch , distrib_profile: $distrib_profile
gitops_user: $gitops_user , gitops_target: $gitops_target

EOF

# all verified, exit if test was requested
if test "$command" = "test"; then exit 0; fi

# create log dir
if test ! -e "$log_path"; then mkdir -p "$log_path"; fi

# load or generate hostkeys, netplan, systemd_network
if test -e "$recovery_hostkeys_file"; then
    recovery_hostkeys=$(cat "$recovery_hostkeys_file")
else
    if test "$recovery_install" = "true"; then
        generate_hostkeys
        recovery_hostkeys="$generated_hostkeys"
        echo "$recovery_hostkeys" > "$recovery_hostkeys_file"
    fi
fi
netplan_data="$DEFAULT_netplan_data"
systemd_network_data="$DEFAULT_systemd_network"
if test -e "$netplan_file"; then netplan_data=$(cat "$netplan_file"); fi
if test -e "$systemd_network_file"; then systemd_network_data=$(cat "$systemd_network_file"); fi

# load ssh_id, ssh_known_hosts, gpg_id
ssh_id=""; ssh_known_hosts=""; gpg_id=""
if test -e "$ssh_id_file"; then
    ssh_id=$(cat "$ssh_id_file")
fi
if test -e "$ssh_known_hosts_file"; then
    ssh_known_hosts=$(printf \
        "# ---BEGIN OPENSSH KNOWN HOSTS---\n%s\n# ---END OPENSSH KNOWN HOSTS---\n" \
        "$(cat $ssh_known_hosts_file)")
fi
if test -e "$gpg_id_file"; then
    gpg_id=$(cat "$gpg_id_file")
fi


# ### create-liveimage
if test "$command" = "create-liveimage"; then
    echo "creating liveimage"

    download_path="$run_path/liveimage"
    mkdir -p "$download_path"
    # optional but with a http proxy setting it will get downloaded from cache
    with_proxy "$self_path/recovery/recovery-build-ubuntu.sh" download "$download_path"
    # write recovery.squashfs with new hostkeys for bootstrap-0
    if test -e "$download_path/scripts"; then rm -r "$download_path/scripts"; fi
    mkdir -p "$download_path/scripts"
    cp -a $self_path/recovery/* "$download_path/scripts"
    cp -a $self_path/storage/* "$download_path/scripts"
    cp $self_path/bootstrap-library.sh "$download_path/scripts/"
    echo "$generated_hostkeys" > "$download_path/bootstrap-0.hostkeys"
    if test ! -e "$netplan_file"; then echo "$netplan_data" > "$netplan_file"; fi
    "$self_path/recovery/recovery-config-ubuntu.sh" --custom \
        "$download_path/recovery.squashfs" "$hostname" "-" "$netplan_file" \
        "$download_path/bootstrap-0.hostkeys" "$authorized_keys_file" \
        "$download_path/scripts" - "$recovery_autologin" "default" "$http_proxy"
    # create liveimage
    with_proxy "$self_path/recovery/recovery-build-ubuntu.sh" create liveimage \
            "$download_path" \
            "$download_path/$bootstrap0liveimage" \
            "$download_path/recovery.squashfs" \
        | tee "$log_path/bootstrap-create-liveimage.log"
    exit 0
fi


# ### STEP recovery
if test "$do_phase" = "all" -o "$do_phase" = "plain" -o "$do_phase" = "recovery"; then
    echo "Step: recovery"
    sshopts="-o UserKnownHostsFile=$config_path/temporary.known_hosts"

    echo "copy ssh_authorized_keys, recovery_hostkeys, network config and install scripts to target"
    scp $sshopts \
        "$authorized_keys_file" \
        "$self_path/bootstrap-0.sh" \
        "$self_path/bootstrap-library.sh" \
        "$(ssh_uri ${sshlogin} scp)/tmp"
    echo "$recovery_hostkeys" \
        | ssh $sshopts "$(ssh_uri ${sshlogin})" "cat - > /tmp/recovery_hostkeys"
    echo "$netplan_data" \
        | ssh $sshopts "$(ssh_uri ${sshlogin})" "cat - > /tmp/netplan.yaml"
    echo "$systemd_network_data" \
        | ssh $sshopts "$(ssh_uri ${sshlogin})" "cat - > /tmp/systemd.network"

    if test "$recovery_install" = "true"; then
        scp $sshopts -rp \
            "$self_path/recovery" \
            "$self_path/storage" \
            "$(ssh_uri ${sshlogin} scp)/tmp"

        baseimage=$($self_path/recovery/recovery-build-ubuntu.sh show imagename)
        keyfile=$($self_path/recovery/recovery-build-ubuntu.sh show keyfile)
        if test -e "$run_path/liveimage/$baseimage"; then
            echo "copy $baseimage to target (assuming it is a physical install without http proxy)"
            ssh $sshopts "$(ssh_uri ${sshlogin})" "mkdir -p /tmp/liveimage"
            if test -e "$run_path/liveimage/$keyfile"; then
                scp $sshopts "$run_path/liveimage/$keyfile" \
                    "$(ssh_uri ${sshlogin} scp)/tmp/liveimage/$keyfile"
            fi
            scp $sshopts "$run_path/liveimage/$baseimage" \
                "$(ssh_uri ${sshlogin} scp)/tmp/liveimage/$baseimage"
        fi
        echo "write out recovery hostkeys to local config"
        echo "$recovery_hostkeys" | grep "rsa_public:" \
            | sed -r "s/[^:]+: +(.+)/$(ssh_uri ${sshlogin} known) \1/" \
            > "$config_path/recovery.known_hosts"
        echo "$recovery_hostkeys" | grep "ed25519_public:" \
            | sed -r "s/[^:]+: +(.+)/$(ssh_uri ${sshlogin} known) \1/" \
            >> "$config_path/recovery.known_hosts"
        echo "$recovery_hostkeys" > "$config_path/recovery_hostkeys"
        ssh-keygen -H -f "$config_path/recovery.known_hosts"
        if test -e "$config_path/recovery.known_hosts.old"; then
            rm "$config_path/recovery.known_hosts.old"
        fi
    fi

    echo "call bootstrap-0, wipe disks, install tools, create partitions, optional write recovery"
    ssh $sshopts "$(ssh_uri ${sshlogin})" \
        "chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy; /tmp/bootstrap-0.sh $hostname \"$storage_ids\" --yes $storage_opts $select_no_recovery $select_autologin" 2>&1 | tee "$log_path/bootstrap-recovery.log"

    if test "$recovery_install" != "true"; then
        echo "did not install recovery (as requested), therefore do not reboot machine"
    else
        echo "recovery installed, reboot into recovery"
        ssh $sshopts "$(ssh_uri ${sshlogin})" '{ sleep 1; reboot; } >/dev/null &' || true
        echo "sleep 10 seconds, for machine to stop responding to ssh"
        sleep 10
    fi
fi


# ### STEP system
if test "$do_phase" = "all" -o "$do_phase" = "plain" -o "$do_phase" = "system"; then
    option_no_reboot=false
    if test "$1" = "--no-reboot"; then option_no_reboot=true; shift; fi

    waitfor_ssh "$sshlogin"
    echo "Step: system"
    sshopts="-o UserKnownHostsFile=$config_path/recovery.known_hosts"

    echo "copy ssh_authorized_keys, recovery_hostkeys, network config and install scripts to target"
    scp $sshopts \
        "$authorized_keys_file" \
        "$config_path/recovery_hostkeys" \
        "$self_path/bootstrap-1.sh" \
        "$self_path/bootstrap-1-restore.sh" \
        "$self_path/bootstrap-2-$distrib_id.sh" \
        "$self_path/bootstrap-2-restore.sh" \
        "$self_path/bootstrap-library.sh" \
        "$(ssh_uri ${sshlogin} scp)/tmp"
    echo "$netplan_data" \
        | ssh $sshopts "$(ssh_uri ${sshlogin})" "cat - > /tmp/netplan.yaml"
    echo "$systemd_network_data" \
        | ssh $sshopts "$(ssh_uri ${sshlogin})" "cat - > /tmp/systemd.network"
    scp $sshopts -rp \
        "$self_path/recovery" \
        "$self_path/storage" \
        "$self_path/dracut" \
        "$(ssh_uri ${sshlogin} scp)/tmp"

    if test "$recovery_autologin" = "true"; then
        echo "recovery_autologin is true, touching /tmp/recovery/feature.autologin"
        ssh $sshopts ${sshlogin} "touch /tmp/recovery/feature.autologin"
    fi
    if test "$distrib_id" = "nixos"; then
        echo "copy nix configuration files to remote"
        scp $sshopts "$config_path/*.nix" \
            "$(ssh_uri ${sshlogin} scp)/tmp/"
    fi
    echo "call bootstrap-1, format storage, install system or restore from backup"
    echo -n "$diskphrase" | ssh $sshopts ${sshlogin} "
        chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy;
        /tmp/bootstrap-1.sh $hostname $firstuser \"$storage_ids\" --yes \
        $select_root_lvm_vol_size $select_data_lvm_vol_size \
        --distrib-id \"$distrib_id\" --distrib-codename \"$distrib_codename\" \
        --distrib-branch \"$distrib_branch\" --distrib-profile \"$distrib_profile\" \
        $@" 2>&1 | tee "$log_path/bootstrap-system.log"

    echo "copy initrd and system ssh hostkeys from target"
    printf "%s %s\n" "$(ssh_uri ${sshlogin} known)" \
        "$(ssh $sshopts ${sshlogin} 'cat /tmp/ssh_hostkeys/initrd_ssh_host_ed25519_key.pub')" \
        > "$config_path/initrd.known_hosts"
    printf "%s %s\n" "$(ssh_uri ${sshlogin} known)" \
        "$(ssh $sshopts ${sshlogin} 'cat /tmp/ssh_hostkeys/ssh_host_ed25519_key.pub')" \
        > "$config_path/system.known_hosts"
    printf "%s %s\n" "$(ssh_uri ${sshlogin} known)" \
        "$(ssh $sshopts ${sshlogin} 'cat /tmp/ssh_hostkeys/ssh_host_rsa_key.pub')" \
        >> "$config_path/system.known_hosts"
    ssh-keygen -H -f "$config_path/initrd.known_hosts"
    ssh-keygen -H -f "$config_path/system.known_hosts"
    for i in initrd system; do
        old="$config_path/${i}.known_hosts.old"
        if test -e "$old"; then rm "$old"; fi
    done

    if test "$option_no_reboot" = "true"; then
        echo "dont reboot into target system for further inspection"
        exit 0
    else
        echo "reboot into target system"
        ssh $sshopts "$(ssh_uri ${sshlogin})" 'systemctl --no-block reboot' || true
        echo "sleep 10 seconds, for machine to stop responding to ssh"
        sleep 10
    fi
fi


# ### STEP gitops
if test "$do_phase" = "all" -o "$do_phase" = "gitops"; then
    # initramfs luks open
    waitfor_ssh "$sshlogin"
    echo "Step: gitops"

    if (ssh-keyscan -p "$(ssh_uri ${sshlogin} port)" -H "$(ssh_uri ${sshlogin} host)" \
        | sed -r 's/.+(ssh-[^ ]+) (.+)$/\1 \2/g' \
        | grep -q -F -f - "$config_path/initrd.known_hosts") ; then
        echo "initrd is waiting for cryptopen, sending passphrase"
        sshopts="-o UserKnownHostsFile=$config_path/initrd.known_hosts"
        echo -n "$diskphrase" | ssh $sshopts "$(ssh_uri ${sshlogin})" \
            'phrase=$(cat -); for s in /var/run/systemd/ask-password/sck.*; do echo -n "$phrase" | /lib/systemd/systemd-reply-password 1 $s; done'
        echo "done sending passphrase, waiting 6 seconds for system startup to continue"
        sleep 6
        waitfor_ssh "$sshlogin"
    fi

    sshopts="-o UserKnownHostsFile=$config_path/system.known_hosts"
    ssh $sshopts "$(ssh_uri ${sshlogin})" "mkdir -p $gitops_target/$base_name"
    echo "transfering source to target"

    if test "$gitops_source" = ""; then
        echo "Warning: gitops_source is unset. Fallback to rsync repository to target instead cloning via from-git.sh"
        echo "only good for testing, or movement of the repository to the calling computer, eg. desktop setup"
        rsync -az -e "ssh $sshopts -p $(ssh_uri ${sshlogin} port)" \
            --delete --exclude "./run" \
            "$base_path" "$(ssh_uri ${sshlogin} rsync):$gitops_target"
    else
        echo "call from-git.sh with keys from stdin"
        scp $sshopts \
            "$self_path/../salt/salt-shared/gitops/from-git.sh" \
            "$(ssh_uri ${sshlogin} scp)/tmp"

        printf "%s\n%s\n%s\n" "$ssh_id" "$gpg_id" "$ssh_known_hosts" | \
            ssh $sshopts "$(ssh_uri ${sshlogin})" "
                http_proxy=\"$http_proxy\"; export http_proxy;
                chmod +x /tmp/from-git.sh;
                /tmp/from-git.sh bootstrap \
                    --url \"$gitops_source\" \
                    --branch \"${gitops_branch:-master}\" \
                    --user \"$gitops_user\" \
                    --home \"$gitops_target\" \
                    --git-dir \"${gitops_target}/${base_name}\" \
                    --keys-from-stdin
                "
    fi

    gitops_args="$@"
    if test "$gitops_args" = ""; then gitops_args="state.highstate"; fi
    echo "execute-saltstack.sh $gitops_args"
    ssh $sshopts "$(ssh_uri ${sshlogin})" \
        "http_proxy=\"$http_proxy\"; export http_proxy; \
        chown -R $gitops_user:$gitops_user $gitops_target/$base_name; \
        $gitops_target/$base_name/salt/salt-shared/gitops/execute-saltstack.sh \
            $gitops_target/$base_name $gitops_args" 2>&1 | tee "$log_path/bootstrap-gitops.log"
fi
