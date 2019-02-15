#!/bin/bash
set -eo pipefail
set -x
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


usage() {
    cat "$self_path/README.md"
    cat <<EOF
Optional parameter for bootstrap-0:
-----------------------------------
EOF
    . "$self_path/bootstrap-0-recovery.sh" || true
    exit 1
}


# main
if test "$#" -lt 7; then usage; fi

# check requisites
for i in nc ssh gpg scp; do 
    if ! which $i > /dev/null; then echo "Error: needed program $i not found."; exit 1; fi
done

# parse args
self_path=$(dirname "$(readlink -e "$0")")
config_path="$self_path/config"
sshlogin="$1"
hostname="$2"
firstuser="$3"
diskids="$4"
diskphrasegpg="$5"
sshkeyfile="$6"
shift 6
if test "$1" = "--recovery_hostkeys"; then
    recovery_hostkeys=$(cat $2)
    shift 2
else
    echo "create ssh hostkeys"
    generate_recovery_hostkeys
fi
if test "$1" = "--netplan"; then
    netplan_data=$(cat $2)
    shift 2
else
    netplan_data="$DEFAULT_netplan_data"
fi
if test "$1" = "--http_proxy"; then
    http_proxy=$2
    shift 2
else
    http_proxy=""
fi
if test "$1" != "--yes"; then usage; fi
shift 
if test "$1" = "--phase-2"; then 
    do_phase_1="false"; shift
else 
    do_phase_1="true"
fi
diskphrase=$(cat $diskphrasegpg | gpg --decrypt)
if test "$diskphrase" = ""; then
    echo "Error: diskphrase is empty, abort"
    exit 1
fi


if test "$do_phase_1" = "true"; then
    echo "copy ssh_authorized_keys, ssh_hostkeys, netplan, install script to target"
    scp "$sshkeyfile" "${sshlogin}:/tmp/authorized_keys"
    echo "$recovery_hostkeys" | ssh "${sshlogin}" "cat - > /tmp/recovery_hostkeys"
    echo "$netplan_data" | ssh "${sshlogin}" "cat - > /tmp/netplan.yaml"
    scp "$self_path/bootstrap-0-recovery.sh" \
        "${sshlogin}:/tmp"
    scp -rp "$self_path/recovery" "${sshlogin}:/tmp"
    
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
    ssh "${sshlogin}" "chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy; /tmp/bootstrap-0-recovery.sh $hostname \"$diskids\" --yes $args"
    
    # echo "get recovery.squashfs from target"
    # scp "${sshlogin}:/tmp/recovery.squashfs" "$config_path/"
    
    echo "reboot into recovery (FIXME: reboot -f)"
    ssh "${sshlogin}" "reboot -f" || true
    echo "sleep 10 seconds, for machine to stop responding to ssh"
    sleep 10
fi

waitfor_ssh "${sshlogin#*@}"

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
echo -n "$diskphrase" | ssh $sshopts ${sshlogin} "chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy; /tmp/bootstrap-1-install.sh $hostname $firstuser \"$diskids\" --yes $@"

echo "reboot"
ssh $sshopts ${sshlogin} "reboot" || true
echo "sleep 10 seconds, for machine to stop responding to ssh"
sleep 10

waitfor_ssh ${sshlogin#*@}

sshopts="-o UserKnownHostsFile=$config_path/installed.known_hosts"
scp $sshopts "$self_path/bootstrap-3-salt-call.sh" \
    "${sshlogin}:/tmp"
scp $sshopts -rp \
    "$self_path/salt" \
    "${sshlogin}:/tmp"
echo "third part, install saltstack and run state.highstate"
ssh $sshopts ${sshlogin} "chmod +x /tmp/*.sh; http_proxy=\"$http_proxy\"; export http_proxy; /tmp/bootstrap-3-salt-call.sh"
