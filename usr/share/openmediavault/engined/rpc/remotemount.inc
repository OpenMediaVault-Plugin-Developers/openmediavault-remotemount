<?php
/**
 * @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
 * @author    Volker Theile <volker.theile@openmediavault.org>
 * @copyright Copyright (c) 2009-2013 Volker Theile
 * @copyright Copyright (c) 2013-2023 OpenMediaVault Plugin Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */
require_once("openmediavault/globals.inc");
require_once("openmediavault/functions.inc");

class OMVRpcServiceRemoteMount extends \OMV\Rpc\ServiceAbstract
{
    public function getName()
    {
        return "RemoteMount";
    }

    public function initialize()
    {
        $this->registerMethod("getList");
        $this->registerMethod("getListBg");
        $this->registerMethod("get");
        $this->registerMethod("set");
        $this->registerMethod("delete");
        $this->registerMethod("mount");
    }

    public function getList($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.remotemount.mount");
	    $sfobjects = $db->get("conf.system.sharedfolder");
        // Add additional mount informations.
        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            $mntentref = $objectv->get("mntentref");
            $fs = \OMV\System\Filesystem\Filesystem::getImpl($objectv->get('uuid'));
            $inuse = false;
            foreach ($sfobjects as $sfobject) {
                $sfmntentref = $sfobject->get("mntentref");
                if ($mntentref == $sfmntentref) {
                    $inuse = true;
                    break;
                }
            }
            $objectv->add("inuse", "boolean", $inuse);
            $objectv->add("mounted", "boolean", $fs->isMounted());
            $objectsAssoc[] = $objectv->getAssoc();
        }
        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getListBg($params, $context) {
        return $this->callMethodBg("getList", $params, $context);
    }

    public function get($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.remotemount.mount", $params['uuid']);
        return $object->getAssoc();
    }

    public function set($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $db = \OMV\Config\Database::getInstance();
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject("conf.service.remotemount.mount");
        $object->setAssoc($params);
        // Set the configuration object.
        $isNew = $object->isNew();
        if (TRUE === $isNew) {
            // Check uniqueness
            $db->assertIsUnique($object, "name");
        }
        $db->set($object);
        // create mntent entry for new mounts
        if (TRUE === $isNew) {
            $baseDir = \OMV\Environment::get("OMV_MOUNT_DIR");
            $result = \OMV\Rpc\Rpc::call('FsTab', 'set', [
                'uuid' => $object->get('mntentref'),
                'fsname' => $object->get('uuid'),
                'dir' => sprintf("%s/remotemount/%s", $baseDir, $object->get('name')),
                'type' => $object->get('mounttype'),
                'opts' => '',
                'freq' => 0,
                'passno' => 0,
                'hidden' => true,
            ], $context);
            // update uuid in config
            $object->set('mntentref', $result['uuid']);
            $db->set($object);
        }
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function delete($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.remotemount.mount", $params['uuid']);
        // Delete the configuration object.
        $db->delete($object);
        // Delete the filesystem
        \OMV\Rpc\Rpc::call("FsTab", "delete", [
            "uuid" => $object->get("mntentref")
        ], $context);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }

    public function mount($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $rmntobj = $db->get("conf.service.remotemount.mount", $params['uuid']);
        $mntobj = $db->get("conf.system.filesystem.mountpoint", $rmntobj->get('mntentref'));
        $action = $params['action'];
        // get escaped systemd mount
        $cmdArgs = [];
        $cmdArgs[] = '--path';
        $cmdArgs[] = '--suffix=mount';
        $cmdArgs[] = $mntobj->get('dir');
        $output = [];
        $cmd = new \OMV\System\Process('systemd-escape', $cmdArgs);
        $cmd->execute($output, $exitStatus);
        // perform action on systemd mount
        $cmdArgs = [];
        $cmdArgs[] = $action;
        $cmdArgs[] = $output[0];
        $output = [];
        $cmd = new \OMV\System\Process('systemctl', $cmdArgs);
        $cmd->execute($output, $exitStatus);
    }
}
