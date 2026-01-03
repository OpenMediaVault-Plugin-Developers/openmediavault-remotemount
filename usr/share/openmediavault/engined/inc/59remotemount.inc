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

use OMV\Config\Database;
use OMV\System\Filesystem\Backend\Manager;
use OMV\System\Filesystem\Backend\Cifs;
use OMV\System\Filesystem\Backend\Nfs;
use OMV\System\Filesystem\Backend\Nfs4;
use OMV\System\Filesystem\Backend\Davfs;
use OMV\System\Filesystem\Backend\S3fs;
use OMV\System\Filesystem\Backend\Fuse;

$database = Database::getInstance();
$filesystemBackendManager = Manager::getInstance();
$filesystemBackendManager->registerBackend(new Cifs($database));
$filesystemBackendManager->registerBackend(new Nfs($database));
$filesystemBackendManager->registerBackend(new Nfs4($database));
$filesystemBackendManager->registerBackend(new Davfs($database));
$filesystemBackendManager->registerBackend(new S3fs($database));
$filesystemBackendManager->registerBackend(new Fuse($database));
