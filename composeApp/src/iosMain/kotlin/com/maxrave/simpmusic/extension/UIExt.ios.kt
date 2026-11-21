package com.maxrave.simpmusic.extension

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import com.maxrave.domain.data.model.ui.ScreenSizeInfo
import platform.UIKit.UIApplication
import kotlin.math.roundToInt

@Composable
actual fun getScreenSizeInfo(): ScreenSizeInfo {
    val density = LocalDensity.current
    val window = LocalWindowInfo.current
    val heightPx = window.containerSize.height
    val widthPx = window.containerSize.width
    return ScreenSizeInfo(
        hDP = with(density) { heightPx.toDp().value.roundToInt() },
        wDP = with(density) { widthPx.toDp().value.roundToInt() },
        hPX = heightPx,
        wPX = widthPx,
    )
}

/** Holds the display awake while composed, like FLAG_KEEP_SCREEN_ON on Android. */
@Composable
actual fun KeepScreenOn() {
    DisposableEffect(Unit) {
        UIApplication.sharedApplication.idleTimerDisabled = true
        onDispose { UIApplication.sharedApplication.idleTimerDisabled = false }
    }
}

// Picture-in-picture needs an AVPlayerLayer, which the first iOS cut does not have.
@Composable
actual fun rememberIsInPipMode(): Boolean = false
