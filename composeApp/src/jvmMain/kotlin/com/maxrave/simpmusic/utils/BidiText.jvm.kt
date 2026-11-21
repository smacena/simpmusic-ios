package com.maxrave.simpmusic.utils

import java.text.Bidi

private fun bidiOf(
    text: String,
    defaultLeftToRight: Boolean,
) = Bidi(text, if (defaultLeftToRight) Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT else Bidi.DIRECTION_DEFAULT_RIGHT_TO_LEFT)

actual fun bidiBaseIsLeftToRight(
    text: String,
    defaultLeftToRight: Boolean,
): Boolean = bidiOf(text, defaultLeftToRight).baseIsLeftToRight()

actual fun bidiIsLeftToRight(
    text: String,
    defaultLeftToRight: Boolean,
): Boolean = bidiOf(text, defaultLeftToRight).isLeftToRight
