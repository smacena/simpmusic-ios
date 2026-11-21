package com.maxrave.simpmusic

import androidx.compose.runtime.remember
import androidx.compose.ui.window.ComposeUIViewController
import coil3.ImageLoader
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSOperationQueue
import platform.UIKit.UIApplicationDidReceiveMemoryWarningNotification
import coil3.compose.LocalPlatformContext
import coil3.compose.setSingletonImageLoaderFactory
import coil3.disk.DiskCache
import coil3.network.ktor3.KtorNetworkFetcherFactory
import coil3.request.CachePolicy
import coil3.request.crossfade
import com.maxrave.common.AppIdentity
import com.maxrave.data.di.loader.loadAllModules
import com.maxrave.logger.Logger
import com.maxrave.simpmusic.di.viewModelModule
import com.maxrave.simpmusic.utils.NetworkFirstInterceptor
import com.maxrave.simpmusic.utils.VersionManager
import com.maxrave.simpmusic.utils.imageHttpClient
import com.maxrave.simpmusic.utils.iosDocumentsPath
import okio.FileSystem
import okio.SYSTEM
import org.koin.core.context.loadKoinModules
import org.koin.core.context.startKoin
import org.simpmusic.discord.configDiscord
import org.simpmusic.lastfm.configLastfm
import platform.UIKit.UIDevice

private var started = false

/** One-time process setup, mirroring runDesktopApp(): logging, DI, version info. */
private fun startApp() {
    if (started) return
    started = true
    Logger.enableFileLogging("${iosDocumentsPath()}/logs")
    configDiscord(BuildKonfig.discordClientId)
    com.maxrave.simpmusic.expect.startNetworkMonitor()
    startKoin {
        loadAllModules(
            AppIdentity(
                applicationId = "com.maxrave.simpmusic",
                versionName = BuildKonfig.versionName,
                platform = "${UIDevice.currentDevice.systemName} ${UIDevice.currentDevice.systemVersion}",
            ),
        )
        loadKoinModules(viewModelModule)
    }
    VersionManager.initialize()
    configLastfm(BuildKonfig.lastfmApiKey, BuildKonfig.lastfmSecret)
    com.maxrave.simpmusic.utils.IosAutoBackup.runIfDue()
    platform.Foundation.NSNotificationCenter.defaultCenter.addObserverForName(
        platform.UIKit.UIApplicationWillEnterForegroundNotification,
        null,
        platform.Foundation.NSOperationQueue.mainQueue,
    ) { _ -> com.maxrave.simpmusic.utils.IosAutoBackup.runIfDue() }
}

fun MainViewController() =
    ComposeUIViewController {
        remember { startApp() }
        val context = LocalPlatformContext.current
        setSingletonImageLoaderFactory {
            lateinit var imageLoader: ImageLoader
            imageLoader =
                ImageLoader
                    .Builder(context)
                    .components {
                        add(NetworkFirstInterceptor { imageLoader })
                        add(KtorNetworkFetcherFactory(httpClient = { imageHttpClient }))
                    }.diskCachePolicy(CachePolicy.ENABLED)
                    .networkCachePolicy(CachePolicy.ENABLED)
                    .diskCache(
                        DiskCache
                            .Builder()
                            .directory(FileSystem.SYSTEM_TEMPORARY_DIRECTORY / "image_cache")
                            .maxSizeBytes(256L * 1024 * 1024)
                            .build(),
                    ).crossfade(true)
                    .build()
            // Low on memory (a game or the camera opened while music plays in the background):
            // drop the decoded covers rather than have iOS end the app and stop the music.
            NSNotificationCenter.defaultCenter.addObserverForName(
                UIApplicationDidReceiveMemoryWarningNotification,
                null,
                NSOperationQueue.mainQueue,
            ) { _ -> imageLoader.memoryCache?.clear() }
            imageLoader
        }
        App()
    }
