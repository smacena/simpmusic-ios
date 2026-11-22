@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package org.simpmusic.loginsync

import com.maxrave.logger.Logger
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.cio.CIO
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.contentLength
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.pointed
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.toKString
import kotlinx.cinterop.value
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.CPointerVar
import platform.UIKit.UIDevice
import platform.posix.AF_INET
import platform.posix.IFF_LOOPBACK
import platform.posix.IFF_UP
import platform.posix.sockaddr_in
import platform.darwin.freeifaddrs
import platform.darwin.getifaddrs
import platform.darwin.ifaddrs

/*
 * iOS's end when the iPhone RECEIVES sign-ins (from the Android app): the same one-shot server as
 * Desktop's, on Ktor's CIO engine for Kotlin/Native. Only the device name and the address scan differ.
 */

private const val TAG = "LoginSyncServer"

/**
 * The Desktop's end of the transport: a one-shot Ktor server (CIO engine) between start() and stop().
 *
 * Handlers are suspend functions, so [Handler.onPayload] is a plain call and no server thread is ever
 * blocked. The JDK HttpServer this replaced ran handlers ON its dispatcher thread and joined that
 * thread in stop() — stopping from the UI thread during a payload froze the app.
 */
class LoginSyncServer(
    private val handler: Handler,
) {
    interface Handler {
        /** A phone holding this session's key said hello. */
        fun onHello()

        /** The phone backed out before sending. */
        fun onCancel()

        /** The phone's payload; the return value is sealed back as the reply. Throwing rejects it. */
        suspend fun onPayload(payload: ByteArray): ByteArray

        /** The reply to a payload has been sent: the session is spent. */
        fun onDelivered()

        /** A payload could not be taken; [reason] is shown to the user. */
        fun onRejected(reason: String)
    }

    /** What the QR needs besides an address. */
    class Session internal constructor(
        val port: Int,
        private val key: ByteArray,
    ) {
        fun invite(host: String) = LoginSyncInvite(listOf(host), port, key)
    }

    private var server: EmbeddedServer<*, *>? = null
    private var key = ByteArray(0)

    @kotlin.concurrent.Volatile
    private var delivered = false

    private val device by lazy { localDeviceName() }

    /** Opens a fresh session — new key, new port — replacing any previous one. */
    suspend fun start(): Session {
        stop()
        key = LoginSyncCipher.newKey()
        delivered = false
        val http =
            embeddedServer(CIO, port = 0, host = "0.0.0.0") {
                routing {
                    post(LoginSyncWire.path(LoginSyncWire.HELLO)) { handle(call, LoginSyncWire.HELLO) }
                    post(LoginSyncWire.path(LoginSyncWire.PAYLOAD)) { handle(call, LoginSyncWire.PAYLOAD) }
                    post(LoginSyncWire.path(LoginSyncWire.CANCEL)) { handle(call, LoginSyncWire.CANCEL) }
                }
            }
        http.startSuspend(wait = false)
        server = http
        // Port 0 asks the OS for a free one; this is the only way to learn which.
        return Session(http.engine.resolvedConnectors().first().port, key)
    }

    /** NonCancellable: a caller being cancelled must not leave the port open. */
    suspend fun stop() {
        val http = server ?: return
        server = null
        withContext(NonCancellable + Dispatchers.Default) { http.stopSuspend(gracePeriodMillis = 0, timeoutMillis = 500) }
    }

    private suspend fun handle(
        call: ApplicationCall,
        kind: String,
    ) {
        // A spent session answers nothing: its key has done its one job.
        if (delivered) return call.respond(HttpStatusCode.Gone)
        if ((call.request.contentLength() ?: 0) > LoginSyncWire.MAX_BODY_BYTES) {
            return reject(call, kind, HttpStatusCode.PayloadTooLarge, "the sign-ins were larger than ${LoginSyncWire.MAX_BODY_BYTES / 1024 / 1024} MB")
        }
        try {
            val plain =
                LoginSyncCipher.open(key, LoginSyncWire.aad(kind, reply = false), call.receive<ByteArray>())
                    ?: return reject(call, kind, HttpStatusCode.Forbidden, "the phone used a different code")
            val reply =
                when (kind) {
                    LoginSyncWire.HELLO -> {
                        handler.onHello()
                        LoginSyncWire.json.encodeToString(DeviceName.serializer(), withContext(Dispatchers.Default) { device }).encodeToByteArray()
                    }

                    LoginSyncWire.PAYLOAD -> {
                        handler.onPayload(plain)
                    }

                    else -> {
                        handler.onCancel()
                        "{}".encodeToByteArray()
                    }
                }
            call.respondBytes(LoginSyncCipher.seal(key, LoginSyncWire.aad(kind, reply = true), reply), ContentType.Application.OctetStream)
            if (kind == LoginSyncWire.PAYLOAD) {
                // Only once the phone has its answer.
                delivered = true
                handler.onDelivered()
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Logger.e(TAG, "handle $kind", e)
            handler.onRejected(e.message ?: e.describe())
            call.respond(HttpStatusCode.InternalServerError)
        }
    }

    // A stray request without the key must not knock a waiting QR off the screen, so a rejected hello
    // is answered but not reported; a rejected payload is.
    private suspend fun reject(
        call: ApplicationCall,
        kind: String,
        status: HttpStatusCode,
        reason: String,
    ) {
        Logger.e(TAG, "reject $kind ${status.value}: $reason")
        if (kind == LoginSyncWire.PAYLOAD) handler.onRejected(reason)
        call.respond(status)
    }
}

/** One address this iPhone can be reached on, labelled by its interface (en0 = Wi-Fi). */
data class LocalAddress(
    val interfaceName: String,
    val ip: String,
)

/** Every IPv4 address an Android phone on the same network (or a tailnet) could reach. */
fun reachableAddresses(): List<LocalAddress> {
    val found = mutableListOf<LocalAddress>()
    memScoped {
        val list = alloc<CPointerVar<ifaddrs>>()
        if (getifaddrs(list.ptr) != 0) return emptyList()
        var cursor = list.value
        while (cursor != null) {
            val entry = cursor.pointed
            val addr = entry.ifa_addr
            val flags = entry.ifa_flags.toInt()
            val name = entry.ifa_name?.toKString().orEmpty()
            if (addr != null && addr.pointed.sa_family.toInt() == AF_INET && (flags and IFF_UP) != 0 && (flags and IFF_LOOPBACK) == 0 &&
                !name.startsWith("pdp_ip") // cellular: unreachable from the LAN
            ) {
                val sin = addr.reinterpret<sockaddr_in>().pointed
                // s_addr is in network byte order: its first byte in memory is the first octet.
                val raw = sin.sin_addr.s_addr
                val ip = listOf(raw and 0xffu, (raw shr 8) and 0xffu, (raw shr 16) and 0xffu, (raw shr 24) and 0xffu).joinToString(".")
                if (!ip.startsWith("169.254.")) found += LocalAddress(if (name == "en0") "Wi-Fi" else name, ip)
            }
            cursor = entry.ifa_next
        }
        freeifaddrs(list.value)
    }
    // Wi-Fi first: that is where the Android phone almost always is.
    return found.distinctBy { it.ip }.sortedBy { if (it.interfaceName == "Wi-Fi") 0 else 1 }
}

internal fun localDeviceName(): DeviceName = DeviceName(name = UIDevice.currentDevice.name, os = "iOS ${UIDevice.currentDevice.systemVersion}")
