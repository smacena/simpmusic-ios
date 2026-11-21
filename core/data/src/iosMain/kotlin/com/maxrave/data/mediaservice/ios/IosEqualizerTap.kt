@file:OptIn(ExperimentalForeignApi::class)

package com.maxrave.data.mediaservice.ios

import com.maxrave.logger.Logger
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.COpaquePointerVar
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.toCPointer
import kotlinx.cinterop.toLong
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.FloatVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.pointed
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.set
import kotlinx.cinterop.staticCFunction
import kotlinx.cinterop.value
import platform.AVFoundation.AVAssetTrack
import platform.AVFoundation.AVMutableAudioMix
import platform.AVFoundation.AVMutableAudioMixInputParameters
import platform.CoreAudioTypes.AudioBufferList
import platform.CoreAudioTypes.AudioStreamBasicDescription
import platform.CoreAudioTypes.kAudioFormatFlagIsFloat
import platform.CoreAudioTypes.kAudioFormatFlagIsNonInterleaved
import platform.CoreMedia.CMItemCountVar
import platform.MediaToolbox.MTAudioProcessingTapCallbacks
import platform.MediaToolbox.MTAudioProcessingTapCreate
import platform.MediaToolbox.MTAudioProcessingTapFlags
import platform.MediaToolbox.MTAudioProcessingTapFlagsVar
import platform.MediaToolbox.MTAudioProcessingTapGetSourceAudio
import platform.MediaToolbox.MTAudioProcessingTapGetStorage
import platform.MediaToolbox.MTAudioProcessingTapRef
import platform.MediaToolbox.MTAudioProcessingTapRefVar
import platform.MediaToolbox.kMTAudioProcessingTapCallbacksVersion_0
import platform.MediaToolbox.kMTAudioProcessingTapCreationFlag_PostEffects
import kotlin.concurrent.Volatile
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

// The ten-band equalizer on iOS. AVPlayer has no equalizer of its own, so the audio is processed
// in an MTAudioProcessingTap attached to the player item's audio mix: AVFoundation hands every
// buffer to process() before it reaches the output. The filters are the same Audio-EQ-Cookbook
// peaking biquads, centres and Q that Android (EqualizerAudioProcessor) and Desktop (ffmpeg
// "equalizer") run, so one stored curve — and one AutoEq profile — sounds the same everywhere.

private const val BANDS = 10
private const val Q = 1.41
private val CENTRES = DoubleArray(BANDS) { 31.25 * 2.0.pow(it) }
private const val MAX_CHANNELS = 8

/**
 * Taps that can run at once: the current track's and, during a crossfade, the incoming one's.
 * Each has its own filter memory, or the two would scramble each other's state into crackles.
 */
internal const val TAP_SLOTS = 2

/** Shared between the UI thread (setEqualizer) and the audio thread (process). */
internal object IosEqualizer {
    @Volatile private var gainsDb: FloatArray = FloatArray(0)

    @Volatile private var preampDb: Float = 0f

    @Volatile private var sampleRate: Double = 44_100.0

    @Volatile var floatNonInterleaved = false
        private set

    /** b0, b1, b2, a1, a2 per band, normalised by a0. Swapped whole, never edited in place. */
    @Volatile private var coefficients: DoubleArray = DoubleArray(0)

    @Volatile private var preampLinear: Float = 1f

    /** Filter memory per tap slot, channel and band: z1, z2. Only touched by the audio threads. */
    private val state = Array(TAP_SLOTS) { Array(MAX_CHANNELS) { DoubleArray(BANDS * 2) } }

    val active: Boolean get() = coefficients.isNotEmpty() || preampLinear != 1f

    fun set(
        bands: List<Float>,
        preamp: Float,
    ) {
        gainsDb = FloatArray(BANDS) { bands.getOrElse(it) { 0f } }.takeIf { bands.isNotEmpty() } ?: FloatArray(0)
        preampDb = if (bands.isEmpty()) 0f else preamp
        rebuild()
    }

    fun prepare(
        slot: Int,
        rate: Double,
        isFloatNonInterleaved: Boolean,
    ) {
        sampleRate = rate
        floatNonInterleaved = isFloatNonInterleaved
        state[slot].forEach { it.fill(0.0) }
        rebuild()
        if (!isFloatNonInterleaved) Logger.w("IosEqualizer", "unexpected tap format; equalizer bypassed")
    }

    private fun rebuild() {
        val gains = gainsDb
        preampLinear = 10.0.pow(preampDb / 20.0).toFloat()
        if (gains.isEmpty() || gains.all { it == 0f }) {
            coefficients = DoubleArray(0)
            return
        }
        val c = DoubleArray(BANDS * 5)
        for (b in 0 until BANDS) {
            val a = 10.0.pow(gains[b] / 40.0)
            val w0 = 2 * PI * CENTRES[b] / sampleRate
            if (w0 >= PI) {
                // Above Nyquist (16 kHz at a 22 kHz rate): leave the band out.
                c[b * 5] = 1.0
                continue
            }
            val alpha = sin(w0) / (2 * Q)
            val cosW = cos(w0)
            val a0 = 1 + alpha / a
            c[b * 5] = (1 + alpha * a) / a0
            c[b * 5 + 1] = (-2 * cosW) / a0
            c[b * 5 + 2] = (1 - alpha * a) / a0
            c[b * 5 + 3] = (-2 * cosW) / a0
            c[b * 5 + 4] = (1 - alpha / a) / a0
        }
        coefficients = c
    }

    /** Filters one channel of [frames] float samples in place. */
    fun processChannel(
        slot: Int,
        channel: Int,
        data: CPointer<FloatVar>,
        frames: Int,
    ) {
        if (!floatNonInterleaved || channel >= MAX_CHANNELS) return
        val c = coefficients
        val pre = preampLinear
        val z = state[slot][channel]
        for (i in 0 until frames) {
            var x = (data[i] * pre).toDouble()
            if (c.isNotEmpty()) {
                for (b in 0 until BANDS) {
                    val o = b * 5
                    // Transposed direct form II.
                    val y = c[o] * x + z[b * 2]
                    z[b * 2] = c[o + 1] * x - c[o + 3] * y + z[b * 2 + 1]
                    z[b * 2 + 1] = c[o + 2] * x - c[o + 4] * y
                    x = y
                }
            }
            data[i] = x.toFloat()
        }
    }
}

private val tapCallbacksProcess =
    staticCFunction {
        tap: MTAudioProcessingTapRef?,
        numberFrames: Long,
        _: MTAudioProcessingTapFlags,
        bufferList: CPointer<AudioBufferList>?,
        framesOut: CPointer<CMItemCountVar>?,
        flagsOut: CPointer<MTAudioProcessingTapFlagsVar>?,
        ->
        if (MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, null, framesOut) != 0) return@staticCFunction
        val slot = tapSlot(tap)
        val list = bufferList?.pointed ?: return@staticCFunction
        val eq = IosEqualizer.active
        val fx = IosAudioEffects.active
        if (!eq && !fx) return@staticCFunction
        if (!IosEqualizer.floatNonInterleaved) return@staticCFunction
        val frames = framesOut?.pointed?.value?.toInt() ?: numberFrames.toInt()
        val buffers = list.mBuffers
        for (ch in 0 until list.mNumberBuffers.toInt()) {
            val buffer = buffers[ch]
            val data = buffer.mData?.reinterpret<FloatVar>() ?: continue
            if (eq) IosEqualizer.processChannel(slot, ch, data, frames)
            if (fx) IosAudioEffects.processChannel(slot, ch, data, frames)
            protectOutput(data, frames)
        }
    }

private const val LIMIT_KNEE = 0.8f

/**
 * Last stage before the speaker, after the equalizer and the effects. A bass boost plus reverb
 * plus echo can add up past full scale, and a filter fed a bad value could emit NaN or infinity.
 * Invalid samples become silence; peaks above the knee are bent smoothly towards ±1 and never
 * past it, so no combination of settings can produce harsh clipping or a sudden blast.
 */
private fun protectOutput(
    data: CPointer<FloatVar>,
    frames: Int,
) {
    val headroom = 1f - LIMIT_KNEE
    for (i in 0 until frames) {
        val x = data[i]
        if (!x.isFinite()) {
            data[i] = 0f
            continue
        }
        val a = kotlin.math.abs(x)
        if (a > LIMIT_KNEE) {
            val over = (a - LIMIT_KNEE) / headroom
            // over/(1+over) rises from 0 towards 1: the output approaches ±1 without reaching it.
            val y = LIMIT_KNEE + headroom * (over / (1f + over))
            data[i] = if (x < 0f) -y else y
        }
    }
}

/** The slot a tap was created for, carried as its storage pointer (slot + 1, so never null). */
private fun tapSlot(tap: MTAudioProcessingTapRef?): Int =
    ((MTAudioProcessingTapGetStorage(tap).toLong() - 1).toInt()).coerceIn(0, TAP_SLOTS - 1)

private val tapCallbacksInit =
    staticCFunction { _: MTAudioProcessingTapRef?, clientInfo: COpaquePointer?, storageOut: CPointer<COpaquePointerVar>? ->
        storageOut?.pointed?.value = clientInfo
    }

private val tapCallbacksPrepare =
    staticCFunction { tap: MTAudioProcessingTapRef?, _: Long, format: CPointer<AudioStreamBasicDescription>? ->
        val f = format?.pointed ?: return@staticCFunction
        val flags = f.mFormatFlags
        val slot = tapSlot(tap)
        IosEqualizer.prepare(
            slot,
            f.mSampleRate,
            (flags and kAudioFormatFlagIsFloat) != 0u && (flags and kAudioFormatFlagIsNonInterleaved) != 0u,
        )
        IosAudioEffects.prepare(slot, f.mSampleRate)
    }

/** An audio mix carrying the equalizer tap for [track], or null if the tap could not be made. */
internal fun equalizerAudioMix(
    track: AVAssetTrack,
    slot: Int = 0,
): AVMutableAudioMix? =
    memScoped {
        val callbacks = alloc<MTAudioProcessingTapCallbacks>()
        callbacks.version = kMTAudioProcessingTapCallbacksVersion_0
        callbacks.clientInfo = (slot.coerceIn(0, TAP_SLOTS - 1) + 1).toLong().toCPointer()
        callbacks.init = tapCallbacksInit
        callbacks.finalize = null
        callbacks.prepare = tapCallbacksPrepare
        callbacks.unprepare = null
        callbacks.process = tapCallbacksProcess
        val tapOut = alloc<MTAudioProcessingTapRefVar>()
        val status = MTAudioProcessingTapCreate(null, callbacks.ptr, kMTAudioProcessingTapCreationFlag_PostEffects, tapOut.ptr)
        if (status != 0) {
            Logger.e("IosEqualizer", "MTAudioProcessingTapCreate failed ($status)")
            return@memScoped null
        }
        val parameters = AVMutableAudioMixInputParameters.audioMixInputParametersWithTrack(track)
        parameters.setAudioTapProcessor(tapOut.value)
        AVMutableAudioMix().apply { setInputParameters(listOf(parameters)) }
    }
