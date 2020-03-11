{% from 'bootstrap.sls' import project_basepath, machine_config, authorized_keys %}

hostname: {{ machine_config.hostname }}

authorized_keys:
{% for key in authorized_keys.split("\n") %}
  - "{{ key}}"
{% endfor %}

ssh_deprecated_keys:

desktop:
  user: {{ machine_config.firstuser }}
