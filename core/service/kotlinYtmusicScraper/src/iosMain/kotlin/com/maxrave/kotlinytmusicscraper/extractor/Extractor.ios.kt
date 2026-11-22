package com.maxrave.kotlinytmusicscraper.extractor

import com.maxrave.kotlinytmusicscraper.models.SongItem
import kotlinx.cinterop.readValue
import platform.AVFoundation.addMutableTrackWithMediaType
import platform.AVFoundation.preferredTransform
import platform.AVFoundation.tracksWithMediaType
import com.maxrave.kotlinytmusicscraper.models.response.DownloadProgress

actual class Extractor {
    actual fun init() {
    }

    actual fun logIn(cookie: String?) {}

    actual fun newPipePlayer(videoId: String): List<Pair<Int, String>> = emptyList()

    actual fun liveHlsUrl(videoId: String): String? = null

    /**
     * Music video download on iOS: AVFoundation muxes the H.264 video (.mp4) and the AAC audio
     * (saved under the ".webm" name the shared code uses, so it is renamed to .m4a first, since
     * AVFoundation picks the parser by extension) into one MP4 without re-encoding.
     */
    @OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
    actual fun mergeAudioVideoDownload(filePath: String): DownloadProgress {
        val fm = platform.Foundation.NSFileManager.defaultManager
        val videoPath = "$filePath.mp4"
        val audioPath = "$filePath.m4a"
        val outPath = "$filePath-SimpMusic.mp4"
        // The .m4a stays: it is the offline audio, played whenever video mode is off.
        fun cleanup() {
            listOf(videoPath, "$filePath.webm", "$filePath.jpg").forEach { fm.removeItemAtPath(it, null) }
        }
        fm.removeItemAtPath(audioPath, null)
        fm.removeItemAtPath(outPath, null)
        if (!fm.moveItemAtPath("$filePath.webm", audioPath, null)) {
            cleanup()
            return DownloadProgress.failed("Audio file missing")
        }
        val video = platform.AVFoundation.AVURLAsset(uRL = platform.Foundation.NSURL.fileURLWithPath(videoPath), options = null)
        val audio = platform.AVFoundation.AVURLAsset(uRL = platform.Foundation.NSURL.fileURLWithPath(audioPath), options = null)
        val vTrack = video.tracksWithMediaType(platform.AVFoundation.AVMediaTypeVideo).firstOrNull() as? platform.AVFoundation.AVAssetTrack
        val aTrack = audio.tracksWithMediaType(platform.AVFoundation.AVMediaTypeAudio).firstOrNull() as? platform.AVFoundation.AVAssetTrack
        if (vTrack == null || aTrack == null) {
            cleanup()
            return DownloadProgress.failed("Unsupported video or audio format")
        }
        val composition = platform.AVFoundation.AVMutableComposition()
        val range = platform.CoreMedia.CMTimeRangeMake(platform.CoreMedia.kCMTimeZero.readValue(), video.duration)
        val cv = composition.addMutableTrackWithMediaType(platform.AVFoundation.AVMediaTypeVideo, platform.CoreMedia.kCMPersistentTrackID_Invalid)
        val ca = composition.addMutableTrackWithMediaType(platform.AVFoundation.AVMediaTypeAudio, platform.CoreMedia.kCMPersistentTrackID_Invalid)
        val ok =
            cv?.insertTimeRange(range, vTrack, platform.CoreMedia.kCMTimeZero.readValue(), null) == true &&
                ca?.insertTimeRange(range, aTrack, platform.CoreMedia.kCMTimeZero.readValue(), null) == true
        if (!ok) {
            cleanup()
            return DownloadProgress.failed("Could not combine audio and video")
        }
        cv?.setPreferredTransform(vTrack.preferredTransform)
        val export =
            platform.AVFoundation.AVAssetExportSession(asset = composition, presetName = platform.AVFoundation.AVAssetExportPresetPassthrough)
        export.outputURL = platform.Foundation.NSURL.fileURLWithPath(outPath)
        export.outputFileType = platform.AVFoundation.AVFileTypeMPEG4
        val done = platform.darwin.dispatch_semaphore_create(0)
        export.exportAsynchronouslyWithCompletionHandler { platform.darwin.dispatch_semaphore_signal(done) }
        platform.darwin.dispatch_semaphore_wait(done, platform.darwin.DISPATCH_TIME_FOREVER)
        val success = export.status == platform.AVFoundation.AVAssetExportSessionStatusCompleted
        cleanup()
        return if (success) DownloadProgress.VIDEO_DONE else DownloadProgress.failed(export.error?.localizedDescription ?: "Export failed")
    }

    actual fun saveAudioWithThumbnail(
        filePath: String,
        track: SongItem,
    ): DownloadProgress = DownloadProgress.failed("Not supported on iOS")
}