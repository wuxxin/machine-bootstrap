#!/bin/bash
set -eo pipefail
set -x

scriptpath=$(dirname "$(readlink -e "$0")")
basepath=$(readlink -e "$scriptpath/../..")
runpath=$basepath/_run


local_config() {
    echo "generating config files"
    mkdir "$runpath"
    cat | sed -re "s:##BASE##:$basepath:g" > "$runpath/minion" <<EOF
root_dir: ##BASE##/_run
pidfile: salt-minion.pid
pki_dir: pki
cachedir: cache
sock_dir: run
file_client: local

fileserver_backend:
- roots
pillar_roots:
  base:
  - ##BASE##/pillar

file_roots:
  base:
  - ##BASE##/salt/salt-shared
  - ##BASE##/salt/custom

EOF

    echo -e "id: $(hostname)" >> "$runpath/minion"

}



usage(){
    cat << EOF
Usage:  $0 <bootstrap-machine-basedir> --yes [-- salt-call parameter]

EOF
    exit 1
}


# main
os_release=$(lsb_release -r -s)
os_codename=$(lsb_release -c -s)
os_architecture=$(dpkg --print-architecture)
salt_major_version="2018.3"

if test "$1" = "--yes"; then usage; fi
shift
if test "$1" = "--"; then shift; fi
cd /tmp

# wait for cloud-init to finish, interferes with pkg installing and others
if which cloud-init > /dev/null; then 
    cloud-init status --wait
fi

# bootstrap salt-call
mkdir -p /etc/salt
cp /app/appliance/minion /etc/salt/minion
echo -n "${hostname}" > /etc/salt/minion_id


if ! which salt-call > /dev/null; then 
    wget -O - "https://repo.saltstack.com/apt/ubuntu/${os_release}/${os_architecture}/${salt_major_version}/SALTSTACK-GPG-KEY.pub" | sudo apt-key add -
    echo "deb http://repo.saltstack.com/apt/ubuntu/${os_release}/${os_architecture}/${salt_major_version} ${os_codename} main" > /etc/apt/sources.list.d/saltstack.list
    apt-get update
    apt-get install salt-minion
    # keep minion from running
    for i in disable stop mask; do systemctl $i salt-minion; done
fi

# salt-call --pillar-root=/notexisting saltutil.sync_modules 
salt-call --local --config-dir="$runpath" "$@"

