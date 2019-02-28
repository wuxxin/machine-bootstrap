{% set project_basepath=grains['project_basepath'] %}

{% import_text 'config' as temp %}
{% set machine_config= salt['cmd.run_stdout'](
'grep -v -e "^[[:space:]]*$" | grep -v "^#" | '+
'sort | uniq | sed -r "s/([^=]+)=(.*)/\\1: \\2/g"',
stdin=temp, python_shell=True)|load_yaml %}
{% set temp="" %}

{% import_text 'authorized_keys' as authorized_keys %}

{#
{% set machine_config= salt['cmd.run_stdout'](
'cat '+ project_basepath+ '/machine-config/config'+ ' | '+ 
'grep -v -e "^[[:space:]]*$" | grep -v "^#" | '+
'sort | uniq | sed -r "s/([^=]+)=(.*)/\\1: \\2/g"',
python_shell=True)|load_yaml %}
#}
