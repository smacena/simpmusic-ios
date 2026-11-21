@file:OptIn(ExperimentalForeignApi::class)

package com.maxrave.data.mediaservice.ios

import kotlin.concurrent.AtomicReference
import com.maxrave.domain.data.player.AudioEffects
import com.maxrave.domain.data.player.ReverbImpulseResponse
import com.maxrave.domain.data.player.ReverbPreset
import com.maxrave.logger.Logger
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.FloatVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.nativeHeap
import kotlinx.cinterop.plus
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.set
import platform.Accelerate.DSPComplex
import platform.Accelerate.DSPSplitComplex
import platform.Accelerate.FFTSetup
import platform.Accelerate.FFT_FORWARD
import platform.Accelerate.FFT_INVERSE
import platform.Accelerate.FFT_RADIX2
import platform.Accelerate.vDSP_create_fftsetup
import platform.Accelerate.vDSP_ctoz
import platform.Accelerate.vDSP_destroy_fftsetup
import platform.Accelerate.vDSP_fft_zrip
import platform.Accelerate.vDSP_vclr
import platform.Accelerate.vDSP_zvma
import platform.Accelerate.vDSP_ztoc
import platform.darwin.DISPATCH_QUEUE_PRIORITY_DEFAULT
import platform.darwin.DISPATCH_TIME_NOW
import platform.darwin.NSEC_PER_SEC
import platform.darwin.dispatch_after
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_global_queue
import platform.darwin.dispatch_time
import kotlin.concurrent.Volatile

// Delay and Reverb on iOS, processed in the same MTAudioProcessingTap as the equalizer (see
// IosEqualizerTap). Both follow the definitions every platform shares in core/domain:
// DelayEffect.taps() (ffmpeg aecho's feed-forward taps) and ReverbImpulseResponse (the generated
// room IRs), so a stored setting sounds the same on Android, Desktop and iOS.

private const val MAX_CHANNELS = 2

/** Feed-forward echo: y = x·inGain + Σ decayₖ·x[n − dₖ], then ·outGain — aecho's shape. */
internal class EchoEngine(
    taps: com.maxrave.domain.data.player.DelayTaps,
    sampleRate: Double,
) {
    private val inGain = taps.inGain
    private val outGain = taps.outGain
    private val decays = taps.decays
    private val delays = IntArray(taps.delaysMs.size) { (taps.delaysMs[it] * sampleRate / 1000.0).toInt().coerceAtLeast(1) }
    private val size = (delays.maxOrNull() ?: 1) + 1
    private val rings = Array(MAX_CHANNELS) { FloatArray(size) }
    private val heads = IntArray(MAX_CHANNELS)

    fun process(
        channel: Int,
        data: CPointer<FloatVar>,
        frames: Int,
    ) {
        if (channel >= MAX_CHANNELS) return
        val ring = rings[channel]
        var head = heads[channel]
        for (i in 0 until frames) {
            val x = data[i]
            ring[head] = x
            var y = x * inGain
            for (k in delays.indices) {
                var idx = head - delays[k]
                if (idx < 0) idx += size
                y += decays[k] * ring[idx]
            }
            data[i] = y * outGain
            head++
            if (head == size) head = 0
        }
        heads[channel] = head
    }
}

/**
 * Uniformly partitioned overlap-save convolution, block B, FFT 2B, on Accelerate's vDSP — the
 * same algorithm as Android's PartitionedConvolver. The dry signal is delayed by the same one block
 * so `(1 − m)·x + m·(x ⊛ h)` stays aligned. All buffers live on the native heap; [free] releases them.
 */
internal class ReverbEngine(
    impulse: List<FloatArray>,
    private val mix: Float,
) {
    private val block = 1024
    private val n = block * 2
    private val log2n = 11L
    private val half = block // complex bins in vDSP's packed real FFT
    private val setup: FFTSetup? = vDSP_create_fftsetup(log2n.toULong().toLong().let { it.toULong() }, FFT_RADIX2.toInt())
    private val channels = impulse.size.coerceIn(1, MAX_CHANNELS)
    private val partitions = maxOf(1, (impulse.maxOf { it.size } + block - 1) / block)

    // Per channel: partitions × half bins, real and imaginary.
    private val irRe = Array(channels) { nativeHeap.allocArray<FloatVar>(partitions * half) }
    private val irIm = Array(channels) { nativeHeap.allocArray<FloatVar>(partitions * half) }
    private val fdlRe = Array(channels) { nativeHeap.allocArray<FloatVar>(partitions * half) }
    private val fdlIm = Array(channels) { nativeHeap.allocArray<FloatVar>(partitions * half) }
    private val fdlHead = IntArray(channels)
    private val time = nativeHeap.allocArray<FloatVar>(n)
    private val accRe = nativeHeap.allocArray<FloatVar>(half)
    private val accIm = nativeHeap.allocArray<FloatVar>(half)

    private val history = Array(channels) { FloatArray(block) } // previous input block
    private val current = Array(channels) { FloatArray(block) }
    private val wet = Array(channels) { FloatArray(block) }
    private val position = IntArray(channels)

    init {
        for (c in 0 until channels) {
            vDSP_vclr(fdlRe[c], 1, (partitions * half).toULong())
            vDSP_vclr(fdlIm[c], 1, (partitions * half).toULong())
            val h = impulse[c.coerceAtMost(impulse.lastIndex)]
            for (p in 0 until partitions) {
                vDSP_vclr(time, 1, n.toULong())
                for (i in 0 until block) {
                    val src = p * block + i
                    if (src < h.size) time[i] = h[src]
                }
                forward(time, irRe[c] + p * half, irIm[c] + p * half)
            }
        }
    }

    /** Packed real FFT of [input] (n reals) into [re]/[im] (half bins each). */
    private fun forward(
        input: CPointer<FloatVar>,
        re: CPointer<FloatVar>?,
        im: CPointer<FloatVar>?,
    ) = memScoped {
        val split = alloc<DSPSplitComplex>()
        split.realp = re
        split.imagp = im
        vDSP_ctoz(input.reinterpret<DSPComplex>(), 2, split.ptr, 1, half.toULong())
        vDSP_fft_zrip(setup, split.ptr, 1, log2n.toULong(), FFT_FORWARD)
    }

    private fun convolveBlock(c: Int) {
        // Time buffer: previous block then the current one (overlap-save).
        val prev = history[c]
        val cur = current[c]
        for (i in 0 until block) {
            time[i] = prev[i]
            time[block + i] = cur[i]
        }
        val head = fdlHead[c]
        forward(time, fdlRe[c] + head * half, fdlIm[c] + head * half)

        vDSP_vclr(accRe, 1, half.toULong())
        vDSP_vclr(accIm, 1, half.toULong())
        var dc = 0f
        var nyquist = 0f
        memScoped {
            val x = alloc<DSPSplitComplex>()
            val h = alloc<DSPSplitComplex>()
            val acc = alloc<DSPSplitComplex>()
            acc.realp = accRe
            acc.imagp = accIm
            for (p in 0 until partitions) {
                var slot = head - p
                if (slot < 0) slot += partitions
                val xr = fdlRe[c] + slot * half
                val xi = fdlIm[c] + slot * half
                val hr = irRe[c] + p * half
                val hi = irIm[c] + p * half
                // Bin 0 packs DC (real) and Nyquist (imaginary) — multiply them separately.
                dc += xr!![0] * hr!![0]
                nyquist += xi!![0] * hi!![0]
                x.realp = xr
                x.imagp = xi
                h.realp = hr
                h.imagp = hi
                vDSP_zvma(x.ptr, 1, h.ptr, 1, acc.ptr, 1, acc.ptr, 1, half.toULong())
            }
            accRe[0] = dc
            accIm[0] = nyquist
            vDSP_fft_zrip(setup, acc.ptr, 1, log2n.toULong(), FFT_INVERSE)
            vDSP_ztoc(acc.ptr, 1, time.reinterpret<DSPComplex>(), 2, half.toULong())
        }
        // vDSP's packed forward is 2× the DFT and its inverse is unnormalised: 1/(4N) overall.
        val scale = 1f / (4f * n)
        val out = wet[c]
        for (i in 0 until block) out[i] = time[block + i] * scale
        fdlHead[c] = if (head + 1 == partitions) 0 else head + 1
        history[c] = cur
        current[c] = prev
    }

    fun process(
        channel: Int,
        data: CPointer<FloatVar>,
        frames: Int,
    ) {
        if (channel >= channels) return
        var pos = position[channel]
        for (i in 0 until frames) {
            val x = data[i]
            val dryDelayed = history[channel][pos]
            val y = (1f - mix) * dryDelayed + mix * wet[channel][pos]
            current[channel][pos] = x
            data[i] = y
            pos++
            if (pos == block) {
                convolveBlock(channel)
                pos = 0
            }
        }
        position[channel] = pos
    }

    fun free() {
        vDSP_destroy_fftsetup(setup)
        (irRe + irIm + fdlRe + fdlIm).forEach { nativeHeap.free(it.rawValue) }
        nativeHeap.free(time.rawValue)
        nativeHeap.free(accRe.rawValue)
        nativeHeap.free(accIm.rawValue)
    }
}

/**
 * Shared between the UI thread (setAudioEffects) and the audio threads (process). Each tap slot
 * (see TAP_SLOTS) has its own engines: echo lines and reverb tails are filter memory too, and
 * two tracks playing through one engine during a crossfade would smear into each other.
 */
internal object IosAudioEffects {
    @Volatile private var effects: AudioEffects = AudioEffects.NONE

    private val sampleRates = Array(TAP_SLOTS) { AtomicReference(0.0) }
    private val echo = Array(TAP_SLOTS) { AtomicReference<EchoEngine?>(null) }
    private val reverb = Array(TAP_SLOTS) { AtomicReference<ReverbEngine?>(null) }

    fun set(newEffects: AudioEffects) {
        effects = newEffects
        for (slot in 0 until TAP_SLOTS) rebuild(slot)
    }

    fun prepare(
        slot: Int,
        rate: Double,
    ) {
        sampleRates[slot].value = rate
        rebuild(slot)
    }

    private fun rebuild(slot: Int) {
        val rate = sampleRates[slot].value.takeIf { it > 0 } ?: return
        val current = effects
        echo[slot].value = current.delay?.let { EchoEngine(it.taps(), rate) }
        val wanted = current.reverb
        if (wanted == null) {
            retire(reverb[slot].getAndSet(null))
            return
        }
        // The IR is generated and transformed off the audio thread; the old engine keeps playing
        // until the new one is swapped in.
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT.toLong(), 0u)) {
            val stereo = ReverbImpulseResponse.generate(wanted.preset, rate.toInt())
            val engine = ReverbEngine(listOf(stereo.left, stereo.right), wanted.mix.coerceIn(0f, 1f))
            if (effects.reverb != wanted || sampleRates[slot].value != rate) {
                engine.free()
                return@dispatch_async
            }
            retire(reverb[slot].getAndSet(engine))
            Logger.i("IosAudioEffects", "reverb ${wanted.preset} at ${rate.toInt()} Hz ready (slot $slot)")
        }
    }

    /** Frees an engine once the audio thread can no longer be inside it. */
    private fun retire(engine: ReverbEngine?) {
        engine ?: return
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (2 * NSEC_PER_SEC.toLong())), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT.toLong(), 0u)) {
            engine.free()
        }
    }

    val active: Boolean get() = effects.delay != null || effects.reverb != null

    fun processChannel(
        slot: Int,
        channel: Int,
        data: CPointer<FloatVar>,
        frames: Int,
    ) {
        echo[slot].value?.process(channel, data, frames)
        reverb[slot].value?.process(channel, data, frames)
    }
}
