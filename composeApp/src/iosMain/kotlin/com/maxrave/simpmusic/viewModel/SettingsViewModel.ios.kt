package com.maxrave.simpmusic.viewModel

import com.eygraber.uri.Uri
import com.maxrave.common.DB_NAME
import com.maxrave.common.SETTINGS_FILENAME
import com.maxrave.domain.repository.CacheRepository
import com.maxrave.domain.repository.CommonRepository
import com.maxrave.logger.Logger
import com.maxrave.simpmusic.utils.iosDocumentsPath
import com.maxrave.simpmusic.utils.presentShareSheet
import com.maxrave.simpmusic.utils.unzip
import com.maxrave.simpmusic.utils.zipStored
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import multiplatform.network.cmptoast.ToastGravity
import multiplatform.network.cmptoast.showToast
import okio.FileSystem
import okio.Path.Companion.toPath
import okio.SYSTEM
import org.jetbrains.compose.resources.getString
import platform.Foundation.NSBundle
import platform.Foundation.NSURL
import simpmusic.composeapp.generated.resources.Res
import simpmusic.composeapp.generated.resources.restore_success
import kotlin.system.exitProcess

private const val TAG = "BackupRestore"

/** Where DataStoreManagerImpl.ios keeps the settings file. */
private val settingsFile get() = "${iosDocumentsPath()}/$SETTINGS_FILENAME.preferences_pb".toPath()

/** A picked file is a plain path (pickers hand back copies in the app's own storage). */
private fun Uri.toFilePath(): String = (path ?: toString()).removePrefix("file://")

actual suspend fun calculateDataFraction(cacheRepository: CacheRepository): SettingsStorageSectionFraction? = null

actual suspend fun readPickedFile(uri: Uri): ByteArray =
    withContext(Dispatchers.IO) { FileSystem.SYSTEM.read(uri.toFilePath().toPath()) { readByteArray() } }

/**
 * Same archive as Android and Desktop (settings file + database in one ZIP), so a backup made on
 * any of them restores on the others. After writing, the share sheet opens so the file can go to
 * iCloud Drive, AirDrop or anywhere else; it also stays in the app's folder in the Files app.
 */
actual suspend fun backupNative(
    commonRepository: CommonRepository,
    uri: Uri,
    backupDownloaded: Boolean,
) {
    val path = uri.toFilePath()
    withContext(Dispatchers.IO) {
        commonRepository.databaseDaoCheckpoint()
        val entries =
            buildList {
                if (FileSystem.SYSTEM.exists(settingsFile)) {
                    add("$SETTINGS_FILENAME.preferences_pb" to FileSystem.SYSTEM.read(settingsFile) { readByteArray() })
                }
                add(DB_NAME to FileSystem.SYSTEM.read(checkNotNull(commonRepository.getDatabasePath()) { "no database path" }.toPath()) { readByteArray() })
            }
        FileSystem.SYSTEM.write(path.toPath()) { write(zipStored(entries)) }
    }
    withContext(Dispatchers.Main) { presentShareSheet(listOf(NSURL.fileURLWithPath(path))) }
}

actual suspend fun restoreNative(
    commonRepository: CommonRepository,
    uri: Uri,
    getData: () -> Unit,
) {
    val entries = withContext(Dispatchers.IO) { unzip(readPickedFile(uri)) }
    withContext(Dispatchers.IO) {
        entries["$SETTINGS_FILENAME.preferences_pb"]?.let { bytes ->
            FileSystem.SYSTEM.write(settingsFile) { write(bytes) }
        }
        entries[DB_NAME]?.let { bytes ->
            commonRepository.databaseDaoCheckpoint()
            commonRepository.closeDatabase()
            val dbPath = checkNotNull(commonRepository.getDatabasePath()) { "no database path" }
            // A leftover write-ahead log belongs to the OLD database: SQLite would replay it onto
            // the restored file on the next open and corrupt it. Remove both side files first.
            listOf("$dbPath-wal", "$dbPath-shm").forEach { FileSystem.SYSTEM.delete(it.toPath(), mustExist = false) }
            FileSystem.SYSTEM.write(dbPath.toPath()) { write(bytes) }
        }
    }
    Logger.i(TAG, "restored ${entries.keys}")
    withContext(Dispatchers.Main) {
        showToast(getString(Res.string.restore_success), ToastGravity.Bottom)
        // iOS gives an app no way to relaunch itself: close, and the next launch reads the
        // restored database and settings.
        showToast("Reopen SimpMusic to apply the restored backup", ToastGravity.Bottom)
        delay(2500)
        exitProcess(0)
    }
}

actual fun getPackageName(): String = NSBundle.mainBundle.bundleIdentifier ?: "com.maxrave.simpmusic"

actual fun getFileDir(): String = iosDocumentsPath()

/**
 * iOS keeps the app's language in the AppleLanguages default (the same one the per-app language
 * in the Settings app writes). Compose resources read NSLocale.preferredLanguages, which follows
 * it, so the new language applies from the next launch; the screen tells the user to reopen.
 */
actual fun changeLanguageNative(code: String) {
    val tag = if (code == "id-ID") "id-ID" else code
    platform.Foundation.NSUserDefaults.standardUserDefaults.setObject(listOf(tag), forKey = "AppleLanguages")
    platform.Foundation.NSUserDefaults.standardUserDefaults.synchronize()
}
