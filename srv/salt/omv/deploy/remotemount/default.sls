# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2025 openmediavault plugin developers
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

{% set config = salt['omv_conf.get']('conf.service.remotemount') %}
{% set mountsdir = '/etc/systemd/system' %}
{% set mountdir = salt['pillar.get']('default:OMV_MOUNT_DIR', '/srv') %}
{% set remotedir = mountdir ~ '/remotemount' %}
{% set remotediresc = salt['cmd.run']('systemd-escape --path ' ~ remotedir) %}
{% set secrets = '/etc/davfs2/secrets' %}

configure_remote_dir:
  file.directory:
    - name: "{{ remotedir }}"
    - makedirs: True

remove_remotemount_mount_files:
  module.run:
    - file.find:
      - path: "{{ mountsdir }}"
      - iname: "*.mount"
      - grep: "Description(| )=(| )RemoteMount mount for"
      - maxdepth: 1
      - delete: "f"

remove_remotemount_automount_files:
  module.run:
    - file.find:
      - path: "{{ mountsdir }}"
      - iname: "*.automount"
      - grep: "Description(| )=(| )RemoteMount automount for"
      - maxdepth: 1
      - delete: "f"

remove_remotemount_cifs_cred_files:
  module.run:
    - file.find:
      - path: "/root/"
      - iname: ".cifscredentials-*"
      - grep: "username"
      - maxdepth: 1
      - delete: "f"

remove_remotemount_s3fs_cred_files:
  module.run:
    - file.find:
      - path: "/root/"
      - iname: ".s3fscredentials-*"
      - maxdepth: 1
      - delete: "f"

remove_remotemount_davfs_cred_file:
  file.absent:
    - name: "{{ secrets }}"

configure_remotemount_davfs_cred_file:
  file.managed:
    - name: "{{ secrets }}"
    - user: root
    - group: root
    - mode: "0600"
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}

systemd_delete_dead_symlinks:
  cmd.run:
    - name: find /etc/systemd/system/multi-user.target.wants -xtype l -print -delete

{% for mnt in config.mount %}
{% if mnt.mntentref | length == 36 %}

{% set rmount = salt['omv_conf.get']('conf.system.filesystem.mountpoint', mnt.mntentref) -%}
{% set rdir = rmount.dir %}
{% set rname = mnt.name %}

{% set unitname = salt['cmd.run']('systemd-escape --path --suffix=mount ' ~ rdir) %}
{% set mountunit =  mountsdir ~ "/" ~ unitname %}

{%- set credsPrefix = '/root/.' ~ mnt.mounttype ~ 'credentials-' %}
{%- set creds = credsPrefix ~ mnt.mntentref %}

{% if mnt.mounttype == 'cifs' %}
configure_remotemount_cifs_creds_{{ mnt.mntentref }}:
  file.managed:
    - name: "{{ creds }}"
    - user: root
    - group: root
    - mode: 600
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}
        username={{ mnt.username }}
        password={{ mnt.password }}


{% elif mnt.mounttype == 's3fs' %}
configure_remotemount_s3fs_creds_{{ mnt.mntentref }}:
  file.managed:
    - name: "{{ creds }}"
    - user: root
    - group: root
    - mode: 600
    - contents: |
        {{ pillar['headers']['auto_generated'] }}
        {{ pillar['headers']['warning'] }}
        {{ mnt.username }}:{{ mnt.password }}


{% elif mnt.mounttype == 'davfs' %}
configure_remotemount_davfs_creds_{{ mnt.mntentref }}:
  file.append:
    - name: "{{ secrets }}"
    - text:
      - {{ mnt.server }} {{ mnt.username }} {{ mnt.password }}


{% endif %}

configure_remotemount_{{ rname }}:
  file.managed:
    - name: {{ mountunit }}
    - source:
      - salt://{{ tpldir }}/files/etc-systemd-system-remotemount_mount.j2
    - context:
        mount: {{ mnt | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"

{% set unitnameauto = salt['cmd.run']('systemd-escape --path --suffix=automount ' ~ rdir) %}
{% set mountunitauto =  mountsdir ~ "/" ~ unitnameauto %}

#configure_remoteautomount_{{ rname }}:
#  file.managed:
#    - name: {{ mountunitauto }}
#    - source:
#      - salt://{{ tpldir }}/files/etc-systemd-system-remotemount_automount.j2
#    - context:
#        mount: {{ mnt | json }}
#    - template: jinja
#    - user: root
#    - group: root
#    - mode: "0644"

systemd-reload_{{ rname }}:
  cmd.run:
    - name: systemctl daemon-reload

enable_{{ rname }}_remotemount:
  service.enabled:
    - name: {{ unitname }}
    - enable: True

restart_{{ rname }}_remotemount:
  cmd.run:
    - name: systemctl restart '{{ unitname }}'

#enable_{{ rname }}_remotemountauto:
#  service.enabled:
#    - name: {{ unitnameauto }}
#    - enable: True

{% endif %}
{% endfor %}
