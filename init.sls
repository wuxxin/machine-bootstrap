{% if grains['os'] == 'Ubuntu' %}
include:
  - machine-bootstrap.dracut
  - machine-bootstrap.recovery

machine-bootstrap-ubuntu-installed:
  test.nop:
    - require:
      - sls: machine-bootstrap.dracut
      - sls: machine-bootstrap.recovery
{% endif %}

{% set efi_src= '/boot' %}
{% set efi_dest= '/efi2' %}
{% set efi_sync= false %}
{# FIXME: switch efi_src to /efi if there also is boot, set efi_sync=true if /efi2 partition exists #}

bootstrap-library.sh:
  file.managed:
    - name: /usr/local/lib/machine-bootstrap/bootstrap-library.sh
    - source: salt://machine-bootstrap/bootstrap-library.sh
    - makedirs: true

{% for f in ['storage-mount.sh', 'storage-unmount.sh',
 'storage-invalidate-mirror.sh', 'storage-replace-mirror.sh'] %}
{{ f }}:
  file.managed:
    - name: /usr/local/lib/machine-bootstrap/{{ f }}
    - source: salt://machine-bootstrap/storage/{{ f }}
    - filemode: 0755
    - require:
      - file: bootstrap-library.sh
{% endfor %}

storage-efi-sync.sh:
  file.managed:
    - name: /usr/local/lib/machine-bootstrap/storage-efi-sync.sh
    - contents: |
        #!/bin/bash
        set -e
        self_path=$(dirname "$(readlink -e "$0")")
        . "$self_path/bootstrap-library.sh"
        efi_src="$1"; efi_dest="$2"
        if test "$3" != "--yes"; then
            printf "Usage: $0 <efi_src> <efi_dest> --yes
        if both <efi_src> and <efi_dest> are mountpoints, sync files from <efi_src> to <efi_dest>
        rsync all files, copy and modify grub related files, binary duplicate  grub/grubenv
        "
            exit 1
        fi
        if ! mountpoint -q "${efi_src}"; then
            echo "did NOT sync efi: no efi_src mount at ${efi_src}"
            exit 0
        fi
        if ! mountpoint -q "${efi_dest}"; then
            echo "did NOT sync efi: no efi_dest mount at ${efi_dest}"
            exit 0
        fi
        efi_sync "${efi_src}" "${efi_dest}"
    - filemode: 0755
    - require:
      - file: bootstrap-library.sh

efi-sync.service:
  file:
    - name: /etc/systemd/system/efi-sync.service
    - managed
    - contents: |
        [Unit]
        Description=Copy EFI to EFI2 System Partition
        RequiresMountsFor={{ efi_src }}
        RequiresMountsFor={{ efi_dest }}

        [Service]
        Type=oneshot
        ExecStart=/usr/local/lib/machine-bootstrap/storage-efi-sync.sh {{ efi_src }} {{ efi_dest }} --yes
    - require:
      - file: /usr/local/lib/machine-bootstrap/storage-efi-sync.sh
  service:
    - {{ 'enabled' if efi_sync else 'disabled' }}
    - require:
      - file: efi-sync.service
  cmd.run:
    - name: systemctl daemon-reload
    - onchange:
      - file: efi-sync.service
    - require:
      - service: efi-sync.service

efi-sync.path:
  file:
    - name: /etc/systemd/system/efi-sync.path
    - managed
    - contents: |
        [Unit]
        Description=Copy EFI to EFI2 System Partition

        [Path]
        PathChanged={{ efi_src }}

        [Install]
        WantedBy=multi-user.target
        WantedBy=system-update.target
    - require:
      - file: /etc/systemd/system/efi-sync.service
  service:
    - {{ 'enabled' if efi_sync else 'disabled' }}
    - require:
      - file: efi-sync.path
  cmd.run:
    - name: systemctl daemon-reload
    - onchange:
      - file: efi-sync.path
    - require:
      - service: efi-sync.path
