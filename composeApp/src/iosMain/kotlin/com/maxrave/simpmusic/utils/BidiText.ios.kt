package com.maxrave.simpmusic.utils

// No java.text.Bidi on iOS. These follow the same rule the Unicode bidi algorithm uses for the
// base direction (P2/P3: the first strong character decides), which is all the lyrics need.

private fun Char.isStrongRtl(): Boolean {
    val c = code
    return c in 0x0590..0x08FF || // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic Ext
        c in 0xFB1D..0xFDFF || // Hebrew + Arabic presentation forms A
        c in 0xFE70..0xFEFF // Arabic presentation forms B
}

private fun Char.isStrongLtr(): Boolean = isLetter() && !isStrongRtl()

actual fun bidiBaseIsLeftToRight(
    text: String,
    defaultLeftToRight: Boolean,
): Boolean {
    for (c in text) {
        if (c.isStrongRtl()) return false
        if (c.isStrongLtr()) return true
    }
    return defaultLeftToRight
}

actual fun bidiIsLeftToRight(
    text: String,
    defaultLeftToRight: Boolean,
): Boolean = text.none { it.isStrongRtl() } && (defaultLeftToRight || text.any { it.isStrongLtr() })
