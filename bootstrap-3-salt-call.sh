#!/bin/bash
set -eo pipefail
set -x

# defaults
source=ssh://git@pgit.on.ep3.at:10023/3ort/keen.git
branch=master
acknowledged=false
keys_from_stdin=false
# keep minion from running"
defpara="-X" 


usage(){
    cat << EOF
Usage:  $0 [--source giturl] [--branch name] [--keys-from-stdin] --yes [-- salt-call parameter]

install appliance from scratch.

--keys-from-stdin expects up to three key types (ssh key, gpg key, ssh known hosts) 
  to be concated and pasted into stdin.
  
  + the gpg key needs to be armored and is to be used for git-crypt unlock
  + the ssh key is used to fetch the git repository
  + the ssh known hosts are used for ssh git repository server and to be guarded with 
    "# ---BEGIN OPENSSH KNOWN HOSTS---" and "# ---END OPENSSH KNOWN HOSTS---"

EOF
    exit 1
}

extract_gpg(){
    local head="-----BEGIN PGP PRIVATE KEY BLOCK-----"
    local bottom="-----END PGP PRIVATE KEY BLOCK-----"
    echo "$1" | grep -qPz "(?s)$head.*$bottom"
    if test $? -ne 0; then return 1; fi
    echo "$1" | awk "/$head/,/$bottom/"
}

extract_ssh(){
    local oldhead="-----BEGIN RSA PRIVATE KEY-----"
    local oldbottom="-----END RSA PRIVATE KEY-----"
    local newhead="-----BEGIN OPENSSH PRIVATE KEY-----"
    local newbottom="-----END OPENSSH PRIVATE KEY-----"
    echo "$1" | grep -qPz "(?s)$oldhead.*$oldbottom"
    if test $? -eq 0; then 
        echo "$1" | awk "/$oldhead/,/$oldbottom/"
    else
        echo "$1" | grep -qPz "(?s)$newhead.*$newbottom"
        if test $? -ne 0; then return 1; fi
        echo "$1" | awk "/$newhead/,/$newbottom/"
    fi
}

extract_known_hosts(){
  # ---BEGIN OPENSSH KNOWN HOSTS---
  local head="# ---BEGIN OPENSSH KNOWN HOSTS---"
  local bottom="# ---END OPENSSH KNOWN HOSTS---"
  echo "$1" | grep -qPz "(?s)$head.*$bottom"
  if test $? -ne 0; then return 1; fi
  echo "$1" | awk "/$head/,/$bottom/"
}

ssh_type(){
    echo "$@" | grep -q -- "-----BEGIN RSA PRIVATE KEY-----"
    if test $? -eq 0; then 
        echo "id_rsa"
    else
        echo "$@" | grep -q -- "-----BEGIN OPENSSH PRIVATE KEY-----"
        if test $? -eq 0; then 
            echo "id_ed25519"
        fi
    fi
}


if test "$1" = ""; then usage; fi

while true; do
    case $1 in
    -s|--source)
        source=$2
        shift
        ;;
    -b|--branch)
        branch=$2
        shift
        ;;
    -k|--keys-from-stdin)
        keys_from_stdin=true
        ;;
    -y|--yes)
        acknowledged=true
        ;;
    --)
        shift
        break
        ;;
    *)
        break
        ;;
    esac
    shift
done

if test "$acknowledged" != "true"; then usage; fi
cd /tmp

# wait for cloud-init to finish, also interferes with pkg installing 
if which cloud-init > /dev/null; then 
    echo -n "waiting for cloud-init finish..."
    cloud-init status --wait
fi

# set temporary locale and timezone
export LANG=en_US.UTF-8
export LC_MESSAGES=POSIX
printf "LANG=en_US.UTF-8\nLANGUAGE=en_US:en\nLC_MESSAGES=POSIX\n" > /etc/default/locale
timedatectl set-timezone "Europe/Vienna"

# keep update service from interfering, appliance-update will call it
for i in apt-daily.service apt-daily.timer unattended-upgrades.service apt-daily-upgrade.service apt-daily-upgrade.timer ; do
    systemctl disable $i; systemctl stop $i; systemctl mask $i
done
systemctl daemon-reload

# install base packages
export DEBIAN_FRONTEND=noninteractive
apt-get -y update
apt-get -y install software-properties-common locales gosu git git-crypt curl

# set locale
locale-gen en_US.UTF-8 && dpkg-reconfigure locales

# create homedir
export HOME=/app
adduser --disabled-password --gecos ",,," --home "/app" app || true
cp -r /etc/skel/. /app/.

# extract keys from stdin
if $keys_from_stdin; then
    data=$(cat -)
    gpgkey=$(extract_gpg "$data")
    if test $? -ne 0; then 
        echo "Warning: no gpg key found from stdin"
    else
        echo "$gpgkey" | gosu app gpg --batch --yes --import || true
    fi
    sshkey=$(extract_ssh "$data")
    if test $? -ne 0; then 
        echo "Warning: no ssh key found from stdin"
    else
        install -o app -g app -m "0700" -d /app/.ssh
        sshkeytarget="/app/.ssh/$(ssh_type \"$sshkey\")"
        echo "$sshkey" > $sshkeytarget
        chown app:app $sshkeytarget
        chmod "0600" $sshkeytarget
    fi
    known_hosts=$(extract_known_hosts "$data")
    if test $? -ne 0; then 
        echo "Warning: no ssh known hosts found from stdin"
    else
        install -o app -g app -m "0700" -d /app/.ssh
        echo "$known_hosts" > /app/.ssh/known_hosts
        chown app:app /app/.ssh/known_hosts
        chmod "0600" /app/.ssh/known_hosts
    fi
    if test "$gpgkey$sshkey" = ""; then
        echo "Error: neither ssh nor gpg key found from stdin"
        exit 1
    fi
fi

# clone, update and git-crypt unlock appliance source code
if test ! -d /app/appliance; then
    gosu app git clone $source /app/appliance
else
    chown -R app:app /app/appliance
fi
gosu app git -C /app/appliance fetch -a -p
gosu app git -C /app/appliance checkout -f $branch
gosu app git -C /app/appliance reset --hard origin/$branch
gosu app git -C /app/appliance submodule update --init --recursive
pushd /app/appliance && gosu app git-crypt unlock && popd
gosu app mkdir -p /app/etc/tags
echo "$source" | gosu app tee /app/etc/tags/APPLIANCE_GIT_BOOTSTRAP_SOURCE
echo "$branch" | gosu app tee /app/etc/tags/APPLIANCE_GIT_BOOTSTRAP_BRANCH

# set hostname
common="/app/appliance/pillar/common.sls"
intip="127\.0\.1\.1"
shortid=$(grep "set shortid" $common | sed -r "s/.+set shortid= *['\"]([^'\"]+)['\"].+/\1/")
intdomain=$(grep "set intdomain" $common | sed -r "s/.+set intdomain= *['\"]([^'\"]+)['\"].+/\1/")
longid="${shortid}.${intdomain}"
#hostnamectl set-hostname ${longid}
if ! grep -E -q "^${intip}[[:space:]]+${shortid}\.${intdomain}[[:space:]]+${shortid}" /etc/hosts; then
    grep -q "^${intip}" /etc/hosts && \
      sed --in-place=.bak -r "s/^(${intip}[ \t]+).*/\1${longid} ${shortid}/" /etc/hosts || \
      sed --in-place=.bak -r "$ a${intip}\t${longid} ${shortid}" /etc/hosts
fi
hostname -f || (echo "error $? on hostname -f"; exit 1)

# bootstrap salt-call
mkdir -p /etc/salt
cp /app/appliance/minion /etc/salt/minion
echo -n "${longid}" > /etc/salt/minion_id
curl -o /tmp/bootstrap.saltstack.sh -L https://bootstrap.saltstack.com
chmod +x /tmp/bootstrap.saltstack.sh
if test ! "$@" = ""; then
    echo "not using default parameter ($defpara), using parameter $@"
    defpara="$@"
fi
if ! which salt-call > /dev/null; then
    /tmp/bootstrap.saltstack.sh $defpara
fi
# keep minion from running, salt dpkg packages
for i in disable stop mask; do systemctl $i salt-minion; done

# call state.highstate
salt-call --pillar-root=/notexisting saltutil.sync_modules 
salt-call state.highstate "$@"
