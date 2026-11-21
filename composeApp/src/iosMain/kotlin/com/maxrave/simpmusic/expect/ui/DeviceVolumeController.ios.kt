package com.maxrave.simpmusic.expect.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.readValue
import kotlinx.coroutines.delay
import platform.AVFAudio.AVAudioSession
import platform.AVFAudio.outputVolume
import platform.CoreGraphics.CGRectMake
import platform.MediaPlayer.MPVolumeView
import platform.UIKit.UISlider

/**
 * The iPhone's media volume. iOS lets an app change it only through the system's own volume
 * control (MPVolumeView), so a hidden one is kept and its slider moved; the level is read from the
 * audio session. While the volume row is on screen the level is re-read twice a second, so the
 * hardware buttons and Control Center show up in the row too.
 */
@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun rememberDeviceVolumeController(): DeviceVolumeController? {
    val controller = remember { IosDeviceVolumeController() }
    LaunchedEffect(controller) {
        while (true) {
            controller.refresh()
            delay(500)
        }
    }
    return controller
}

@OptIn(ExperimentalForeignApi::class)
private class IosDeviceVolumeController : DeviceVolumeController {
    private val volumeView = MPVolumeView(frame = CGRectMake(-1000.0, -1000.0, 1.0, 1.0))
    private var level by mutableFloatStateOf(AVAudioSession.sharedInstance().outputVolume)

    override val volumeFraction: Float get() = level

    fun refresh() {
        level = AVAudioSession.sharedInstance().outputVolume
    }

    override fun setVolumeFraction(fraction: Float) {
        val value = fraction.coerceIn(0f, 1f)
        val slider = volumeView.subviews.firstOrNull { it is UISlider } as? UISlider ?: return
        slider.setValue(value, animated = false)
        level = value
    }
}
