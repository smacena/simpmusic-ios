package com.maxrave.data.mediaservice.ios

import com.maxrave.data.native.dsp.simp_create_tap
import com.maxrave.data.native.dsp.simp_eq_set
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.AVFoundation.AVAssetTrack
import platform.AVFoundation.AVMutableAudioMix
import platform.AVFoundation.AVMutableAudioMixInputParameters
import platform.CoreFoundation.CFRelease

// The ten-band equalizer on iOS. The filtering itself is C (simpdsp.def), running inside an
// MTAudioProcessingTap on the audio thread; this file only publishes the curve and builds the
// audio mix that carries the tap. Same Audio-EQ-Cookbook peaking biquads, centres (31.25·2^i Hz)
// and Q (1.41) as Android and Desktop, so one stored curve sounds the same everywhere.

private const val BANDS = 10

@OptIn(ExperimentalForeignApi::class)
internal object IosEqualizer {
    /** [bands] empty = equalizer off. */
    fun set(
        bands: List<Float>,
        preamp: Float,
    ) {
        val gains = DoubleArray(minOf(bands.size, BANDS)) { bands[it].toDouble() }
        if (gains.isEmpty()) {
            simp_eq_set(null, 0, 0.0)
        } else {
            gains.usePinned { simp_eq_set(it.addressOf(0), gains.size, preamp.toDouble()) }
        }
    }
}

/** An audio mix carrying the C processing tap for [track] in [slot], or null if it could not be made. */
@OptIn(ExperimentalForeignApi::class)
internal fun equalizerAudioMix(
    track: AVAssetTrack,
    slot: Int = 0,
): AVMutableAudioMix? {
    val tap = simp_create_tap(slot) ?: return null
    val parameters = AVMutableAudioMixInputParameters.audioMixInputParametersWithTrack(track)
    parameters.setAudioTapProcessor(tap)
    CFRelease(tap) // the input parameters keep their own reference
    return AVMutableAudioMix().apply { setInputParameters(listOf(parameters)) }
}
