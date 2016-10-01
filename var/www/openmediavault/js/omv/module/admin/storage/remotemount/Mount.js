/**
 * Copyright (C) 2014-2016 OpenMediaVault Plugin Developers
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
                value: 'cifs'
            }],
            name: ['nfs4', 'port'],
            properties: ['!show', '!submitValue']
        },{
            conditions: [{
                name: 'mounttype',
                value: 'nfs'
            }],
            name: ['username', 'password', 'port'],
            properties: ['!show', '!submitValue']
        },{
            conditions: [{
                name: 'mounttype',
                value: 'sshfs'
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
                [ 'cifs', _('SMB/CIFS') ],
                [ 'sshfs', _('SSHFS') ]
            ],
            editable: false,
            triggerAction: "all",
            listeners: {
                change: this.onTypeChange.bind(this),
                scope: this
            },
            value: "cifs"
        },{
            xtype: 'textfield',
            name: 'name',
            fieldLabel: _('Name'),
            allowBlank: false,
            readOnly: this.uuid !== OMV.UUID_UNDEFINED
        },{
            xtype: 'hiddenfield',
            name: 'mntentref',
            value: OMV.UUID_UNDEFINED
        },{
            xtype: 'textfield',
            name: 'server',
            fieldLabel: _('Server'),
            value: ''
        },{
            xtype: 'textfield',
            name: 'sharename',
            fieldLabel: _('Share'),
            value: ''
        },{
            xtype: 'numberfield',
            name: 'port',
            fieldLabel: _('Port'),
            vtype: 'port',
            minValue: 1,
            maxValue: 65535,
            allowDecimals: false,
            allowBlank: false,
            value: 22
        },{
            xtype: 'checkbox',
            name: 'nfs4',
            fieldLabel: _('Use NFS v4'),
            checked: false
        },{
            xtype: 'textfield',
            name: 'username',
            fieldLabel: _('Username'),
            value: '',
            plugins: [{
                ptype: "fieldinfo",
                text: _("For SMB/CIFS, leave blank to authenticate as guest")
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
            value: '_netdev,iocharset=utf8'
        }];
    },

    onTypeChange: function(combo, newValue, oldValue) {
        var options = this.findField('options');

        if (newValue === 'cifs') {
            options.setValue('_netdev,iocharset=utf8');
        }

        if (newValue === 'nfs') {
            options.setValue('rsize=8192,wsize=8192,timeo=14,intr');
        }

        if (newValue === 'sshfs') {
            options.setValue('_netdev');
        }
    }
});
