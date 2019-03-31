#!/bin/bash
set -eo pipefail
#set -x

self_path=$(dirname "$(readlink -e "$0")")
base_path=$(readlink -e "$self_path/..")


usage(){
    cat << EOF
Usage:  $0 --yes [salt-call parameter]

EOF
    exit 1
}


minion_config() {
    local base_path run_path
    base_path=$1
    run_path=$2
    echo "generating local minion config file"
    mkdir -p "$run_path"
    cat << EOF > "$run_path/minion"
root_dir: $run_path
pidfile: salt-call.pid
pki_dir: pki
cachedir: cache
sock_dir: run
log_file: salt-call.log
log_level_logfile: info
file_client: local

fileserver_backend:
- roots
pillar_roots:
  base:
  - $base_path/machine-config

file_roots:
  base:
  - $base_path/salt/salt-shared
  - $base_path/salt/custom

grains:
  project_basepath: $base_path

id: $(hostname)

EOF

}


salt_install() {
    salt_major_version="2019.2"
    salt_python_version="3"
    os_release=$(lsb_release -r -s)
    os_codename=$(lsb_release -c -s)
    os_distributor=$(lsb_release  -i -s | tr '[:upper:]' '[:lower:]')
    os_architecture=$(dpkg --print-architecture)

    if [[ "$os_codename" =~ ^(trusty|xenial|bionic|stretch)$ ]]; then
        if test "$salt_python_version" = "3" -a "$os_codename" != "trusty"; then
            echo "installing saltstack $salt_major_version for python 3"
            prefixdir="py3"
        else
            echo "installing saltstack $salt_major_version for python 2"
            prefixdir="apt"
        fi
        wget -O - "https://repo.saltstack.com/${prefixdir}/${os_distributor}/${os_release}/${os_architecture}/${salt_major_version}/SALTSTACK-GPG-KEY.pub" | apt-key add -
        echo "deb http://repo.saltstack.com/${prefixdir}/${os_distributor}/${os_release}/${os_architecture}/${salt_major_version} ${os_codename} main" > /etc/apt/sources.list.d/saltstack.list
        DEBIAN_FRONTEND=noninteractive apt-get update -y
    else
        echo "installing saltstack distro buildin version"
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y salt-minion
    # keep minion from running
    for i in disable stop mask; do systemctl $i salt-minion; done
}


# main
run_path=$base_path/run
cd /tmp
if test "$1" != "--yes"; then usage; fi
shift
if which cloud-init > /dev/null; then
    # be sure that cloud-init has finished
    cloud-init status --wait
fi
if ! which salt-call > /dev/null; then
    salt_install
fi
if test ! -e "$run_path/minion"; then
    minion_config "$base_path" "$run_path"
fi
echo "salt-call $@"
echo "(look at $run_path/salt-call.log for more verbosity)"
salt-call --local --config-dir="$run_path" "$@"
