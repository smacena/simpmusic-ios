package com.maxrave.kotlinytmusicscraper.cipher

import com.maxrave.kotlinytmusicscraper.Ytmusic
import com.maxrave.kotlinytmusicscraper.models.YouTubeClient
import com.maxrave.kotlinytmusicscraper.models.response.PlayerResponse
import com.maxrave.ktorext.getEngine
import com.maxrave.logger.Logger
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.http.HttpHeaders
import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.parseQueryString
import kotlinx.coroutines.CoroutineDispatcher

/**
 * True where PipePipe is unavailable (iOS). There the stream URLs come from
 * [LocalStreamDecipher] instead; Android and Desktop keep their PipePipe path untouched.
 */
expect val localStreamDecipherEnabled: Boolean

/** A thread with a very large native stack for QuickJS — see [QuickJsEngine] and FaradayJsDecoder. */
expect fun createJsCipherDispatcher(): CoroutineDispatcher

/**
 * Turns a player response into playable `itag → url` pairs without PipePipe: asks YouTube for the
 * streams with the signature timestamp of the player it is currently serving, then solves each
 * format's `s` (signature) and `n` (throttling) challenges with [FaradayCipherEngine], on-device.
 *
 * Clients are tried in order until one returns usable formats. The signature/`n` solving stays
 * for clients that need it, even though the current default (VISIONOS) needs neither.
 */
internal class LocalStreamDecipher(
    private val ytMusic: Ytmusic,
    private val clients: List<YouTubeClient> = DEFAULT_CLIENTS,
    /** Fetches a fresh visitor id (YouTube.visitorData()). */
    private val fetchVisitorData: suspend () -> String? = { null },
) {
    private val engine by lazy {
        FaradayCipherEngine(
            HttpClient(getEngine()),
            createJsCipherDispatcher(),
            InnerTubeLogger { event ->
                val message = event.message + event.details.entries.joinToString(prefix = " [", postfix = "]") { "${it.key}=${it.value}" }
                when (event.level) {
                    InnerTubeLogLevel.DEBUG -> Logger.d(TAG, message)
                    InnerTubeLogLevel.INFO -> Logger.i(TAG, message)
                    InnerTubeLogLevel.WARN -> Logger.w(TAG, message)
                    InnerTubeLogLevel.ERROR -> Logger.e(TAG, message)
                }
            },
        )
    }


    private class Candidate(
        val itag: Int,
        val baseUrl: String,
        val signature: String?,
        val signatureParam: String,
    )

    suspend fun streams(videoId: String): List<Pair<Int, String>> {
        // Signed out, the app only has the visitor id it saved earlier — none on a fresh install —
        // and without one YouTube answers these clients with LOGIN_REQUIRED ("confirm you're not
        // a bot"). Fetch one once; it is kept on the shared client like any other visitor id.
        if (ytMusic.visitorData.isNullOrEmpty()) {
            runCatching { fetchVisitorData() }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { ytMusic.visitorData = it }
        }
        val info = engine.playerInfo()
        if (info == null) Logger.w(TAG, "$videoId: no player info, trying clients that need no cipher")
        for (client in clients) {
            val result =
                runCatching { streamsFrom(client, videoId, info) }
                    .onFailure { Logger.w(TAG, "$videoId: ${client.clientName} failed: ${it::class.simpleName}") }
                    .getOrNull()
                    .orEmpty()
            if (result.isNotEmpty()) {
                Logger.i(TAG, "$videoId: ${result.size} streams from ${client.clientName}")
                return result
            }
        }
        return emptyList()
    }

    private suspend fun streamsFrom(
        client: YouTubeClient,
        videoId: String,
        info: FaradayCipherEngine.PlayerInfo?,
    ): List<Pair<Int, String>> {
        val response =
            ytMusic
                .player(client, videoId, playlistId = null, cpn = null, signatureTimestamp = info?.signatureTimestamp)
                .body<PlayerResponse>()
        if (response.playabilityStatus.status != "OK") {
            Logger.w(TAG, "$videoId: ${client.clientName} says ${response.playabilityStatus.status}")
            return emptyList()
        }
        val formats = response.streamingData?.formats.orEmpty() + response.streamingData?.adaptiveFormats.orEmpty()
        val candidates =
            formats.mapNotNull { format ->
                val url = format.url
                val cipher = format.signatureCipher
                when {
                    !url.isNullOrEmpty() -> Candidate(format.itag, url, null, "sig")
                    !cipher.isNullOrEmpty() -> {
                        val params = parseQueryString(cipher)
                        val base = params["url"] ?: return@mapNotNull null
                        Candidate(format.itag, base, params["s"], params["sp"] ?: "signature")
                    }
                    else -> null
                }
            }
        if (candidates.isEmpty()) return emptyList()

        val signatures = candidates.mapNotNull { it.signature }
        val nParameters = candidates.mapNotNull { Url(it.baseUrl).parameters["n"] }
        val needsSolver = signatures.isNotEmpty() || nParameters.isNotEmpty()
        if (needsSolver && info == null) return emptyList()
        val solved =
            if (needsSolver) engine.decode(info!!.playerId, signatures, nParameters) else FaradayCipherEngine.DecodeResult(emptyMap(), emptyMap())
        Logger.i(
            TAG,
            "$videoId: ${client.clientName} sig ${solved.signatures.size}/${signatures.distinct().size}, " +
                "n ${solved.nParameters.size}/${nParameters.distinct().size}",
        )

        return candidates.mapNotNull { candidate ->
            val builder = URLBuilder(candidate.baseUrl)
            candidate.signature?.let { s ->
                val decoded = solved.signatures[s] ?: return@mapNotNull null
                builder.parameters[candidate.signatureParam] = decoded
            }
            builder.parameters["n"]?.let { n ->
                // An unsolved n still plays, only throttled; keep the stream rather than drop it.
                solved.nParameters[n]?.let { builder.parameters["n"] = it }
            }
            candidate.itag to builder.buildString()
        }
    }

    private val probeClient by lazy { HttpClient(getEngine()) }

    /**
     * Whether the CDN serves [url]. The shared check (`Ytmusic.is403Url`) sends a HEAD through the
     * InnerTube client, with its music.youtube.com headers and cookies — googlevideo answers 403
     * to that for these web-client URLs even when they play fine, so this asks for two bytes
     * with a plain GET instead, the way a player actually opens the stream.
     */
    suspend fun isPlayable(url: String): Boolean =
        runCatching {
            probeClient.get(url) { header(HttpHeaders.Range, "bytes=0-1") }.status.value in 200..299
        }.getOrDefault(false)

    /** Drop the cached player table after the CDN rejected a URL deciphered here. */
    suspend fun invalidate() = engine.invalidate()

    companion object {
        private const val TAG = "LocalStreamDecipher"

        /**
         * VISIONOS alone, measured against live responses on 2026-11-21: its URLs play whole in
         * AVPlayer. WEB_REMIX deciphers fine but googlevideo stops serving it after ~1 MB without a
         * PO token; ANDROID_VR URLs are refused outright; TVHTML5 answers LOGIN_REQUIRED.
         */
        val DEFAULT_CLIENTS = listOf(YouTubeClient.VISIONOS)
    }
}

/**
 * True on iOS: AVPlayer cannot decode Opus, so downloads take the AAC stream and keep it as
 * `.m4a` instead of the Opus `.webm` (and skip the FFmpeg-based tagging Android and Desktop do).
 */
expect val downloadsAsAac: Boolean
