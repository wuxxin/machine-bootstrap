{% from "machine-bootstrap/node/defaults.jinja" import settings %}
include:
  - machine-bootstrap.node.hostname

{% macro add_internal_bridge(bridge_name, bridge_cidr) %}
  {% if salt['cmd.retcode']('which netplan') == 0 %}
bridge_{{ bridge_name }}:
  file.managed:
    - name: /etc/netplan/50-{{ bridge_name }}.yaml
    - makedirs: true
    - contents: |
        network:
          version: 2
          bridges:
            {{ bridge_name}}:
              parameters:
                stp: false
              addresses:
                - {{ bridge_cidr }}
              dhcp4: no
              dhcp6: no
  cmd.run:
    - name: netplan generate && netplan apply
    - onchanges:
      - file: bridge_{{ bridge_name }}

  {% else %}
bridge_{{ bridge_name }}:
  file.managed:
    - name: /etc/network/interfaces.d/{{ bridge_name }}.cfg
    - makedirs: true
    - contents: |
        auto {{ bridge_name }}
        iface {{ bridge_name }} inet static
            address {{ bridge_cidr|regex_replace ('([^/]+)/.+', '\\1') }}
            netmask {{ salt['network.convert_cidr'](bridge_cidr)['netmask'] }}
            bridge_fd 0
            bridge_maxwait 0
            bridge_ports none
            bridge_stp off
    - require:
      - pkg: bridge-utils
  cmd.run:
    - name: ifup {{ bridge_name }}
    - onchanges:
      - file: bridge_{{ bridge_name }}
  {% endif %}
{% endmacro %}

bridge-utils:
  pkg:
    - installed

{{ add_internal_bridge(settings.bridge_name, settings.bridge_cidr) }}

/etc/netplan/80-lan.yaml:
  file.managed:
    - contents: |
{{ intend(quy<, yaml)}}
  cmd.run:
    - name: netplan generate && netplan apply
    - onchanges:
      - file: /etc/netplan/80-lan.yaml

/etc/recovery/netplan.yaml:
  file.managed:
   - contents: |
{{ intend(quy<, yaml)}}
