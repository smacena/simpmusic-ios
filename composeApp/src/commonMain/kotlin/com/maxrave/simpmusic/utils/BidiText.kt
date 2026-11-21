package com.maxrave.simpmusic.utils

/** Whether the paragraph's base direction is left-to-right ([java.text.Bidi.baseIsLeftToRight]). */
expect fun bidiBaseIsLeftToRight(
    text: String,
    defaultLeftToRight: Boolean = true,
): Boolean

/** Whether the whole text runs left-to-right ([java.text.Bidi.isLeftToRight]). */
expect fun bidiIsLeftToRight(
    text: String,
    defaultLeftToRight: Boolean = true,
): Boolean
