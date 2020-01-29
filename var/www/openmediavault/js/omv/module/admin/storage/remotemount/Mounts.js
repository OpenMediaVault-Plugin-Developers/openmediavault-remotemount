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
// require("js/omv/workspace/grid/Panel.js")
// require("js/omv/data/Store.js")
// require("js/omv/data/Model.js")
// require("js/omv/data/proxy/RpcBg.js")
// require("js/omv/module/admin/storage/remotemount/Mount.js")

Ext.define('OMV.module.admin.storage.remotemount.Mounts', {
    extend: 'OMV.workspace.grid.Panel',
    requires: [
        'OMV.data.Store',
        'OMV.data.Model',
        'OMV.data.proxy.RpcBg',
        'OMV.module.admin.storage.remotemount.Mount'
    ],

    hidePagingToolbar: false,
    reloadOnActivate: true,
    rememberSelected: true,
    //autoReload: true,

    columns: [{
        xtype: "textcolumn",
        header: _('UUID'),
        hidden: true,
        dataIndex: 'uuid'
    },{
        xtype: "textcolumn",
        header: _('Type'),
        flex: 1,
        sortable: true,
        dataIndex: 'mounttype',
        renderer  : function (value) {
            var content;
            switch (value) {
                case 'cifs':
                    content = _("SMB/CIFS");
                    break;
                case 'nfs':
                    content = _("NFS");
                    break;
                case 'davfs':
                    content = _("DAVFS");
                    break;
            }
            return content;
        }
    },{
        xtype: "textcolumn",
        header: _('Name'),
        flex: 1,
        sortable: true,
        dataIndex: 'name'
    },{
        xtype: "textcolumn",
        header: _('Server'),
        flex: 1,
        sortable: true,
        dataIndex: 'server'
    },{
        xtype: "textcolumn",
        header: _('Share'),
        flex: 1,
        sortable: true,
        dataIndex: 'sharename'
    },{
        xtype: "enabledcolumn",
        header: _('Mounted'),
        flex: 1,
        sortable: true,
        dataIndex: 'mounted'
    },{
        xtype: "enabledcolumn",
        header: _('Shared'),
        flex: 1,
        sortable: true,
        dataIndex: 'shared'
    }],

    store: Ext.create('OMV.data.Store', {
        autoLoad: true,
        model: OMV.data.Model.createImplicit({
            idProperty: 'uuid',
            fields: [{
                name: 'uuid',
                type: 'string'
            },{
                name: 'mounttype',
                type: 'string'
            },{
                name: 'name',
                type: 'string'
            },{
                name: 'server',
                type: 'string'
            },{
                name: 'sharename',
                type: 'string'
            },{ 
                name: 'mounted', 
                type: 'boolean' 
            },{
                name: 'shared', 
                type: 'boolean' 
            }]
        }),
        proxy: {
            type: 'rpcbg',
            rpcData: {
                'service': 'RemoteMount',
                'method': 'getListBg'
            }
        },
        remoteSort: true,
        sorters: [{
            direction: 'ASC',
            property: 'name'
        }]
    }),
        
    getTopToolbarItems: function() {
		var me = this;
		var items = me.callParent(arguments);
		Ext.Array.insert(items, 3, [{
			id: me.getId() + "-mount",
			xtype: "button",
			text: _("Mount"),
			iconCls: "x-fa fa-play",
			handler: Ext.Function.bind(me.onMountButton, me, [ me ]),
			scope: me,
			disabled: true
		},{
			id: me.getId() + "-unmount",
			xtype: "button",
			text: _("Unmount"),
			iconCls: "x-fa fa-eject",
			handler: Ext.Function.bind(me.onUnmountButton, me, [ me ]),
			scope: me,
			disabled: true
		}]);
		return items;
	},
    
    onSelectionChange: function(model, records) {
		var me = this;
		me.callParent(arguments);
		// Process additional buttons.
		var tbarBtnDisabled = {
			"mount": true,
			"unmount": true,
            "delete": true,
            "edit": true
		};
        if(records.length == 1) {
			var record = records[0];
		    if (true === record.get("mounted")) {
                if (false === record.get("shared")) {
			        tbarBtnDisabled["unmount"] = false;
                }
		    } else {
			    tbarBtnDisabled["mount"] = false;
                tbarBtnDisabled["delete"] = false;
                tbarBtnDisabled["edit"] = false;
		    }
        }
		// Update the button controls.
		Ext.Object.each(tbarBtnDisabled, function(key, value) {
			this.setToolbarButtonDisabled(key, value);
		}, me);
	},

    onAddButton: function() {
        Ext.create('OMV.module.admin.storage.remotemount.Mount', {
            title: _('Add mount'),
            uuid: OMV.UUID_UNDEFINED,
            listeners: {
                scope: this,
                submit: function() {
                    this.doReload();
                }
            }
        }).show();
    },

    onEditButton: function() {
        var record = this.getSelected();

        Ext.create('OMV.module.admin.storage.remotemount.Mount', {
            title: _('Edit mount'),
            uuid: record.get('uuid'),
            listeners: {
                scope: this,
                submit: function() {
                    this.doReload();
                    OMV.MessageBox.info(null, _('NOTE: The changes won\'t take effect until you\'ve restarted the system or manually remounted the mount.'));
                }
            }
        }).show();
    },

    doDeletion: function(record) {
        OMV.Rpc.request({
            scope: this,
            callback: this.onDeletion,
            rpcData: {
                service: 'RemoteMount',
                method: 'delete',
                params: {
                    uuid: record.get('uuid')
                }
            }
        });
    },
    
    onMountButton: function() {
		var me = this;
		var record = me.getSelected();
		// Execute RPC.
		OMV.Rpc.request({
			scope: me,
			callback: function(id, success, response) {
				this.doReload();
			},
			relayErrors: false,
			rpcData: {
				service: "RemoteMount",
				method: "mount",
				params: {
					uuid: record.get('uuid')
				}
			}
		});
	},

	onUnmountButton: function() {
		var me = this;
		var record = me.getSelected();
		// Execute RPC.
		OMV.Rpc.request({
			scope: me,
			callback: function(id, success, response) {
				this.doReload();
			},
			relayErrors: false,
			rpcData: {
				service: "RemoteMount",
				method: "unmount",
				params: {
					uuid: record.get('uuid')
				}
			}
		});
	}
});

OMV.WorkspaceManager.registerPanel({
    id: 'mounts',
    path: '/storage/remotemount',
    text: _('Mounts'),
    position: 30,
    className: 'OMV.module.admin.storage.remotemount.Mounts'
});
