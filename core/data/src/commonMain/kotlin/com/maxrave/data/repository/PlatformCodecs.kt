package com.maxrave.data.repository

/** False on iOS: AVPlayer has no Opus decoder, so the AAC streams are requested instead. */
internal expect val platformPlaysOpus: Boolean

/**
 * False on iOS, which has no crossfade/AutoMix yet. The Tidal BPM/key lookup in getStream exists
 * only to feed AutoMix, and it sits on the path that starts every track, so iOS skips it.
 */
internal expect val platformUsesAutoMix: Boolean
