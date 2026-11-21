package com.maxrave.ktorext.crypto

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.CoreCrypto.CCHmac
import platform.CoreCrypto.CC_SHA1_DIGEST_LENGTH
import platform.CoreCrypto.CC_SHA256_DIGEST_LENGTH
import platform.CoreCrypto.kCCHmacAlgSHA1
import platform.CoreCrypto.kCCHmacAlgSHA256
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.time.Clock

/** CommonCrypto-backed twin of the JVM implementation (javax.crypto.Mac + Base64). */
actual class Hmac actual constructor(
    algorithm: String,
    secretKey: String,
) {
    private val tokenTtl: Long = 300_000 // 5 minutes, as on the JVM
    private val key = secretKey.encodeToByteArray()
    private val alg: UInt
    private val digestLength: Int

    init {
        when (algorithm.uppercase()) {
            "HMACSHA256" -> {
                alg = kCCHmacAlgSHA256
                digestLength = CC_SHA256_DIGEST_LENGTH
            }
            "HMACSHA1" -> {
                alg = kCCHmacAlgSHA1
                digestLength = CC_SHA1_DIGEST_LENGTH
            }
            else -> throw IllegalArgumentException("Unsupported HMAC algorithm: $algorithm")
        }
    }

    actual fun getMacTimestampPair(uri: String): Pair<String, String> {
        val timestamp = Clock.System.now().toEpochMilliseconds().toString()
        return generateHmac("$timestamp$uri") to timestamp
    }

    @OptIn(ExperimentalForeignApi::class, ExperimentalEncodingApi::class)
    actual fun generateHmac(data: String): String {
        val message = data.encodeToByteArray()
        val out = ByteArray(digestLength)
        // usePinned on an empty array has no address to take, so give CommonCrypto one byte.
        val keyBytes = if (key.isEmpty()) ByteArray(1) else key
        val msgBytes = if (message.isEmpty()) ByteArray(1) else message
        keyBytes.usePinned { k ->
            msgBytes.usePinned { m ->
                out.usePinned { o ->
                    CCHmac(alg, k.addressOf(0), key.size.toULong(), m.addressOf(0), message.size.toULong(), o.addressOf(0))
                }
            }
        }
        return Base64.encode(out)
    }

    actual fun validateHmac(
        data: String,
        hmac: String,
    ): Boolean = generateHmac(data) == hmac

    actual fun isValidTimestamp(timestamp: String): Boolean {
        val requestTime = timestamp.toLongOrNull() ?: return false
        return (Clock.System.now().toEpochMilliseconds() - requestTime) < tokenTtl
    }
}
