package com.maxrave.spotify.auth

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.CoreCrypto.CCHmac
import platform.CoreCrypto.CC_SHA1_DIGEST_LENGTH
import platform.CoreCrypto.kCCHmacAlgSHA1

private const val BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
private const val TIME_STEP_SECONDS = 30L
private const val DIGITS = 6

/**
 * RFC 6238 TOTP — the same output Android and Desktop get from kotlin-onetimepassword's
 * GoogleAuthenticator (Base32 secret, HMAC-SHA1, 30-second steps, 6 digits), computed with
 * CommonCrypto because that library is JVM-only. This used to be TODO(), which crashed the app
 * the moment Spotify sign-in asked for a code.
 */
@OptIn(ExperimentalForeignApi::class)
actual fun generateTotp(
    secret: String,
    timestamp: Long,
): String {
    val key = base32Decode(secret)
    var counter = timestamp / 1000 / TIME_STEP_SECONDS
    val message = ByteArray(8)
    for (i in 7 downTo 0) {
        message[i] = (counter and 0xFF).toByte()
        counter = counter shr 8
    }
    val digest = ByteArray(CC_SHA1_DIGEST_LENGTH)
    key.usePinned { k ->
        message.usePinned { m ->
            digest.usePinned { d ->
                CCHmac(
                    kCCHmacAlgSHA1,
                    if (key.isEmpty()) null else k.addressOf(0),
                    key.size.toULong(),
                    m.addressOf(0),
                    message.size.toULong(),
                    d.addressOf(0),
                )
            }
        }
    }
    val offset = digest.last().toInt() and 0x0F
    val binary =
        ((digest[offset].toInt() and 0x7F) shl 24) or
            ((digest[offset + 1].toInt() and 0xFF) shl 16) or
            ((digest[offset + 2].toInt() and 0xFF) shl 8) or
            (digest[offset + 3].toInt() and 0xFF)
    var modulus = 1
    repeat(DIGITS) { modulus *= 10 }
    return (binary % modulus).toString().padStart(DIGITS, '0')
}

/** Base32 (RFC 4648) to bytes; padding and case are ignored, as GoogleAuthenticator does. */
internal fun base32Decode(input: String): ByteArray {
    val out = ArrayList<Byte>(input.length * 5 / 8)
    var buffer = 0
    var bits = 0
    for (c in input.uppercase()) {
        if (c == '=' || c.isWhitespace()) continue
        val value = BASE32_ALPHABET.indexOf(c)
        require(value >= 0) { "Invalid Base32 character" }
        buffer = (buffer shl 5) or value
        bits += 5
        if (bits >= 8) {
            out.add(((buffer shr (bits - 8)) and 0xFF).toByte())
            bits -= 8
        }
    }
    return out.toByteArray()
}
