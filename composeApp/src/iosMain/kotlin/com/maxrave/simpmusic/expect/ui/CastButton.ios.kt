package com.maxrave.simpmusic.expect.ui

import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.UIKitView
import kotlinx.cinterop.ExperimentalForeignApi
import platform.AVKit.AVRoutePickerView
import platform.UIKit.UIColor

/**
 * The Cast slot on iOS is AirPlay: Apple TV, HomePod, AirPlay speakers and Bluetooth outputs, via
 * the system route picker (the same sheet Control Center opens). Google Cast's receiver list does
 * not apply, so [rememberCastReceivers] stays empty.
 */
@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun PlatformCastButton(
    modifier: Modifier,
    tint: Color,
) {
    val argb = tint.toArgb()
    val color =
        UIColor.colorWithRed(
            ((argb shr 16) and 0xFF) / 255.0,
            ((argb shr 8) and 0xFF) / 255.0,
            (argb and 0xFF) / 255.0,
            ((argb ushr 24) and 0xFF) / 255.0,
        )
    UIKitView(
        factory = {
            AVRoutePickerView().apply {
                backgroundColor = UIColor.clearColor
                prioritizesVideoDevices = false
            }
        },
        modifier = modifier.size(40.dp),
        update = { view ->
            view.tintColor = color
            view.activeTintColor = color
        },
    )
}

actual fun isPlatformCastAvailable(): Boolean = true

@Composable
actual fun rememberCastReceivers(discover: Boolean): CastReceivers = NoCastReceivers

private val NoCastReceivers = CastReceivers(receivers = emptyList(), connect = {}, disconnect = {})
