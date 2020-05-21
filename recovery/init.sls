include:
  - machine-bootstrap.initrd
  - machine-bootstrap.recovery.efi-sync

{% set squashfs_path = '/efi/casper/recovery.squashfs' %}
{% set squashfs_files_path = squashfs_path+ '.files.sha256sum' %}
{% set hash_new = '/etc/recovery/update-recovery-squashfs.sh --host --output-manifest | sha256sum | cut -d " " -f 1' %}
{% set hash_old = 'if test -e '+ squashfs_files_path+ '; then cat '+ squashfs_files_path+ '| sha256sum | cut -d " " -f 1; else echo "unknown"; fi' %}
{% set recovery_version_old = salt['cmd.run_stdout']('if test -e /etc/recovery/recovery_version; then cat /etc/recovery/recovery_version; else echo "none"; fi', python_shell=true) %}
{% set recovery_netplan_path = grains['project_basepath']+ '/config/netplan.yaml' %}

{% if salt['file.file_exists'](recovery_netplan_path) %}
/etc/recovery/netplan.yaml:
  file.managed:
    - contents: |
{{ salt['cmd.run_stdout']('cat '+ recovery_netplan_path)|indent(8,True) }}
    - require_in:
      - cmd: update-recovery-squashfs
{% else %}
missing_recovery_netplan:
  test.show_notification:
    - text: Error, missing recovery netplan on {{ recovery_netplan_path }}
/etc/recovery/netplan.yaml:
  test.fail_without_changes:
    - require_in:
      - cmd: update-recovery-squashfs
{% endif %}

/etc/recovery/bootstrap-library.sh:
  file.managed:
    - source: salt://machine-bootstrap/bootstrap-library.sh
    - require_in:
      - cmd: update-recovery-squashfs

{% for f in ['build-recovery.sh', 'recovery-mount.sh', 'recovery-unmount.sh',
  'storage-invalidate-mirror.sh', 'storage-replace-mirror.sh', 'update-recovery-squashfs.sh'] %}
/etc/recovery/{{ f }}:
  file.managed:
    - source: salt://machine-bootstrap/recovery/{{ f }}
    - filemode: 0755
    - require_in:
      - cmd: update-recovery-squashfs
      - cmd: update-recovery-casper
{% endfor %}

update-recovery-squashfs:
  cmd.run:
    - onlyif: test "$({{ hash_new }})" != "$({{ hash_old }})"
    - name: /etc/recovery/update-recovery-squashfs.sh --host
    - require:
      - sls: machine-bootstrap.recovery.efi-sync

update-recovery-casper:
  cmd.run:
    - onlyif: test "$(/etc/recovery/build-recovery.sh show recovery_version)" != "{{ recovery_version_old }}"
    - name: |
        set -e
        /etc/recovery/build-recovery.sh download /var/tmp/build-recovery
        /etc/recovery/build-recovery.sh extract /var/tmp/build-recovery /boot
        EFI_PART=$(find /dev/disk/by-partlabel/ -type l | \
          sort | grep -E "EFI[12]?$" | tr "\n" " " | awk '{print $1;}')
        EFI_NR=$(cat "/sys/class/block/$(lsblk -no kname ${EFI_PART})/partition")
        EFI_GRUB="hd0,gpt${EFI_NR}"
        EFI_FS_UUID=$(blkid -s UUID -o value "$EFI_PART")
        CASPER_LIVEMEDIA=""
        mkdir -p /etc/grub.d
        /etc/recovery/build-recovery.sh show grub.d/recovery \
            "$EFI_GRUB" "$CASPER_LIVEMEDIA" "$EFI_FS_UUID" > /etc/grub.d/40_recovery
        chmod +x /etc/grub.d/40_recovery
        update-grub
        /etc/recovery/efi-sync.sh --yes
        /etc/recovery/build-recovery.sh show recovery_version > /etc/recovery/recovery_version
    - require:
      - sls: machine-bootstrap.recovery.efi-sync
