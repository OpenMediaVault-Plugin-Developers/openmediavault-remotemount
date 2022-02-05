# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2019-2022 OpenMediaVault Plugin Developers
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

configure_remote_dir:
  file.directory:
    - name: "{{ remotedir }}"
    - makedirs: True

remove_remotemount_mount_files:
  module.run:
    - file.find:
      - path: "{{ mountsdir }}"
      - iname: "{{ remotediresc }}-*.mount"
      - delete: "f"

{% for mnt in config.mount | rejectattr('fstab') %}
{% if mnt.mntentref | length == 36 %}

{% set rmount = salt['omv_conf.get']('conf.system.filesystem.mountpoint', pool.mntentref) -%}
{% set rdir = rmount.dir %}
{% set rname = mnt.name %}

{% set unitname = salt['cmd.run']('systemd-escape --path --suffix=mount ' ~ rdir) %}
{% set mountunit =  mountsdir ~ "/" ~ unitname %}

configure_remotemount_{{ rname }}:
  file.managed:
    - name: {{ mountunit }}
    - source:
      - salt://{{ tpldir }}/files/etc-systemd-system-remotemount_mount.j2
    - context:
        mount: {{ mount | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"

{% set unitnameauto = salt['cmd.run']('systemd-escape --path --suffix=automount ' ~ rdir) %}
{% set mountunitauto =  mountsdir ~ "/" ~ unitnameauto %}

configure_remoteautomount_{{ rname }}:
  file.managed:
    - name: {{ mountunitauto }}
    - source:
      - salt://{{ tpldir }}/files/etc-systemd-system-remotemount_automount.j2
    - context:
        mount: {{ mount | json }}
    - template: jinja
    - user: root
    - group: root
    - mode: "0644"

systemd-reload_{{ rname }}:
  cmd.run:
    - name: systemctl daemon-reload

enable_{{ rname }}_remotemount:
  service.enabled:
    - name: {{ unitname }}
    - enable: True

restart_{{ rname }}_remotemount:
  cmd.run:
    - name: systemctl restart {{ unitname }}

enable_{{ rname }}_remotemountauto:
  service.enabled:
    - name: {{ unitnameauto }}
    - enable: True

{% endif %}
{% endfor %}
