package com.maxrave.simpmusic.utils

import com.maxrave.ktorext.getEngine
import io.ktor.client.HttpClient

/**
 * One HTTP client for the screens that download artwork themselves (palette extraction, share
 * images). Three of them used to pass `HttpClient(CIO)` straight into `rememberNetworkLoader`,
 * which built a fresh client — and a fresh loader — on every recomposition and closed none of
 * them; the others remembered theirs but never closed it either. The engine comes from ktorExt,
 * so this also works on iOS, where CIO has no TLS.
 */
val imageHttpClient: HttpClient by lazy { HttpClient(getEngine()) }
