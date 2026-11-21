package com.maxrave.simpmusic.utils

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.UByteVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import platform.zlib.Z_FINISH
import platform.zlib.Z_OK
import platform.zlib.Z_STREAM_END
import platform.zlib.crc32
import platform.zlib.inflate
import platform.zlib.inflateEnd
import platform.zlib.inflateInit2
import platform.zlib.z_stream

// The backup file is a ZIP holding the settings file and the database. Android and Desktop write
// and read it with java.util.zip, which iOS does not have; this is just enough ZIP to stay
// compatible with both: entries are written STORED (no compression) and read either STORED or
// DEFLATED (what java.util.zip writes), with inflate from the system zlib.

@OptIn(ExperimentalForeignApi::class)
private fun ByteArray.crc32(): Long {
    if (isEmpty()) return 0
    return usePinned { crc32(0u, it.addressOf(0).reinterpret(), size.convert()).toLong() and 0xFFFFFFFFL }
}

private class ZipBuilder {
    private val out = ArrayList<Byte>()

    fun u16(v: Int) {
        out.add((v and 0xFF).toByte())
        out.add(((v shr 8) and 0xFF).toByte())
    }

    fun u32(v: Long) {
        for (i in 0 until 4) out.add(((v shr (8 * i)) and 0xFF).toByte())
    }

    fun bytes(b: ByteArray) {
        b.forEach { out.add(it) }
    }

    val size get() = out.size

    fun toByteArray() = out.toByteArray()
}

/** A STORED (uncompressed) ZIP of [entries], readable by java.util.zip.ZipInputStream. */
fun zipStored(entries: List<Pair<String, ByteArray>>): ByteArray {
    val zip = ZipBuilder()
    val central = ZipBuilder()
    entries.forEach { (name, data) ->
        val nameBytes = name.encodeToByteArray()
        val crc = data.crc32()
        val offset = zip.size.toLong()
        zip.u32(0x04034b50)
        zip.u16(20) // version needed
        zip.u16(0x0800) // UTF-8 names
        zip.u16(0) // STORED
        zip.u16(0)
        zip.u16(0x21) // time / date: 1980-01-01
        zip.u32(crc)
        zip.u32(data.size.toLong())
        zip.u32(data.size.toLong())
        zip.u16(nameBytes.size)
        zip.u16(0)
        zip.bytes(nameBytes)
        zip.bytes(data)

        central.u32(0x02014b50)
        central.u16(20)
        central.u16(20)
        central.u16(0x0800)
        central.u16(0)
        central.u16(0)
        central.u16(0x21)
        central.u32(crc)
        central.u32(data.size.toLong())
        central.u32(data.size.toLong())
        central.u16(nameBytes.size)
        central.u16(0)
        central.u16(0)
        central.u16(0)
        central.u16(0)
        central.u32(0)
        central.u32(offset)
        central.bytes(nameBytes)
    }
    val centralOffset = zip.size.toLong()
    val centralBytes = central.toByteArray()
    zip.bytes(centralBytes)
    zip.u32(0x06054b50)
    zip.u16(0)
    zip.u16(0)
    zip.u16(entries.size)
    zip.u16(entries.size)
    zip.u32(centralBytes.size.toLong())
    zip.u32(centralOffset)
    zip.u16(0)
    return zip.toByteArray()
}

private fun ByteArray.u16(at: Int) = (this[at].toInt() and 0xFF) or ((this[at + 1].toInt() and 0xFF) shl 8)

private fun ByteArray.u32(at: Int): Long = (u16(at).toLong()) or (u16(at + 2).toLong() shl 16)

/** Every entry of a ZIP, by name. Reads the central directory, so data-descriptor entries work. */
fun unzip(zip: ByteArray): Map<String, ByteArray> {
    var eocd = -1
    for (i in zip.size - 22 downTo maxOf(0, zip.size - 22 - 65535)) {
        if (zip.u32(i) == 0x06054b50L) {
            eocd = i
            break
        }
    }
    require(eocd >= 0) { "Not a ZIP file" }
    val count = zip.u16(eocd + 10)
    var p = zip.u32(eocd + 16).toInt()
    val result = LinkedHashMap<String, ByteArray>()
    repeat(count) {
        require(zip.u32(p) == 0x02014b50L) { "Corrupt ZIP central directory" }
        val method = zip.u16(p + 10)
        val compressedSize = zip.u32(p + 20).toInt()
        val size = zip.u32(p + 24).toInt()
        val nameLength = zip.u16(p + 28)
        val extraLength = zip.u16(p + 30)
        val commentLength = zip.u16(p + 32)
        val localOffset = zip.u32(p + 42).toInt()
        val name = zip.decodeToString(p + 46, p + 46 + nameLength)
        val dataStart = localOffset + 30 + zip.u16(localOffset + 26) + zip.u16(localOffset + 28)
        val raw = zip.copyOfRange(dataStart, dataStart + compressedSize)
        result[name] =
            when (method) {
                0 -> raw
                8 -> inflateRaw(raw, size)
                else -> error("Unsupported ZIP method $method for $name")
            }
        p += 46 + nameLength + extraLength + commentLength
    }
    return result
}

@OptIn(ExperimentalForeignApi::class)
private fun inflateRaw(
    input: ByteArray,
    size: Int,
): ByteArray {
    val output = ByteArray(maxOf(size, 1))
    memScoped {
        val stream = alloc<z_stream>()
        // -15: raw deflate, no zlib header — what ZIP stores.
        check(inflateInit2(stream.ptr, -15) == Z_OK) { "inflateInit2 failed" }
        try {
            input.usePinned { inPin ->
                output.usePinned { outPin ->
                    stream.next_in = if (input.isEmpty()) null else inPin.addressOf(0).reinterpret<UByteVar>()
                    stream.avail_in = input.size.convert()
                    stream.next_out = outPin.addressOf(0).reinterpret<UByteVar>()
                    stream.avail_out = output.size.convert()
                    val status = inflate(stream.ptr, Z_FINISH)
                    check(status == Z_STREAM_END || (status == Z_OK && size == 0)) { "inflate failed ($status)" }
                }
            }
        } finally {
            inflateEnd(stream.ptr)
        }
    }
    return output.copyOf(size)
}
