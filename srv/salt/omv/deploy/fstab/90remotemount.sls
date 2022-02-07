{% set config = salt['omv_conf.get']('conf.service.remotemount') %}
{% set cifsCreds = '/root/.cifscredentials-' %}
{% for mnt in config.mount | selectattr('fstab') %}
{% set remotemount = salt['omv_conf.get']('conf.system.filesystem.mountpoint', mnt.mntentref) %}
{% set mntDir = remotemount.dir %}
{% set mount = True %}
{% set options = [] %}
{% set options = mnt.options.split(',') %}
{% if mnt.mounttype == 'cifs' %}
{% if mnt.username | length > 0 %}
{% set _ = options.append('credentials=' + cifsCreds + mnt.mntentref) %}
{% else %}
{% set _ = options.append('guest') %}
{% endif %}
{% set share = '//' + mnt.server + '/' + mnt.sharename | replace(' ', '\\\\040') | replace('\'', '') %}
{% set sharedir = '//' + mnt.server + '/' + mnt.sharename %}
{% set fstype = mnt.mounttype %}
{% elif mnt.mounttype == 'nfs' %}
{% set share = mnt.server + ':' + mnt.sharename %}
{% set sharedir = mnt.server + ':' + mnt.sharename %}
{% set fstype = mnt.mounttype %}
{% elif mnt.mounttype == 'davfs' %}
{% if mnt.username | length <= 0 %}
{% set _ = options.append('guest') %}
{% endif %}
{% set share = mnt.server | replace(' ', '\\\\040') | replace('\'', '') %}
{% set sharedir = mnt.server %}
{% set fstype = mnt.mounttype %}
{% set mount = False %}
{% endif %}

create_remotemount_mountpoint_{{ mnt.uuid }}:
  file.accumulated:
    - filename: "/etc/fstab"
    - text: "{{ share }}\t\t{{ mntDir }}\t{{ fstype }}\t{{ options | join(',') }}\t0 0"
    - require_in:
      - file: append_fstab_entries
mount_filesystem_mountpoint_{{ mnt.uuid }}:
  mount.mounted:
    - name: {{ mntDir }}
    - device: {{ sharedir }}
    - fstype: {{ fstype }}
    - opts: {{ options }}
    - mkmnt: True
    - persist: False
    - mount: {{ mount }}
{% endfor %}
