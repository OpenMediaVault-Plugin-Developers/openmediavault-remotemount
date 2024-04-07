{% set notification_config = salt['omv_conf.get_by_filter'](
  'conf.system.notification.notification',
  {'operator': 'stringEquals', 'arg0': 'id', 'arg1': 'monitfilesystems'})[0] %}

{% if notification_config.enable | to_bool %}

{% set mountpoints = salt['omv_conf.get_by_filter'](
  'conf.system.filesystem.mountpoint',
  {"operator": "or", "arg0": { "operator": "or", "arg0": { "operator": "stringEquals", "arg0": "type", "arg1": "nfs" }, "arg1": { "operator": "stringEquals", "arg0": "type", "arg1": "cifs" }}, "arg1": { "operator": "stringEquals", "arg0": "type", "arg1": "davfs"}}) %}

configure_monit_remotemount_service:
  file.managed:
    - name: "/etc/monit/conf.d/openmediavault-remotemount.conf"
    - source:
      - salt://{{ tpldir }}/files/remotemount.j2
    - template: jinja
    - context:
        mountpoints: {{ mountpoints | json }}
    - user: root
    - group: root
    - mode: 644

{% endif %}
