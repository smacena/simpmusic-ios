package org.simpmusic.lyrics.romanization

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString
import org.simpmusic.lyrics.native.simp_japanese_romaji
import platform.Foundation.NSString
import platform.Foundation.NSStringTransformMandarinToLatin
import platform.Foundation.stringByApplyingTransform
import platform.posix.free

/**
 * Japanese and Chinese romanization from the system itself, so iOS needs neither kuromoji's
 * 13 MB dictionary nor pinyin4j:
 *
 * - Japanese: the system word tokenizer with the "ja" locale knows each word's reading, kanji
 *   included (C helper in jaromaji.def).
 * - Chinese: the Mandarin→Latin transform yields pinyin with tone marks.
 *
 * Null still means "not available" ([LyricsRomanizer] then shows nothing extra).
 */
@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal actual object PlatformRomanizer {
    actual fun japanese(line: String): String? {
        val raw = simp_japanese_romaji(line) ?: return null
        return try {
            raw.toKString().takeIf { it.isNotBlank() }
        } finally {
            free(raw)
        }
    }

    actual fun chinese(line: String): String? =
        runCatching {
            (line as NSString).stringByApplyingTransform(NSStringTransformMandarinToLatin, reverse = false)
        }.getOrNull()
}
