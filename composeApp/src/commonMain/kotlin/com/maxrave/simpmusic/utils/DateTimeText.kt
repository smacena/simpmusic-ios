package com.maxrave.simpmusic.utils

import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.format
import kotlinx.datetime.format.char
import kotlinx.datetime.toLocalDateTime
import kotlin.time.Instant

private val isoSecondsFormat =
    LocalDateTime.Format {
        year()
        char('-')
        monthNumber()
        char('-')
        day()
        char(' ')
        hour()
        char(':')
        minute()
        char(':')
        second()
    }

/**
 * `yyyy-MM-dd HH:mm:ss` in the device's time zone — what the Settings screen printed with
 * java.time's DateTimeFormatter, which shared code cannot use on iOS.
 */
fun formatEpochMillisLocal(epochMillis: Long): String =
    Instant
        .fromEpochMilliseconds(epochMillis)
        .toLocalDateTime(TimeZone.currentSystemDefault())
        .format(isoSecondsFormat)
