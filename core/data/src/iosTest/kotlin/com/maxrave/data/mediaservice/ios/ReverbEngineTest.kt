@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.maxrave.data.mediaservice.ios

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.FloatVar
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.set
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertTrue

@OptIn(ExperimentalForeignApi::class)
class ReverbEngineTest {
    /** An impulse through h = δ[0] + 0.5·δ[1500] (two partitions) comes out as h, one block late. */
    @Test
    fun impulseComesOutAsTheImpulseResponse() =
        memScoped {
            val ir = FloatArray(1600).also {
                it[0] = 1f
                it[1500] = 0.5f
            }
            val engine = ReverbEngine(listOf(ir), mix = 1f)
            val frames = 4096
            val buf = allocArray<FloatVar>(frames)
            for (i in 0 until frames) buf[i] = 0f
            buf[0] = 1f
            // Uneven callback sizes, as the audio tap delivers them.
            var done = 0
            for (chunk in listOf(300, 1000, 700, 2096)) {
                engine.process(0, (buf + done)!!, chunk)
                done += chunk
            }
            val out = FloatArray(frames) { buf[it] }
            engine.free()
            assertTrue(abs(out[1024] - 1f) < 1e-3, "direct tap: ${out[1024]}")
            assertTrue(abs(out[1024 + 1500] - 0.5f) < 1e-3, "late tap: ${out[2524]}")
            val stray = out.withIndex().filter { (i, v) -> i != 1024 && i != 2524 && abs(v) > 1e-3 }
            assertTrue(stray.isEmpty(), "unexpected energy at ${stray.take(5)}")
        }
}

private operator fun kotlinx.cinterop.CPointer<FloatVar>.plus(offset: Int) = kotlinx.cinterop.interpretCPointer<FloatVar>(this.rawValue + offset.toLong() * 4)
