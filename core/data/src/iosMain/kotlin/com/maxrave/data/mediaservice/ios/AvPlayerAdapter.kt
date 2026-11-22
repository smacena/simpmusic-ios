package com.maxrave.data.mediaservice.ios

import com.maxrave.common.MERGING_DATA_TYPE
import com.maxrave.domain.data.player.AudioEffects
import com.maxrave.domain.data.player.GenericMediaItem
import com.maxrave.domain.extension.isVideo
import com.maxrave.domain.extension.now
import com.maxrave.domain.data.player.GenericPlaybackParameters
import com.maxrave.domain.data.player.PlayerConstants
import com.maxrave.domain.data.player.PlayerError
import com.maxrave.domain.manager.DataStoreManager
import com.maxrave.domain.mediaservice.player.MediaPlayerInterface
import com.maxrave.domain.mediaservice.player.MediaPlayerListener
import com.maxrave.domain.repository.StreamRepository
import com.maxrave.logger.Logger
import kotlin.coroutines.resume
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.readValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.lastOrNull
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.AVFAudio.AVAudioSession
import platform.AVFAudio.AVAudioSessionCategoryPlayback
import platform.AVFAudio.AVAudioSessionInterruptionNotification
import platform.AVFAudio.AVAudioSessionInterruptionOptionKey
import platform.AVFAudio.AVAudioSessionInterruptionOptionShouldResume
import platform.AVFAudio.AVAudioSessionInterruptionTypeBegan
import platform.AVFAudio.AVAudioSessionInterruptionTypeEnded
import platform.AVFAudio.AVAudioSessionInterruptionTypeKey
import platform.AVFAudio.AVAudioSessionMediaServicesWereResetNotification
import platform.AVFAudio.AVAudioSessionRouteChangeNotification
import platform.AVFAudio.AVAudioSessionRouteChangeReasonKey
import platform.AVFAudio.AVAudioSessionRouteChangeReasonOldDeviceUnavailable
import platform.AVFAudio.setActive
import platform.AVFoundation.AVAssetTrack
import platform.AVFoundation.AVKeyValueStatusLoaded
import platform.AVFoundation.AVMediaTypeAudio
import platform.AVFoundation.AVMediaTypeVideo
import platform.AVFoundation.AVMutableComposition
import platform.AVFoundation.AVPlayer
import platform.AVFoundation.AVPlayerItem
import platform.AVFoundation.AVPlayerItemDidPlayToEndTimeNotification
import platform.AVFoundation.AVPlayerItemFailedToPlayToEndTimeNotification
import platform.AVFoundation.AVPlayerItemStatusFailed
import platform.AVFoundation.AVPlayerItemStatusReadyToPlay
import platform.AVFoundation.AVPlayerTimeControlStatusPlaying
import platform.AVFoundation.AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate
import platform.AVFoundation.AVURLAsset
import platform.AVFoundation.addMutableTrackWithMediaType
import platform.AVFoundation.asset
import platform.AVFoundation.audioMix
import platform.AVFoundation.currentItem
import platform.AVFoundation.currentTime
import platform.AVFoundation.duration
import platform.AVFoundation.pause
import platform.AVFoundation.play
import platform.AVFoundation.rate
import platform.AVFoundation.replaceCurrentItemWithPlayerItem
import platform.AVFoundation.seekToTime
import platform.AVFoundation.setAudioMix
import platform.AVFoundation.timeControlStatus
import platform.AVFoundation.tracksWithMediaType
import platform.AVFoundation.volume
import platform.CoreMedia.CMTimeGetSeconds
import platform.CoreMedia.CMTimeMakeWithSeconds
import platform.CoreMedia.CMTimeRangeMake
import platform.CoreMedia.kCMPersistentTrackID_Invalid
import platform.CoreMedia.kCMTimeZero
import platform.Foundation.NSNotification
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSNumber
import platform.Foundation.NSOperationQueue
import platform.Foundation.NSURL
import platform.darwin.NSObjectProtocol
import kotlin.math.pow
import kotlin.random.Random
import com.maxrave.data.native.dsp.simp_dj_set
import com.maxrave.data.native.dsp.simp_level
import com.maxrave.data.native.dsp.simp_normalize_set
import kotlin.time.TimeSource

/**
 * [MediaPlayerInterface] over AVPlayer, for iOS.
 *
 * It mirrors the queue semantics of the desktop MpvPlayerAdapter (playlist order vs. a separate
 * shuffle order, repeat modes, Next/Previous rules, listener callbacks) so the shared handler logic
 * ported from Desktop behaves the same. What it deliberately leaves out for this first cut:
 * crossfade, equalizer/effects, video, gapless pre-buffering and downloads.
 *
 * Everything runs on [coroutineScope], which on iOS is the main dispatcher — AVPlayer expects to be
 * driven from the main thread.
 */
@OptIn(ExperimentalForeignApi::class)
class AvPlayerAdapter(
    private val coroutineScope: CoroutineScope,
    private val dataStoreManager: DataStoreManager,
    private val streamRepository: StreamRepository,
) : MediaPlayerInterface {
    private enum class State { IDLE, PREPARING, READY, ENDED }

    /** The player of the current track. A crossfade swaps in a new one for the incoming track. */
    private var player = AVPlayer()

    /** The outgoing track's player while a crossfade runs, or null. */
    private var fadingOut: AVPlayer? = null
    private var crossfadeJob: Job? = null

    /** Which EQ/effects tap slot the current player's item uses; a crossfade alternates it. */
    private var currentSlot = 0

    private var crossfadeEnabled = false

    /** DJ mode: low-pass sweep on the outgoing track, high-pass on the incoming (C filter per tap slot). */
    private var djCrossfadeEnabled = false
    private var crossfadeDurationMs = 5_000
    private var skipCrossfadeInAlbum = false
    private var userVolume = 1f
    private var normalizeEnabled = false

    /** The AVPlayer itself, for the video surface in the UI (MediaPlayerViewWithSubtitle). */
    val avPlayer: AVPlayer get() = player

    /** Whether the current item carries a video track (a music video in watch-video mode). */
    var currentIsVideo: Boolean = false
        private set

    /** Mirrors the "watch video instead of playing audio" setting, as the desktop adapter does. */
    private var watchVideoEnabled = false
    private val listeners = mutableListOf<MediaPlayerListener>()

    private val playlist = mutableListOf<GenericMediaItem>()

    /** Playlist indices in play order while shuffle is on. */
    private val shuffleOrder = mutableListOf<Int>()

    /** Inverse of [shuffleOrder]: playlist index → position in it. */
    private val shuffleIndices = mutableMapOf<Int, Int>()

    private var index = 0
    private var state = State.IDLE
    private var loadedMediaId: String? = null

    /** The item listeners were last told about through onMediaItemTransition. */
    private var announcedMediaId: String? = null
    private var loadJob: Job? = null
    private var retriedAfterError = false

    private var internalShuffle = false
    private var internalRepeat = PlayerConstants.REPEAT_MODE_OFF
    private var internalPlayWhenReady = false
    private var internalParameters = GenericPlaybackParameters.DEFAULT

    private var lastIsPlaying = false
    private var lastLoading = false
    private var cachedPosition = 0L
    private var cachedDuration = 0L

    /**
     * The track's real length, when known. AVFoundation misreads YouTube's fragmented MP4 files —
     * measured 2026-11-21: 563 s reported for a 281.6 s track — so its own duration made the
     * progress bar run at half speed and stop halfway when the song ended. googlevideo URLs carry
     * the true length in their `dur` parameter, and the format table keeps it for downloads.
     */
    private var knownDurationMs = 0L

    /** When the current stream link stops working (its `expire` parameter), if it has one. */
    private var urlExpiresAtSec: Long? = null

    private fun urlExpired(): Boolean {
        val expires = urlExpiresAtSec ?: return false
        return kotlin.time.Clock.System.now().epochSeconds >= expires - URL_EXPIRY_MARGIN_SEC
    }

    /**
     * Stream URLs resolved ahead of time for the track that plays next, keyed by mediaId.
     * Resolving takes a player request plus a metadata lookup — seconds on a phone connection —
     * so doing it only once the current track has ended left a gap between songs. Desktop
     * precaches the next track the same way.
     */
    private val prefetched = mutableMapOf<String, String>()
    private var prefetchJob: Job? = null

    private var endObserver: NSObjectProtocol? = null
    private var failObserver: NSObjectProtocol? = null
    private var pollJob: Job? = null
    private val sessionObservers = mutableListOf<NSObjectProtocol>()

    /** Whether music was playing when a call, alarm or Siri took the audio session. */
    private var playingBeforeInterruption = false

    /** When the player started waiting for data while it should be playing, or null. */
    private var stalledSince: TimeSource.Monotonic.ValueTimeMark? = null
    private var lastStallReload: TimeSource.Monotonic.ValueTimeMark? = null

    init {
        setUpAudioSession()
        val center = NSNotificationCenter.defaultCenter
        observeAudioSession(center)
        endObserver =
            center.addObserverForName(AVPlayerItemDidPlayToEndTimeNotification, null, NSOperationQueue.mainQueue) { note ->
                if (note?.`object` == player.currentItem) coroutineScope.launch { onTrackEnded() }
            }
        failObserver =
            center.addObserverForName(AVPlayerItemFailedToPlayToEndTimeNotification, null, NSOperationQueue.mainQueue) { note ->
                if (note?.`object` == player.currentItem) coroutineScope.launch { onItemFailed("failed to play to end") }
            }
        pollJob = coroutineScope.launch { pollLoop() }
        coroutineScope.launch {
            dataStoreManager.watchVideoInsteadOfPlayingAudio.collect { watchVideoEnabled = it == DataStoreManager.TRUE }
        }
        coroutineScope.launch {
            dataStoreManager.normalizeVolume.collect {
                normalizeEnabled = it == DataStoreManager.TRUE
                loadedMediaId?.let { id -> applyNormalization(id) }
            }
        }
        coroutineScope.launch { dataStoreManager.crossfadeEnabled.collect { crossfadeEnabled = it == DataStoreManager.TRUE } }
        coroutineScope.launch { dataStoreManager.crossfadeDuration.collect { crossfadeDurationMs = it } }
        coroutineScope.launch { dataStoreManager.crossfadeSkipAlbum.collect { skipCrossfadeInAlbum = it == DataStoreManager.TRUE } }
        coroutineScope.launch { dataStoreManager.crossfadeDjMode.collect { djCrossfadeEnabled = it == DataStoreManager.TRUE } }
        coroutineScope.launch { dataStoreManager.skipSilent.collect { skipSilentEnabled = it == DataStoreManager.TRUE } }
    }

    // ---------------------------------------------------------------------------------------
    // Transport

    override fun play() {
        coroutineScope.launch {
            internalPlayWhenReady = true
            when {
                state == State.ENDED -> seekToIndex(index, 0, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_SEEK)
                loadedMediaId != playlist.getOrNull(index)?.mediaId -> load(0, null)
                urlExpired() -> {
                    // Paused for hours: googlevideo links last about six, and AVPlayer would fail
                    // on the first byte it hasn't buffered. Fetch a new one and carry on in place.
                    Logger.i(TAG, "stream link expired while paused: refreshing")
                    loadedMediaId?.let {
                        streamRepository.invalidateFormat(it)
                        streamRepository.invalidateFormat("${MERGING_DATA_TYPE.VIDEO}$it")
                    }
                    load(cachedPosition, null)
                }
                else -> startPlayback()
            }
        }
    }

    override fun pause() {
        coroutineScope.launch {
            internalPlayWhenReady = false
            finishCrossfade()
            player.pause()
        }
    }

    override fun stop() {
        coroutineScope.launch {
            internalPlayWhenReady = false
            finishCrossfade()
            loadJob?.cancel()
            player.pause()
            player.replaceCurrentItemWithPlayerItem(null)
            loadedMediaId = null
            setState(State.IDLE)
        }
    }

    override fun seekTo(positionMs: Long) {
        coroutineScope.launch {
            // Past the real end lies only the inflated tail AVFoundation imagines (see
            // knownDurationMs): stop just short of the end and let the track finish normally.
            val positionMs = if (knownDurationMs > 0) positionMs.coerceIn(0, knownDurationMs - 500) else positionMs
            finishCrossfade()
            player.seekToTime(CMTimeMakeWithSeconds(positionMs / 1000.0, 1000))
            cachedPosition = positionMs
            notify { onSeeked(positionMs) }
        }
    }

    override fun seekTo(
        mediaItemIndex: Int,
        positionMs: Long,
    ) {
        coroutineScope.launch { seekToIndex(mediaItemIndex, positionMs, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_SEEK) }
    }

    override fun seekBack() = seekTo((currentPosition - SEEK_STEP_MS).coerceAtLeast(0))

    override fun seekForward() = seekTo((currentPosition + SEEK_STEP_MS).coerceAtMost(duration.coerceAtLeast(0)))

    override fun seekToNext() {
        coroutineScope.launch { if (hasNextMediaItem()) seekToIndex(nextIndex(), 0, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_SEEK) }
    }

    override fun seekToPrevious() {
        coroutineScope.launch {
            if (cachedPosition > PREVIOUS_THRESHOLD_MS || !hasPreviousMediaItem()) {
                player.seekToTime(CMTimeMakeWithSeconds(0.0, 1000))
                cachedPosition = 0
                notify { onSeeked(0) }
            } else {
                seekToIndex(previousIndex(), 0, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_SEEK)
            }
        }
    }

    override fun seekToPreviousMediaItem() {
        coroutineScope.launch { if (hasPreviousMediaItem()) seekToIndex(previousIndex(), 0, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_SEEK) }
    }

    override fun prepare() {
        coroutineScope.launch {
            if (playlist.isNotEmpty() && loadedMediaId != playlist.getOrNull(index)?.mediaId) load(0, null)
        }
    }

    // ---------------------------------------------------------------------------------------
    // Playlist

    override fun setMediaItem(mediaItem: GenericMediaItem) {
        coroutineScope.launch {
            playlist.clear()
            prefetched.clear()
            playlist.add(mediaItem)
            index = 0
            rebuildShuffle(keepCurrentFirst = true)
            loadedMediaId = null
            timelineChanged()
            announceIfNew()
        }
    }

    override fun addMediaItem(mediaItem: GenericMediaItem) {
        coroutineScope.launch { insert(playlist.size, mediaItem) }
    }

    override fun addMediaItem(
        index: Int,
        mediaItem: GenericMediaItem,
    ) {
        coroutineScope.launch { insert(index.coerceIn(0, playlist.size), mediaItem) }
    }

    private fun insert(
        at: Int,
        item: GenericMediaItem,
    ) {
        val wasEmpty = playlist.isEmpty()
        playlist.add(at, item)
        if (!wasEmpty && at <= index) index++
        if (internalShuffle) {
            for (i in shuffleOrder.indices) if (shuffleOrder[i] >= at) shuffleOrder[i]++
            val currentPos = shuffleIndices[index] ?: -1
            val insertPos = Random.nextInt(currentPos + 1, shuffleOrder.size + 1)
            shuffleOrder.add(insertPos, at)
            rebuildShuffleIndices()
        }
        timelineChanged()
        if (wasEmpty) announceIfNew()
    }

    override fun removeMediaItem(index: Int) {
        coroutineScope.launch { removeRange(index, index + 1) }
    }

    override fun removeMediaItems(
        fromIndex: Int,
        toIndex: Int,
        onRemoved: (removedIds: List<String>) -> Unit,
    ) {
        coroutineScope.launch { onRemoved(removeRange(fromIndex, toIndex)) }
    }

    private fun removeRange(
        from: Int,
        to: Int,
    ): List<String> {
        val start = from.coerceIn(0, playlist.size)
        val end = to.coerceIn(start, playlist.size)
        if (start == end) return emptyList()
        val removedIds = playlist.subList(start, end).map { it.mediaId }
        val removedCurrent = index in start until end
        repeat(end - start) { playlist.removeAt(start) }
        val count = end - start
        if (internalShuffle) {
            shuffleOrder.removeAll { it in start until end }
            for (i in shuffleOrder.indices) if (shuffleOrder[i] >= end) shuffleOrder[i] -= count
            rebuildShuffleIndices()
        }
        when {
            playlist.isEmpty() -> {
                index = 0
                loadJob?.cancel()
                player.replaceCurrentItemWithPlayerItem(null)
                loadedMediaId = null
                setState(State.IDLE)
            }
            removedCurrent -> {
                index = start.coerceAtMost(playlist.lastIndex)
                load(0, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED)
            }
            index >= end -> index -= count
        }
        timelineChanged()
        return removedIds
    }

    override fun moveMediaItem(
        fromIndex: Int,
        toIndex: Int,
    ) {
        coroutineScope.launch {
            if (fromIndex !in playlist.indices || toIndex !in playlist.indices) return@launch
            playlist.add(toIndex, playlist.removeAt(fromIndex))
            index =
                when {
                    index == fromIndex -> toIndex
                    fromIndex < index && toIndex >= index -> index - 1
                    fromIndex > index && toIndex <= index -> index + 1
                    else -> index
                }
            if (internalShuffle) {
                for (i in shuffleOrder.indices) {
                    val v = shuffleOrder[i]
                    shuffleOrder[i] =
                        when {
                            v == fromIndex -> toIndex
                            fromIndex < toIndex && v in (fromIndex + 1)..toIndex -> v - 1
                            fromIndex > toIndex && v in toIndex until fromIndex -> v + 1
                            else -> v
                        }
                }
                rebuildShuffleIndices()
            }
            timelineChanged()
        }
    }

    override fun moveShuffledItem(
        fromShuffledIndex: Int,
        toShuffledIndex: Int,
    ) {
        coroutineScope.launch {
            if (!internalShuffle) return@launch
            if (fromShuffledIndex !in shuffleOrder.indices || toShuffledIndex !in shuffleOrder.indices) return@launch
            shuffleOrder.add(toShuffledIndex, shuffleOrder.removeAt(fromShuffledIndex))
            rebuildShuffleIndices()
            timelineChanged()
        }
    }

    override fun clearMediaItems() {
        coroutineScope.launch {
            playlist.clear()
            shuffleOrder.clear()
            shuffleIndices.clear()
            announcedMediaId = null
            prefetched.clear()
            index = 0
            loadJob?.cancel()
            player.pause()
            player.replaceCurrentItemWithPlayerItem(null)
            loadedMediaId = null
            setState(State.IDLE)
            timelineChanged()
        }
    }

    override fun replaceMediaItem(
        index: Int,
        mediaItem: GenericMediaItem,
    ) {
        coroutineScope.launch {
            if (index !in playlist.indices) return@launch
            playlist[index] = mediaItem
            timelineChanged()
        }
    }

    override fun getMediaItemAt(index: Int): GenericMediaItem? = playlist.getOrNull(index)

    override fun getCurrentMediaTimeLine(): List<GenericMediaItem> =
        if (internalShuffle) shuffleOrder.mapNotNull { playlist.getOrNull(it) } else playlist.toList()

    override fun getUnshuffledIndex(shuffledIndex: Int): Int = if (internalShuffle) shuffleOrder.getOrNull(shuffledIndex) ?: -1 else shuffledIndex

    // ---------------------------------------------------------------------------------------
    // State

    override val isPlaying: Boolean get() = player.timeControlStatus == AVPlayerTimeControlStatusPlaying
    override val currentPosition: Long get() = cachedPosition
    override val duration: Long get() = cachedDuration
    override val bufferedPosition: Long get() = cachedPosition
    override val bufferedPercentage: Int get() = if (cachedDuration > 0) ((cachedPosition * 100) / cachedDuration).toInt() else 0
    override val currentMediaItem: GenericMediaItem? get() = playlist.getOrNull(index)
    override val currentMediaItemIndex: Int get() = index
    override val mediaItemCount: Int get() = playlist.size
    override val contentPosition: Long get() = cachedPosition
    override val playbackState: Int
        get() =
            when (state) {
                State.IDLE -> PlayerConstants.STATE_IDLE
                State.PREPARING -> PlayerConstants.STATE_BUFFERING
                State.READY -> PlayerConstants.STATE_READY
                State.ENDED -> PlayerConstants.STATE_ENDED
            }

    override fun hasNextMediaItem(): Boolean =
        playlist.isNotEmpty() &&
            (
                internalRepeat == PlayerConstants.REPEAT_MODE_ALL ||
                    if (internalShuffle) (shuffleIndices[index] ?: -1) in 0 until shuffleOrder.lastIndex else index < playlist.lastIndex
            )

    override fun hasPreviousMediaItem(): Boolean =
        playlist.isNotEmpty() &&
            (
                internalRepeat == PlayerConstants.REPEAT_MODE_ALL ||
                    if (internalShuffle) (shuffleIndices[index] ?: -1) > 0 else index > 0
            )

    private fun nextIndex(): Int {
        if (internalShuffle && shuffleOrder.isNotEmpty()) {
            val pos = shuffleIndices[index] ?: 0
            return shuffleOrder.getOrNull(pos + 1) ?: shuffleOrder.first()
        }
        return if (index < playlist.lastIndex) index + 1 else 0
    }

    private fun previousIndex(): Int {
        if (internalShuffle && shuffleOrder.isNotEmpty()) {
            val pos = shuffleIndices[index] ?: 0
            return shuffleOrder.getOrNull(pos - 1) ?: shuffleOrder.last()
        }
        return if (index > 0) index - 1 else playlist.lastIndex
    }

    override var shuffleModeEnabled: Boolean
        get() = internalShuffle
        set(value) {
            if (internalShuffle == value) return
            internalShuffle = value
            rebuildShuffle(keepCurrentFirst = true)
            val list = getCurrentMediaTimeLine()
            notify { onShuffleModeEnabledChanged(value, list) }
            timelineChanged()
        }

    override var repeatMode: Int
        get() = internalRepeat
        set(value) {
            if (internalRepeat == value) return
            internalRepeat = value
            notify { onRepeatModeChanged(value) }
        }

    override var playWhenReady: Boolean
        get() = internalPlayWhenReady
        set(value) {
            if (value) play() else pause()
        }

    override var playbackParameters: GenericPlaybackParameters
        get() = internalParameters
        set(value) {
            internalParameters = value
            if (isPlaying) player.rate = value.speed
        }

    override val audioSessionId: Int = PlayerConstants.AUDIO_SESSION_ID_UNSET

    override var volume: Float
        get() = userVolume
        set(value) {
            userVolume = value.coerceIn(0f, 1f)
            if (fadingOut == null) player.volume = targetVolume()
            notify { onVolumeChanged(userVolume) }
        }

    /** The level the current player sits at outside a crossfade ramp. */
    private fun targetVolume(): Float = userVolume * sleepFadeFactor

    override var sleepFadeFactor: Float = 1f
        set(value) {
            field = value
            if (fadingOut == null) player.volume = targetVolume()
        }
    override var crossfadeSuppressed: Boolean = false
    override var albumTrackIds: Set<String> = emptySet()
    override var skipSilenceEnabled: Boolean = false

    override fun addListener(listener: MediaPlayerListener) {
        listeners.add(listener)
    }

    override fun removeListener(listener: MediaPlayerListener) {
        listeners.remove(listener)
    }

    override fun release() {
        finishCrossfade()
        pollJob?.cancel()
        loadJob?.cancel()
        player.pause()
        player.replaceCurrentItemWithPlayerItem(null)
        endObserver?.let { NSNotificationCenter.defaultCenter.removeObserver(it) }
        failObserver?.let { NSNotificationCenter.defaultCenter.removeObserver(it) }
        sessionObservers.forEach { NSNotificationCenter.defaultCenter.removeObserver(it) }
        sessionObservers.clear()
        listeners.clear()
    }

    // ---------------------------------------------------------------------------------------
    // Audio session: calls, alarms, headphones

    private fun setUpAudioSession() {
        runCatching {
            val session = AVAudioSession.sharedInstance()
            session.setCategory(AVAudioSessionCategoryPlayback, error = null)
            session.setActive(true, error = null)
        }.onFailure { Logger.e(TAG, "audio session setup failed", it) }
    }

    private fun observeAudioSession(center: NSNotificationCenter) {
        sessionObservers +=
            center.addObserverForName(AVAudioSessionInterruptionNotification, null, NSOperationQueue.mainQueue) { note ->
                coroutineScope.launch { onInterruption(note) }
            }
        sessionObservers +=
            center.addObserverForName(AVAudioSessionRouteChangeNotification, null, NSOperationQueue.mainQueue) { note ->
                coroutineScope.launch { onRouteChange(note) }
            }
        sessionObservers +=
            center.addObserverForName(AVAudioSessionMediaServicesWereResetNotification, null, NSOperationQueue.mainQueue) { _ ->
                coroutineScope.launch { onMediaServicesReset() }
            }
    }

    private fun NSNotification?.number(key: Any?): ULong? = (this?.userInfo?.get(key) as? NSNumber)?.unsignedLongValue

    /**
     * A phone or FaceTime call, an alarm, a timer or Siri took the audio session. iOS has already
     * silenced the player when "began" arrives; when the interruption ends it says whether the
     * music should come back (ShouldResume). It doesn't after a call the user declined to resume
     * from, or when another music app took over — then the music stays paused, like Apple Music.
     */
    private fun onInterruption(note: NSNotification?) {
        when (note.number(AVAudioSessionInterruptionTypeKey)) {
            AVAudioSessionInterruptionTypeBegan -> {
                playingBeforeInterruption = internalPlayWhenReady
                Logger.i(TAG, "audio interrupted (was playing: $playingBeforeInterruption)")
                internalPlayWhenReady = false
                finishCrossfade()
                player.pause()
            }
            AVAudioSessionInterruptionTypeEnded -> {
                val options = note.number(AVAudioSessionInterruptionOptionKey) ?: 0uL
                val shouldResume = options and AVAudioSessionInterruptionOptionShouldResume != 0uL
                Logger.i(TAG, "audio interruption ended (resume: $shouldResume)")
                if (shouldResume && playingBeforeInterruption) {
                    setUpAudioSession()
                    internalPlayWhenReady = true
                    if (state == State.READY) startPlayback() else play()
                }
                playingBeforeInterruption = false
            }
        }
    }

    /**
     * Headphones unplugged or a Bluetooth device gone: pause, so the music doesn't carry on out
     * of the phone's speaker. Plugging something in changes nothing, as on every iPhone app.
     */
    private fun onRouteChange(note: NSNotification?) {
        if (note.number(AVAudioSessionRouteChangeReasonKey) == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
            Logger.i(TAG, "audio device disconnected: pausing")
            internalPlayWhenReady = false
            finishCrossfade()
            player.pause()
        }
    }

    /** The system audio daemon restarted: every audio object is void, so set up and reload. */
    private fun onMediaServicesReset() {
        Logger.w(TAG, "media services were reset: reloading")
        setUpAudioSession()
        if (playlist.getOrNull(index) != null && state != State.IDLE) load(cachedPosition, null)
    }

    // ---------------------------------------------------------------------------------------
    // Internals

    private fun seekToIndex(
        target: Int,
        positionMs: Long,
        reason: Int,
    ) {
        if (target !in playlist.indices) return
        if (target == index && loadedMediaId == playlist[target].mediaId && state != State.ENDED) {
            player.seekToTime(CMTimeMakeWithSeconds(positionMs / 1000.0, 1000))
            cachedPosition = positionMs
            notify { onSeeked(positionMs) }
            return
        }
        index = target
        load(positionMs, reason)
    }

    private fun load(
        startPositionMs: Long,
        transitionReason: Int?,
    ) {
        val item = playlist.getOrNull(index) ?: return
        loadJob?.cancel()
        finishCrossfade()
        player.pause()
        cachedPosition = startPositionMs
        cachedDuration = 0
        knownDurationMs = 0
        retriedAfterError = false
        setState(State.PREPARING)
        // ExoPlayer (and the desktop adapter) announce the FIRST item too, not just later changes;
        // the handler only learns what is playing from this, so without it the mini player and
        // the now-playing screen never appear.
        if (transitionReason != null || item.mediaId != announcedMediaId) {
            announce(item, transitionReason ?: PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED)
        }
        loadJob =
            coroutineScope.launch {
                if (watchVideoEnabled && item.isVideo()) {
                    val video = resolveVideo(item.mediaId)
                    if (!isActive) return@launch
                    if (video != null && playComposition(item.mediaId, video.first, video.second, startPositionMs)) return@launch
                    Logger.w(TAG, "${item.mediaId}: video unavailable, playing audio only")
                }
                val url = prefetched.remove(item.mediaId) ?: resolveUrl(item.mediaId) ?: resolveWithRetry(item.mediaId)
                if (!isActive) return@launch
                if (url == null) {
                    reportError("No playable stream for ${item.mediaId}")
                    return@launch
                }
                knownDurationMs = realDurationMs(item.mediaId, url)
                playUrl(item.mediaId, url, startPositionMs)
            }
    }

    private suspend fun playUrl(
        mediaId: String,
        url: String,
        startPositionMs: Long,
    ) {
        val playable = url
        // Flags only, never the URL itself: it carries the listener's IP address.
        Logger.i(
            TAG,
            "play $mediaId: " +
                "ipv6=${Regex("[?&]ip=([^&]*)").find(url)?.groupValues?.get(1)?.contains("%3A") == true} " +
                "itag=${Regex("[?&]itag=(\\d+)").find(url)?.groupValues?.get(1)} c=${Regex("[?&]c=([^&]*)").find(url)?.groupValues?.get(1)}",
        )
        val nsUrl = (if (playable.startsWith("/")) NSURL.fileURLWithPath(playable) else NSURL.URLWithString(playable)) ?: return reportError("Bad URL")
        // The equalizer/effects tap goes on BEFORE the item plays. Attaching an audio mix to an item
        // that is already playing makes AVFoundation stop, rebuild and resume its audio pipeline
        // ("stopResetDisturbReprepareAndResume ... AudioProcessingTap" in the log) — an audible
        // hiccup at the start of every song. Loading the track list first takes a few ms.
        val asset = AVURLAsset(uRL = nsUrl, options = null)
        val tracksLoaded = asset.loadKeys(listOf("tracks"))
        if (mediaId != playlist.getOrNull(index)?.mediaId) return
        val avItem = AVPlayerItem(asset = asset)
        if (tracksLoaded) attachEqualizer(avItem)
        applyNormalization(mediaId)
        urlExpiresAtSec = Regex("[?&]expire=(\\d+)").find(url)?.groupValues?.get(1)?.toLongOrNull()
        currentIsVideo = false
        player.replaceCurrentItemWithPlayerItem(avItem)
        loadedMediaId = mediaId
        if (startPositionMs > 0) player.seekToTime(CMTimeMakeWithSeconds(startPositionMs / 1000.0, 1000))
        if (internalPlayWhenReady) startPlayback()
    }

    /** The real length from the URL's `dur` parameter, or the format table for local files. */
    private suspend fun realDurationMs(
        videoId: String,
        url: String,
    ): Long {
        Regex("[?&]dur=([0-9.]+)").find(url)?.groupValues?.get(1)?.toDoubleOrNull()?.let { return (it * 1000).toLong() }
        val seconds = runCatching { streamRepository.getNewFormat(videoId).lastOrNull()?.lengthSeconds }.getOrNull()
        return (seconds ?: 0) * 1000L
    }

    /** Video URL plus audio URL for a music video, as the desktop adapter merges them. */
    private suspend fun resolveVideo(videoId: String): Pair<String, String>? {
        // A downloaded music video already carries its sound: same file for picture and audio.
        downloadedVideoPath(videoId)?.let { return it to it }
        val video =
            runCatching { streamRepository.getStream(dataStoreManager, videoId, isDownloading = false, isVideo = true).lastOrNull() }
                .getOrNull() ?: return null
        val audio = resolveUrl(videoId) ?: return null
        return video to audio
    }

    /**
     * Plays a separate video stream and audio stream as one item. googlevideo serves them apart
     * (H.264 video, AAC audio); an AVMutableComposition joins the two tracks — the AVFoundation
     * counterpart of Android's MergingMediaSource and mpv's EDL. Measured on 2026-11-21 against
     * live 720p + AAC URLs: ready to play in about a second.
     */
    private suspend fun playComposition(
        mediaId: String,
        videoUrl: String,
        audioUrl: String,
        startPositionMs: Long,
    ): Boolean {
        val videoAsset = NSURL.URLWithString(videoUrl)?.let { AVURLAsset(uRL = it, options = null) } ?: return false
        val audioAsset = NSURL.URLWithString(audioUrl)?.let { AVURLAsset(uRL = it, options = null) } ?: return false
        if (!videoAsset.loadKeys(listOf("tracks", "duration")) || !audioAsset.loadKeys(listOf("tracks", "duration"))) return false
        val videoTrack = videoAsset.tracksWithMediaType(AVMediaTypeVideo).firstOrNull() as? AVAssetTrack ?: return false
        val audioTrack = audioAsset.tracksWithMediaType(AVMediaTypeAudio).firstOrNull() as? AVAssetTrack ?: return false
        // The audio decides the length: the video file's own duration has been seen reported
        // at twice the real length.
        val duration = audioAsset.duration
        val composition = AVMutableComposition()
        val range = CMTimeRangeMake(kCMTimeZero.readValue(), duration)
        val ok =
            composition
                .addMutableTrackWithMediaType(AVMediaTypeVideo, kCMPersistentTrackID_Invalid)
                ?.insertTimeRange(range, ofTrack = videoTrack, atTime = kCMTimeZero.readValue(), error = null) == true &&
                composition
                    .addMutableTrackWithMediaType(AVMediaTypeAudio, kCMPersistentTrackID_Invalid)
                    ?.insertTimeRange(range, ofTrack = audioTrack, atTime = kCMTimeZero.readValue(), error = null) == true
        if (!ok) return false
        knownDurationMs = realDurationMs(mediaId, audioUrl)
        Logger.i(TAG, "play $mediaId: video + audio composition")
        currentIsVideo = true
        urlExpiresAtSec = Regex("[?&]expire=(\\d+)").find(audioUrl)?.groupValues?.get(1)?.toLongOrNull()
        val compositionItem = AVPlayerItem(asset = composition)
        attachEqualizer(compositionItem) // before playing, for the same reason as in playUrl
        applyNormalization(mediaId)
        player.replaceCurrentItemWithPlayerItem(compositionItem)
        loadedMediaId = mediaId
        if (startPositionMs > 0) player.seekToTime(CMTimeMakeWithSeconds(startPositionMs / 1000.0, 1000))
        if (internalPlayWhenReady) startPlayback()
        return true
    }

    /** Loads [keys] on an asset and reports whether every one of them loaded. */
    private suspend fun AVURLAsset.loadKeys(keys: List<String>): Boolean =
        suspendCancellableCoroutine { continuation ->
            loadValuesAsynchronouslyForKeys(keys) {
                val allLoaded = keys.all { statusOfValueForKey(it, error = null) == AVKeyValueStatusLoaded }
                if (continuation.isActive) continuation.resume(allLoaded)
            }
        }

    /** Puts the equalizer tap on the current item, once its audio track is known. */
    private fun attachEqualizer(item: AVPlayerItem) {
        if (item.audioMix != null) return
        val track = item.asset.tracksWithMediaType(AVMediaTypeAudio).firstOrNull() as? AVAssetTrack ?: return
        equalizerAudioMix(track, currentSlot)?.let { item.audioMix = it }
    }

    /**
     * Volume normalization: YouTube reports each track's loudness relative to its reference level
     * (`loudnessDb`, positive = louder). The gain undoes it — louder tracks are turned down, quieter
     * ones up by at most 6 dB, with the C limiter guarding the boost — and is applied in the audio
     * tap. Off, or when the format carries no loudness, the gain is 1.
     */
    private suspend fun applyNormalization(mediaId: String) {
        val gain =
            if (!normalizeEnabled) {
                1f
            } else {
                val db = runCatching { streamRepository.getNewFormat(mediaId).lastOrNull()?.loudnessDb }.getOrNull()
                if (db == null) 1f else 10f.pow(-db / 20f).coerceIn(0.25f, 2f)
            }
        simp_normalize_set(gain)
    }

    override fun setAudioEffects(effects: AudioEffects) {
        IosAudioEffects.set(effects)
    }

    override fun setEqualizer(
        bandsDb: List<Float>,
        preampDb: Float,
    ) {
        IosEqualizer.set(bandsDb, preampDb)
    }

    private fun startPlayback() {
        player.play()
        if (internalParameters.speed != 1f) player.rate = internalParameters.speed
    }

    /** Same order as the desktop adapter: the cached format first, then a fresh extraction. */
    private suspend fun resolveUrl(
        videoId: String,
        useCache: Boolean = true,
    ): String? {
        // A downloaded song plays from disk, offline included — the order Desktop uses too.
        downloadedAudioPath(videoId)?.let { return it }
        val cached =
            streamRepository
                .getNewFormat(videoId)
                .lastOrNull()
                ?.takeIf { useCache && it.expiredTime > now() }
                ?.audioUrl
                ?.takeIf { it.isNotEmpty() }
        // No HEAD pre-check here: googlevideo answers 403 to the InnerTube client's HEAD for these
        // URLs even when they play. A stale URL fails in AVPlayer instead, and onItemFailed drops
        // the cached format and extracts again.
        if (cached != null) return cached
        return runCatching {
            streamRepository.getStream(dataStoreManager, videoId, isDownloading = false, isVideo = false).lastOrNull()
        }.onFailure { Logger.e(TAG, "stream extraction failed for $videoId", it) }.getOrNull()
    }

    private suspend fun onItemFailed(reason: String) {
        val mediaId = loadedMediaId ?: return
        Logger.w(TAG, "item failed ($reason)")
        if (!retriedAfterError) {
            // A stale cached URL is the usual cause: drop it and extract once more.
            retriedAfterError = true
            streamRepository.invalidateFormat(mediaId)
            streamRepository.invalidateFormat("${MERGING_DATA_TYPE.VIDEO}$mediaId")
            // Straight to a fresh extraction: the cached row is the URL that just failed.
            val url = resolveWithRetry(mediaId)
            if (url != null && mediaId == playlist.getOrNull(index)?.mediaId) {
                val position = cachedPosition
                playUrl(mediaId, url, position)
                retriedAfterError = true
                return
            }
        }
        reportError(reason)
    }

    /**
     * A fresh extraction, retried while the connection is down (a tunnel, a lift, Wi-Fi handing
     * over to mobile data) — about half a minute before giving up and reporting the error.
     */
    private suspend fun resolveWithRetry(mediaId: String): String? {
        repeat(NETWORK_RETRIES) { attempt ->
            resolveUrl(mediaId, useCache = false)?.let { return it }
            if (mediaId != playlist.getOrNull(index)?.mediaId) return null
            Logger.w(TAG, "stream for $mediaId unavailable, retry ${attempt + 1}/$NETWORK_RETRIES")
            delay(NETWORK_RETRY_DELAY_MS)
        }
        return null
    }

    private fun reportError(message: String) {
        Logger.e(TAG, message)
        setState(State.IDLE)
        notify { onPlayerError(PlayerError(PlayerConstants.ERROR_CODE_TIMEOUT, "ERROR_CODE_IO_UNSPECIFIED", message)) }
    }

    /** Resolves the next track's URL in the background, once per track. */
    private fun prefetchNext() {
        if (!hasNextMediaItem()) return
        val next = playlist.getOrNull(nextIndex()) ?: return
        if (next.mediaId == loadedMediaId || next.mediaId in prefetched) return
        prefetchJob?.cancel()
        prefetchJob =
            coroutineScope.launch {
                // Prefetched URLs are only kept for the next track; the rest would expire unused.
                prefetched.keys.retainAll(setOf(next.mediaId))
                resolveUrl(next.mediaId)?.let { prefetched[next.mediaId] = it }
            }
    }

    private fun onTrackEnded() {
        // The position is polled every POLL_MS, so the last sample can sit just short of the end.
        // Pin it to the duration so the progress bar finishes before the next track starts.
        if (cachedDuration > 0) cachedPosition = cachedDuration
        when {
            internalRepeat == PlayerConstants.REPEAT_MODE_ONE -> {
                player.seekToTime(CMTimeMakeWithSeconds(0.0, 1000))
                player.play()
                playlist.getOrNull(index)?.let { item -> announce(item, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_REPEAT) }
            }
            hasNextMediaItem() -> {
                index = nextIndex()
                load(0, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_AUTO)
            }
            else -> {
                internalPlayWhenReady = false
                setState(State.ENDED)
            }
        }
    }

    private suspend fun pollLoop() {
        while (true) {
            val item = player.currentItem
            if (item != null) {
                val pos = CMTimeGetSeconds(player.currentTime())
                if (!pos.isNaN()) cachedPosition = (pos * 1000).toLong()
                val dur = CMTimeGetSeconds(item.duration)
                cachedDuration =
                    when {
                        knownDurationMs > 0 -> knownDurationMs
                        !dur.isNaN() && !dur.isInfinite() -> (dur * 1000).toLong()
                        else -> cachedDuration
                    }
                // With the inflated length, AVPlayer can sit "playing" silence after the real end
                // instead of posting DidPlayToEnd. Past the true length, move on ourselves.
                if (knownDurationMs > 0 && state == State.READY && cachedPosition >= knownDurationMs + END_GRACE_MS) {
                    onTrackEnded()
                }
                checkStall()
                checkSilence()
                maybeStartCrossfade()
                when (item.status) {
                    AVPlayerItemStatusReadyToPlay ->
                        if (state == State.PREPARING) {
                            setState(State.READY)
                            attachEqualizer(item)
                            prefetchNext()
                        }
                    AVPlayerItemStatusFailed -> if (state == State.PREPARING || state == State.READY) onItemFailed("item status failed")
                }
            }
            val playing = player.timeControlStatus == AVPlayerTimeControlStatusPlaying
            if (playing != lastIsPlaying) {
                lastIsPlaying = playing
                notify { onIsPlayingChanged(playing) }
            }
            val loading = state == State.PREPARING || player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate
            if (loading != lastLoading) {
                lastLoading = loading
                notify { onIsLoadingChanged(loading) }
            }
            delay(POLL_MS)
        }
    }

    /**
     * The player is waiting for data while it should be playing.
     *
     * Near the real end that is the inflated duration again: AVPlayer believes the file goes on
     * and waits for bytes that don't exist (seen 2026-11-21: stuck 0.07 s before the end, so the
     * next song never started). That is the end of the track.
     *
     * Mid-track it is the network. AVPlayer resumes by itself when the connection comes back, but
     * not when the URL has expired meanwhile, so after a while it reloads from where it stopped.
     */
    /**
     * Skip silence (iOS): the C tap publishes each buffer's peak. About -50 dBFS for 0.75 s
     * mid-track jumps 1.5 s ahead; a silent tail in the last 25 s ends the track. Never in the
     * first 3 s, during a crossfade, or while buffering.
     */
    private fun checkSilence() {
        val now: Double = platform.CoreFoundation.CFAbsoluteTimeGetCurrent()
        val duration = if (knownDurationMs > 0) knownDurationMs else cachedDuration
        if (!skipSilentEnabled || state != State.READY || !internalPlayWhenReady || fadingOut != null ||
            player.timeControlStatus != platform.AVFoundation.AVPlayerTimeControlStatusPlaying ||
            cachedPosition < 3_000 || duration < 10_000
        ) {
            silentSince = null
            return
        }
        if (simp_level() >= 0.003f) {
            silentSince = null
            return
        }
        val since = silentSince ?: now.also { silentSince = it }
        val silentFor = now - since
        if (duration - cachedPosition < 25_000 && silentFor >= 1.0) {
            silentSince = null
            onTrackEnded()
        } else if (silentFor >= 0.75) {
            silentSince = null
            seekTo(minOf(cachedPosition + 1_500, duration - 1_000))
        }
    }

    private var silentSince: Double? = null
    private var skipSilentEnabled = false

    private fun checkStall() {
        val waiting =
            state == State.READY && internalPlayWhenReady &&
                player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate
        if (!waiting) {
            stalledSince = null
            return
        }
        val since = stalledSince ?: TimeSource.Monotonic.markNow().also { stalledSince = it }
        val stalledMs = since.elapsedNow().inWholeMilliseconds
        if (knownDurationMs > 0 && cachedPosition >= knownDurationMs - END_STALL_WINDOW_MS && stalledMs >= END_STALL_MS) {
            Logger.i(TAG, "stalled at the real end (${cachedPosition}/${knownDurationMs} ms): next track")
            stalledSince = null
            onTrackEnded()
            return
        }
        val sinceReload = lastStallReload?.elapsedNow()?.inWholeMilliseconds ?: Long.MAX_VALUE
        if (stalledMs >= STALL_RELOAD_MS && sinceReload >= STALL_RELOAD_MS) {
            val mediaId = loadedMediaId ?: return
            Logger.w(TAG, "stalled ${stalledMs} ms mid-track: reloading $mediaId at $cachedPosition ms")
            lastStallReload = TimeSource.Monotonic.markNow()
            stalledSince = null
            coroutineScope.launch {
                val url = resolveUrl(mediaId, useCache = false) ?: return@launch
                if (mediaId == loadedMediaId && internalPlayWhenReady) playUrl(mediaId, url, cachedPosition)
            }
        }
    }

    // ---------------------------------------------------------------------------------------
    // Crossfade

    /** The fade length for this transition; "Auto" (beat analysis on Desktop) is a fixed 8 s here. */
    private fun fadeMs(): Long =
        if (crossfadeDurationMs == DataStoreManager.CROSSFADE_DURATION_AUTO) AUTO_CROSSFADE_MS else crossfadeDurationMs.toLong()

    /**
     * Starts the next track [fadeMs] before this one ends and overlaps the two, when crossfade is
     * on and nothing rules it out: a Listen Together room, repeat-one, a music video (one video
     * surface), a track too short to fade (under three fade lengths), two tracks of the album
     * the user wants played through, or a next stream not resolved yet — then the track simply
     * ends and the next one starts as usual.
     */
    private fun maybeStartCrossfade() {
        if (!crossfadeEnabled || crossfadeSuppressed || fadingOut != null || crossfadeJob?.isActive == true) return
        if (state != State.READY || !internalPlayWhenReady || !isPlaying || currentIsVideo) return
        if (internalRepeat == PlayerConstants.REPEAT_MODE_ONE || !hasNextMediaItem()) return
        val fade = fadeMs()
        val length = knownDurationMs
        if (length <= 0 || length < fade * 3 || cachedPosition < length - fade) return
        val nextIndex = nextIndex()
        val next = playlist.getOrNull(nextIndex) ?: return
        if (watchVideoEnabled && next.isVideo()) return
        val currentId = loadedMediaId ?: return
        if (skipCrossfadeInAlbum && currentId in albumTrackIds && next.mediaId in albumTrackIds) return
        val url = prefetched[next.mediaId] ?: return
        prefetched.remove(next.mediaId)
        crossfadeJob = coroutineScope.launch { runCrossfade(nextIndex, next, url, fade) }
    }

    private suspend fun runCrossfade(
        nextIndex: Int,
        next: GenericMediaItem,
        url: String,
        fade: Long,
    ) {
        val nsUrl = (if (url.startsWith("/")) NSURL.fileURLWithPath(url) else NSURL.URLWithString(url)) ?: return
        val incoming = AVPlayer()
        incoming.volume = 0f
        val item = AVPlayerItem(uRL = nsUrl)
        incoming.replaceCurrentItemWithPlayerItem(item)
        // Wait for the incoming stream to be ready, but never past the point where the outgoing
        // track runs out: if it isn't ready in time, the normal end-of-track path takes over.
        var waited = 0L
        while (item.status != AVPlayerItemStatusReadyToPlay) {
            if (item.status == AVPlayerItemStatusFailed || waited > fade / 2) {
                Logger.w(TAG, "crossfade: next stream not ready in time; plain transition")
                incoming.replaceCurrentItemWithPlayerItem(null)
                prefetched[next.mediaId] = url
                return
            }
            delay(POLL_MS)
            waited += POLL_MS
        }
        if (!internalPlayWhenReady || state != State.READY) {
            incoming.replaceCurrentItemWithPlayerItem(null)
            prefetched[next.mediaId] = url
            return
        }
        Logger.i(TAG, "crossfade ${fade} ms into ${next.mediaId}")
        val outgoing = player
        fadingOut = outgoing
        player = incoming
        currentSlot = 1 - currentSlot
        attachEqualizer(item)
        applyNormalization(next.mediaId)
        index = nextIndex
        loadedMediaId = next.mediaId
        cachedPosition = 0
        knownDurationMs = realDurationMs(next.mediaId, url)
        cachedDuration = knownDurationMs
        urlExpiresAtSec = Regex("[?&]expire=(\\d+)").find(url)?.groupValues?.get(1)?.toLongOrNull()
        retriedAfterError = false
        stalledSince = null
        incoming.play()
        if (internalParameters.speed != 1f) incoming.rate = internalParameters.speed
        announce(next, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_AUTO)
        notify { onCrossfadeStateChanged(true) }
        // Equal-power curve: the summed loudness stays level through the overlap.
        val startVolume = outgoing.volume
        for (step in 1..CROSSFADE_STEPS) {
            delay(fade / CROSSFADE_STEPS)
            if (fadingOut !== outgoing) return
            val t = step.toDouble() / CROSSFADE_STEPS
            outgoing.volume = (startVolume * kotlin.math.cos(t * PI_HALF)).toFloat()
            incoming.volume = (targetVolume() * kotlin.math.sin(t * PI_HALF)).toFloat()
            if (djCrossfadeEnabled) {
                // Same curve as Android: sigmoid in time, exponential in frequency.
                val p = 1.0 / (1.0 + kotlin.math.exp(-10.0 * (t - 0.5)))
                simp_dj_set(1 - currentSlot, 1, (20000.0 * (200.0 / 20000.0).pow(p)).toFloat())
                simp_dj_set(currentSlot, 2, (2000.0 * (20.0 / 2000.0).pow(p)).toFloat())
            }
        }
        finishCrossfade()
        prefetchNext()
    }

    /**
     * Ends a crossfade at once — at its natural end, or because the user paused, skipped or
     * seeked, or a call came in: the outgoing track stops and the current one gets full volume.
     */
    private fun finishCrossfade() {
        val outgoing = fadingOut ?: run {
            crossfadeJob?.cancel()
            crossfadeJob = null
            return
        }
        fadingOut = null
        crossfadeJob?.cancel()
        crossfadeJob = null
        outgoing.pause()
        outgoing.replaceCurrentItemWithPlayerItem(null)
        simp_dj_set(0, 0, 20000f)
        simp_dj_set(1, 0, 20000f)
        player.volume = targetVolume()
        notify { onCrossfadeStateChanged(false) }
    }

    private fun setState(newState: State) {
        if (state == newState) return
        state = newState
        val exo = playbackState
        notify { onPlaybackStateChanged(exo) }
    }

    private fun rebuildShuffle(keepCurrentFirst: Boolean) {
        shuffleOrder.clear()
        if (internalShuffle && playlist.isNotEmpty()) {
            val rest = playlist.indices.filter { it != index }.shuffled()
            if (keepCurrentFirst) shuffleOrder.add(index)
            shuffleOrder.addAll(rest)
        }
        rebuildShuffleIndices()
    }

    private fun rebuildShuffleIndices() {
        shuffleIndices.clear()
        shuffleOrder.forEachIndexed { pos, playlistIndex -> shuffleIndices[playlistIndex] = pos }
    }

    private fun announce(
        item: GenericMediaItem,
        reason: Int,
    ) {
        announcedMediaId = item.mediaId
        notify { onMediaItemTransition(item, reason) }
    }

    /** An empty playlist that gains an item points at it, and says so — as ExoPlayer does. */
    private fun announceIfNew() {
        val item = playlist.getOrNull(index) ?: return
        if (item.mediaId != announcedMediaId) announce(item, PlayerConstants.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED)
    }

    private fun timelineChanged() {
        val list = getCurrentMediaTimeLine()
        notify { onTimelineChanged(list, "TIMELINE_CHANGE_REASON_PLAYLIST_CHANGED") }
    }

    private fun notify(block: MediaPlayerListener.() -> Unit) {
        listeners.toList().forEach { runCatching { it.block() }.onFailure { e -> Logger.e(TAG, "listener threw", e) } }
    }

    private companion object {
        const val TAG = "AvPlayerAdapter"
        const val POLL_MS = 250L
        const val SEEK_STEP_MS = 10_000L
        const val PREVIOUS_THRESHOLD_MS = 3_000L
        const val END_GRACE_MS = 1_500L
        const val END_STALL_WINDOW_MS = 2_000L
        const val END_STALL_MS = 750L
        const val STALL_RELOAD_MS = 15_000L
        const val URL_EXPIRY_MARGIN_SEC = 120L
        const val AUTO_CROSSFADE_MS = 8_000L
        const val CROSSFADE_STEPS = 50
        const val PI_HALF = kotlin.math.PI / 2
        const val NETWORK_RETRIES = 6
        const val NETWORK_RETRY_DELAY_MS = 5_000L
    }
}
