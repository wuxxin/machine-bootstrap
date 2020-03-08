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
    local base_path config_path
    base_path=$1
    config_path=$2
    echo "generating local minion config file"
    mkdir -p "$config_path"
    cat << EOF > "$config_path/minion"
id: $(hostname)
log_level_logfile: info
file_client: local

fileserver_backend:
- roots

pillar_roots:
  base:
  - $base_path/config

file_roots:
  base:
  - $base_path/salt/salt-shared
  - $base_path/salt/custom

grains:
  project_basepath: $base_path

EOF

}

salt_install() {
    salt_major_version="2019.2"
    os_release=$(lsb_release -r -s)
    os_codename=$(lsb_release -c -s)
    os_distributor=$(lsb_release  -i -s | tr '[:upper:]' '[:lower:]')
    os_architecture=$(dpkg --print-architecture)

    if test "$os_architecture" = "amd64"; then
        if [[ "$os_codename" =~ ^(xenial|bionic|stretch|buster)$ ]]; then
            prefixdir="py3"
            echo "installing saltstack ($salt_major_version) for python 3 from ppa"
            wget -O - "https://repo.saltstack.com/${prefixdir}/${os_distributor}/${os_release}/${os_architecture}/${salt_major_version}/SALTSTACK-GPG-KEY.pub" | apt-key add -
            echo "deb [arch=${os_architecture}] http://repo.saltstack.com/${prefixdir}/${os_distributor}/${os_release}/${os_architecture}/${salt_major_version} ${os_codename} main" > /etc/apt/sources.list.d/saltstack.list
            DEBIAN_FRONTEND=noninteractive apt-get update -y
        else
            echo "installing distro buildin saltstack version"
        fi
    else
        echo "installing distro buildin saltstack version"
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y salt-minion
    echo "keep minion from running automatically"
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
