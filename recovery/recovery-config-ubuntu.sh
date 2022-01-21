#!/bin/sh
set -e
# set -x

self_path=$(dirname "$(readlink -e "$0")")


usage() {

    cat << EOF
Usage: $(basename $0)  --host
                        [--output <squashfsoutputfile>|--output-manifest] [<hostname>]
       $(basename $0)  --custom
                        <squashfsoutputfile> <hostname> <hostid>|-
                        <netplan_file> <hostkeys_file> <authorized_keys_file>
                        <scriptdir> <archivedir>|- <autologin(true|false)>
                        "<packagelist(default|-|package+)>" [<http_proxy>]

--host                  create a recovery squash file based on the hosts default parameter
    [--output <file>]   write to other than default outputfile
    [--output-manifest] do not create squashfs,
                        but display list of generated files excluding archivedir
    [<hostname>]        set different hostname, maybe required after hostname change in node.env

--custom                create a recovery squashfs file on custom parameter
    hostid|-:           hostid in binary form, use "-" if no id
    archivedir:         expects local apt-archive with "Release" and
                        "Packages" files, use "-" if no archive
    <packagelist>:      "default" for default list, "-" for no packages, else list of packages

defaults:
  squashfsoutputfile:   $destfile
  hostname:             if not set from commandline, hostname -f
  hostid:               if exists from /etc/hostid else "-"
  netplan_file:         if exists from /etc/recovery/netplan.yaml else from /etc/netplan/*
  systemd_netdev_file   if exists from /etc/systemd/network/
  systemd_network_file  if exists from /etc/systemd/network/
  hostkeys_file:        /etc/recovery/recovery_hostkeys
  authorized_keys_file: /root/.ssh/authorized_keys
  scriptdir:            /etc/recovery (will be copied to recovery:/usr/sbin/)
  archivedir:           if exists "$custom_archive" else "-"
  autologin:            "true" if exists /etc/recovery/feature.autologin else "false"
  packagelist:          "default"
  http_proxy:           from environment if http_proxy is set: $http_proxy

  default package list: $default_packages

EOF
    exit 1
}


generate_recovery_squashfs() {
    local basedir cfgdir destfile hostname hostid netplan_data hostkeys_data
    local authorized_keys_data scriptdir archivedir autologin packages http_proxy
    local prefixdir
    destfile=$1; hostname=$2; hostid=$3; netplan_data="$4"; hostkeys_data="$5";
    authorized_keys_data="$6"; scriptdir=$7; archivedir=$8; autologin=$9;
    packages="${10}"; http_proxy="${11}"

    prefixdir=/run/user/$(id -u)
    if test ! -e $prefixdir; then mkdir -p $prefixdir; fi
    basedir=$(mktemp -d -p $prefixdir || (echo "error making temporary dir" 1>&2; exit 1))
    cfgdir="$basedir/etc/cloud/cloud.cfg.d"

    echo "create recovery.squashfs" 1>&2
    mkdir -p "$cfgdir"

    echo "write meta-data.cfg" 1>&2
    printf "instance-id: %s\nlocal-hostname: %s\n" $hostname $hostname > "$cfgdir/meta-data.cfg"

    echo "write netplan as network-config.cfg" 1>&2
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
        packages="$default_packages"
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
  - name: installer
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
$(printf "%s" "$authorized_keys_data" | sed -e 's/^/      - /')

EOF
    if test "$hostkeys_data" != ""; then
        echo "write recovery_hostkeys to user-data.cfg" 1>&2
        printf "%s\n\n" "$hostkeys_data" >> "$cfgdir/user-data.cfg"
    fi

    echo "disable snapd and subiquity" 1>&2
    mkdir -p "$basedir/etc/systemd/system"
    for i in snapd.apparmor.service snapd.recovery-chooser-trigger.service \
        snapd.snap-repair.timer snapd.autoimport.service snapd.seeded.service \
        snapd.socket snapd.core-fixup.service snapd.service \
        snapd.system-shutdown.service snapd.failure.service snapd.snap-repair.service \
        serial-subiquity@.service; do
        ln -s /dev/null "$basedir/etc/systemd/system/$i"
    done

    if test "$autologin" = "true"; then
        echo "modify tty4 for autologin" 1>&2
        mkdir -p "$basedir/etc/systemd/system/getty@tty4.service.d"
        cat > "$basedir/etc/systemd/system/getty@tty4.service.d/override.conf" <<"EOF"
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f root' --autologin root --noclear %I $TERM
EOF
    fi

    if test "$hostid" != "-"; then
        echo "add /etc/hostid" 1>&2
        printf "%s" "$hostid" > $basedir/etc/hostid
    fi

    echo "include helper scripts in squashfs" 1>&2
    mkdir -p $basedir/usr/sbin
    cp $scriptdir/*.sh $basedir/usr/sbin/

    cd $basedir
    echo "make sha256sum of current files as hash"  1>&2
    find .  -type f -print0 | xargs -0 sha256sum -b > "${destfile}.files.sha256sum"

    if test "$archivedir" != "" -a "$archivedir" != "-"; then
        echo "include custom archive in squashfs" 1>&2
        mkdir -p "$basedir$archivedir"
        cp -t "$basedir$archivedir" $archivedir/*
        mkdir -p "$basedir$(dirname $custom_sources_list)"
        cat > "$basedir$custom_sources_list" << EOF
deb [ trusted=yes ] file:$archivedir ./
EOF
        echo "make sha256sum of custom archive file Package as hash"  1>&2
        sha256sum -b .$archivedir/Packages >> "${destfile}.files.sha256sum"
    fi

    echo "create squashfs" 1>&2
    mksquashfs . "$destfile" -no-progress -root-owned -quiet 1>&2
    cd /
    # echo "workdir was $basedir" 1>&2
    if test -d $basedir; then rm -r $basedir; fi
}


# ###
# main

# defaults
custom_archive=/usr/local/lib/bootstrap-custom-archive
custom_sources_list=/etc/apt/sources.list.d/local-bootstrap-custom.list
destfile="/efi/casper/recovery.squashfs"
dryrun=false
# get default_packages either from bootstrap-library.sh if existing, else hardcode
library_path=""
for i in "$self_path" "$self_path/.."; do
    if test -e "$i/bootstrap-library.sh"; then library_path="$i"; break; fi
done
if test "$library_path" = ""; then
    # XXX keep in sync with get_default_packages from bootstrap-library.sh
    default_packages="cryptsetup gdisk mdadm lvm2 grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed efibootmgr squashfs-tools openssh-server curl gnupg gpgv ca-certificates bzip2 libc-bin rsync tmux haveged debootstrap"
else
    . "$library_path/bootstrap-library.sh"
    default_packages="$(get_default_packages)"
fi

if test "$1" != "--host" -a "$1" != "--custom"; then usage; fi

if test "$1" = "--host"; then
    shift
    if test "$1" = "--output"; then
        destfile="$(readlink -f $2)"
        shift 2
    elif test "$1" = "--output-manifest"; then
        shift
        prefixdir=/run/user/$(id -u)
        if test ! -e $prefixdir; then mkdir -p $prefixdir; fi
        basedir=$(mktemp -d -p $prefixdir || (echo "error making temporary dir" 1>&2; exit 1))
        destfile=$basedir/recovery.squashfs
        dryrun=true
    fi
    $0 --custom \
        $destfile \
        $(test "$1" != "" && echo "$1" || echo $(hostname -f)) \
        "$(test -e /etc/hostid && echo "/etc/hostid" || printf '%s' '-')" \
        "$(test -e /etc/recovery/netplan.yaml && echo '/etc/recovery/netplan.yaml' || echo '/etc/netplan/*')" \
        /etc/recovery/recovery_hostkeys \
        /root/.ssh/authorized_keys \
        /etc/recovery \
        $(test -e $custom_archive && echo "$custom_archive" || printf '%s' '-') \
        $(test -e /etc/recovery/feature.autologin && echo "true" || echo "false") \
        default \
        $http_proxy
    if test "$dryrun" = "true"; then
        cat ${destfile}.files.sha256sum
        # echo "workdir was $basedir" 1>&2
        if test -d $basedir; then rm -r $basedir; fi
    fi
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
        echo "Warning: destination file already exists, renaming to ${destfile}.old" 1>&2
        mv "$destfile" "${destfile}.old"
    fi
    generate_recovery_squashfs "$destfile" "$hostname" "$hostid_data" \
        "$netplan_data" "$hostkeys_data" "$authorized_keys_data" \
        "$scriptdir" "$archivedir" "$autologin" "$packages" "$http_proxy"
fi
