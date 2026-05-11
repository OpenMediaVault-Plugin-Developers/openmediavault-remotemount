<?php

/**
 * Copyright (C) 2014-2026 openmediavault plugin developers.
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
    // Mount points already handed out in the current getCandidates() sweep.
    // The PID check handles forking daemons (each request is a separate fork).
    // The 60 s window is a fallback for non-forking daemons; getCandidates
    // completes well within that window even with many slow filesystem entries.
    private static array $handedOutMountPoints = [];
    // Cache of fsname → mount-point resolutions within the same sweep so that
    // the same fsname (e.g. //HOST/SHARE looked up once per shared-folder that
    // lives on it) always returns the same mount point without triggering the
    // duplicate-suppression logic meant for distinct filesystems.
    private static array $resolvedFsnames = [];
    private static float $handedOutAt = 0.0;
    private static int $handedOutPid = -1;

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
            $uuid = $this->findUuidByDir($args);
        }

        if (!is_uuid($uuid)) {
            $uuid = $this->findUuidByFsname($args);
        }

        if (!is_uuid($uuid)) {
            $mountPoint = $this->fetchMountPointByFsnameAndType($args, $this->type);
            $uuid = $this->extractUuidFromMountPoint($mountPoint);
        }

        $remoteObject = $this->database->get($this->dataModelPath, $uuid);
        $mntObject = $this->database->get($this->mountPointDataModelPath, $remoteObject->get('mntentref'));

        return new Remote($remoteObject->get('uuid'), $mntObject->get('dir'), $remoteObject->get('name'), $this);
    }

    /**
     * Resolve a mount directory path to a remotemount UUID via the config
     * database. Works regardless of whether the mount is currently active.
     *
     * @param string $dir The mount directory path.
     *
     * @return string The UUID, or empty string if not found.
     */
    private function findUuidByDir($dir)
    {
        // FuseRclone backend has type 'fuse.rclone' but DB stores 'rclone'.
        $dbType = ($this->type === 'fuse.rclone') ? 'rclone' : $this->type;

        try {
            foreach ($this->database->get($this->dataModelPath) as $object) {
                if ($object->get('mounttype') !== $dbType) {
                    continue;
                }
                $mntObject = $this->database->get(
                    $this->mountPointDataModelPath,
                    $object->get('mntentref')
                );
                $mntDir = $mntObject->get('dir');
                // Exact match: args is the remotemount directory itself.
                if ($mntDir === $dir) {
                    return $object->get('uuid');
                }
                // Prefix match: args is a sub-path within one of our mounts
                // (e.g. a bind-mount source like /srv/remotemount/sftp1/subdir
                // created by the SFTP plugin). The trailing slash prevents
                // false matches between /srv/remotemount/sftp1 and
                // /srv/remotemount/sftp10.
                if (strpos($dir, rtrim($mntDir, '/') . '/') === 0) {
                    return $object->get('uuid');
                }
            }
        } catch (\Exception $e) {
            // Fall through to the existing grep-based fallback.
        }

        return '';
    }

    /**
     * Resolve a remotemount UUID from its filesystem source path (fsname) via
     * the config database. Works regardless of whether the mount is active or
     * a unit file exists. Handles \040 octal encoding used in /proc/mounts.
     *
     * @param string $fsname
     *
     * @return string The UUID, or empty string if not found.
     */
    private function findUuidByFsname($fsname)
    {
        $dbType = ($this->type === 'fuse.rclone') ? 'rclone' : $this->type;
        // Normalize \040 octal encoding (used in /proc/mounts) to literal spaces
        // so it matches the unencoded values stored in the database.
        $normalized = str_replace('\\040', ' ', $fsname);

        try {
            foreach ($this->database->get($this->dataModelPath) as $object) {
                if ($object->get('mounttype') !== $dbType) {
                    continue;
                }
                $computed = $this->computeFsnameForObject($object);
                if ($computed !== '' &&
                    ($computed === $fsname || $computed === $normalized)) {
                    return $object->get('uuid');
                }
            }
        } catch (\Exception $e) {
            // Fall through to the existing /proc/mounts + unit-file fallback.
        }

        return '';
    }

    /**
     * Reconstruct the expected filesystem source path (fsname) for a config
     * object. Returns empty string for types where the fsname is not derivable
     * from the database fields alone (e.g. rclone).
     *
     * @param \OMV\Config\ConfigObject $object
     *
     * @return string
     */
    private function computeFsnameForObject($object)
    {
        switch ($object->get('mounttype')) {
            case 'cifs':
                return '//' . $object->get('server') . '/' . $object->get('sharename');
            case 'nfs':
                return $object->get('server') . ':' . $object->get('sharename');
            case 'davfs':
                return $object->get('server');
            default:
                return '';
        }
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
            $units = '/etc/systemd/system/srv-remotemount-*.service';
            $cmd = sprintf('grep -rlF "%s" %s 2>/dev/null | xargs -r grep -h "^Description=" | awk -F":" \'/Description/ { print $NF }\' | tr -d " \n"', $mountPoint, $units);
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
        $now = microtime(true);
        $pid = getmypid();
        if ($pid !== self::$handedOutPid || ($now - self::$handedOutAt) > 60.0) {
            self::$handedOutMountPoints = [];
            self::$resolvedFsnames = [];
            self::$handedOutPid = $pid;
        }
        self::$handedOutAt = $now;

        // Same fsname already resolved in this sweep (e.g. two shared folders
        // on the same remote mount): return the cached result directly so the
        // duplicate-suppression logic doesn't block the second lookup.
        if (isset(self::$resolvedFsnames[$fsname])) {
            return self::$resolvedFsnames[$fsname];
        }

        $mounts = file('/proc/mounts');
        $types = ['nfs','nfs4','autofs'];
        $mp = '';
        $fs = '';
        foreach ($mounts as $mount) {
            $splitContent = preg_split('/\s+/', $mount);
            if (in_array($splitContent[2], $types)) {
                $fs = 'nfs';
            }
            if ($splitContent[2] === 'fuse.rclone') {
                $fs = 'rclone';
            }
            if ($splitContent[2] == 'davfs' && $type == 'fuse') {
                $type = 'davfs';
            }
            if ($type === $splitContent[2] || $type === $fs) {
                if ($fsname === $splitContent[0] || $fsname === $splitContent[1]) {
                    $candidate = $splitContent[1];
                    if (!in_array($candidate, self::$handedOutMountPoints)) {
                        $mp = $candidate;
                        self::$handedOutMountPoints[] = $mp;
                        self::$resolvedFsnames[$fsname] = $mp;
                        break;
                    }
                }
            }
        }
        if ($mp == '') {
            $units = '/etc/systemd/system/srv-remotemount-*.mount';
            $cmd = sprintf('grep -A14 -B14 -h "%s" %s | awk -F"=" \'$1 == "Where" { print $2 }\'', $fsname, $units);
            exec($cmd, $output);
            foreach (($output ?? []) as $candidate) {
                $candidate = trim($candidate);
                if ($candidate !== '' && !in_array($candidate, self::$handedOutMountPoints)) {
                    $mp = $candidate;
                    self::$handedOutMountPoints[] = $mp;
                    self::$resolvedFsnames[$fsname] = $mp;
                    break;
                }
            }
        }
        if ($mp == '' && ($type === 'fuse.rclone' || $type === 'rclone')) {
            $units = '/etc/systemd/system/srv-remotemount-*.service';
            $cmd = sprintf('grep -rlF "%s" %s 2>/dev/null | head -1', $fsname, $units);
            exec($cmd, $output);
            if (!empty($output[0])) {
                $mp = $fsname;
                self::$handedOutMountPoints[] = $mp;
                self::$resolvedFsnames[$fsname] = $mp;
            }
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
