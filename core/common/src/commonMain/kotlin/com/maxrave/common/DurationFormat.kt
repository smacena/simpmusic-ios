package com.maxrave.common

/**
 * `mm:ss` with both fields zero-padded, as `"%02d:%02d".format(s / 60, s % 60)` printed it.
 * `String.format` exists only on the JVM, so shared code goes through this instead.
 */
fun formatMinutesSeconds(totalSeconds: Int): String {
    val minutes = (totalSeconds / 60).toString().padStart(2, '0')
    val seconds = (totalSeconds % 60).toString().padStart(2, '0')
    return "$minutes:$seconds"
}

/** `value` with exactly [decimals] digits after a dot, like `"%.1f".format(value)` in English. */
fun formatDecimal(
    value: Double,
    decimals: Int,
): String {
    if (value.isNaN() || value.isInfinite()) return value.toString()
    var factor = 1L
    repeat(decimals) { factor *= 10 }
    val scaled = kotlin.math.round(kotlin.math.abs(value) * factor).toLong()
    val sign = if (value < 0 && scaled != 0L) "-" else ""
    if (decimals == 0) return "$sign$scaled"
    val whole = scaled / factor
    val fraction = (scaled % factor).toString().padStart(decimals, '0')
    return "$sign$whole.$fraction"
}

/** `value` with a comma between each group of three digits, like `"%,d".format(value)` in English. */
fun formatGrouped(value: Long): String {
    val digits = kotlin.math.abs(value).toString()
    val grouped = digits.reversed().chunked(3).joinToString(",").reversed()
    return if (value < 0) "-$grouped" else grouped
}
