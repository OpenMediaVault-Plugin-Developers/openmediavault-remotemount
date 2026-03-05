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

/**
 * Backend registered as 'rclone' to match the mounttype stored in the
 * OMV config database (conf.system.filesystem.mountpoint.type).
 * Used by enumerateSharedFolders and related DB-driven lookups.
 */
class Rclone extends RemoteAbstract
{
    public function __construct(Database $database)
    {
        parent::__construct($database);

        $this->type = 'rclone';
        $this->properties = self::PROP_POSIX_ACL;
    }
}

/**
 * Backend registered as 'fuse.rclone' to match the kernel filesystem type
 * that rclone reports in /proc/mounts. Used by getImplByMountPoint() which
 * reads the kernel fstype and calls getBackendByType('fuse.rclone').
 * This is what allows rclone mounts to appear in the shared folder dropdown.
 */
class FuseRclone extends Rclone
{
    public function __construct(Database $database)
    {
        parent::__construct($database);

        $this->type = 'fuse.rclone';
    }
}
