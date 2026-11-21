package com.maxrave.spotify.auth

import kotlin.test.Test
import kotlin.test.assertEquals

class SpotifyTotpIosTest {
    // RFC 6238 appendix B, SHA-1 seed "12345678901234567890", truncated to 6 digits.
    private val rfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    @Test
    fun matchesRfc6238Vectors() {
        assertEquals("287082", generateTotp(rfcSecret, 59_000L))
        assertEquals("081804", generateTotp(rfcSecret, 1_111_111_109_000L))
        assertEquals("050471", generateTotp(rfcSecret, 1_111_111_111_000L))
        assertEquals("005924", generateTotp(rfcSecret, 1_234_567_890_000L))
        assertEquals("279037", generateTotp(rfcSecret, 2_000_000_000_000L))
    }

    @Test
    fun spotifySecretProducesSixDigits() {
        val code = SpotifyTotp.at(1_700_000_000_000L, null)
        assertEquals(6, code.length)
    }
}
