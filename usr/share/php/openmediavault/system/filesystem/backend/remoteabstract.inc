<?php

/**
 * Copyright (C) 2014-2025 openmediavault plugin developers.
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

namespace OMV\System\Filesystem\Backend;

use OMV\Config\Database;
use OMV\Config\DatabaseException;
use OMV\Exception;
use OMV\System\Filesystem\Remote;
use SplFileObject;

abstract class RemoteAbstract extends BackendAbstract
{
    /**
     * @var Database
     */
    protected $database;

    /**
     * @var string
     */
    protected $dataModelPath = 'conf.service.remotemount.mount';

    /**
     * @var string
     */
    private $mountPointDataModelPath = 'conf.system.filesystem.mountpoint';

    public function __construct(Database $database)
    {
        $this->database = $database;
    }

    /**
     * Get a list of filesystems of the given filesystem backend.
     *
     * @return array
     */
    public function enumerate()
    {
        $filesystems = [];
        $objects = [];

        try {
            foreach ($this->database->get($this->dataModelPath) as $object) {
                if ($object->get('mounttype') === $this->type) {
                    $objects[] = $object;
                }
            }
        } catch (DatabaseException $e) {
            return $filesystems;
        }

        foreach ($objects as $object) {
            $filesystem = $this->getImpl($object->get('uuid'));

            $filesystems[$filesystem->getDeviceFile()] = [
                'devicefile' => $filesystem->getDeviceFile(),
                'uuid' => $filesystem->getUuid(),
                'label' => $filesystem->getLabel(),
                'type' => $filesystem->getType(),
            ];
        }

        return $filesystems;
    }

    /**
     * Check whether the filesystem implemented by this backend is identified by
     * the block device identification library. If this is not the case, then
     * the backend must override the enumerate method.
     *
     * @return bool
     */
    public function isBlkidEnumerated()
    {
        return false;
    }

    /**
     * Check whether the given filesystem identifier is represented by this
     * filesystem backend.
     *
     * @param string $id The filesystem identifier (e.g. UUID or device path).
     *
     * @return bool
     */
    public function isTypeOf($id)
    {
        foreach ($this->enumerate() as $mount) {
            if ($mount['uuid'] == $id || $mount['devicefile'] == $id) {
                return true;
            }
        }

        return false;
    }

    /**
     * Does the filesystem have a device file? E.g. union mount or overlay
     * filesystems like Mergerfs don't have a device file.
     *
     * @return bool
     */
    public function hasDeviceFile()
    {
        return false;
    }

/**
     * @param string $args A string with either the UUID, mount point or the
     *                     fsname.
     *
     * @return Remote
     *
     * @throws Exception
     */
    public function getImpl($args)
    {
        $uuid = $args;

        if (!is_uuid($args)) {
            $mountPoint = $this->fetchMountPointByFsnameAndType($args, $this->type);
            $uuid = $this->extractUuidFromMountPoint($mountPoint);
        }

        $remoteObject = $this->database->get($this->dataModelPath, $uuid);
        $mntObject = $this->database->get($this->mountPointDataModelPath, $remoteObject->get('mntentref'));

        return new Remote($remoteObject->get('uuid'), $mntObject->get('dir'), $remoteObject->get('name'), $this);
    }

    /**
     * Extract the UUID of a mount by it's mount point.
     *
     * @param string $mountPoint
     *
     * @return string
     *
     * @throws Exception
     */
    public static function extractUuidFromMountPoint($mountPoint)
    {
        $regex = '/[a-f0-9]{8}\-[a-f0-9]{4}\-4[a-f0-9]{3}\-(8|9|a|b)[a-f0-9]{3}\-[a-f0-9]{12}/';
        $mountsFile = '/proc/mounts';

        foreach (new SplFileObject($mountsFile) as $content) {
            $splitContent = preg_split('/\s+/', $content);
            if (in_array($mountPoint, $splitContent)) {
                preg_match($regex, $content, $match);
                if ($match) {
                    $uuid = $match[0];
                    break;
                }
            }
        }
        if (!is_uuid($uuid)) {
            $units = '/etc/systemd/system/srv-remotemount-*.mount';
            $cmd = sprintf('grep -B6 -h "%s" %s | awk -F":" \'/Description/ { print $2 }\' | sed "/^$/d"', $mountPoint, $units);
            exec($cmd, $output);
            $uuid = $output[0];
        }
        if (!is_uuid($uuid)) {
            throw new Exception(sprintf(
                'Couldn\'t extract an UUID from the provided path \'%s\'.',
                $mountPoint
            ));
        }

        return $uuid;
    }

    /**
     * Fetch the mount point from /proc/mounts or systemd mount units.
     *
     * @param string $fsname
     * @param string $type
     *
     * @return string
     *
     * @throws Exception
     */
    private static function fetchMountPointByFsnameAndType($fsname, $type)
    {
        $mounts = file('/proc/mounts');
        $types = ['nfs','nfs4','autofs'];
        $mp = '';
        foreach ($mounts as $mount) {
            $splitContent = preg_split('/\s+/', $mount);
            if (in_array($splitContent[2], $types)) {
                $fs = 'nfs';
            }
            if ($splitContent[2] == 'davfs' && $type == 'fuse') {
                $type = 'davfs';
            }
            if ($type === $splitContent[2] || $type === $fs) {
                if ($fsname === $splitContent[0] || $fsname === $splitContent[1]) {
                    $mp = $splitContent[1];
                    break;
                }
            }
        }
        if ($mp == '') {
            $units = '/etc/systemd/system/srv-remotemount-*.mount';
            $cmd = sprintf('grep -A14 -B14 -h "%s" %s | awk -F"=" \'$1 == "Where" { print $2 }\'', $fsname, $units);
            exec($cmd, $output);
            $mp = $output[0];
        }
        if ($mp == '') {
            throw new Exception(sprintf(
                'Could not fetch a matching mount point from the provided fsname: \'%s\'.',
                $fsname
            ));
        }
        return ($mp);
    }
}
