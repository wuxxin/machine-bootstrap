{#
+ update files for dracut initrd generation
+ update dracut initrd if files have changed
#}

{% for f in ['initramfs-sshd.service', 'module-setup.sh', 'sshd_config', 'stop-initramfs-sshd.sh'] %}
/usr/lib/dracut/modules.d/46sshd/{{ f }}:
  file.managed:
    - source: salt://machine-bootstrap/initrd/{{ f }}
  {%- if f.endswith('.sh') %}
    - mode: "755"
  {%- endif %}
    - onchanges_in:
      - cmd: update_dracut
{% endfor %}

update_dracut:
  cmd.run:
    - name: for v in $(find /boot -maxdepth 1 -name "vmlinuz*" | sed -r "s#^/boot/vmlinuz-(.+)#\\1#g"); do if test -e /lib/modules/$; then dracut --force /boot/initrd.img-${v} "${v}"; fi; done
