#!/bin/sh
set -e
# set -x

self_path=$(dirname "$(readlink -e "$0")")


usage() {

    cat << EOF
Usage:  $0 --host [--output <squashfsoutputfile>] [<hostname>]
        $0 --custom <squashfsoutputfile> <hostname> <hostid>|-
                    <netplan_file> <hostkeys_file> <authorized_keys_file>
                    <scriptdir> <archivedir>|- <autologin(true|false)>
                    "<packagelist(default|-|package+)>" [<http_proxy>]

--custom        create a recovery squashfs file on custom parameter
    hostid:         hostid in binary form, use "-" if no id
    archivedir:     expects local apt-archive with "Release" and
                    "Packages" files, use "-" if no archive
    <packagelist>:  "default" for default list, "-" for no packages, else list of packages

--host          create a recovery squash file based on the hosts default parameter
    --output <squashfsoutputfile>
                write to different outputfile
    <hostname>  set different hostname

defaults:
  squashfsoutputfile:   /efi/casper/recovery.squashfs
  hostname:             if not set from commandline, from hostname -f
  hostid:               if exists from /etc/hostid else "-"
  netplan_file:         if exists from /etc/recovery/netplan.yml else from /etc/netplan/*
  hostkeys_file:        /etc/recovery/recovery_hostkeys
  authorized_keys_file: /root/.ssh/authorized_keys
  scriptdir:            /etc/recovery (will be copied to recovery:/sbin/)
  archivedir:           if exists "$custom_archive" else "-"
  autologin:            "true" if exists /etc/recovery/feature.autologin else "false"
  packagelist:          "default" for default list
  http_proxy:           from default env

EOF
    exit 1
}


generate_recovery_squashfs() {
    local basedir cfgdir destfile hostname hostid netplan_data hostkeys_data
    local authorized_keys_data scriptdir archivedir autologin packages http_proxy
    destfile=$1; hostname=$2; hostid=$3; netplan_data="$4"; hostkeys_data="$5";
    authorized_keys_data="$6"; scriptdir=$7; archivedir=$8; autologin=$9;
    packages="${10}"; http_proxy="${11}"
    basedir=$(mktemp -d || (echo "error making temporary dir"; exit 1))
    cfgdir="$basedir/etc/cloud/cloud.cfg.d"

    echo "create recovery.squashfs"
    mkdir -p "$cfgdir"

    echo "write meta-data.cfg"
    printf "instance-id: %s\nlocal-hostname: %s\n" $hostname $hostname > "$cfgdir/meta-data.cfg"

    echo "write netplan as network-config.cfg"
    echo "$netplan_data" > "$cfgdir/network-config.cfg"

    ci_http_proxy=""
    no_ssh_genkeytypes=""
    if test "$http_proxy" != ""; then
        ci_http_proxy="http_proxy: \"$http_proxy\""
    fi
    if test "$hostkeys_data" != ""; then
        no_ssh_genkeytypes="ssh_genkeytypes: []"
    fi
    if test "$packages" = "default"; then
        packages="$(get_default_packages)"
    elif test "$packages" = "-"; then
        packages=""
    fi

    cat > "$cfgdir/user-data.cfg" <<EOF
#cloud-config
# XXX keep the "#cloud-config" line first and unchanged

preserve_hostname: false
fqdn: $hostname

apt:
  sources_list: |
      deb \$MIRROR \$RELEASE main restricted universe multiverse
      deb \$MIRROR \$RELEASE-updates main restricted universe multiverse
      deb \$SECURITY \$RELEASE-security main restricted universe multiverse
      deb \$MIRROR \$RELEASE-backports main restricted universe multiverse
  $ci_http_proxy

package_upgrade: false
$(if test "$packages" != ""; then printf "packages:\n"; fi)
$(for p in $packages; do printf "  - %s\n" "$p"; done)

disable_root: false
ssh_pwauth: false
ssh_deletekeys: true
$no_ssh_genkeytypes

ssh_authorized_keys:
$(printf "%s" "$authorized_keys_data" | sed -e 's/^/  - /')

users:
  - name: root
    lock_passwd: true

EOF
cat > /dev/null << EOF
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
$(printf "%s" "$authorized_keys_data" | sed -e 's/^/      - /')

EOF
    if test "$hostkeys_data" != ""; then
        echo "write recovery_hostkeys to user-data.cfg"
        printf "%s\n\n" "$hostkeys_data" >> "$cfgdir/user-data.cfg"
    fi
    if test "$autologin" = "true"; then
        echo "modify tty4 for autologin"
        mkdir -p "$basedir/etc/systemd/system/getty@tty4.service.d"
        cat > "$basedir/etc/systemd/system/getty@tty4.service.d/override.conf" <<"EOF"
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f root' --autologin root --noclear %I $TERM
EOF
    fi

    if test "$hostid" != "-"; then
        echo "add /etc/hostid"
        printf "%s" "$hostid" > $basedir/etc/hostid
    fi

    echo "include helper scripts in squashfs"
    mkdir -p $basedir/usr/sbin
    cp -a $scriptdir/*.sh $basedir/usr/sbin/

    if test "$archivedir" != "" -a "$archivedir" != "-"; then
        echo "include custom archive in squashfs"
        mkdir -p "$basedir$archivedir"
        cp -t "$basedir$archivedir" $archivedir/*
        mkdir -p "$basedir$(dirname $custom_sources_list)"
        cat > "$basedir$custom_sources_list" << EOF
deb [ trusted=yes ] file:$archivedir ./
EOF
    fi

    echo "create squashfs"
    cd $basedir
    mksquashfs . "$destfile" -no-progress -root-owned
    cd /
    echo "remote workdir $basedir"
    if test -d $basedir; then rm -r $basedir; fi
}


# ###
# main
custom_archive=/usr/local/lib/bootstrap-custom-archive
custom_sources_list=/etc/apt/sources.list.d/local-bootstrap-custom.list

if test "$1" != "--host" -a "$1" != "--custom"; then usage; fi

for i in . ..; do
    if test -e "$self_path/$i/bootstrap-library.sh"; then
        . "$self_path/$i/bootstrap-library.sh"
    fi
done

if test "$1" = "--host"; then
    shift
    if test "$1" = "--output"; then
        destfile="$2"
        shift 2
    else
        destfile="/efi/casper/recovery.squashfs"
    fi
    $0 --custom \
    $destfile \
    $(test "$1" != "" && echo "$1" || echo $(hostname -f)) \
    "$(test -e /etc/hostid && echo "/etc/hostid" || printf '%s' '-')" \
    "$(test -e /etc/recovery/netplan.yml && echo '/etc/recovery/netplan.yml' || echo '/etc/netplan/*')" \
    /etc/recovery/recovery_hostkeys \
    /root/.ssh/authorized_keys \
    /etc/recovery \
    $(test -e $custom_archive && echo "$custom_archive" || printf '%s' '-') \
    $(test -e /etc/recovery/feature.autologin && echo "true" || echo "false") \
    default \
    $http_proxy
else
    shift
    if test "${10}" = ""; then usage; fi
    destfile=$1
    hostname=$2
    hostid_file=$3
    netplan_file=$4
    hostkeys_file=$5
    authorized_keys_file=$6
    scriptdir=$7
    archivedir=$8
    autologin=$9
    packages="${10}"
    http_proxy="${11}"
    for i in $netplan_file $hostkeys_file $authorized_keys_file; do
        if test ! -e "$i"; then
            echo "Error: file $i not found"
            usage
        fi
    done
    if test "$hostid_file" = "-"; then
        hostid_data="-"
    elif test -e "$hostid_file"; then
        hostid_data=$(cat "$hostid_file")
    else
        echo "Error: file $hostid_file not found"
        usage
    fi
    if test "$archivedir" != "-" -a ! -d $archivedir; then
        echo "Error: directory $archivedir not found"
        usage
    fi
    netplan_data=$(cat $netplan_file)
    hostkeys_data=$(cat "$hostkeys_file")
    authorized_keys_data=$(cat "$authorized_keys_file")
    if test -e "$destfile"; then
        echo "Warning: destination file already exists, renaming to ${destfile}.old"
        mv "$destfile" "${destfile}.old"
    fi
    generate_recovery_squashfs "$destfile" "$hostname" "$hostid_data" \
        "$netplan_data" "$hostkeys_data" "$authorized_keys_data" \
        "$scriptdir" "$archivedir" "$autologin" "$packages" "$http_proxy"
fi
