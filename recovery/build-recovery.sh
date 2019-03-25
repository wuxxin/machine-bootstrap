#!/bin/sh
set -e
# set -x

# Default Recovery Image Base
baseurl="http://old-releases.ubuntu.com/releases/18.04.1"
imagename="ubuntu-18.04.1-live-server-amd64.iso"

bios_isolinux="/usr/lib/ISOLINUX/isolinux.bin"
bios_hybridmbr="/usr/lib/ISOLINUX/isohdpfx.bin"
bios_ldlinux="/usr/lib/syslinux/modules/bios/ldlinux.c32"
efi_syslinux="/usr/lib/SYSLINUX.EFI/efi64/syslinux.efi"
efi_ldlinux="/usr/lib/syslinux/modules/efi64/ldlinux.e64"


usage() {
    cat << EOF
$0 download             <downloaddir>
$0 extract              <downloaddir> <targetdir>
$0 create-liveimage     <downloaddir> <targetiso> [<recovery.squashfs>]
$0 show grub.cfg        <grub_root> <casper_livemedia> <uuid_boot>
$0 show grub.d/recovery <grub_root> <casper_livemedia> <uuid_boot>

$0 show imagename
    returns expected source image for recovery building
$0 --check-req
    confirm all needed requisites are present, exit 0 if true

EOF
    exit 1
}


as_root() {
    if test "$(id -u)" != "0"; then sudo $@; else $@; fi
}


check_requisites() {
    local need_install i
    need_install=false
    if test "$1" = "download"; then
        for i in curl gpg gpgv; do
            if ! which $i > /dev/null; then
                echo "Error: needed program $i not found."
                echo "execute 'apt-get install curl gnupg gpgv'"
                exit 1
            fi
        done
    else
        for i in $bios_isolinux $bios_hybridmbr $bios_ldlinux $efi_syslinux $efi_ldlinux; do
            if test ! -e "$i"; then
                echo "Error: $(basename $i) not found"
                need_install=true
            fi
        done
        for i in xorrisofs syslinux mkfs.msdos curl gpg gpgv; do
            if ! which $i > /dev/null; then
                echo "Error: needed program $i not found."
                need_install=true
            fi
        done
        if $need_install; then
            echo "execute 'apt-get install isolinux syslinux syslinux-efi syslinux-common xorriso dosfstools curl gnupg gpgv'"
            exit 1
        fi
    fi
}


download_casper_image() {
    local basedir baseurl imagename imagehash validate_result real_fingerprint gpghome
    local cdimage_keyid cdimage_fingerprint cdimage_keyname cdimage_keyfile cdimage_keyserver
    basedir="$1"
    baseurl="$2"
    imagename="$3"
    # gpg key that should have signed the image
    cdimage_keyid="D94AA3F0EFE21092"
    cdimage_fingerprint="843938DF228D22F7B3742BC0D94AA3F0EFE21092"
    cdimage_keyname="cdimage@ubuntu.com"
    cdimage_keyfile="${cdimage_keyname}.gpg"
    cdimage_keyserver="keyserver.ubuntu.com"
    gpghome="$basedir/gpghome"

    echo "get gpg key $cdimage_keyname ($cdimage_keyid)"
    if test -e "$gpghome"; then rm -rf "$gpghome"; fi
    mkdir -m 0700 "$gpghome"
    gpg --quiet --homedir "$gpghome" --batch --yes --keyserver $cdimage_keyserver --recv-keys $cdimage_keyid
    real_fingerprint=$(LC_MESSAGES=POSIX gpg --quiet --homedir "$gpghome" --keyid-format long --fingerprint $cdimage_keyid | grep "fingerprint = " | sed -r "s/.*= (.*)/\1/g" | tr -d " ")
    if test "$cdimage_fingerprint" != "$real_fingerprint"; then
        echo "error: fingerprint mismatch: expected: $cdimage_fingerprint , real: $real_fingerprint"
        exit 1
    fi
    gpg --quiet --homedir "$gpghome" --export $cdimage_keyid > "$basedir/$cdimage_keyfile"
    rm -r "$gpghome"

    echo "get checksum files for image"
    for i in SHA256SUMS SHA256SUMS.gpg; do
        echo "get $baseurl/$i"
        curl -L -s "$baseurl/$i" > "$basedir/$i"
    done

    echo "validate that checksum files are signed with correct key"
    gpgv_result=$(LC_MESSAGES=POSIX gpgv --keyring="$basedir/$cdimage_keyfile" "$basedir/SHA256SUMS.gpg" "$basedir/SHA256SUMS" 2>&1 >/dev/null || true)
    if ! $(printf "%s" "$gpgv_result" | \
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
        curl -f -# -L -s "$baseurl/$imagename" -o "$basedir/$imagename"
    fi
    if test "$validate_result" != "0"; then
        echo "checksum image $imagename"
        echo "$imagehash *$basedir/$imagename" | sha256sum --check
    fi
}


extract_casper_iso() {
    local iso_file iso_mount targetdir
    iso_file="$1"
    iso_mount="$2"
    targetdir="$3"
    echo "extract casper kernel,initrd,filesystem from $iso_file to $targetdir"

    mkdir -p "$iso_mount"
    as_root mount -o loop "$iso_file" "$iso_mount"
    mkdir -p "$targetdir/casper"
    cp -a -t "$targetdir/casper" $iso_mount/casper/filesystem*
    cp -a -t "$targetdir/casper" "$iso_mount/casper/initrd"
    cp -a -t "$targetdir/casper" "$iso_mount/casper/vmlinuz"
    cp -a -t "$targetdir/"       "$iso_mount/.disk"
    as_root umount "$iso_mount"
    rmdir "$iso_mount"
}


show_grub_cfg() {
    local grub_root casper_livemedia uuid_boot
    grub_root="$1"
    casper_livemedia="$2"
    uuid_boot="$3"
    cat - << EOF
set timeout=2

insmod part_gpt
insmod diskfilter
insmod mdraid1x
insmod ext2
insmod gzio

# casper recovery
menuentry "Ubuntu 18.04 Casper Recovery" {
    set root="$grub_root"
    search --no-floppy --fs-uuid --set=root --hint="$grub_root" "$uuid_boot"
    linux  /casper/vmlinuz boot=casper toram textonly $casper_livemedia noeject noprompt ds=nocloud
    initrd /casper/initrd
}
EOF
}


show_grub_d_recovery() {
    local grub_root casper_livemedia uuid_boot
    grub_root="$1"
    casper_livemedia="$2"
    uuid_boot="$3"
    cat - << EOF
#!/bin/sh
exec tail -n +3 \$0
# live system recovery
menuentry "Ubuntu 18.04 Casper Recovery" --id "recovery" {
    set root="$grub_root"
    search --no-floppy --fs-uuid --set=root --hint="$grub_root" "$uuid_boot"
    linux  /casper/vmlinuz boot=casper toram textonly $casper_livemedia noeject noprompt ds=nocloud
    initrd /casper/initrd
}

fallback=recovery

EOF

}


create_liveimage() {
      local download_path build_path liveimage recoverysquash
      download_path="$1"
      build_path="$download_path/build"
      liveimage="$2"
      recoverysquash="$3"
      mkdir -p "$download_path" "$build_path/casper" "$build_path/isolinux"

      # download image
      download_casper_image "$download_path" "$baseurl" "$imagename"
      if test "$recoverysquash" != ""; then
          # add recovery.squashfs if specified
          cp "$recoverysquash" "$build_path/casper/recovery.squashfs"
      fi

      # make bios syslinux config
      cat - > "$build_path/isolinux/isolinux.cfg" << EOF
say "bootstrap-machine bootstrap-0-liveimage"
default bootstrap
label bootstrap
    kernel /casper/vmlinuz
    initrd /casper/initrd
    append boot=casper toram textonly noeject noprompt ds=nocloud
EOF
      cp "$bios_isolinux" "$build_path/isolinux/isolinux.bin"
      cp "$bios_ldlinux" "$build_path/isolinux/ldlinux.c32"

      extract_casper_iso "$download_path/$imagename" "$download_path/isomount" "$build_path"
      as_root chown -R $(id -u):$(id -g) "$build_path"
      as_root chmod -R u+w "$build_path"

      # make ESP partition image (efi/boot/bootx64.efi)
      esp_img="$build_path/isolinux/esp.img"
      esp_mount="$download_path/espmount"
      if mountpoint -q "$esp_mount"; then as_root umount $esp_mount; fi
      if test -e "$esp_img"; then rm "$esp_img"; fi
      if test -e "$esp_mount"; then rmdir "$esp_mount"; fi
      mkdir -p "$esp_mount"
      esp_size=0
      for i in "$build_path/casper/vmlinuz" "$build_path/casper/initrd" $efi_syslinux $efi_ldlinux; do
          esp_size=$(( esp_size+ ($(stat -c %b*%B "$i")/1024) ))
      done
      truncate -s $((esp_size+256))k "$esp_img"
      mkfs.msdos -v -F 16 -f 1 -M 0xF0 -r 112 -R 1 -S 512 -s 8 "$esp_img"
      as_root mount "$esp_img" "$esp_mount" -o uid=$(id -u)
      mkdir -p "$esp_mount/boot" "$esp_mount/syslinux" "$esp_mount/efi/boot"
      cp $efi_syslinux "$esp_mount/efi/boot/bootx64.efi"
      cp $efi_ldlinux "$esp_mount/efi/boot/"
      cp "$build_path/casper/initrd" "$esp_mount/boot/"
      cp "$build_path/casper/vmlinuz" "$esp_mount/boot/"
      cat "$build_path/isolinux/isolinux.cfg" | sed -r "s#/casper#/boot#g" > "$esp_mount/syslinux/syslinux.cfg"
      as_root umount "$esp_mount"
      if test -e "$esp_mount"; then rmdir "$esp_mount"; fi
      syslinux --install --directory syslinux/ "$esp_img"

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
      rm -r "$build_path"
}


# parse args
if test "$1" = "--check-req"; then check_requisites; exit 0; fi
if test "$1" != "download" -a "$1" != "extract" \
    -a "$1" != "show" -a "$1" != "create-liveimage"; then usage; fi
cmd="$1"
shift

if test "$cmd" = "create-liveimage"; then
    if test "$2" = ""; then usage; fi
    downloaddir="$1"
    liveimage="$2"
    shift 2
    recoverysquash=""
    if test "$1" != ""; then recoverysquash="$1"; shift; fi
    check_requisites
    create_liveimage "$downloaddir" "$liveimage" "$recoverysquash"
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
    extract_casper_iso "$downloaddir/$imagename" "$downloaddir/isomount" "$targetdir"
elif test "$cmd" = "show"; then
    if test "$1" = "imagename"; then
        echo "$imagename"
    elif test "$1" = "grub.cfg" -o "$1" = "grub.d/recovery"; then
        if test "$4" = ""; then usage; fi
        show_grub="$1"
        grub_root="$2"
        casper_livemedia="$3"
        uuid_boot="$4"
        shift 4
        if test "$show_grub" = "grub.cfg"; then
            show_grub_cfg "$grub_root" "$casper_livemedia" "$uuid_boot"
        else
            show_grub_d_recovery "$grub_root" "$casper_livemedia" "$uuid_boot"
        fi
    fi
fi
