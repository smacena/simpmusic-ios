package com.maxrave.data.mediaservice.ios

import com.maxrave.data.native.dsp.simp_echo_set
import com.maxrave.data.native.dsp.simp_eq_set
import com.maxrave.data.native.dsp.simp_normalize_set
import com.maxrave.data.native.dsp.simp_process_channel
import com.maxrave.data.native.dsp.simp_reverb_set
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlin.math.abs
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@OptIn(ExperimentalForeignApi::class)
class SimpDspTest {
    @AfterTest
    fun reset() {
        simp_eq_set(null, 0, 0.0)
        simp_echo_set(null, null, 0, 1f, 1f)
        simp_reverb_set(null, null, 0, 0f)
        simp_normalize_set(1f)
    }

    private fun process(buffer: FloatArray, slot: Int = 0) =
        buffer.usePinned { simp_process_channel(slot, 0, it.addressOf(0), buffer.size) }

    @Test
    fun everythingOffIsBitIdentical() {
        val input = FloatArray(4096) { kotlin.math.sin(it * 0.05f) * 0.5f }
        val buf = input.copyOf()
        process(buf)
        assertTrue(buf.contentEquals(input))
    }

    @Test
    fun flatEqualizerIsTransparent() {
        val gains = DoubleArray(10)
        gains.usePinned { simp_eq_set(it.addressOf(0), 10, 0.0) }
        val input = FloatArray(4096) { kotlin.math.sin(it * 0.05f) * 0.5f }
        val buf = input.copyOf()
        process(buf)
        for (i in buf.indices) assertTrue(abs(buf[i] - input[i]) < 1e-5f, "sample $i")
    }

    @Test
    fun reverbImpulseLandsOneBlockLater() {
        val ir = FloatArray(3000).also { it[0] = 1f; it[1500] = 0.5f }
        ir.usePinned { simp_reverb_set(it.addressOf(0), it.addressOf(0), ir.size, 1f) }
        val buf = FloatArray(8192).also { it[0] = 0.5f }
        process(buf)
        assertTrue(abs(buf[1024] - 0.5f) < 1e-3f, "direct at 1024: ${buf[1024]}")
        assertTrue(abs(buf[2524] - 0.25f) < 1e-3f, "reflection at 2524: ${buf[2524]}")
        assertTrue(abs(buf[500]) < 1e-4f)
    }

    @Test
    fun echoRepeatsAfterTheDelay() {
        val delays = doubleArrayOf(10.0) // 441 samples at 44.1 kHz
        val decays = floatArrayOf(0.5f)
        delays.usePinned { d -> decays.usePinned { k -> simp_echo_set(d.addressOf(0), k.addressOf(0), 1, 1f, 1f) } }
        val buf = FloatArray(2048).also { it[0] = 0.4f }
        process(buf)
        assertEquals(0.4f, buf[0], 1e-6f)
        assertEquals(0.2f, buf[441], 1e-6f)
    }

    @Test
    fun limiterNeverExceedsFullScaleAndDropsNaN() {
        simp_normalize_set(4f) // forces the chain on; 4x gain pushes everything past full scale
        val buf = floatArrayOf(0.9f, -0.9f, 0.1f, Float.NaN, 0.5f)
        process(buf)
        assertTrue(buf.all { abs(it) < 1f }, buf.joinToString())
        assertEquals(0f, buf[3])
    }
}
