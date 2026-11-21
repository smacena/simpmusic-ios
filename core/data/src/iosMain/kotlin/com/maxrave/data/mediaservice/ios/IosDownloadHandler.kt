@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.maxrave.data.mediaservice.ios

import com.maxrave.common.MERGING_DATA_TYPE
import com.maxrave.domain.data.entities.DownloadState
import com.maxrave.domain.mediaservice.handler.DownloadHandler
import com.maxrave.domain.repository.SongRepository
import com.maxrave.domain.utils.isLive
import com.maxrave.domain.utils.toTrack
import com.maxrave.logger.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.lastOrNull
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import platform.Foundation.NSDocumentDirectory
import platform.Foundation.NSFileManager
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSUserDomainMask

private const val TAG = "IosDownloads"

/** Documents/downloads — inside the app, kept across launches, visible in the Files app. */
internal fun iosDownloadDir(): String {
    val documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, true).firstOrNull() as? String ?: ""
    val dir = "$documents/downloads"
    NSFileManager.defaultManager.createDirectoryAtPath(dir, withIntermediateDirectories = true, attributes = null, error = null)
    return dir
}

/** The downloaded audio file for [videoId], or null if there is none. */
internal fun downloadedAudioPath(videoId: String): String? {
    val path = "${iosDownloadDir()}/$videoId.m4a"
    return path.takeIf { NSFileManager.defaultManager.fileExistsAtPath(it) }
}

/**
 * Downloads for iOS, after Desktop's DownloadUtils: the shared YouTube.download writes the AAC
 * stream to Documents/downloads/<videoId>.m4a, and both download states (the song row and the
 * per-track map the playlist UI reads) follow it. No notifications: iOS shows the progress in-app.
 */
internal class IosDownloadHandler(
    private val songRepository: SongRepository,
) : DownloadHandler {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private val _downloads = MutableStateFlow<Map<String, Pair<DownloadHandler.Download?, DownloadHandler.Download?>>>(emptyMap())
    override val downloads: StateFlow<Map<String, Pair<DownloadHandler.Download?, DownloadHandler.Download?>>> get() = _downloads

    private val _downloadTask = MutableStateFlow<Map<String, Int>>(emptyMap())
    override val downloadTask: StateFlow<Map<String, Int>> get() = _downloadTask

    private fun publish(
        videoId: String,
        state: Int?,
    ) = _downloadTask.update { if (state == null) it - videoId else it + (videoId to state) }

    override suspend fun downloadTrack(
        videoId: String,
        title: String,
        thumbnail: String,
    ) {
        val song = songRepository.getSongById(videoId).lastOrNull() ?: return
        if (song.isLive) {
            songRepository.updateDownloadState(videoId, DownloadState.STATE_NOT_DOWNLOADED)
            publish(videoId, null)
            return
        }
        songRepository.updateDownloadState(videoId, DownloadState.STATE_DOWNLOADING)
        publish(videoId, DownloadState.STATE_DOWNLOADING)
        songRepository
            .downloadToFile(song.toTrack(), path = "${iosDownloadDir()}/$videoId", videoId = videoId, isVideo = false)
            .collect { state ->
                when {
                    state.isError -> {
                        Logger.w(TAG, "$videoId failed: ${state.errorMessage}")
                        songRepository.updateDownloadState(videoId, DownloadState.STATE_NOT_DOWNLOADED)
                        publish(videoId, DownloadState.STATE_NOT_DOWNLOADED)
                    }
                    state.isDone -> {
                        songRepository.updateDownloadState(videoId, DownloadState.STATE_DOWNLOADED)
                        publish(videoId, DownloadState.STATE_DOWNLOADED)
                    }
                }
            }
    }

    private fun deleteFilesOf(videoId: String?) {
        val manager = NSFileManager.defaultManager
        val dir = iosDownloadDir()
        manager.contentsOfDirectoryAtPath(dir, error = null).orEmpty().filterIsInstance<String>().forEach { name ->
            if (videoId == null || name.contains(videoId)) {
                manager.removeItemAtPath("$dir/$name", error = null)
                if (videoId == null) {
                    val id = name.substringBefore('.').removePrefix(MERGING_DATA_TYPE.VIDEO)
                    scope.launch { songRepository.updateDownloadState(id, DownloadState.STATE_NOT_DOWNLOADED) }
                }
            }
        }
    }

    override fun removeDownload(videoId: String) {
        deleteFilesOf(videoId)
        publish(videoId, null)
        scope.launch { songRepository.updateDownloadState(videoId, DownloadState.STATE_NOT_DOWNLOADED) }
    }

    override fun removeAllDownloads() {
        _downloadTask.value = emptyMap()
        deleteFilesOf(null)
    }
}
