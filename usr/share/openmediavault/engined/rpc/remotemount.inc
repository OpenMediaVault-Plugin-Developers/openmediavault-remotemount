<?php

/**
 * Copyright (C) 2013-2016 OpenMediaVault Plugin Developers.
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
namespace OMV\Engined\Rpc;

use Exception;
use OMV\Config\ConfigObject;
use OMV\Config\Database;
use OMV\Engine\Module\Manager as ModuleManager;
use OMV\Rpc\Rpc;
use OMV\Rpc\ServiceAbstract;
use OMV\System\Filesystem\Filesystem;
use OMV\Uuid;

class RemoteMount extends ServiceAbstract
{
    /** @var Database */
    private $database;

    /** @var string */
    private $dataModelPath = 'conf.service.remotemount.mount';

    /** @var string */
    private $mountPointDataModelPath = 'conf.system.filesystem.mountpoint';

    public function __construct(Database $database = null)
    {
        $this->database = $database ?: Database::getInstance();
    }

    /**
     * Get the name of the RPC service.
     *
     * @return string
     */
    public function getName()
    {
        return 'RemoteMount';
    }

    /**
     * Initialize the RPC service.
     *
     * @return void
     */
    public function initialize()
    {
        $this->registerMethod('getList');
        $this->registerMethod('get');
        $this->registerMethod('set');
        $this->registerMethod('delete');
    }

    /**
     * Get a list of the existing remote mounts.
     *
     * @param $params  The method parameters.
     * @param $context The context of the caller.
     *
     * @return array
     */
    public function getList($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.getlist');

        $objects = $this->database->get($this->dataModelPath);
        $mounts = [];
        foreach ($objects as $object) {
            $mounts[] = $object->getAssoc();
        }

        return $this->applyFilter(
            $mounts,
            $params['start'],
            $params['limit'],
            $params['sortfield'],
            $params['sortdir']
        );
    }

    /**
     * Get the configuration for a single existing remote mount.
     *
     * @param $params  The method parameters.
     * @param $context The context of the caller.
     *
     * @return array
     */
    public function get($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $object = $this->database->get($this->dataModelPath, $params['uuid']);

        return $object->getAssoc();
    }

    /**
     * Set the configuration for a single new or existing remote mount.
     *
     * @param $params  The method parameters.
     * @param $context The context of the caller.
     *
     * @return array
     */
    public function set($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.remotemount.set');

        $object = new ConfigObject($this->dataModelPath);
        $object->setAssoc($params);

        $isNewObject = $object->isNew();

        if ($isNewObject) {
            $this->database->assertIsUnique($object, 'name');
        }

        // Save the object before generating a fstab entry to generate a valid
        // UUID.
        $this->database->set($object);

        // Create or update the mntent entry.
        $mntent = $this->setMntentEntry($object);

        // The fstab module does not mark itself as dirty when a mntent
        // configuration is modified, only when created or deleted.
        if (!$isNewObject) {
            $moduleManager = ModuleManager::getInstance();
            $moduleManager->setModuleDirty('fstab');
        }

        if ($isNewObject) {
            try {
                $object->set('mntentref', $mntent['uuid']);

                $this->database->set($object);
            } catch (Exception $e) {
                $this->database->delete($object);
                Rpc::call('FsTab', 'delete', ['uuid' => $mntent['uuid']], $context);

                throw $e;
            }
        }

        return $object->getAssoc();
    }

    /**
     * Delete the configuration of a single existing union filesystem.
     *
     * @param $params  The method parameters.
     * @param $context The context of the caller.
     *
     * @return void
     */
    public function delete($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        // FIXME: Check that the filesystem is not used before deleting it.
        $object = $this->database->get($this->dataModelPath, $params['uuid']);
        $this->database->delete($object);

        Rpc::call('FsTab', 'delete', ['uuid' => $object->get('mntentref')], $context);
    }

    /**
     * Create or update a mntent configuration object from a configuration object.
     *
     * @param ConfigObject $object The object to create a mntent entry for.
     *
     * @return string Returns the mntentref for the mntent entry.
     */
    private function setMntentEntry(ConfigObject $object)
    {
        $mountPoint = Filesystem::buildMountPath($object->get('uuid'));

        $mntentEntry = [
            'uuid' => $object->get('mntentref'),
            'fsname' => $object->get('uuid'),
            'dir' => $mountPoint,
            'type' => $object->get('mounttype'),
            'opts' => '',
            'freq' => 0,
            'passno' => 0,
        ];

        $mntent = Rpc::call('FsTab', 'set', $mntentEntry, $this->getAdminContext());

        return $mntent;
    }
}
