package com.maxrave.simpmusic.utils

import kotlin.io.encoding.Base64
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class IosZipTest {
    @Test
    fun storedArchiveRoundTrips() {
        val db = ByteArray(100_000) { (it * 31).toByte() }
        val settings = "settings".encodeToByteArray()
        val back = unzip(zipStored(listOf("settings.preferences_pb" to settings, "music_database.db" to db)))
        assertContentEquals(settings, back["settings.preferences_pb"])
        assertContentEquals(db, back["music_database.db"])
    }

    /** A deflated archive, like the ones Android (java.util.zip) and Desktop write. */
    @Test
    fun readsDeflatedBackupsFromOtherPlatforms() {
        val zip = Base64.decode("UEsDBBQAAAAIAKGcdV222spiGAAAAO4CAAAXAAAAc2V0dGluZ3MucHJlZmVyZW5jZXNfcGIrTi0pycxLL9ZNqixJLVYoHuWOcocvFwBQSwMEFAAAAAgAoZx1XZ07zrtuAQAAACgAABEAAABtdXNpY19kYXRhYmFzZS5kYmNgZGJmYWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTV1BUUlZRVVPX0NTS1tHV0zcwNDI2MTUzt7C0sraxtbN3cHRydnF1c/fw9PL28fXzDwgMCg4JDQuPiIyKjomNi09ITEpOSU1Lz8jMys7JzcsvKCwqLiktK6+orKquqa2rb2hsam5pbWvv6Ozq7unt658wcdLkKVOnTZ8xc9bsOXPnzV+wcNHiJUuXLV+xctXqNWvXrd+wcdPmLVu3bd+xc9fuPXv37T9w8NDhI0ePHT9x8tTpM2fPnb9w8dLlK1evXb9x89btO3fv3X/w8NHjJ0+fPX/x8tXrN2/fvf/w8dPnL1+/ff/x89fvP3///WcY9f+o/0f9P+r/Uf+P+n/U/6P+H/X/qP9H/T/q/1H/j/p/1P+j/h/1/6j/R/0/6v9R/4/6f9T/o/4f9f+o/0f9P+r/Uf+P+n/U/6P+H/X/qP9H/T/q/1H/j/p/CPofAFBLAQIUAxQAAAAIAKGcdV222spiGAAAAO4CAAAXAAAAAAAAAAAAAACAAQAAAABzZXR0aW5ncy5wcmVmZXJlbmNlc19wYlBLAQIUAxQAAAAIAKGcdV2dO867bgEAAAAoAAARAAAAAAAAAAAAAACAAU0AAABtdXNpY19kYXRhYmFzZS5kYlBLBQYAAAAAAgACAIQAAADqAQAAAAA=")
        val back = unzip(zip)
        assertEquals(setOf("settings.preferences_pb", "music_database.db"), back.keys)
        assertContentEquals("settings-bytes ".repeat(50).encodeToByteArray(), back["settings.preferences_pb"])
        assertContentEquals(ByteArray(256 * 40) { (it % 256).toByte() }, back["music_database.db"])
    }
}
