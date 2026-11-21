package com.maxrave.ktorext.encoding

import io.ktor.util.ContentEncoder
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.ByteWriteChannel
import kotlin.coroutines.CoroutineContext

/**
 * NSURLSession, under Ktor's Darwin engine, already inflates `br` responses before Ktor sees the
 * body, so all this encoder has to do on iOS is advertise `br` and pass bytes through untouched.
 * (It used to be TODO(), which threw the moment any client installing `brotli()` was built.)
 */
private object PassthroughBrotliEncoder : ContentEncoder {
    override val name: String = "br"

    override fun encode(
        source: ByteReadChannel,
        coroutineContext: CoroutineContext,
    ): ByteReadChannel = source

    override fun encode(
        source: ByteWriteChannel,
        coroutineContext: CoroutineContext,
    ): ByteWriteChannel = source

    override fun decode(
        source: ByteReadChannel,
        coroutineContext: CoroutineContext,
    ): ByteReadChannel = source
}

actual fun createBrotliEncoder(): ContentEncoder = PassthroughBrotliEncoder
