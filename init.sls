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

/usr/local/lib/machine-bootstrap/bootstrap-library.sh:
  file.managed:
    - source: salt://machine-bootstrap/bootstrap-library.sh
    - makedirs: true

{#
/usr/local/lib/machine-bootstrap/efi-sync.sh:
  file.managed:
    - filemode: 0755
    - require:
      - file: /usr/local/lib/machine-bootstrap/bootstrap-library.sh

/etc/systemd/system/efi-sync.service:
  file.managed:
    - require:
      - file: /usr/local/lib/machine-bootstrap/efi-sync.sh

/etc/systemd/system/efi-sync.path:
  file.managed:
    - require:
      - file: /etc/systemd/system/efi-sync.service
#}
