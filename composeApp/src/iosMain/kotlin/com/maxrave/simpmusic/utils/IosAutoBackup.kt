package com.maxrave.simpmusic.utils

import com.maxrave.common.DB_NAME
import com.maxrave.common.SETTINGS_FILENAME
import com.maxrave.domain.manager.DataStoreManager
import com.maxrave.domain.repository.CommonRepository
import com.maxrave.logger.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okio.FileSystem
import okio.Path.Companion.toPath
import okio.SYSTEM
import org.koin.mp.KoinPlatform
import kotlin.time.Clock

/**
 * Automatic backups on iOS. Android schedules them with WorkManager; iOS's BGTaskScheduler runs a
 * task only when the system chooses, so here the check runs whenever the app starts or returns to
 * the foreground: if the chosen interval has passed, the same archive a manual backup writes goes
 * into Documents/backups (visible in the Files app, and included in the device's iCloud backup),
 * and only the newest [DataStoreManager.autoBackupMaxFiles] are kept.
 */
object IosAutoBackup {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private const val TAG = "IosAutoBackup"
    private const val DAY_MS = 24L * 60 * 60 * 1000

    fun runIfDue() {
        scope.launch {
            if (!mutex.tryLock()) return@launch
            try {
                backupIfDue()
            } catch (e: Exception) {
                Logger.e(TAG, "auto backup failed", e)
            } finally {
                mutex.unlock()
            }
        }
    }

    private suspend fun backupIfDue() {
        val koin = KoinPlatform.getKoin()
        val dataStore = koin.get<DataStoreManager>()
        if (dataStore.autoBackupEnabled.first() != DataStoreManager.TRUE) return
        val interval =
            when (dataStore.autoBackupFrequency.first()) {
                DataStoreManager.AUTO_BACKUP_FREQUENCY_WEEKLY -> 7 * DAY_MS
                DataStoreManager.AUTO_BACKUP_FREQUENCY_MONTHLY -> 30 * DAY_MS
                else -> DAY_MS
            }
        val now = Clock.System.now().toEpochMilliseconds()
        if (now - dataStore.autoBackupLastTime.first() < interval) return

        val repository = koin.get<CommonRepository>()
        val dir = "${iosDocumentsPath()}/backups".toPath()
        FileSystem.SYSTEM.createDirectories(dir)
        repository.databaseDaoCheckpoint()
        val settings = "${iosDocumentsPath()}/$SETTINGS_FILENAME.preferences_pb".toPath()
        val entries =
            buildList {
                if (FileSystem.SYSTEM.exists(settings)) add("$SETTINGS_FILENAME.preferences_pb" to FileSystem.SYSTEM.read(settings) { readByteArray() })
                val db = repository.getDatabasePath() ?: return
                add(DB_NAME to FileSystem.SYSTEM.read(db.toPath()) { readByteArray() })
            }
        val file = dir / "SimpMusic_auto_$now.backup"
        // Written to a temporary name and renamed, so a backup cut short never looks complete.
        val partial = dir / "SimpMusic_auto_$now.backup.part"
        FileSystem.SYSTEM.write(partial) { write(zipStored(entries)) }
        FileSystem.SYSTEM.atomicMove(partial, file)
        dataStore.setAutoBackupLastTime(now)

        val keep = dataStore.autoBackupMaxFiles.first().coerceAtLeast(1)
        FileSystem.SYSTEM
            .list(dir)
            .filter { it.name.startsWith("SimpMusic_auto_") && it.name.endsWith(".backup") }
            .sortedByDescending { it.name }
            .drop(keep)
            .forEach { FileSystem.SYSTEM.delete(it, mustExist = false) }
        Logger.i(TAG, "auto backup written (${entries.size} entries), keeping $keep")
    }
}
