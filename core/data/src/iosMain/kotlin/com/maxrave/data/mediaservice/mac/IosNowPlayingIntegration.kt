package com.maxrave.data.mediaservice.mac

import com.maxrave.ktorext.getEngine
import com.maxrave.logger.Logger
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.readRawBytes
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.withContext
import platform.Foundation.NSData
import platform.Foundation.NSNumber
import platform.Foundation.create
import platform.MediaPlayer.MPChangePlaybackPositionCommandEvent
import platform.MediaPlayer.MPMediaItemArtwork
import platform.MediaPlayer.MPMediaItemPropertyAlbumTitle
import platform.MediaPlayer.MPMediaItemPropertyArtist
import platform.MediaPlayer.MPMediaItemPropertyArtwork
import platform.MediaPlayer.MPMediaItemPropertyPlaybackDuration
import platform.MediaPlayer.MPMediaItemPropertyTitle
import platform.MediaPlayer.MPNowPlayingInfoCenter
import platform.MediaPlayer.MPNowPlayingInfoPropertyElapsedPlaybackTime
import platform.MediaPlayer.MPNowPlayingInfoPropertyPlaybackQueueCount
import platform.MediaPlayer.MPNowPlayingInfoPropertyPlaybackQueueIndex
import platform.MediaPlayer.MPNowPlayingInfoPropertyPlaybackRate
import platform.MediaPlayer.MPNowPlayingPlaybackStatePaused
import platform.MediaPlayer.MPNowPlayingPlaybackStatePlaying
import platform.MediaPlayer.MPRemoteCommandCenter
import platform.MediaPlayer.MPRemoteCommandHandlerStatusCommandFailed
import platform.MediaPlayer.MPRemoteCommandHandlerStatusSuccess
import platform.UIKit.UIImage

// The desktop handler drives macOS's Now Playing through MacOSMediaIntegration (JNA into the ObjC
// runtime). iOS has the same MediaPlayer framework natively, so this keeps that class's API —
// the shared handler code calls it unchanged — and talks to MPNowPlayingInfoCenter directly.

data class NowPlayingInfo(
    val title: String,
    val artist: String,
    val album: String = "",
    val durationSeconds: Double,
    val elapsedTimeSeconds: Double = 0.0,
    val playbackRate: Double = 1.0,
    val artworkUrl: String? = null,
    val queueIndex: Int = 0,
    val queueCount: Int = 1,
)

interface MacOSRemoteCommandListener {
    fun onPlay()

    fun onPause()

    fun onTogglePlayPause()

    fun onStop()

    fun onNextTrack()

    fun onPreviousTrack()

    fun onSeekForward()

    fun onSeekBackward()

    fun onChangePlaybackPosition(positionSeconds: Double)
}

class MacOSMediaIntegration private constructor() {
    private var listener: MacOSRemoteCommandListener? = null
    private val info = mutableMapOf<Any?, Any?>()
    private val artworkClient by lazy { HttpClient(getEngine()) }
    private var artworkUrlShown: String? = null

    fun initialize(): Boolean {
        val center = MPRemoteCommandCenter.sharedCommandCenter()
        center.playCommand.addTargetWithHandler { listener?.onPlay(); MPRemoteCommandHandlerStatusSuccess }
        center.pauseCommand.addTargetWithHandler { listener?.onPause(); MPRemoteCommandHandlerStatusSuccess }
        center.togglePlayPauseCommand.addTargetWithHandler { listener?.onTogglePlayPause(); MPRemoteCommandHandlerStatusSuccess }
        center.stopCommand.addTargetWithHandler { listener?.onStop(); MPRemoteCommandHandlerStatusSuccess }
        center.nextTrackCommand.addTargetWithHandler { listener?.onNextTrack(); MPRemoteCommandHandlerStatusSuccess }
        center.previousTrackCommand.addTargetWithHandler { listener?.onPreviousTrack(); MPRemoteCommandHandlerStatusSuccess }
        center.changePlaybackPositionCommand.addTargetWithHandler { event ->
            val position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            if (position == null) {
                MPRemoteCommandHandlerStatusCommandFailed
            } else {
                listener?.onChangePlaybackPosition(position)
                MPRemoteCommandHandlerStatusSuccess
            }
        }
        return true
    }

    fun setRemoteCommandListener(listener: MacOSRemoteCommandListener) {
        this.listener = listener
    }

    fun updateNowPlayingInfo(nowPlaying: NowPlayingInfo) {
        if (nowPlaying.artworkUrl != artworkUrlShown) info.remove(MPMediaItemPropertyArtwork)
        info[MPMediaItemPropertyTitle] = nowPlaying.title
        info[MPMediaItemPropertyArtist] = nowPlaying.artist
        info[MPMediaItemPropertyAlbumTitle] = nowPlaying.album
        info[MPMediaItemPropertyPlaybackDuration] = NSNumber(double = nowPlaying.durationSeconds)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(double = nowPlaying.elapsedTimeSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(double = nowPlaying.playbackRate)
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = NSNumber(unsignedLong = nowPlaying.queueIndex.toULong())
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = NSNumber(unsignedLong = nowPlaying.queueCount.toULong())
        publish()
    }

    @OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
    suspend fun loadAndSetArtwork(url: String) {
        val image =
            withContext(Dispatchers.IO) {
                runCatching {
                    val bytes = artworkClient.get(url).readRawBytes()
                    val data = bytes.usePinned { NSData.create(bytes = it.addressOf(0), length = bytes.size.toULong()) }
                    UIImage.imageWithData(data)
                }.onFailure { Logger.w(TAG, "artwork load failed: ${it::class.simpleName}") }.getOrNull()
            } ?: return
        withContext(Dispatchers.Main) {
            artworkUrlShown = url
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize = image.size) { _ -> image }
            publish()
        }
    }

    fun updatePlaybackState(isPlaying: Boolean) {
        MPNowPlayingInfoCenter.defaultCenter().playbackState =
            if (isPlaying) MPNowPlayingPlaybackStatePlaying else MPNowPlayingPlaybackStatePaused
        info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(double = if (isPlaying) 1.0 else 0.0)
        publish()
    }

    fun updateCommandsEnabled(
        hasNext: Boolean,
        hasPrevious: Boolean,
        canSeek: Boolean,
    ) {
        val center = MPRemoteCommandCenter.sharedCommandCenter()
        center.nextTrackCommand.enabled = hasNext
        center.previousTrackCommand.enabled = hasPrevious
        center.changePlaybackPositionCommand.enabled = canSeek
    }

    fun updateElapsedTime(
        elapsedSeconds: Double,
        rate: Double,
    ) {
        if (info.isEmpty()) return
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(double = elapsedSeconds)
        publish()
    }

    private var lastPublishedElapsed = -10.0
    private var lastDuration = -1.0
    private var lastPlaying: Boolean? = null

    /**
     * Keeps elapsed time, duration and rate current. Called on every progress tick (50 ms), so it
     * only republishes when something the system cannot extrapolate changed: iOS advances the
     * elapsed time itself from the rate, so a drift under a second needs no update.
     */
    fun updateTiming(
        elapsedSeconds: Double,
        durationSeconds: Double,
        isPlaying: Boolean,
    ) {
        if (info.isEmpty()) return
        val expected = lastPublishedElapsed
        val drift = kotlin.math.abs(elapsedSeconds - expected)
        if (durationSeconds == lastDuration && isPlaying == lastPlaying && drift < 1.0) {
            if (isPlaying) lastPublishedElapsed += 0.05
            return
        }
        lastPublishedElapsed = elapsedSeconds
        lastDuration = durationSeconds
        lastPlaying = isPlaying
        if (durationSeconds > 0) info[MPMediaItemPropertyPlaybackDuration] = NSNumber(double = durationSeconds)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(double = elapsedSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(double = if (isPlaying) 1.0 else 0.0)
        publish()
    }

    fun clearNowPlayingInfo() {
        info.clear()
        artworkUrlShown = null
        MPNowPlayingInfoCenter.defaultCenter().nowPlayingInfo = null
    }

    fun release() {
        clearNowPlayingInfo()
        val center = MPRemoteCommandCenter.sharedCommandCenter()
        listOf(
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.stopCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.changePlaybackPositionCommand,
        ).forEach { it.removeTarget(null) }
        listener = null
    }

    private fun publish() {
        MPNowPlayingInfoCenter.defaultCenter().nowPlayingInfo = info.toMap()
    }

    companion object {
        private const val TAG = "IosNowPlaying"
        private val instance by lazy { MacOSMediaIntegration() }

        fun isSupported(): Boolean = true

        fun getInstance(): MacOSMediaIntegration = instance
    }
}
