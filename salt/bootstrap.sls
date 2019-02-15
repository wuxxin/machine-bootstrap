{% if pillar desktop.homeshick.repos %}
  {% for repo in desktop.homeshick.repos %}
    {% set repodir= user_home+ '/.homesick/repos/'+ repo.name %}
homeshick_{{ repo.name }}:
  git.latest:
    - name: {{ repo.url}}
    - target: {{ repodir }}
    - user: {{ user }}
    - require:
      - file: homeshick
  {% endfor %}
{% endif %}
