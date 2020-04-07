{# if /etc/recovery already exists
update recovery casper and recovery squashfs if info updated #}

{% for f in ['build-recovery.sh', 'efi-sync.sh', 'recovery-mount.sh', 'recovery-unmount.sh', 'storage-invalidate-mirror.sh', 'storage-replace-mirror.sh', 'update-recovery-squashfs.sh'] %}
/etc/recovery/{{ f }}:
  file.managed:
    source: salt://machine-bootstrap/{{ f }}
    filemode: 0755

update-recovery-squashfs:
  cmd.run:
    - onlyif: test $(sha256sum -b /efi/casper/recovery.squashfs)  != $(update-recovery-squashfs.sh --host --output /dev/stdout | sha256sum -b)
    - name: update-recovery-squashfs.sh --host

update-recovery-casper:
  cmd.run:
    - onlyif: test "$(build-recovery.sh show imageurl)" != "$(cat /efi/.disk/download_url)"
    - name: fixme: build-recovery.sh download, extract, move with old, sync efi
