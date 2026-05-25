{% set notification_config = salt['omv_conf.get_by_filter'](
  'conf.system.notification.notification',
  {'operator': 'stringEquals', 'arg0': 'id', 'arg1': 'monitfilesystems'})[0] %}

{% if notification_config.enable | to_bool %}

{% set mountpoints = salt['omv_conf.get_by_filter'](
  'conf.system.filesystem.mountpoint',
  {"operator": "or",
   "arg0": {"operator": "or",
     "arg0": {"operator": "or",
       "arg0": {"operator": "stringEquals", "arg0": "type", "arg1": "nfs"},
       "arg1": {"operator": "stringEquals", "arg0": "type", "arg1": "cifs"}},
     "arg1": {"operator": "stringEquals", "arg0": "type", "arg1": "davfs"}},
   "arg1": {"operator": "stringEquals", "arg0": "type", "arg1": "rclone"}}) %}

{# Build a list of mountpoint UUIDs that the user has intentionally unmounted
   so the template can skip them and monit will not auto-remount them. #}
{% set remotemounts = salt['omv_conf.get_by_filter'](
  'conf.service.remotemount.mount',
  {"operator": "or",
   "arg0": {"operator": "or",
     "arg0": {"operator": "or",
       "arg0": {"operator": "stringEquals", "arg0": "mounttype", "arg1": "nfs"},
       "arg1": {"operator": "stringEquals", "arg0": "mounttype", "arg1": "cifs"}},
     "arg1": {"operator": "stringEquals", "arg0": "mounttype", "arg1": "davfs"}},
   "arg1": {"operator": "stringEquals", "arg0": "mounttype", "arg1": "rclone"}}) | default([]) %}

{% set unmonitored_refs = [] %}
{% for rm in remotemounts %}
{% if not rm.monitored | default(true) | to_bool %}
{% do unmonitored_refs.append(rm.mntentref) %}
{% endif %}
{% endfor %}

configure_monit_remotemount_service:
  file.managed:
    - name: "/etc/monit/conf.d/openmediavault-remotemount.conf"
    - source:
      - salt://{{ tpldir }}/files/remotemount.j2
    - template: jinja
    - context:
        mountpoints: {{ mountpoints | json }}
        unmonitored_refs: {{ unmonitored_refs | json }}
    - user: root
    - group: root
    - mode: "0644"

{% endif %}
