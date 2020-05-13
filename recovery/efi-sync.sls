
/etc/recovery/efi-sync.sh:
  file.managed:
    - source: salt://machine-bootstrap/recovery/efi-sync.sh
    - filemode: 0755

/etc/systemd/system/efi-sync.path:
  file.managed:
    - contents: |
        [Unit]
        Description=Copy EFI to EFI2 System Partition

        [Path]
        PathChanged=/efi

        [Install]
        WantedBy=multi-user.target
        WantedBy=system-update.target

/etc/systemd/system/efi-sync.service:
  file.managed:
    - contents: |
        [Unit]
        Description=Copy EFI to EFI2 System Partition
        RequiresMountsFor=/efi
        RequiresMountsFor=/efi2

        [Service]
        Type=oneshot
        ExecStart=/etc/recovery/efi-sync.sh --yes
