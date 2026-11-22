package org.simpmusic.loginsync

import java.security.GeneralSecurityException
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-256-GCM over `nonce(12) || ciphertext || tag(16)`, with [LoginSyncWire.aad] as associated data.
 * javax.crypto is usable in commonMain because this module targets Android and JVM only.
 */
internal actual object LoginSyncCipher {
    private val random = SecureRandom()

    actual fun newKey(): ByteArray = ByteArray(LoginSyncWire.KEY_BYTES).also(random::nextBytes)

    actual fun seal(
        key: ByteArray,
        aad: ByteArray,
        plain: ByteArray,
    ): ByteArray {
        val nonce = ByteArray(LoginSyncWire.NONCE_BYTES).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(LoginSyncWire.TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return nonce + cipher.doFinal(plain)
    }

    /** Null when [sealed] was not sealed with [key] for this [aad]: forged, corrupted, or another kind. */
    actual fun open(
        key: ByteArray,
        aad: ByteArray,
        sealed: ByteArray,
    ): ByteArray? {
        if (sealed.size < LoginSyncWire.NONCE_BYTES + LoginSyncWire.TAG_BITS / 8) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val spec = GCMParameterSpec(LoginSyncWire.TAG_BITS, sealed, 0, LoginSyncWire.NONCE_BYTES)
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), spec)
            cipher.updateAAD(aad)
            cipher.doFinal(sealed, LoginSyncWire.NONCE_BYTES, sealed.size - LoginSyncWire.NONCE_BYTES)
        } catch (e: GeneralSecurityException) {
            null
        }
    }
}

