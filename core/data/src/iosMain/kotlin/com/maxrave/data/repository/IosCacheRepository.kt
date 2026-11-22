@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.maxrave.data.repository

import com.maxrave.common.Config
import com.maxrave.data.mediaservice.ios.iosDownloadDir
import com.maxrave.domain.repository.CacheRepository
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileSize
import platform.Foundation.NSNumber
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSURLCache
import platform.Foundation.NSUserDomainMask

/**
 * iOS storage for Settings → Storage. AVPlayer keeps no song cache of its own, so "player cache" is
 * the app's URL cache (artwork, API responses, stream pieces); downloads are Documents/downloads;
 * the canvas cache is Caches/canvas.
 */
internal class IosCacheRepository : CacheRepository {
    override suspend fun getCacheSize(cacheName: String): Long =
        when (cacheName) {
            Config.PLAYER_CACHE -> NSURLCache.sharedURLCache.currentDiskUsage.toLong()
            Config.DOWNLOAD_CACHE -> folderSize(iosDownloadDir())
            Config.CANVAS_CACHE -> folderSize(canvasDir())
            else -> 0L
        }

    override fun clearCache(cacheName: String) {
        when (cacheName) {
            Config.PLAYER_CACHE -> NSURLCache.sharedURLCache.removeAllCachedResponses()
            Config.DOWNLOAD_CACHE -> clearFolder(iosDownloadDir())
            Config.CANVAS_CACHE -> clearFolder(canvasDir())
        }
    }

    override suspend fun getAllCacheKeys(cacheName: String): List<String> = emptyList()

    override suspend fun getFullyCachedSongIds(): List<String> = emptyList()

    override suspend fun removeCachedSong(videoId: String) {}

    private fun canvasDir(): String {
        val caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, true).firstOrNull() as? String ?: ""
        return "$caches/canvas"
    }

    private fun folderSize(path: String): Long {
        val fm = NSFileManager.defaultManager
        val names = fm.subpathsOfDirectoryAtPath(path, null).orEmpty().filterIsInstance<String>()
        return names.sumOf { name ->
            ((fm.attributesOfItemAtPath("$path/$name", null)?.get(NSFileSize) as? NSNumber)?.longLongValue ?: 0L)
        }
    }

    private fun clearFolder(path: String) {
        val fm = NSFileManager.defaultManager
        fm.contentsOfDirectoryAtPath(path, null).orEmpty().filterIsInstance<String>().forEach { fm.removeItemAtPath("$path/$it", null) }
    }
}
