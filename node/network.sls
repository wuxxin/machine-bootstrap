{% from "machine-bootstrap/node/defaults.jinja" import settings %}

include:
  - .hostname

{% macro add_internal_bridge(bridge_name, bridge_cidr, priority=80) %}
  {% if salt['cmd.retcode']('which netplan') == 0 %}
bridge_{{ bridge_name }}:
  file.managed:
    - name: /etc/netplan/{{ priority }}-{{ bridge_name }}.yaml
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
              dhcp4: false
              dhcp6: false
  cmd.run:
    - name: netplan generate && netplan apply
    - onchanges:
      - file: bridge_{{ bridge_name }}

  {% else %}
bridge_{{ bridge_name }}:
  file.managed:
    - name: /etc/network/interfaces.d/{{ priority }}-{{ bridge_name }}.cfg
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

/etc/netplan/50-lan.yaml:
  file.managed:
    - contents: |
{{ settings.netplan_default|indent(8,True) }}
  cmd.run:
    - name: netplan generate && netplan apply
    - onchanges:
      - file: /etc/netplan/50-lan.yaml
