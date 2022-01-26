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
hostname=$1
firstuser=$2
shift 3
option_restore_backup=false
if test "$1" = "--restore-from-backup"; then
    option_restore_backup=true
    shift
fi

# include library
. "$self_path/bootstrap-library.sh"
