{#
+ update files
+ if zfs was updated, or files:
  + regenerate recovery-squashfs
+ if casper can be updated
  + update casper
#}

{% from "machine-bootstrap/node/defaults.jinja" import settings %}

/etc/recovery/netplan.yaml:
  file.managed:
    - contents: |
{{ settings.netplan_recovery|yaml(false)|indent(8,True) }}

{% for f in ['build-recovery.sh', 'efi-sync.sh', 'recovery-mount.sh', 'recovery-unmount.sh', 'storage-invalidate-mirror.sh', 'storage-replace-mirror.sh', 'update-recovery-squashfs.sh'] %}
/etc/recovery/{{ f }}:
  file.managed:
    - source: salt://machine-bootstrap/{{ f }}
    - filemode: 0755
    - require_in:
      - cmd: update-recovery-squashfs
      - cmd: update-recovery-casper
{% endfor %}

fixme update-recovery-squashfs.sh is not stdout capable
update-recovery-squashfs:
  cmd.run:
    - name: update-recovery-squashfs.sh --host
    - onlyif: test $(sha256sum -b /efi/casper/recovery.squashfs)  != $(update-recovery-squashfs.sh --host --output /dev/stdout | sha256sum -b)
    - require:
      - sls: .zfs

update-recovery-casper:
  cmd.run:
    - onlyif: test "$(build-recovery.sh show imageurl)" != "$(cat /efi/.disk/download_url)"
    - name: fixme: build-recovery.sh download, extract, move with old, sync efi
    - require:
      - sls: zfs
