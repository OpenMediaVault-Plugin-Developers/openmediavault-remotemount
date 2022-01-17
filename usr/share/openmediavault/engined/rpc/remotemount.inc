<?php

/**
 * Copyright (C) 2013-2022 OpenMediaVault Plugin Developers.
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
use OMV\System\MountPoint;

class RemoteMount extends ServiceAbstract
{
    /** @var Database */
    private $database;

    /** @var string */
    private $dataModelPath = 'conf.service.remotemount.mount';

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
        $this->registerMethod('getListBg');
        $this->registerMethod('get');
        $this->registerMethod('set');
        $this->registerMethod('delete');
        $this->registerMethod('mount');
        $this->registerMethod('unmount');
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
            //$mounts[] = $object->getAssoc();
            $fs = \OMV\System\Filesystem\Filesystem::getImpl($object->get('uuid'));
            $isShared = $this->IsSharedFolder($object);           
            $mounts[] = array_merge($object->GetAssoc(),array('mounted' => $fs->isMounted()),array('shared' => $isShared));
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
	 * Execute the getList() RPC as background process.
	 */
	public function getListBg($params, $context) {
		return $this->callMethodBg("getList", $params, $context);
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

        // If it's a new entry we'll create a new mntent.
        if ($isNewObject) {
            $mntent = $this->setMntentEntry($object);
            try {
                $object->set('mntentref', $mntent['uuid']);
                $this->database->set($object);
            } catch (Exception $e) {
                $this->database->delete($object);
                Rpc::call('FsTab', 'delete', ['uuid' => $mntent['uuid']], $context);
                throw $e;
            }
        }

        // The fstab module does not mark itself as dirty when a mntent
        // configuration is modified, only when created or deleted.
        if (!$isNewObject) {
            $moduleManager = ModuleManager::getInstance();
            $moduleManager->setModuleDirty('fstab');
        }

        $objects = $this->database->get($this->dataModelPath);
        $this->BuildCreds($objects);
        $this->BuildSecrets($objects);

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

        $object = $this->database->get($this->dataModelPath, $params['uuid']);
        $fs = \OMV\System\Filesystem\Filesystem::getImpl($object->get('uuid'));
        if (!is_null($fs) && $fs->exists()) {
            if (TRUE === $this->IsSharedFolder($object)) {
				throw new Exception(
					"The filesystem '%s' is used. Please remove all shares before deleting.",
					$fs->getPredictableDeviceFile());
			}
            if (TRUE === $fs->isMounted()) {
				$fs->umount(TRUE);
			}
            Rpc::call('FsTab', 'delete', ['uuid' => $object->get('mntentref')], $context);
            $this->database->delete($object);
            
            $this->RemoveCreds($object);
            $objects = $this->database->get($this->dataModelPath);
            $this->BuildSecrets($objects);
        }
    }
    
    /**
     * Mount the configuration of a single existing union filesystem.
     *
     * @param $params  The method parameters.
     * @param $context The context of the caller.
     *
     * @return void
     */
    public function mount($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $object = $this->database->get($this->dataModelPath, $params['uuid']);
        $fs = \OMV\System\Filesystem\Filesystem::getImpl($object->get('uuid'));
        if (!is_null($fs) && $fs->exists()) {
			if (TRUE === $fs->isMounted()) {
				throw new Exception(
					"The filesystem '%s' is already mounted.",
					$fs->getPredictableDeviceFile());
			}
			$fs->mount();
		}
    }
    
    /**
     * Unmount the configuration of a single existing union filesystem.
     *
     * @param $params  The method parameters.
     * @param $context The context of the caller.
     *
     * @return void
     */
    public function unmount($params, $context)
    {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.common.objectuuid');

        $object = $this->database->get($this->dataModelPath, $params['uuid']);
        $fs = \OMV\System\Filesystem\Filesystem::getImpl($object->get('uuid'));
        if (!is_null($fs) && $fs->exists()) {
			if (TRUE === $fs->isMounted())
				$fs->umount(TRUE);
		}
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
        $mountPoint = MountPoint::buildPath($object->get('uuid'));

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
    
    /**
     * This function checks if there is a shared folder and returns true of false
     *
     * @param object (remotemount object)
     *
     * @return true if shared folder exists or false if not
     */
    private function IsSharedFolder($object)
    {
        $isShared = FALSE;
        $ref=$object->GetAssoc()['mntentref'];
        $db = \OMV\Config\Database::getInstance();
		$sharedobjects = $db->get("conf.system.sharedfolder");
        foreach ($sharedobjects as $sharedobject) {
            $share=$sharedobject->getAssoc();
            if (strcmp($share['mntentref'], $ref) == 0) {
                $isShared = TRUE;
            }
        }

        return $isShared;
    }
    
    /**
     * This function builds credentials files for cifs
     *
     * @param objects (remotemount objects)
     *
     * @return none
     */   
    private function BuildCreds($objects)
    {
        $cifsCreds = '/root/.cifscredentials-';
        foreach ($objects as $fs) {
            if ($fs->get('mounttype') == 'cifs') {
                if (!empty($fs->get('username'))) {
                    $credFile = $cifsCreds . $fs->get('mntentref');
                    file_put_contents(
                        $credFile,
                        sprintf("username=%s\npassword=%s", $fs->get('username'), $fs->get('password'))
                    );
                    chmod($credFile, 0600);
                }
            }
        }
    }
    
        /**
     * This function remove credentials files for cifs
     *
     * @param object (remotemount object)
     *
     * @return none
     */   
    private function RemoveCreds($object)
    {
        $cifsCreds = '/root/.cifscredentials-';
        if ($object->get('mounttype') == 'cifs') {
            $credFile = $cifsCreds . $object->get('mntentref');
            unlink($credFile);
        }
    }
    
    
    /**
     * This function builds secrets file for davfs
     *
     * @param objects (remotemount objects)
     *
     * @return none
     */   
    private function BuildSecrets($objects)
    {
        $credFile = '/etc/davfs2/secrets';
        $bakFile = '/etc/davfs2/secrets.bak';
        copy($credFile, $bakFile);
        file_put_contents($credFile, '# Credentials file created by Open Media Vault WebDAV plugin');
        foreach ($objects as $fs) {
            if ($fs->get('mounttype') == 'davfs') {
                if (!empty($fs->get('username'))) {
                    file_put_contents(
                        $credFile,
                        sprintf("\n%s %s %s", $fs->get('server'), $fs->get('username'), $fs->get('password')), FILE_APPEND | LOCK_EX
                    );
                    chmod($credFile, 0600);
                }
            }
        }
    }
}
