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
            // AVPlayer streams straight from the network: no song cache on disk yet.
            single<CacheRepository> {
                object : CacheRepository {
                    override suspend fun getCacheSize(cacheName: String): Long = 0L

                    override fun clearCache(cacheName: String) {}

                    override suspend fun getAllCacheKeys(cacheName: String): List<String> = emptyList()

                    override suspend fun getFullyCachedSongIds(): List<String> = emptyList()

                    override suspend fun removeCachedSong(videoId: String) {}
                }
            }
            single<DownloadHandler> { IosDownloadHandler(songRepository = get()) }
        },
    )
}

/** Login sync is one-sided per platform: Desktop hosts, Android sends, iOS takes no part. */
actual fun loadLoginSyncModule() {
    loadKoinModules(
        module {
            // Settings asks this whether a pairing exists; on iOS there never is one.
            single<LibrarySyncRepository> {
                object : LibrarySyncRepository {
                    override val state: StateFlow<LibrarySyncState> = MutableStateFlow(LibrarySyncState())
                    override val pendingSettings: StateFlow<PendingSettings?> = MutableStateFlow(null)

                    override suspend fun syncNow() {}

                    override suspend fun unpairAll() {}

                    override suspend fun applyPendingSettings() {}

                    override suspend fun dismissPendingSettings() {}
                }
            }
        },
    )
}
