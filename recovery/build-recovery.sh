#!/bin/sh
set -e
set -x

# Default Recovery Image Base
baseurl="http://old-releases.ubuntu.com/releases/18.04.1"
imagename="ubuntu-18.04.1-live-server-amd64.iso"


usage() {

    cat << EOF
$0 create <downloaddir> <targetdir>
$0 show grub.cfg        <grub_root> <casper_livemedia> <uuid_boot>
$0 show grub.d/recovery <grub_root> <casper_livemedia> <uuid_boot>
$0 show isolinux

EOF
    exit 1
}


download_casper_image() {
    local basedir baseurl gpghome imagename imagehash real_fingerprint
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

    echo "check if checksum files are signed with correct key"
    gpgv --keyring="$basedir/$cdimage_keyfile" "$basedir/SHA256SUMS.gpg" "$basedir/SHA256SUMS"
    fixme currently exits 2
    imagehash=$(cat "$basedir/SHA256SUMS" | grep "$imagename" | sed -r "s/^([^ ]+) \*.+/\1/g")

    if test -e "$basedir/$imagename"; then
        if $(echo "$imagehash *$basedir/$imagename" | sha256sum --check); then
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
    echo "checksum image $imagename"
    echo "$imagehash *$basedir/$imagename" | sha256sum --check

}


extract_casper_iso() {
    local iso_file iso_mount targetdir
    # iso_mount=/mnt/iso
    # targetdir=/mnt/boot
    iso_file="$1"
    iso_mount="$2"
    targetdir="$3"
    echo "extract casper kernel,initrd,filesystem from $iso_file to $targetdir"

    mkdir -p "$iso_mount"
    mount -o loop "$iso_file" "$iso_mount"
    mkdir -p "$targetdir/casper"
    cp -a -t "$targetdir/casper" $iso_mount/casper/filesystem*
    cp -a -t "$targetdir/casper" "$iso_mount/casper/initrd"
    cp -a -t "$targetdir/casper" "$iso_mount/casper/vmlinuz"
    cp -a -t "$targetdir/"       "$iso_mount/.disk"
    umount "$iso_mount"
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


show_isolinux() {
    cat - << EOF
say "bootstrap-machine bootstrap-0-liveimage, you have 3 seconds to abort loading"
prompt 3
default bootstrap
label bootstrap
    kernel /casper/vmlinuz
    initrd /casper/initrd
    append boot=casper toram textonly $casper_livemedia noeject noprompt ds=nocloud
EOF
}



# parse args
if test "$1" != "create" -a "$1" != "show"; then usage; fi
cmd="$1"
shift

if test "$cmd" = "create"; then
    if test "$2" = ""; then usage; fi
    downloaddir="$1"
    targetdir="$2"
    shift 2
    for i in gpg gpgv curl; do
        if ! which $i > /dev/null; then
            echo "Error: needed program $i not found."
            echo "execute 'apt-get install gnupg gpgv curl'"
            exit 1
        fi
    done
    download_casper_image "$downloaddir" "$baseurl" "$imagename"
    extract_casper_iso "$downloaddir/$imagename" "$downloaddir/isomount" "$targetdir"
elif test "$cmd" = "show"; then
    if test "$1" = "isolinux"; then
        shift
        show_isolinux
    else
        if test "$1" != "grub.cfg" -a "$1" != "grub.d/recovery"; then usage; fi
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
