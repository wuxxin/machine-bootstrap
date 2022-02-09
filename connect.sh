#!/bin/bash
set -e


usage() {
    cat <<EOF
Usage:
    $0 [--show-ssh|--show-scp] [user@]temporary|recovery|initrd|system
    $0 initrd-unlock [--unsafe]
    $0 recovery-unlock|temporary-unlock [--unsafe] [optional-storage-parameter]

use ssh keys and config taken from $config_path to connect to a system via ssh

+ --show-ssh: only displays the parameters for ssh
+ --show-scp: only displays the parameters for scp
    may be used like "scp \$(./machine-bootstrap/connect.sh --show-scp system)/root/test.txt ."

+ [user@]temporary, recovery, initrd, system
    connect to system with the expected the ssh hostkey
    use "user@temporary" to connect as nonroot user

+ initrd-unlock [--unsafe]
    uses the initrd host key for connection,
    transfers the diskphrase keys to /lib/systemd/systemd-reply-password

+ recovery-unlock [--unsafe] [optional-storage-mount-parameter]
    uses the recovery host key for connection,
    transfers the diskphrase keys and execute storage-mount.sh from recovery,
    mount all partitions and prepare a chroot at /mnt

+ temporary-unlock [--unsafe] [optional-storage-mount-parameter]
    uses the temporary host key for connection,
    transfers and execute storage-mount.sh script with the diskphrase keys,
    mount all partitions and prepare a chroot at /mnt

+ --unsafe
    before posting the disk encryption unlock key,
    connect does some attestation of the remote platform
    and exits if any of these tests are failing.
    to ignore these attestation errors, use --unsafe

    **currently this does not much**, only the storageid's configured in
    config/node.env:storage_ids are checked to be available

+ optional storage-mount-parameter
    see storage/storage-mount.sh for parameter

EOF
    exit 1
}


remote_attestation_ssh() { # "$sshopts" "$(ssh_uri ${sshlogin})" ignorefail
    local sshopts sshurl ignorefail remote_attest err
    sshopts="$1"
    sshurl="$2"
    ignorefail=$(echo $3 | tr '[:upper:]' '[:lower:]')
    remote_attest="for i in ${storage_ids}; do if test ! -e /dev/disk/by-id/\$i; then exit 1; fi; done"
    # TODO: add cpuinfo and macaddr check
    # cat /proc/cpuinfo | grep "model name" | uniq | sed -r "s/model name.+: (.+)/\1/g"

    ssh $sshopts $sshurl "$remote_attest" && err=$? || err=$?
    if test $err -ne 0; then
        if test "$ignorefail" = "true"; then
            echo "Warning: Remote Attestation failed, but ignorefail=true"
        else
            echo "Error: Remote Attestation failed, and ignorefail!=true, abort"
            exit 1
        fi
    fi
}


ssh_uri() { # sshlogin ("",ssh,scp,host,port,user,known)
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


# ### main
self_path=$(dirname "$(readlink -e "$0")")
config_path="$(readlink -m "$self_path/../config")"
if test -n "$MACHINE_BOOTSTRAP_CONFIG_DIR"; then
    config_path="$MACHINE_BOOTSTRAP_CONFIG_DIR"
fi
config_file=$config_path/node.env
diskpassphrase_file=$config_path/disk.passphrase.gpg
showargs=false
allowunsafe=false
sshuser=""

# enforce english as expected output language of script
export LC_MESSAGES="POSIX"

# parse args
if test "$1" = "--show-ssh"; then showargs=ssh; shift; fi
if test "$1" = "--show-scp"; then showargs=scp; shift; fi
if test "$1" = ""; then usage; fi
hosttype="$1"
shift
if test "${hosttype##*@}" = "temporary"; then
    sshuser="${hosttype%%@*}"
    hosttype="${hosttype##*@}"
fi
if [[ ! "$hosttype" =~ ^(temporary|temporary-unlock|recovery|recovery-unlock|initrd|initrd-unlock|system)$ ]]; then usage; fi

if test ! -e "$config_file"; then
    echo "ERROR: config file ($config_file) not found"
    exit 1
fi
. "$config_file"
if test "$sshlogin" = ""; then
    echo "ERROR: config file ($config_file) has no settings 'sshlogin'"
    exit 1
fi
if test "$sshuser" != ""; then
    sshlogin="${sshuser}@${sshlogin##*@}"
fi

# print corresponding ssh or scp args and exit
if test "$showargs" != "false"; then
    # if set, remove "-unlock" from hosttype
    hosttype="${hosttype%%-unlock}"
    echo "-o UserKnownHostsFile=$config_path/${hosttype}.known_hosts $(ssh_uri ${sshlogin} $showargs)"

# unlock storage and login
elif test "$hosttype" = "temporary-unlock" -o \
          "$hosttype" = "initrd-unlock" -o \
          "$hosttype" = "recovery-unlock"; then

    if test "$1" = "--unsafe"; then allowunsafe=true; shift; fi
    if test ! -e "$diskpassphrase_file"; then
        echo "ERROR: diskphrase file $diskpassphrase_file not found"
        usage
    fi
    diskphrase=$(cat "$diskpassphrase_file" | gpg --decrypt)
    if test "$diskphrase" = ""; then
        echo "Error: diskphrase is empty, abort"
        exit 1
    fi

    hosttype="${hosttype%%-unlock}"
    sshopts="-o UserKnownHostsFile=$config_path/${hosttype}.known_hosts"
    waitfor_ssh "$sshlogin"
    remote_attestation_ssh "$sshopts" "$(ssh_uri ${sshlogin})" $allowunsafe

    if test "$hosttype" = "temporary"; then
        scp $sshopts \
            "$self_path/storage/storage-mount.sh" \
            "$self_path/storage/storage-unmount.sh" \
            "$self_path/bootstrap-library.sh" \
            "$(ssh_uri ${sshlogin} scp)/tmp"
        echo -n "$diskphrase" | ssh $sshopts $(ssh_uri ${sshlogin}) \
            "/tmp/storage-mount.sh --yes --password-from-stdin $@"
        ssh $sshopts $(ssh_uri ${sshlogin})
    elif test "$hosttype" = "initrd"; then
        echo -n "$diskphrase" | ssh $sshopts $(ssh_uri ${sshlogin}) \
            'phrase=$(cat -); for s in /var/run/systemd/ask-password/sck.*; do echo -n "$phrase" | /lib/systemd/systemd-reply-password 1 $s; done'
    elif test "$hosttype" = "recovery"; then
        echo -n "$diskphrase" | ssh $sshopts $(ssh_uri ${sshlogin}) \
            "storage-mount.sh --yes --password-from-stdin $@"
        ssh $sshopts $(ssh_uri ${sshlogin})
    fi

# normal login
else
    waitfor_ssh "$sshlogin"
    sshopts="-o UserKnownHostsFile=$config_path/${hosttype}.known_hosts"
    ssh $sshopts $(ssh_uri ${sshlogin}) "$@"
fi
