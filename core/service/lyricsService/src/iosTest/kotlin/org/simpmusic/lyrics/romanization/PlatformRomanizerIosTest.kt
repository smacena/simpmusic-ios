package org.simpmusic.lyrics.romanization

import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class PlatformRomanizerIosTest {
    @Test
    fun japaneseKanjiAndKanaBecomeRomaji() {
        val out = assertNotNull(PlatformRomanizer.japanese("東京に行きます"))
        println("JA: $out")
        assertTrue(out.all { it.code < 0x3000 }, "still has CJK characters: $out")
        assertTrue(out.lowercase().contains("ky"), out)
    }

    @Test
    fun chineseBecomesPinyinWithTones() {
        val out = assertNotNull(PlatformRomanizer.chinese("你好世界"))
        println("ZH: $out")
        assertTrue(out.contains("nǐ") && out.contains("hǎo"), out)
    }
}
