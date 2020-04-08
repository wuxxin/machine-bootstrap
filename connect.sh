#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")
config_path="$(readlink -m "$self_path/../config")"
if test -n "$MACHINE_BOOTSTRAP_CONFIG_DIR"; then
    config_path="$MACHINE_BOOTSTRAP_CONFIG_DIR"
fi
config_file=$config_path/machine-config.env
diskpassphrase_file=$config_path/disk.passphrase.gpg


usage() {
    cat <<EOF
Usage: $0 [--show-ssh|--show-scp]
    temporary|recovery|recoveryluks|recoverymount|initrd|initrdluks|system [\$@]

use ssh keys and config taken from $config_path to connect to system via ssh

+ temporary, recovery, initrd, system
    connect to system with the expected the ssh hostkey

+ initrdluks [--allow-virtual]
    uses the initrd host key for connection,
    and transfers the luks diskphrase keys to /lib/systemd/systemd-reply-password

+ recoveryluks [--allow-virtual]
    uses the recovery host key for connection,
    and transfers the luks diskphrase keys to recovery-mount.sh

+ recoverymount [--allow-virtual]
    equal to recoveryluks but also mount all partitions and prepare a chroot at /mnt

--allow-virtual: do not abort if target system looks like virtual machine
--show-ssh: only displays the parameters for ssh
--show-scp: only displays the parameters for scp
    may be used for scp \$(connect.sh --show-args system)/root/test.txt .
EOF
    exit 1
}

abort_if_virtual_ssh() { # "$allowvirtual" "$sshopts" "$(ssh_uri ${sshlogin})"
    local allowvirtual sshopts sshurl
    allowvirtual="$1"
    sshopts="$2"
    sshurl="$3"
    echo "Fixme: check for virtual machine via ssh"
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


# parse args
export LC_MESSAGES="POSIX"
showargs=false
allowvirtual=false
if test "$1" = "--show-ssh"; then showargs=ssh; shift; fi
if test "$1" = "--show-scp"; then showargs=scp; shift; fi
if [[ ! "$1" =~ ^(temporary|recovery|recoveryluks|recoverymount|initrd|initrdluks|system)$ ]]; then usage; fi
hosttype="$1"
shift 1

if test ! -e "$config_file"; then
    echo "ERROR: configuration file ($config_file) not found, abbort"
    exit 1
fi
. "$config_file"

if test "$sshlogin" = ""; then
    echo "ERROR: configuration file ($config_file) has no settings 'sshlogin', abbort"
    exit 1
fi

if test "$showargs" != "false"; then
    if test "$hosttype" = "initrdluks"; then
        hosttype="initrd"
    fi
    if test "$hosttype" = "recoverymount" -o "$hosttype" = "recoveryluks"; then
        hosttype="recovery"
    fi
    echo "-o UserKnownHostsFile=$config_path/${hosttype}.known_hosts $(ssh_uri ${sshlogin} $showargs)"
    exit 0
fi
if test "$hosttype" = "initrdluks" -o "$hosttype" = "recoveryluks" -o "$hosttype" = "recoverymount"; then
    if test ! -e "$diskpassphrase_file"; then
        echo "ERROR: diskphrase file $diskpassphrase_file not found"
        usage
    fi
    if test "$1" = "--allow-virtual"; then allowvirtual=true; shift; fi
    diskphrase=$(cat "$diskpassphrase_file" | gpg --decrypt)
    if test "$diskphrase" = ""; then
        echo "Error: diskphrase is empty, abort"
        exit 1
    fi
    if test "$hosttype" = "recoverymount" -o "$hosttype" = "recoveryluks"; then
        sshopts="-o UserKnownHostsFile=$config_path/recovery.known_hosts"
        waitfor_ssh "$sshlogin"
        abort_if_virtual_ssh $allowvirtual $sshopts $(ssh_uri ${sshlogin})
        echo -n "$diskphrase" | ssh $sshopts $(ssh_uri ${sshlogin}) \
            'recovery-mount.sh --yes --only-raid-crypt --luks-from-stdin'
        if test "$hosttype" = "recoverymount"; then
            ssh $sshopts $(ssh_uri ${sshlogin}) \
                "recovery-mount.sh --yes --without-raid-crypt $@"
        fi
        ssh $sshopts $(ssh_uri ${sshlogin})
    else
        sshopts="-o UserKnownHostsFile=$config_path/initrd.known_hosts"
        waitfor_ssh "$sshlogin"
        abort_if_virtual_ssh $allowvirtual $sshopts $(ssh_uri ${sshlogin})
        echo -n "$diskphrase" | ssh $sshopts $(ssh_uri ${sshlogin}) \
            'phrase=$(cat -); for s in /var/run/systemd/ask-password/sck.*; do echo -n "$phrase" | /lib/systemd/systemd-reply-password 1 $s; done'
    fi
else
    waitfor_ssh "$sshlogin"
    sshopts="-o UserKnownHostsFile=$config_path/${hosttype}.known_hosts"
    ssh $sshopts $(ssh_uri ${sshlogin}) "$@"
fi
