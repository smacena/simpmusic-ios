package com.maxrave.data.mediaservice.ios

import com.maxrave.data.native.dsp.simp_echo_set
import com.maxrave.data.native.dsp.simp_reverb_set
import com.maxrave.data.native.dsp.simp_sample_rate
import com.maxrave.domain.data.player.AudioEffects
import com.maxrave.domain.data.player.ReverbImpulseResponse
import com.maxrave.logger.Logger
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.darwin.DISPATCH_QUEUE_PRIORITY_DEFAULT
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_global_queue
import kotlin.concurrent.Volatile

// Delay and Reverb on iOS. The processing is C (simpdsp.def); Kotlin turns the shared definitions
// in core/domain into parameters: DelayEffect.taps() (ffmpeg aecho's feed-forward taps) and
// ReverbImpulseResponse (the generated room IRs), so a setting sounds the same on every platform.

@OptIn(ExperimentalForeignApi::class)
internal object IosAudioEffects {
    @Volatile private var effects: AudioEffects = AudioEffects.NONE

    fun set(newEffects: AudioEffects) {
        effects = newEffects
        applyEcho(newEffects)
        applyReverb(newEffects)
    }

    private fun applyEcho(current: AudioEffects) {
        val taps = current.delay?.taps()
        if (taps == null || taps.delaysMs.isEmpty()) {
            simp_echo_set(null, null, 0, 1f, 1f)
            return
        }
        val delays = DoubleArray(taps.delaysMs.size) { taps.delaysMs[it].toDouble() }
        val decays = taps.decays
        delays.usePinned { d ->
            decays.usePinned { k ->
                simp_echo_set(d.addressOf(0), k.addressOf(0), minOf(delays.size, decays.size), taps.inGain, taps.outGain)
            }
        }
    }

    private fun applyReverb(current: AudioEffects) {
        val wanted = current.reverb
        if (wanted == null) {
            simp_reverb_set(null, null, 0, 0f)
            return
        }
        // Generating the IR and its spectra takes tens of milliseconds: off the caller's thread.
        // The engine already playing keeps playing until the new one is swapped in.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT.toLong(), 0u)) {
            val rate = simp_sample_rate().toInt()
            val stereo = ReverbImpulseResponse.generate(wanted.preset, rate)
            if (effects.reverb != wanted) return@dispatch_async
            val length = minOf(stereo.left.size, stereo.right.size)
            stereo.left.usePinned { l ->
                stereo.right.usePinned { r ->
                    simp_reverb_set(l.addressOf(0), r.addressOf(0), length, wanted.mix.coerceIn(0f, 1f))
                }
            }
            Logger.i("IosAudioEffects", "reverb ${wanted.preset} at $rate Hz ready")
        }
    }
}
