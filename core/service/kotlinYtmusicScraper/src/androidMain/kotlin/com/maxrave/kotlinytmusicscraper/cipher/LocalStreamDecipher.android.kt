package com.maxrave.kotlinytmusicscraper.cipher

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.asCoroutineDispatcher
import java.util.concurrent.Executors

// PipePipe resolves streams here; the common decipher path stays off.
actual val localStreamDecipherEnabled: Boolean = false

actual fun createJsCipherDispatcher(): CoroutineDispatcher =
    Executors
        .newSingleThreadExecutor { runnable -> Thread(null, runnable, "QuickJs-Local", 32L * 1024L * 1024L) }
        .asCoroutineDispatcher()

actual val downloadsAsAac: Boolean = false
