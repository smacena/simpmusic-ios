package com.maxrave.simpmusic.expect.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.UIKitInteropProperties
import androidx.compose.ui.viewinterop.UIKitView
import coil3.compose.AsyncImage
import com.maxrave.data.mediaservice.ios.AvPlayerAdapter
import com.maxrave.domain.data.model.metadata.Line
import com.maxrave.domain.data.model.metadata.Lyrics
import com.maxrave.domain.data.model.streams.TimeLine
import com.maxrave.domain.manager.DataStoreManager
import com.maxrave.domain.mediaservice.handler.MediaPlayerHandler
import com.maxrave.domain.mediaservice.player.MediaPlayerInterface
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.readValue
import kotlinx.cinterop.useContents
import kotlinx.coroutines.delay
import org.koin.compose.koinInject
import platform.AVFoundation.AVLayerVideoGravityResizeAspect
import platform.AVFoundation.AVLayerVideoGravityResizeAspectFill
import platform.AVFoundation.AVPlayer
import platform.AVFoundation.currentItem
import platform.AVFoundation.muted
import platform.AVFoundation.AVPlayerItem
import platform.AVFoundation.AVPlayerItemDidPlayToEndTimeNotification
import platform.AVFoundation.AVPlayerLayer
import platform.AVFoundation.pause
import platform.AVFoundation.play
import platform.AVFoundation.presentationSize
import platform.AVFoundation.replaceCurrentItemWithPlayerItem
import platform.AVFoundation.seekToTime
import platform.CoreGraphics.CGRectZero
import platform.CoreMedia.CMTimeMake
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSOperationQueue
import platform.Foundation.NSURL
import platform.QuartzCore.CATransaction
import platform.UIKit.UIApplicationDidEnterBackgroundNotification
import platform.UIKit.UIApplicationWillEnterForegroundNotification
import platform.UIKit.UIColor
import platform.UIKit.UIView

// Canvas loops and animated covers: a muted AVPlayer drawing through an AVPlayerLayer inside a
// UIKitView. It is separate from the music player (AvPlayerAdapter), as on Android and Desktop.

@OptIn(ExperimentalForeignApi::class)
private class PlayerLayerView : UIView(frame = CGRectZero.readValue()) {
    val playerLayer = AVPlayerLayer()

    init {
        backgroundColor = UIColor.clearColor
        layer.addSublayer(playerLayer)
    }

    override fun layoutSubviews() {
        super.layoutSubviews()
        // No implicit animation, or the video slides into place on every resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun MediaPlayerView(
    url: String,
    modifier: Modifier,
    cropToBounds: Boolean,
    onFirstFrame: () -> Unit,
) {
    val latestOnFirstFrame = rememberUpdatedState(onFirstFrame)
    val player = remember { AVPlayer().apply { muted = true } }
    val view = remember { PlayerLayerView().apply { playerLayer.player = player } }

    DisposableEffect(url) {
        val item = NSURL.URLWithString(url)?.let { AVPlayerItem(uRL = it) }
        player.replaceCurrentItemWithPlayerItem(item)
        player.play()
        // Canvases loop for as long as they are on screen.
        val observer =
            NSNotificationCenter.defaultCenter.addObserverForName(AVPlayerItemDidPlayToEndTimeNotification, item, NSOperationQueue.mainQueue) { _ ->
                player.seekToTime(CMTimeMake(0, 1))
                player.play()
            }
        onDispose {
            NSNotificationCenter.defaultCenter.removeObserver(observer)
            player.pause()
            player.replaceCurrentItemWithPlayerItem(null)
        }
    }
    // Callers keep the still artwork up until the first frame is actually on screen.
    LaunchedEffect(url) {
        while (!view.playerLayer.readyForDisplay) delay(100)
        latestOnFirstFrame.value()
    }
    view.playerLayer.videoGravity = if (cropToBounds) AVLayerVideoGravityResizeAspectFill else AVLayerVideoGravityResizeAspect

    UIKitView(
        factory = { view },
        modifier = modifier,
        properties = UIKitInteropProperties(isInteractive = false, isNativeAccessibilityEnabled = false),
    )
}

/** The music player's own AVPlayer, when the iOS backend is the one running. */
@Composable
private fun rememberMainAvPlayer(): AvPlayerAdapter? {
    val player = koinInject<MediaPlayerInterface>()
    return remember(player) { player as? AvPlayerAdapter }
}

/** Width / height of the video the main player is showing, or null for audio-only items. */
@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun rememberVideoAspectRatio(playerName: String): Float? {
    val adapter = rememberMainAvPlayer() ?: return null
    var ratio by remember { mutableStateOf<Float?>(null) }
    LaunchedEffect(adapter) {
        while (true) {
            ratio =
                if (!adapter.currentIsVideo) {
                    null
                } else {
                    adapter.avPlayer.currentItem?.presentationSize?.useContents { if (width > 0 && height > 0) (width / height).toFloat() else null }
                }
            delay(500)
        }
    }
    return ratio
}

/**
 * The main player's video (music videos in watch-video mode), or the artwork for audio, with the
 * synced lyric line underneath as a subtitle — the layout of Desktop's MediaPlayerViewWithSubtitleJvm.
 */
@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun MediaPlayerViewWithSubtitle(
    modifier: Modifier,
    playerName: String,
    shouldPip: Boolean,
    shouldShowSubtitle: Boolean,
    shouldScaleDownSubtitle: Boolean,
    isInPipMode: Boolean,
    timelineState: TimeLine,
    lyricsData: Lyrics?,
    translatedLyricsData: Lyrics?,
    mainTextStyle: TextStyle,
    translatedTextStyle: TextStyle,
) {
    val adapter = rememberMainAvPlayer()
    val handler = koinInject<MediaPlayerHandler>()
    val nowPlaying by handler.nowPlayingState.collectAsState()
    val lyricsOffsetMs by koinInject<DataStoreManager>().lyricsOffsetMs.collectAsState(0)

    var isVideo by remember { mutableStateOf(false) }
    LaunchedEffect(adapter) {
        while (adapter != null) {
            isVideo = adapter.currentIsVideo
            delay(300)
        }
    }

    val nowMs = timelineState.current - lyricsOffsetMs
    fun indexAt(lines: List<Line>?): Int {
        if (lines.isNullOrEmpty() || nowMs <= 0) return -1
        return lines.indexOfLast { (it.startTimeMs.toLongOrNull() ?: Long.MAX_VALUE) <= nowMs }
    }
    val lineIndex = indexAt(lyricsData?.lines)
    val translatedIndex = indexAt(translatedLyricsData?.lines)

    Box(modifier.graphicsLayer { clip = true }, contentAlignment = Alignment.Center) {
        if (isVideo && adapter != null) {
            val view = remember { PlayerLayerView().apply { playerLayer.videoGravity = AVLayerVideoGravityResizeAspect } }
            DisposableEffect(adapter) {
                view.playerLayer.player = adapter.avPlayer
                // iOS pauses a player whose video is on screen when the app leaves it (home
                // button, screen lock), which stopped the music of a music video in the
                // background. Detached from the layer it carries on as audio; back in front,
                // the picture comes back.
                val center = NSNotificationCenter.defaultCenter
                val observers =
                    listOf(
                        center.addObserverForName(UIApplicationDidEnterBackgroundNotification, null, NSOperationQueue.mainQueue) { _ ->
                            view.playerLayer.player = null
                        },
                        center.addObserverForName(UIApplicationWillEnterForegroundNotification, null, NSOperationQueue.mainQueue) { _ ->
                            view.playerLayer.player = adapter.avPlayer
                        },
                    )
                onDispose {
                    observers.forEach { center.removeObserver(it) }
                    view.playerLayer.player = null
                }
            }
            UIKitView(
                factory = { view },
                modifier = Modifier.fillMaxSize(),
                properties = UIKitInteropProperties(isInteractive = false, isNativeAccessibilityEnabled = false),
            )
        } else {
            AsyncImage(
                model = nowPlaying.songEntity?.thumbnails,
                contentDescription = null,
                contentScale = ContentScale.FillHeight,
                modifier = Modifier.fillMaxHeight(),
            )
        }
        val line = lyricsData?.lines?.getOrNull(lineIndex)?.words?.replace(Regex("<\\d{1,2}:\\d{2}(\\.\\d{1,3})?>"), "")?.trim()
        if (shouldShowSubtitle && !line.isNullOrEmpty()) {
            val scale = if (shouldScaleDownSubtitle) 0.8f else 1f
            Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth(0.8f)
                    .padding(bottom = if (shouldScaleDownSubtitle) 10.dp else 40.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = line,
                    style = mainTextStyle.copy(fontSize = mainTextStyle.fontSize * scale, shadow = SUBTITLE_SHADOW),
                    color = Color.White,
                    textAlign = TextAlign.Center,
                )
                translatedLyricsData?.lines?.getOrNull(translatedIndex)?.words?.takeIf { it.isNotBlank() }?.let { translated ->
                    Text(
                        text = translated.trim(),
                        style = translatedTextStyle.copy(fontSize = translatedTextStyle.fontSize * scale, shadow = SUBTITLE_SHADOW),
                        color = Color.Yellow,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

private val SUBTITLE_SHADOW = Shadow(color = Color.Black, offset = Offset(2f, 2f), blurRadius = 4f)
