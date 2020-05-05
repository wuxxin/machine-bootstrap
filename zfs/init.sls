{#
+ update all files
+ if machine-config says frankenstein=true
  + test which customized zfs we have runninng
  + if there is a newer version (or not installed so far)
    + build and update running system
    + update recovery-squashfs

https://github.com/vpsfreecz/zfs/tree/vpsadminos-master-2004060


#}

{% for f in ['build-custom-zfs.sh', 'customize-running-system.sh'] %}
/etc/recovery/zfs/{{ f }}:
  file.managed:
    - source: salt://machine-bootstrap/{{ f }}
    - filemode: "0755"
    - makedirs: true
{% endfor %}

{% for p in salt['cmd.run_stdout'](
  'find '+ grains['project_basepath']+
    '/machine-bootstrap/zfs/ -name "*.patch" -type f -printf "%f\n" | sort -n',
  python_shell=True) %}
/etc/recovery/zfs/{{ p }}
  file.managed:
    - source: salt://machine-bootstrap/zfs/{{ p }}
{% endfor %}
