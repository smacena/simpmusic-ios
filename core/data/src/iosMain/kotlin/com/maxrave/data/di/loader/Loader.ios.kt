package com.maxrave.data.di.loader

import com.maxrave.common.Config.SERVICE_SCOPE
import com.maxrave.data.mediaservice.ios.AvPlayerAdapter
import com.maxrave.data.mediaservice.ios.IosDownloadHandler
import com.maxrave.domain.data.model.librarysync.LibrarySyncState
import com.maxrave.domain.data.model.librarysync.PendingSettings
import com.maxrave.domain.mediaservice.handler.DownloadHandler
import com.maxrave.domain.mediaservice.player.MediaPlayerInterface
import com.maxrave.domain.repository.CacheRepository
import com.maxrave.domain.repository.LibrarySyncRepository
import com.maxrave.domain.repository.LibrarySyncPhoneRepository
import com.maxrave.domain.repository.LoginSyncHostRepository
import com.maxrave.domain.repository.LoginSyncSenderRepository
import com.maxrave.data.loginsync.LoginSyncHostRepositoryImpl
import com.maxrave.data.loginsync.LoginSyncSenderRepositoryImpl
import com.maxrave.data.loginsync.LoginSyncStore
import org.simpmusic.loginsync.LoginSyncClient
import com.maxrave.domain.data.model.loginsync.DesktopInfo
import com.maxrave.domain.data.model.loginsync.LoginSyncService
import com.maxrave.domain.data.model.librarysync.SyncPeer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.koin.core.context.loadKoinModules
import org.koin.core.qualifier.named
import org.koin.dsl.module

actual fun loadMediaService() {
    loadKoinModules(
        module {
            // AVPlayer is driven from the main thread; the handler runs on the same scope.
            single<CoroutineScope>(qualifier = named(SERVICE_SCOPE)) { CoroutineScope(Dispatchers.Main + SupervisorJob()) }
            single<MediaPlayerInterface> {
                AvPlayerAdapter(
                    coroutineScope = get(named(SERVICE_SCOPE)),
                    dataStoreManager = get(),
                    streamRepository = get(),
                )
            }
            single<CacheRepository> { com.maxrave.data.repository.IosCacheRepository() }
            single<DownloadHandler> { IosDownloadHandler(songRepository = get(), dataStoreManager = get()) }
        },
    )
}

/**
 * Login sync on iOS goes both ways: the iPhone hosts a QR for the Android app to send sign-ins to
 * (like Desktop), or scans a computer's QR and sends its own (like Android). Library sync (the paired
 * channel) stays Android/Desktop-only, so its repository is a stub that never pairs.
 */
actual fun loadLoginSyncModule() {
    loadKoinModules(
        module {
            single { LoginSyncStore(get(), get(), get()) }
            single<LoginSyncSenderRepository> { LoginSyncSenderRepositoryImpl(get(), LoginSyncClient()) }
            single<LoginSyncHostRepository> { LoginSyncHostRepositoryImpl(get()) }
            single<LibrarySyncPhoneRepository> {
                object : LibrarySyncPhoneRepository {
                    override val state: StateFlow<LibrarySyncState> = MutableStateFlow(LibrarySyncState())
                    override val pendingSettings: StateFlow<PendingSettings?> = MutableStateFlow(null)

                    override suspend fun syncNow() {}

                    override suspend fun unpairAll() {}

                    override suspend fun applyPendingSettings() {}

                    override suspend fun dismissPendingSettings() {}

                    override fun isPairingCode(qrText: String): Boolean = false

                    override suspend fun reach(qrText: String): DesktopInfo = throw UnsupportedOperationException("library sync is not available on iOS")

                    override suspend fun pair(): SyncPeer = throw UnsupportedOperationException("library sync is not available on iOS")

                    override fun cancelPairing() {}

                    override suspend fun sendLogins(services: Set<LoginSyncService>): List<LoginSyncService> = emptyList()
                }
            }
            single<LibrarySyncRepository> { get<LibrarySyncPhoneRepository>() }
        },
    )
}
