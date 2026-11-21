package com.maxrave.simpmusic.expect

import com.maxrave.logger.Logger
import com.maxrave.simpmusic.utils.iosDocumentsPath
import com.maxrave.simpmusic.utils.presentShareSheet
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.withContext
import okio.FileSystem
import okio.Path.Companion.toPath
import okio.SYSTEM
import platform.Foundation.NSURL

private const val TAG = "ShareImage"

private fun writeToDocuments(
    bytes: ByteArray,
    fileName: String,
): String {
    val path = "${iosDocumentsPath()}/$fileName"
    FileSystem.SYSTEM.write(path.toPath()) { write(bytes) }
    return path
}

// Saved into the app's Documents folder (visible in the Files app). Writing to the photo library
// would need an NSPhotoLibraryAddUsageDescription prompt for every first save.
actual suspend fun saveImageToDevice(
    bytes: ByteArray,
    fileName: String,
): Boolean =
    withContext(Dispatchers.IO) {
        runCatching { writeToDocuments(bytes, fileName) }
            .onFailure { Logger.w(TAG, "Could not save image: ${it.message}") }
            .isSuccess
    }

actual suspend fun shareImage(
    bytes: ByteArray,
    fileName: String,
    chooserTitle: String,
    mimeType: String,
): Boolean {
    val path =
        withContext(Dispatchers.IO) {
            runCatching { writeToDocuments(bytes, fileName) }
                .onFailure { Logger.w(TAG, "Could not stage image for sharing: ${it.message}") }
                .getOrNull()
        } ?: return false
    return withContext(Dispatchers.Main) { presentShareSheet(listOf(NSURL.fileURLWithPath(path))) }
}
