#!/bin/bash
set -e
# set -x

self_path=$(dirname "$(readlink -e "$0")")

# Install Image
distroname=bionic
distroversion=18.04.3
kernel_name="hwe-vmlinuz"
initrd_name="hwe-initrd"
#distroname=eoan
#distroversion=19.10
#kernel_name="vmlinuz"
#initrd_name="initrd"
baseurl="http://releases.ubuntu.com/releases/${distroname}"
imagename="ubuntu-${distroversion}-live-server-amd64.iso"

# gpg keys allowed to sign images
cdimage_keyids="0x46181433FBB75451 0xD94AA3F0EFE21092"
cdimage_fingerprints="843938DF228D22F7B3742BC0D94AA3F0EFE21092
C5986B4F1257FFA86632CBA746181433FBB75451"
cdimage_keyname="cdimage@ubuntu.com"
cdimage_keyfile="${cdimage_keyname}.gpg"
cdimage_keyserver="hkp://keyserver.ubuntu.com"

# support files
bios_isolinux="/usr/lib/ISOLINUX/isolinux.bin"
bios_hybridmbr="/usr/lib/ISOLINUX/isohdpfx.bin"
bios_ldlinux="/usr/lib/syslinux/modules/bios/ldlinux.c32"
efi_syslinux="/usr/lib/SYSLINUX.EFI/efi64/syslinux.efi"
efi_ldlinux="/usr/lib/syslinux/modules/efi64/ldlinux.e64"


usage() {
    cat << EOF
$0 download               <downloaddir>
$0 extract                <downloaddir> <targetdir>
$0 create liveimage       <downloaddir> <targetiso> [<recovery.squashfs>]
$0 create installer-addon <src-squashfs> <dest-squashfs> <workdir> [<kernel_version>]
$0 show grub.cfg          <grub_root> <casper_livemedia> <uuid_volume>
$0 show grub.d/recovery   <grub_root> <casper_livemedia> <uuid_volume>
$0 show kernel_version    <targetdir containing kernel image>
    returns the kernel version found in targetdir
$0 show imagename
    returns the expected source image name for recovery building
$0 show keyfile
    returns the expected signingkeys file name for verifying downloads
$0 --check-req
    confirm all needed requisites are present, exit 0 if true

EOF
    exit 1
}


as_root() {
    if test "$(id -u)" != "0"; then sudo -- "$@"; else $@; fi
}


deb_chroot() {
    chrootdir=$1
    shift
    as_root env LANG="POSIX" LANGUAGE="C" LC_MESSAGES="POSIX" \
        DEBIAN_FRONTEND=noninteractive chroot "$chrootdir" "$@"
}


check_requisites() {
    local need_install silent req_list i
    need_install=false
    silent=false
    if test "$1" = "list"; then silent=true; shift; fi
    if test "$1" = "download"; then
        req_list="curl gpg gpgv"
        for i in $req_list; do
            if ! which $i > /dev/null; then
                if test "$silent" = "true"; then
                    echo "$req_list"
                    exit 0
                else
                    echo "Error: needed program $i not found."
                    echo "execute 'apt-get install $req_list'"
                    exit 1
                fi
            fi
        done
    else
        for i in $bios_isolinux $bios_hybridmbr $bios_ldlinux $efi_syslinux $efi_ldlinux; do
            if test ! -e "$i"; then
                need_install=true
                if test "$silent" != "true"; then
                    echo "Error: $(basename $i) not found"
                fi
            fi
        done
        for i in xorrisofs syslinux mkfs.msdos curl gpg gpgv; do
            if ! which $i > /dev/null; then
                need_install=true
                if test "$silent" != "true"; then
                    echo "Error: needed program $i not found"
                fi
            fi
        done
        req_list="isolinux syslinux syslinux-efi syslinux-common xorriso dosfstools curl gnupg gpgv"
        if test "$need_install" = "true"; then
            if test "$silent" = "true"; then
                echo "$req_list"
                exit 0
            else
                echo "Error: needed program $i not found."
                echo "execute 'apt-get install $req_list'"
                exit 1
            fi
        fi
    fi
}


download_casper_image() {
    local basedir baseurl imagename imagehash validate_result real_fingerprint gpghome
    basedir="$1"
    baseurl="$2"
    imagename="$3"
    gpghome="$basedir/gpghome"

    if test ! -e "$basedir/$cdimage_keyfile"; then
        echo "get gpg key $cdimage_keyname ($cdimage_keyids)"
        if test -e "$gpghome"; then rm -rf "$gpghome"; fi
        mkdir -m 0700 "$gpghome"
        gpg --quiet --homedir "$gpghome" --batch --yes --keyserver $cdimage_keyserver --recv-keys $cdimage_keyids
        real_fingerprint=$(LC_MESSAGES=POSIX gpg --quiet --homedir "$gpghome" --keyid-format long --fingerprint $cdimage_keyids | grep "fingerprint = " | sed -r "s/.*= (.*)/\1/g" | tr -d " ")
        if test "$cdimage_fingerprints" != "$real_fingerprint"; then
            echo "error: fingerprint mismatch: expected: $cdimage_fingerprints , real: $real_fingerprint"
            exit 1
        fi
        gpg --quiet --homedir "$gpghome" --export $cdimage_keyids > "$basedir/$cdimage_keyfile"
        rm -r "$gpghome"
    else
        echo "using verified cached keys from $basedir/$cdimage_keyfile"
    fi

    echo "get checksum files for image"
    for i in SHA256SUMS SHA256SUMS.gpg; do
        echo "get $baseurl/$i"
        curl -L -S -s "$baseurl/$i" -o "$basedir/$i"
    done

    echo "validate that checksum files are signed with correct key"
    gpgv_result=$(LC_MESSAGES=POSIX gpgv --keyring="$basedir/$cdimage_keyfile" "$basedir/SHA256SUMS.gpg" "$basedir/SHA256SUMS" 2>&1 >/dev/null || true)
    if ! (printf "%s" "$gpgv_result" | \
        grep -q -E "^gpgv: Good signature from.+<$cdimage_keyname>\"$"); then
        echo "ERROR: signature verification failed"
        exit 1
    fi

    imagehash=$(cat "$basedir/SHA256SUMS" | grep "$imagename" | sed -r "s/^([^ ]+) \*.+/\1/g")
    validate_result=1

    if test -e "$basedir/$imagename"; then
        echo "$imagehash *$basedir/$imagename" | sha256sum --check || validate_result=$? && validate_result=$?
        if test "$validate_result" = "0"; then
            echo "$imagename already on storage, and hash is correct"
        else
            echo "Warning: $imagename already on storage, but hash is different, deleting image"
            rm "$basedir/$imagename"
        fi
    fi
    if test ! -e "$basedir/$imagename"; then
        echo "download image $baseurl/$imagename"
        curl -f "-#" -L -S -s "$baseurl/$imagename" -o "$basedir/$imagename"
    fi
    if test "$validate_result" != "0"; then
        echo "checksum image $imagename"
        echo "$imagehash *$basedir/$imagename" | sha256sum --check
    fi
}


extract_casper_from_iso() {
    local iso_file iso_mount targetdir loopdev
    iso_file="$1"
    iso_mount="$2"
    targetdir="$3"
    echo "extract casper kernel,initrd,filesystem from $iso_file to $targetdir"

    as_root mkdir -p "$iso_mount"
    loopdev=$(as_root losetup --show -f "$iso_file")
    as_root mount "$loopdev" "$iso_mount"
    as_root mkdir -p "$targetdir/casper"
    as_root cp -a -t "$targetdir/casper" \
        "$iso_mount/casper/$kernel_name" \
        "$iso_mount/casper/$initrd_name" \
        $iso_mount/casper/filesystem*
    as_root cp -a -t "$targetdir/" "$iso_mount/.disk"
    as_root umount "$iso_mount"
    as_root losetup -d "$loopdev"
    as_root rmdir "$iso_mount"
}


show_grub_cfg() {
    local grub_root casper_livemedia uuid_volume
    grub_root="$1"
    casper_livemedia="$2"
    uuid_volume="$3"
    cat - << EOF
set timeout=2

insmod part_gpt
insmod diskfilter
insmod mdraid1x
insmod fat
insmod ext2
insmod gzio

# casper recovery
menuentry "Ubuntu $distroversion Casper Recovery" {
    set root="$grub_root"
    search --no-floppy --fs-uuid --set=root --hint="$grub_root" "$uuid_volume"
    linux  /casper/$kernel_name boot=casper toram textonly $casper_livemedia noeject noprompt ds=nocloud cloud-init=enabled
    initrd /casper/$initrd_name
}
EOF
}


show_grub_d_recovery() {
    local grub_root casper_livemedia uuid_volume
    grub_root="$1"
    casper_livemedia="$2"
    uuid_volume="$3"
    cat - << EOF
#!/bin/sh
exec tail -n +3 \$0
# live system recovery
menuentry "Ubuntu $distroversion Casper Recovery" --id "recovery" {
    set root="$grub_root"
    search --no-floppy --fs-uuid --set=root --hint="$grub_root" "$uuid_volume"
    linux  /casper/$kernel_name boot=casper toram textonly $casper_livemedia noeject noprompt ds=nocloud cloud-init=enabled
    initrd /casper/$initrd_name
}

fallback=recovery

EOF

}


setup_mountpoint() {
    local mountpoint="$1"
    as_root mount --rbind /dev "$mountpoint/dev"
    as_root mount --make-rslave "$mountpoint/dev"
    as_root mount proc-live -t proc "$mountpoint/proc"
    as_root mount sysfs-live -t sysfs "$mountpoint/sys"
    as_root mount -t tmpfs none "$mountpoint/tmp"
    as_root mount -t tmpfs none "$mountpoint/var/lib/apt"
    as_root mount -t tmpfs none "$mountpoint/var/cache/apt"
}


teardown_mountpoint() {
    # Reverse the operations from setup_mountpoint
    local mountpoint="$1"
    # ensure we have exactly one trailing slash, and escape all slashes for awk
    mountpoint_match=$(echo "$mountpoint" | sed -e's,/$,,; s,/,\\/,g;')'\/'
    # sort -r ensures that deeper mountpoints are unmounted first
    for submount in $(awk </proc/self/mounts "\$2 ~ /$mountpoint_match/ \
                      { print \$2 }" | LC_ALL=C sort -r); do
        echo "unmounting $submount"
        as_root mount --make-private "$submount"
        as_root umount "$submount"
    done
}


umount_loop() {
    dir=$1
    ! mountpoint -q -- "$dir" && return
    # limitation: can only find processes using mountpoint before unmount
    # https://github.com/karelzak/util-linux/issues/484
    open_files=$(as_root lsof "$dir" 2>/dev/null || true)
    # Exits non-zero if object not in use
    # Avoid "WARNING: can't stat() fuse.gvfsd-fuse file system /run/user/1000/gvfs"
    mountpoints=$(awk -v dir="$dir" 'BEGIN{dir="^" dir "$"} $2 ~ dir {print $1}' /etc/mtab)

    while as_root "umount" -Rdl -- "$dir"; do # returns false when already unmounted
      # -R  Recursive unmount
      # -d  Remove the associated loop device
      # -l  Lazy remove filesystem references immediately
      # -v  Verbose
      sleep 0.01;
    done

    if loop_dev=$(losetup -a --list | grep --fixed-strings "$mountpoints"); then
      printf "WARNING: loop device remains after unmount:\n%s\n" "$loop_dev" 2>&1
      printf "%s\n" "$open_files" 2>&1
    fi
}


create_installer_squashfs() { # src_squash dest_squash workdir kernel_version
    local src_squash=$1
    local dest_squash=$2
    local workdir=$3
    local kernel_version=$4
    local src_mount=$workdir/filesystem.squashfs.dir
    local dest_mount=$workdir/installer.squashfs.dir
    local overlay_dir=$workdir/overlay
    local overlay_work_dir=$workdir/work
    local loopdev

    cd "$workdir"
    as_root mkdir -p "$src_mount" "$dest_mount" "$overlay_dir" "$overlay_work_dir"

    # mount source squash, mount overlay, mount bind mounts
    loopdev=$(as_root losetup --show -f "$src_squash")
    as_root mount -t squashfs "$loopdev" "$src_mount"
    as_root mount -t overlay overlay \
        -olowerdir="$src_mount",upperdir="$overlay_dir",workdir="$overlay_work_dir" \
        "$dest_mount"
    setup_mountpoint "$dest_mount"

    # customize for running in chroot
    as_root /bin/bash << POSTMOUNTEOF
set -x

# save original resolv.conf, copy current resolv.conf from running system
if test -e "$dest_mount/etc/resolv.conf"; then
    cp -f "$dest_mount/etc/resolv.conf" resolv.conf.tmp
fi
cp -L --remove-destination /etc/resolv.conf "$dest_mount/etc/resolv.conf"

# allow installing software without additional setup (eg. write out kernel)
cat > "$dest_mount/usr/sbin/policy-rc.d" << EOF
#!/bin/sh
echo "All runlevel operations denied by policy" >&2
exit 101
EOF
chmod 0755 "$dest_mount/usr/sbin/policy-rc.d"

# create dummy update-initramfs
cat > $workdir/update-initramfs << EOF
#! /bin/sh
echo "update-initramfs: diverted" >&2
exit 0
EOF
chmod +x $workdir/update-initramfs

# create exit early version of systemd-detect-virt, will be copied after dpkg diversion
echo "exit 1" > $workdir/systemd-detect-virt
chmod +x $workdir/systemd-detect-virt

POSTMOUNTEOF

    # diverts
    for i in /etc/grub.d/30_os-prober /usr/sbin/update-initramfs /usr/bin/systemd-detect-virt; do
        deb_chroot "$dest_mount" dpkg-divert --local --rename \
            --divert $i.dpkg-divert --add $i
    done
    as_root cp -f $workdir/update-initramfs "$dest_mount/usr/sbin/update-initramfs"
    as_root cp -f $workdir/systemd-detect-virt "$dest_mount/usr/bin/systemd-detect-virt"

    # Make installer layer
    # Install casper for live session magic and other selected packages
    packages="lupin-casper linux-firmware $(get_default_packages)"
    if test "$kernel_version" != ""; then
        packages="$packages linux-modules-$kernel_version linux-modules-extra-$kernel_version linux-headers-$kernel_version"
    fi
    deb_chroot "$dest_mount" apt-get update
    deb_chroot "$dest_mount" apt-get -y install $packages
    deb_chroot "$dest_mount" apt-get clean

    # remove diverts
    deb_chroot "$dest_mount" rm -f /usr/sbin/update-initramfs  /usr/bin/systemd-detect-virt
    for i in /etc/grub.d/30_os-prober /usr/sbin/update-initramfs /usr/bin/systemd-detect-virt; do
        deb_chroot "$dest_mount" dpkg-divert --local --rename --remove $i
    done

    # unmount bind mounts, unmount overlay, unmount source squashfs
    teardown_mountpoint "$dest_mount"
    as_root umount "$dest_mount"
    umount_loop "$src_mount"

    # cleanup and finalize overlay
    as_root /bin/bash << POSTUNMOUNTEOF
set -x

# remove temporary created files in workdir
for i in systemd-detect-virt update-initramfs resolv.conf.tmp; do
    if test -e $workdir/$i; then rm -f $workdir/$i; fi
done

# remove temporary /etc/resolv.conf
if test -e $overlay_dir/etc/resolv.conf; then
    rm -f $overlay_dir/etc/resolv.conf
fi

# remove policy-rc.d runlevel override
if test -e $overlay_dir/usr/sbin/policy-rc.d; then
    rm $overlay_dir/usr/sbin/policy-rc.d
fi

#rm -rf $overlay_dir/run
rm -rf $overlay_dir/boot
if test -e "$overlay_dir/var/lib/dpkg/triggers"; then
    rm -rf "$overlay_dir/var/lib/dpkg/triggers"
fi

# remove casper script trying to mount any swap on startup
rm -f $overlay_dir/usr/share/initramfs-tools/scripts/casper-bottom/*swap

# keep lxd from snapd seeds
sed -i -e'N;/name: lxd/,+2d' $overlay_dir/var/lib/snapd/seed/seed.yaml

# wait until network is online
ln -s /bin/true $overlay_dir/lib/systemd/systemd-networkd-wait-online

# do not ratelimit journald
mkdir -p $overlay_dir/etc/systemd/journald.conf.d
printf '[Journal]\nRateLimitIntervalSec=0\n' \
    > $overlay_dir/etc/systemd/journald.conf.d/no-rate-limit.conf

# copied from original installer.squashfs, in the hope to make snapd working
mkdir -p $overlay_dir/lib/systemd/system/snapd.service.d
printf '[Service]\nEnvironment=SNAP_REEXEC=0\n' \
    > $overlay_dir/lib/systemd/system/snapd.service.d/no-reexec.conf

# remove other stray files
for i in \
    initrd.img initrd.img.old vmlinuz vmlinuz.old \
    etc/.pwd.lock etc/shadow- etc/passwd- \
    etc/ssh/ssh_host_ecdsa_key etc/ssh/ssh_host_ecdsa_key.pub \
    etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub \
    etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub \
    var/lib/dpkg/lock var/lib/dpkg/lock-frontend var/lib/dpkg/status-old \
    var/lib/dpkg/triggers/Lock \
    var/lib/update-notifier/updates-available; do
    if test -e $overlay_dir/\$i; then
        rm -f $overlay_dir/\$i
    fi
done
POSTUNMOUNTEOF

    # create squashfs from overlay
    cd "$overlay_dir"
    if test -e "${dest_squash}"; then as_root rm -f ${dest_squash}; fi
    echo "mksquashfs ${dest_squash}"
    as_root mksquashfs . "${dest_squash}" -no-progress -xattrs -comp xz
    as_root chown "$(id -u -n):$(id -u -n)" "${dest_squash}"
    cd "$workdir"

    # remove work files
    as_root rm -rf "$overlay_dir"
    as_root rm -rf "$overlay_work_dir"
}


create_liveimage() {
    local download_path build_path liveimage recoverysquash
    download_path="$1"
    build_path="$download_path/build"
    installer_path="$download_path/installer"
    liveimage="$2"
    recoverysquash="$3"

    # download image
    mkdir -p "$download_path"
    download_casper_image "$download_path" "$baseurl" "$imagename"

    # extract casper
    as_root mkdir -p "$build_path/casper" "$build_path/isolinux" "$installer_path"
    extract_casper_from_iso "$download_path/$imagename" "$download_path/isomount" "$build_path"
    as_root chmod -R u+w "$build_path"
    kernel_version=$(file "$build_path/casper/$kernel_name" -b | sed -r "s/^.+version ([^ ]+) .+/\1/g")

    # add installer.squashfs (tools that are needed for recovery, eg. ssh)
    create_installer_squashfs "$build_path/casper/filesystem.squashfs" \
        "$build_path/casper/installer.squashfs" "$installer_path" "$kernel_version"

    # add recovery settings squashfs if set as calling parameter
    if test "$recoverysquash" != ""; then
      # add recovery.squashfs if specified
      as_root cp "$recoverysquash" "$build_path/casper/recovery.squashfs"
    fi

    # BIOS booting: make bios syslinux config
    as_root tee "$build_path/isolinux/isolinux.cfg" << EOF
say "machine-bootstrap - bootstrap-0-liveimage"
default bootstrap
label bootstrap
    kernel /casper/$kernel_name
    initrd /casper/$initrd_name
    append boot=casper toram textonly noeject noprompt ds=nocloud
EOF
    as_root cp "$bios_isolinux" "$build_path/isolinux/isolinux.bin"
    as_root cp "$bios_ldlinux" "$build_path/isolinux/ldlinux.c32"

    # EFI booting: make ESP partition image (efi/boot/bootx64.efi)
    esp_img="$build_path/isolinux/esp.img"
    esp_mount="$download_path/espmount"
    if mountpoint -q "$esp_mount"; then as_root umount "$esp_mount"; fi
    if test -e "$esp_img"; then as_root rm "$esp_img"; fi
    if test -e "$esp_mount"; then as_root rmdir "$esp_mount"; fi
    mkdir -p "$esp_mount"
    esp_size=0
    for i in "$build_path/casper/$kernel_name" \
        "$build_path/casper/$initrd_name" $efi_syslinux $efi_ldlinux; do
        esp_size=$(( esp_size+ ($(stat -c %b*%B "$i")/1024) ))
    done
    as_root truncate -s $((esp_size+100*1024))k "$esp_img"
    mkfs.msdos -v -F 16 -f 1 -M 0xF0 -r 112 -R 1 -S 512 -s 8 "$esp_img"
    as_root mount "$esp_img" "$esp_mount" -o uid=$(id -u)
    mkdir -p "$esp_mount/boot" "$esp_mount/syslinux" "$esp_mount/efi/boot"
    cp $efi_syslinux "$esp_mount/efi/boot/bootx64.efi"
    cp $efi_ldlinux "$esp_mount/efi/boot/"
    cp "$build_path/casper/$kernel_name" "$esp_mount/boot/"
    cp "$build_path/casper/$initrd_name" "$esp_mount/boot/"
    cat "$build_path/isolinux/isolinux.cfg" | sed -r "s#/casper#/boot#g" > "$esp_mount/syslinux/syslinux.cfg"
    as_root umount "$esp_mount"
    if test -e "$esp_mount"; then as_root rmdir "$esp_mount"; fi
    as_root syslinux --install --directory syslinux/ "$esp_img"

    # make iso
    xorrisofs -o "$liveimage" \
        -r -isohybrid-mbr "$bios_hybridmbr" \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin -no-emul-boot \
        -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e isolinux/esp.img -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$build_path"

    # remove build files
    as_root rm -r "$build_path"
    as_root rm -r "$installer_path"
}


# parse args
if test "$1" = "--check-req"; then shift; check_requisites "$@"; exit 0; fi
if test "$1" != "download" -a "$1" != "extract" \
    -a "$1" != "show" -a "$1" != "create"; then usage; fi
cmd="$1"
shift

# if http_proxy is set, reexport for sub-processes
if test "$http_proxy" != ""; then export http_proxy; fi

for i in . ..; do
    if test -e "$self_path/$i/bootstrap-library.sh"; then
        . "$self_path/$i/bootstrap-library.sh"
    fi
done

if test "$cmd" = "create"; then
    if test "$1" = "liveimage"; then
        shift
        if test "$2" = ""; then usage; fi
        downloaddir="$1"
        liveimage="$2"
        shift 2
        recoverysquash=""
        if test "$1" != ""; then recoverysquash="$1"; shift; fi
        check_requisites
        create_liveimage "$downloaddir" "$liveimage" "$recoverysquash"
    elif test "$1" = "installer-addon"; then
        shift
        src_squash="$1"
        dest_squash="$2"
        work_dir="$3"
        kernel_version="$4"
        if test "$work_dir" = "" -o ! -e "$src_squash" -o ! -e "$work_dir"; then usage; fi
        check_requisites
        create_installer_squashfs "$src_squash" "$dest_squash" "$work_dir" "$kernel_version"
    fi
elif test "$cmd" = "download"; then
    if test "$1" = ""; then usage; fi
    downloaddir="$1"
    shift
    check_requisites download
    download_casper_image "$downloaddir" "$baseurl" "$imagename"
elif test "$cmd" = "extract"; then
    if test "$2" = ""; then usage; fi
    downloaddir="$1"
    targetdir="$2"
    shift 2
    extract_casper_from_iso "$downloaddir/$imagename" "$downloaddir/isomount" "$targetdir"
elif test "$cmd" = "show"; then
    if test "$1" = "imagename"; then
        echo "$imagename"
    elif test "$1" = "keyfile"; then
        echo "$cdimage_keyfile"
    elif test "$1" = "kernel_version"; then
        targetdir=$2
        if test ! -e "$targetdir/$kernel_name"; then
            echo "error: $targetdir/$kernel_name not existing"
            usage
        fi
        kernel_version=$(file "$targetdir/$kernel_name" -b | sed -r "s/^.+version ([^ ]+) .+/\1/g")
        echo "$kernel_version"
    elif test "$1" = "grub.cfg" -o "$1" = "grub.d/recovery"; then
        if test "$4" = ""; then usage; fi
        show_grub="$1"
        grub_root="$2"
        casper_livemedia="$3"
        uuid_volume="$4"
        shift 4
        if test "$show_grub" = "grub.cfg"; then
            show_grub_cfg "$grub_root" "$casper_livemedia" "$uuid_volume"
        else
            show_grub_d_recovery "$grub_root" "$casper_livemedia" "$uuid_volume"
        fi
    fi
fi
