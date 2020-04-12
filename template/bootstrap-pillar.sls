{% set project_basepath=grains['project_basepath'] %}

{% import_text 'machine-config.env' as machine_config_input %}
{% set machine_config_raw= salt['cmd.run_stdout'](
'grep -v -e "^[[:space:]]*$" | grep -v "^#" | '+
'sort | uniq | sed -r "s/([^=]+)=(.*)/\\1: \\2/g"',
stdin=machine_config_input, python_shell=True) %}
{% set machine_config= machine_config_raw|load_yaml %}
{% set machine_config_input="" %}
{% set machine_config_raw="" %}

{% import_text 'authorized_keys' as authorized_keys %}
