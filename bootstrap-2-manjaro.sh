#!/bin/bash
set -eo pipefail
#set -x

self_path=$(dirname "$(readlink -e "$0")")

usage() {
    cat <<EOF
Usage: $0 hostname firstuser --yes [--restore-from-backup]

"http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"
EOF
    exit 1
}

restore_warning() {
    echo "WARNING: --restore-from-backup: $@"
}

# parse args
if test "$3" != "--yes"; then usage; fi
hostname=$1; firstuser=$2; shift 3
restore_backup=false
if test "$1" = "--restore-from-backup"; then restore_backup=true; shift; fi

# if http_proxy is set, reexport for sub-processes
if test "$http_proxy" != ""; then export http_proxy; fi

# include library
. "$self_path/bootstrap-library.sh"

echo "configure systemd-firstboot"
export LANG="en_US.UTF-8"
export LC_MESSAGES="POSIX"
export LANGUAGE="en_US:en"
export KEYMAP="us"
export TIMEZONE="Etc/UTC"
systemd-firstboot --locale="$LANG" --locale-messages="$LC_MESSAGES" \
    --keymap="$KEYMAP" --timezone="$TIMEZONE" --hostname="$hostname"

create_fstab "manjaro"
create_crypttab
mkinitcpio -P
bootctl install
