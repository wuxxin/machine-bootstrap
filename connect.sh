#!/bin/bash
set -e
self_path=$(dirname $(readlink -e "$0"))
config_path="$(readlink -e "$self_path/../machine-config")"
if test -n "$BOOTSTRAP_MACHINE_CONFIG_DIR"; then
    config_path="$BOOTSTRAP_MACHINE_CONFIG_DIR"
fi
config_file=$config_path/config
diskpassphrase_file=$config_path/disk.passphrase.gpg


usage() {
    cat <<EOF
Usage: $0 temporary|recovery|initrd|luksopen|system [\$@]

ssh connect with different ssh_hostkeys used.

ssh keys and config are taken from directory $config_path 

luksopen uses the initrd host key for connection,
and transfers the luks diskphrase keys to /lib/systemd/systemd-reply-password

EOF
    exit 1
}

waitfor_ssh() {
    local retries maxretries retry sshhost
    retries=0; maxretries=90; retry=true; sshhost=$1
    while "$retry"; do
        ((retries+=1))
        if test "$retries" -ge "$maxretries"; then
            echo "Error, could not connect to $sshhost in $maxretries tries, giving up"
            exit 1
        fi
        nc -z -w 2 "$sshhost" 22 && err=$? || err=$?
        if test "$err" -eq "0"; then
            retry=false
        else
            echo -n "."
            sleep 1
        fi
    done
}


# parse args
if [[ ! "$1" =~ ^(temporary|recovery|initrd|luksopen|system)$ ]]; then usage; fi
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

if test "$hosttype" = "luksopen"; then
    sshopts="-o UserKnownHostsFile=$config_path/initrd.known_hosts"
    if test ! -e "$diskpassphrase_file"; then
        echo "ERROR: diskphrase file $diskpassphrase_file not found"
        usage
    fi
    diskphrase=$(cat "$diskpassphrase_file" | gpg --decrypt)
    if test "$diskphrase" = ""; then
        echo "Error: diskphrase is empty, abort"
        exit 1
    fi
    waitfor_ssh "${sshlogin#*@}"
    echo -n "$diskphrase" | ssh $sshopts ${sshlogin} \
        'phrase=$(cat -); for s in /var/run/systemd/ask-password/sck.*; do echo -n "$phrase" | /lib/systemd/systemd-reply-password 1 $s; done'
else
    waitfor_ssh "${sshlogin#*@}"
    sshopts="-o UserKnownHostsFile=$config_path/${hosttype}.known_hosts"
    ssh $sshopts ${sshlogin} "$@"
fi
