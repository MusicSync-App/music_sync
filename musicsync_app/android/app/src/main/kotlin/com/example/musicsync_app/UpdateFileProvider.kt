package com.example.musicsync_app

import androidx.core.content.FileProvider

/**
 * FileProvider propriu (subclasă) ca să nu intre în conflict, la unirea
 * manifestelor, cu FileProvider-ele declarate de pluginuri.
 */
class UpdateFileProvider : FileProvider()
