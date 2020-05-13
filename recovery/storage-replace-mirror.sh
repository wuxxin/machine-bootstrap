#!/bin/bash
set -e

. "$self_path/bootstrap-library.sh"

cat <<"EOF"
recovery-replace-mirror.sh --valid-data sourceserial --new-mirror targetserial

+ gdisk /dev/whateverhasdata | gdisk /dev/whatisnew
+ mkfs.fat -F 32 "${disk}-part${EFI_NR}"
+ copy contents of other efi part
+ reassamble mdadm-boot
+ reassemble luks *
  + luksformat luks-swap${disk} if existing
  + luksformat luks-root${disk}
+ reassamble mdadm-swap if existing
+ reassamble rpool
  + add spare to zfs mirror
+ update initramfs ?
+ grub-install newdisk

EOF

. "$self_path/bootstrap-library.sh"


exit 1
