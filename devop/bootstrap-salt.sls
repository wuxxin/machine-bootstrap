
{% from 'desktop/user/lib.sls' import user, user_info, user_home with context %}

{% set targetdir= user_home+ '/.homesick/repos/{{ hostname }}' %}
{% set srcdir= salt['file.join'](slspath, '/../../../home') %}


{#
{ % if pillar['desktop.homeshick.repos'] %}
#}
{{ targetdir }}:
  file.symlink:
    - target: {{ srcdir }}

{#
{% endif %}
#}
