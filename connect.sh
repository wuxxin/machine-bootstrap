#!/bin/bash
set -e

self_path=$(dirname $(readlink -e "$0"))
if test -z "$BOOTSTRAP_MACHINE_CONFIG_DIR"; then
    config_path="$BOOTSTRAP_MACHINE_CONFIG_DIR"
else
    config_path="$(readlink -e $self_path/../machine-config)"
fi
config_file=$config_path/config


usage() {
    cat <<EOF
Usage: $0 temporary|recovery|initrd|system [\$@]

ssh connect with different ssh_hostkeys used.
ssh keys and config are taken from $self_path 
EOF
    exit 1
}


# parse args
if [[ ! "$1" =~ ^(temporary|recovery|initrd|system)$ ]]; then usage; fi
hosttype="$1"
shift 1

if test ! -e "$config_file"; then
    echo "ERROR: configuration file ($config_file) not found, abbort"
    exit 1
fi
. $config_file

if test "$sshlogin" = ""; then
    echo "ERROR: configuration file ($config_file) has no settings 'sshlogin', abbort"
    exit 1
fi

sshopts="-o UserKnownHostsFile=$config_path/${hosttype}.known_hosts"
ssh $sshopts ${sshlogin} "$@"

