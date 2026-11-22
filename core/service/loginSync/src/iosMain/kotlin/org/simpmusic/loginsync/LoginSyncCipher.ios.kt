@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package org.simpmusic.loginsync

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.CoreCrypto.CCCrypt
import platform.CoreCrypto.kCCAlgorithmAES
import platform.CoreCrypto.kCCEncrypt
import platform.CoreCrypto.kCCOptionECBMode
import platform.CoreCrypto.kCCSuccess
import platform.Security.SecRandomCopyBytes
import platform.Security.kSecRandomDefault
import platform.posix.size_tVar

/**
 * AES-256-GCM for iOS, wire-identical to javax's "AES/GCM/NoPadding" with a 96-bit nonce and a
 * 128-bit tag (NIST SP 800-38D). CommonCrypto has no public GCM, so AES itself comes from
 * CommonCrypto (ECB over a buffer of counter blocks = CTR mode in one call) and GHASH is done here.
 */
internal actual object LoginSyncCipher {
    actual fun newKey(): ByteArray = randomBytes(LoginSyncWire.KEY_BYTES)

    actual fun seal(
        key: ByteArray,
        aad: ByteArray,
        plain: ByteArray,
    ): ByteArray {
        val nonce = randomBytes(LoginSyncWire.NONCE_BYTES)
        val (cipher, tag) = gcm(key, nonce, aad, plain, encrypt = true)
        return nonce + cipher + tag
    }

    actual fun open(
        key: ByteArray,
        aad: ByteArray,
        sealed: ByteArray,
    ): ByteArray? {
        val tagBytes = LoginSyncWire.TAG_BITS / 8
        if (sealed.size < LoginSyncWire.NONCE_BYTES + tagBytes) return null
        val nonce = sealed.copyOfRange(0, LoginSyncWire.NONCE_BYTES)
        val body = sealed.copyOfRange(LoginSyncWire.NONCE_BYTES, sealed.size - tagBytes)
        val tag = sealed.copyOfRange(sealed.size - tagBytes, sealed.size)
        val (plain, expected) = gcm(key, nonce, aad, body, encrypt = false)
        // Constant-time compare.
        var diff = 0
        for (i in tag.indices) diff = diff or (tag[i].toInt() xor expected[i].toInt())
        return if (diff == 0) plain else null
    }

    private fun gcm(
        key: ByteArray,
        nonce: ByteArray,
        aad: ByteArray,
        input: ByteArray,
        encrypt: Boolean,
    ): Pair<ByteArray, ByteArray> {
        val h = aesEcb(key, ByteArray(16))
        val j0 = nonce + byteArrayOf(0, 0, 0, 1)
        // Counter blocks inc32(J0), inc32(J0)+1, … for the keystream.
        val blocks = (input.size + 15) / 16
        val counters = ByteArray(blocks * 16)
        val base = ((j0[12].toLong() and 0xff) shl 24) or ((j0[13].toLong() and 0xff) shl 16) or
            ((j0[14].toLong() and 0xff) shl 8) or (j0[15].toLong() and 0xff)
        for (b in 0 until blocks) {
            j0.copyInto(counters, b * 16, 0, 12)
            val c = (base + 1 + b) and 0xffffffffL
            counters[b * 16 + 12] = (c shr 24).toByte()
            counters[b * 16 + 13] = (c shr 16).toByte()
            counters[b * 16 + 14] = (c shr 8).toByte()
            counters[b * 16 + 15] = c.toByte()
        }
        val stream = if (blocks > 0) aesEcb(key, counters) else ByteArray(0)
        val output = ByteArray(input.size) { (input[it].toInt() xor stream[it].toInt()).toByte() }
        val cipherText = if (encrypt) output else input
        val s = ghash(h, aad, cipherText)
        val ek = aesEcb(key, j0)
        val tag = ByteArray(16) { (s[it].toInt() xor ek[it].toInt()).toByte() }
        return output to tag
    }

    private fun ghash(
        h: ByteArray,
        aad: ByteArray,
        cipher: ByteArray,
    ): ByteArray {
        val hHi = toLong(h, 0)
        val hLo = toLong(h, 8)
        var yHi = 0L
        var yLo = 0L
        fun absorb(data: ByteArray) {
            var off = 0
            while (off < data.size) {
                val block = ByteArray(16)
                data.copyInto(block, 0, off, minOf(off + 16, data.size))
                yHi = yHi xor toLong(block, 0)
                yLo = yLo xor toLong(block, 8)
                val (a, b) = mul(yHi, yLo, hHi, hLo)
                yHi = a
                yLo = b
                off += 16
            }
        }
        absorb(aad)
        absorb(cipher)
        yHi = yHi xor (aad.size.toLong() * 8)
        yLo = yLo xor (cipher.size.toLong() * 8)
        val (a, b) = mul(yHi, yLo, hHi, hLo)
        return fromLong(a) + fromLong(b)
    }

    /** Multiplication in GF(2^128) with GCM's bit order (SP 800-38D, algorithm 1). */
    private fun mul(
        xHi: Long,
        xLo: Long,
        yHi: Long,
        yLo: Long,
    ): Pair<Long, Long> {
        var zHi = 0L
        var zLo = 0L
        var vHi = yHi
        var vLo = yLo
        for (i in 0 until 128) {
            val bit = if (i < 64) (xHi ushr (63 - i)) and 1L else (xLo ushr (127 - i)) and 1L
            if (bit == 1L) {
                zHi = zHi xor vHi
                zLo = zLo xor vLo
            }
            val lsb = vLo and 1L
            vLo = (vLo ushr 1) or (vHi shl 63)
            vHi = vHi ushr 1
            if (lsb == 1L) vHi = vHi xor (0xE1L shl 56)
        }
        return zHi to zLo
    }

    private fun toLong(
        b: ByteArray,
        off: Int,
    ): Long {
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (b[off + i].toLong() and 0xff)
        return v
    }

    private fun fromLong(v: Long): ByteArray = ByteArray(8) { (v ushr (56 - 8 * it)).toByte() }

    private fun aesEcb(
        key: ByteArray,
        data: ByteArray,
    ): ByteArray {
        val out = ByteArray(data.size)
        memScoped {
            val moved = alloc<size_tVar>()
            val status =
                key.usePinned { k ->
                    data.usePinned { d ->
                        out.usePinned { o ->
                            CCCrypt(
                                kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode,
                                k.addressOf(0), key.size.toULong(), null,
                                d.addressOf(0), data.size.toULong(),
                                o.addressOf(0), out.size.toULong(), moved.ptr,
                            )
                        }
                    }
                }
            check(status == kCCSuccess) { "AES failed: $status" }
            check(moved.value.toInt() == data.size)
        }
        return out
    }

    private fun randomBytes(n: Int): ByteArray {
        val out = ByteArray(n)
        out.usePinned { SecRandomCopyBytes(kSecRandomDefault, n.toULong(), it.addressOf(0)) }
        return out
    }
}
