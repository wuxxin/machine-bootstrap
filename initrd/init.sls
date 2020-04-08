{#

update initrd files for dracut initrd generation
update initrd if files changed

#}

{% for f in ['initramfs-sshd.service', 'module-setup.sh', 'sshd_config', 'stop-initramfs-sshd.sh'] %}
/usr/lib/dracut/modules.d/46sshd/{{ f }}:
  file.managed:
    - source: salt://machine-bootstrap/initrd/{{ f }}
    - onchanges_in:
      - cmd: update_dracut
{% endfor %}

update_dracut:
  cmd.run:
    - name: for v in $(find /boot -maxdepth 1 -name "vmlinuz*" | sed -r "s#^/boot/vmlinuz-(.+)#\\1#g"); do if test -e /lib/modules/$; then dracut --force /boot/initrd.img-${v} "${v}"; fi; done
