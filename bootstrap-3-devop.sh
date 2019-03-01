#!/bin/bash
set -eo pipefail
set -x

self_path=$(dirname "$(readlink -e "$0")")
base_path=$(readlink -e "$self_path/..")


minion_config() {
    local base_path run_path
    base_path=$1
    run_path=$2
    echo "generating local minion config file"
    mkdir -p "$run_path"
    cat << EOF > "$run_path/minion"
root_dir: $run_path
pidfile: salt-minion.pid
pki_dir: pki
cachedir: cache
sock_dir: run
log_file: salt-minion.log
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
    os_release=$(lsb_release -r -s)
    os_codename=$(lsb_release -c -s)
    os_architecture=$(dpkg --print-architecture)
    echo "installing saltstack $salt_major_version"
    wget -O - "https://repo.saltstack.com/apt/ubuntu/${os_release}/${os_architecture}/${salt_major_version}/SALTSTACK-GPG-KEY.pub" | apt-key add -
    echo "deb http://repo.saltstack.com/apt/ubuntu/${os_release}/${os_architecture}/${salt_major_version} ${os_codename} main" > /etc/apt/sources.list.d/saltstack.list
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y salt-minion
    # keep minion from running
    for i in disable stop mask; do systemctl $i salt-minion; done
}


usage(){
    cat << EOF
Usage:  $0 --yes [salt-call parameter]

EOF
    exit 1
}


# main
run_path=$base_path/_run
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
if test ! -e $run_path/minion; then
    minion_config "$base_path" "$run_path"
fi
salt-call --local --config-dir="$run_path" "$@"
