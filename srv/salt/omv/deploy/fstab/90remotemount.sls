{% set config = salt['omv_conf.get']('conf.service.remotemount.mount') %}
{% set cifsCreds = '/root/.cifscredentials-' %}

{% for mount in config.mount %}
{% set remotemount = salt['omv_conf.get_by_filter'](
  'conf.system.filesystem.mountpoint',
  {'operator':'stringEquals', 'arg0':'uuid', 'arg1':mount.mntentref}) %}
{% set mntDir = remotemount[0].dir %}

{% set options = [] %}
{% set options = mount.options.split(',') %}
{%- if mount.mounttype == 'cifs' %}
{%- if mount.username | length > 0 %}
{% set _ = options.append('credentials=' + cifsCreds + mount.mntentref) %}
{%- else %}
{% set _ = options.append('guest') %}
{%- endif %}
{% set share = '//' + mount.server + '/' + mount.sharename | replace('', '\\040') %}
{% set fstype = mount.mounttype %}
{%- elif mount.mounttype == 'nfs' %}
{% set share = mount.server + ':' + mount.sharename %}
{% set fstype = mount.mounttype %}
{%- endif %}

create_remotemount_mountpoint_{{ mount.uuid }}:
  file.accumulated:
    - filename: "/etc/fstab"
    - text: "{{ share }}\t\t{{ mntDir }}\t{{ fstype }}\t{{ options }}\t{{ remotemount.freq }} {{ remotemount.passno }}"
    - require_in:
      - file: append_fstab_entries

mount_filesystem_mountpoint_{{ mount.uuid }}:
  mount.mounted:
    - name: {{ mntDir }}
    - device: {{ share }}
    - fstype: {{ fstype }}
    - opts: {{ options }}
    - mkmnt: True
    - persist: False
    - mount: True
{% endfor %}
