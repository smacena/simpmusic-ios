package com.maxrave.data.io

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.withContext
import platform.Foundation.NSData
import platform.Foundation.dataWithContentsOfFile
import platform.posix.memcpy

/** Bytes of a picked image: a plain path or a file:// URI into the app's own storage. */
@OptIn(ExperimentalForeignApi::class)
actual suspend fun readLocalImageBytes(uri: String): ByteArray? =
    withContext(Dispatchers.IO) {
        val data = NSData.dataWithContentsOfFile(uri.removePrefix("file://")) ?: return@withContext null
        val bytes = ByteArray(data.length.toInt())
        if (bytes.isNotEmpty()) bytes.usePinned { memcpy(it.addressOf(0), data.bytes, data.length) }
        bytes
    }
