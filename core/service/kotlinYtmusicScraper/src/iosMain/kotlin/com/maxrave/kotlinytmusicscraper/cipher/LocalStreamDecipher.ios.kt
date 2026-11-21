package com.maxrave.kotlinytmusicscraper.cipher

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Runnable
import platform.Foundation.NSCondition
import platform.Foundation.NSThread
import kotlin.coroutines.CoroutineContext

actual val localStreamDecipherEnabled: Boolean = true

/**
 * A dispatcher backed by ONE NSThread with a 32 MB stack.
 *
 * Kotlin/Native's newSingleThreadContext cannot size its stack, and secondary iOS threads get
 * 512 KB — YouTube's n-transform recurses far deeper than that inside QuickJS, which then crashes
 * the process instead of raising a JS error (see FaradayJsDecoder on the JVM for the same story).
 */
private class LargeStackThreadDispatcher : CoroutineDispatcher() {
    private val condition = NSCondition()
    private val queue = ArrayDeque<Runnable>()

    init {
        val thread =
            NSThread {
                while (true) {
                    condition.lock()
                    while (queue.isEmpty()) condition.wait()
                    val task = queue.removeFirst()
                    condition.unlock()
                    task.run()
                }
            }
        thread.name = "QuickJs-Local"
        thread.stackSize = 32uL * 1024uL * 1024uL
        thread.start()
    }

    override fun dispatch(
        context: CoroutineContext,
        block: Runnable,
    ) {
        condition.lock()
        queue.addLast(block)
        condition.signal()
        condition.unlock()
    }
}

actual fun createJsCipherDispatcher(): CoroutineDispatcher = LargeStackThreadDispatcher()

actual val downloadsAsAac: Boolean = true
