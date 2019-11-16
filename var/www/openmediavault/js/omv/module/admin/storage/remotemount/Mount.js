/**
 * Copyright (C) 2014-2019 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

// require("js/omv/WorkspaceManager.js")
// require("js/omv/workspace/window/Form.js")
// require("js/omv/workspace/window/plugin/ConfigObject.js")
// require("js/omv/form/field/plugin/FieldInfo.js")

Ext.define('OMV.module.admin.storage.remotemount.Mount', {
    extend: 'OMV.workspace.window.Form',
    requires: [
        'OMV.form.field.plugin.FieldInfo',
        'OMV.workspace.window.plugin.ConfigObject'
    ],

    plugins: [{
        ptype: 'configobject'
    },{
        ptype: 'linkedfields',
        correlations: [{
            conditions: [{
                name: 'mounttype',
                value: 'nfs'
            }],
            name: ['username','password'],
            properties: ['!show', '!submitValue']
        },{
            conditions: [{
                name: 'mounttype',
                value: ['cifs']
            }],
            name: ['nfs4'],
            properties: ['!show', '!submitValue']
        }]
    }],

    hideResetButton: true,

    rpcService: 'RemoteMount',
    rpcGetMethod: 'get',
    rpcSetMethod: 'set',

    getFormItems: function() {
        return [{
            xtype: 'combo',
            name: 'mounttype',
            fieldLabel: _('Mount Type'),
            queryMode: 'local',
            store: [
                [ 'nfs', _('NFS') ],
                [ 'cifs', _('SMB/CIFS') ]
            ],
            editable: false,
            triggerAction: 'all',
            listeners: {
                change: this.onTypeChange.bind(this),
                scope: this
            },
            value: 'cifs'
        },{
            xtype: 'textfield',
            name: 'name',
            fieldLabel: _('Name'),
            allowBlank: false,
            readOnly: this.uuid !== OMV.UUID_UNDEFINED,
            plugins: [{
                ptype: 'fieldinfo',
                text: _('Used for display in OpenMediaVault web interface only.')
            }]
        },{
            xtype: 'hiddenfield',
            name: 'mntentref',
            value: OMV.UUID_UNDEFINED
        },{
            xtype: 'textfield',
            name: 'server',
            fieldLabel: _('Server'),
            value: '',
            allowBlank: false,
            plugins: [{
                ptype: 'fieldinfo',
                text: _('Use FQDN, hostname, or IP address.') +
                        '<br />' +
                      _('For GLUSTERFS, use any node server name or IP address.')
            }]
        },{
            xtype: 'textfield',
            name: 'sharename',
            fieldLabel: _('Share'),
            value: '',
            allowBlank: false,
            plugins: [{
                ptype: 'fieldinfo',
                text: _('For SMB/CIFS, use the share name only.') +
                        '<br />' +
                      _('For NFS, use the export path (ie /export/nfs_share_name).')
            }]
        },{
            xtype: 'checkbox',
            name: 'nfs4',
            fieldLabel: _('NFS v4'),
            checked: false,
            boxLabel: _('Use NFS v4'),
            plugins: [{
                ptype: 'fieldinfo',
                text: _('Will use NFS v2/v3 if unchecked and NFS v4 if checked.')
            }]
        },{
            xtype: 'textfield',
            name: 'username',
            fieldLabel: _('Username'),
            value: '',
            plugins: [{
                ptype: 'fieldinfo',
                text: _('Leave blank to authenticate as guest.')
            }]
        },{
            xtype: 'passwordfield',
            name: 'password',
            fieldLabel: _('Password'),
            value: ''
        },{
            xtype: 'textfield',
            name: 'options',
            fieldLabel: _('Options'),
            value: '_netdev,iocharset=utf8,vers=2.0,nofail',
            plugins: [{
                ptype: 'fieldinfo',
                text: _('For SMB/CIFS options, see man page for ') +
                        '<a href="https://linux.die.net/man/8/mount.cifs" target="_blank">mount.cifs</a>' +
                        '<br />' +
                      _('For NFS options, see man page for ') +
                        '<a href="https://linux.die.net/man/8/mount.nfs" target="_blank">mount.nfs</a>'
           }]
        }];
    },

    onTypeChange: function(combo, newValue, oldValue) {
        var options = this.findField('options');

        if (newValue === 'cifs') {
            options.setValue('_netdev,iocharset=utf8,vers=2.0,nofail');
        } else if (newValue === 'nfs') {
            options.setValue('rsize=8192,wsize=8192,timeo=14,intr,nofail');
        }
    }
});
