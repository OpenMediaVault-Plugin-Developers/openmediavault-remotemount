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
    }],

    hideResetButton: true,

    rpcService: 'RemoteMount',
    rpcGetMethod: 'get',
    rpcSetMethod: 'set',

    getFormItems: function() {
        return [{
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
            xtype: 'combo',
            name: 'mounttype',
            fieldLabel: _('Mount Type'),
            queryMode: 'local',
            store : [
                [ 'nfs', _('NFS') ],
                [ 'cifs', _('SMB/CIFS') ],
                [ 'sshfs', _('SSHFS') ]
            ],
            editable      : false,
            triggerAction : "all",
            value         : "cifs"
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
            xtype: 'textfield',
            name: 'username',
            fieldLabel: _('Username'),
            value: ''
        },{
            xtype: 'passwordfield',
            name: 'password',
            fieldLabel: _('Password'),
            value: ''
        },{
            xtype: 'textfield',
            name: 'options',
            fieldLabel: _('Options'),
            value: ''
        }];
    }
});
