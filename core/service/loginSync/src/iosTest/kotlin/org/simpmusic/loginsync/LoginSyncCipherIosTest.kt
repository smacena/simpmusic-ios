package org.simpmusic.loginsync

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertNull

/** The iOS AES-GCM against NIST's GCM test case 16 (AES-256, 96-bit IV, with AAD). */
class LoginSyncCipherIosTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private val key = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
    private val plain = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
    private val aad = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
    private val iv = hex("cafebabefacedbaddecaf888")
    private val cipher = hex("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662")
    private val tag = hex("76fc6ece0f4e1768cddf8853bb2d551b")

    @Test
    fun opensNistVector() {
        assertContentEquals(plain, LoginSyncCipher.open(key, aad, iv + cipher + tag))
    }

    @Test
    fun rejectsTamperedTag() {
        val bad = tag.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertNull(LoginSyncCipher.open(key, aad, iv + cipher + bad))
    }

    @Test
    fun roundTripsAndBindsAad() {
        val k = LoginSyncCipher.newKey()
        val msg = ByteArray(70_001) { (it * 31).toByte() }
        val sealed = LoginSyncCipher.seal(k, "a".encodeToByteArray(), msg)
        assertContentEquals(msg, LoginSyncCipher.open(k, "a".encodeToByteArray(), sealed))
        assertNull(LoginSyncCipher.open(k, "b".encodeToByteArray(), sealed))
    }
}
