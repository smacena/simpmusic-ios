import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// The music player: queue, AVPlayer, the C audio chain, the lock screen / Dynamic Island, and
/// the everyday situations a phone throws at a music app (calls, headphones, network, a link that
/// expired while paused). Everything runs on the main actor; only the C tap runs on the audio thread.
@MainActor
final class PlayerEngine: ObservableObject {
    static let shared = PlayerEngine()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var position: Double = 0 // seconds
    @Published private(set) var duration: Double = 0 // seconds
    @Published var errorMessage: String?
    /// Where the queue came from, shown as "TOCANDO AGORA / <title>" in the player.
    @Published private(set) var queueTitle: String = "Fila"
    @Published private(set) var rate: Float = 1
    @Published private(set) var sleepDeadline: Date?
    @Published private(set) var sleepAtEndOfTrack = false
    private var sleepTask: Task<Void, Never>?
    @Published var shuffleOn = false
    @Published var repeatMode = 0 // 0 off, 1 all, 2 one

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private var player = AVPlayer()
    /// The outgoing track's player while a crossfade runs.
    private var fadingOut: AVPlayer?
    private var crossfadeTask: Task<Void, Never>?
    /// Which C tap slot the current item uses; a crossfade alternates it.
    private var currentSlot: Int32 = 0

    var crossfadeEnabled: Bool = UserDefaults.standard.bool(forKey: "crossfade.enabled") {
        didSet { UserDefaults.standard.set(crossfadeEnabled, forKey: "crossfade.enabled") }
    }
    var crossfadeSeconds: Double = UserDefaults.standard.object(forKey: "crossfade.seconds") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(crossfadeSeconds, forKey: "crossfade.seconds") }
    }
    private var stream: AudioStream?
    private var prefetched: [String: AudioStream] = [:]
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var wantsToPlay = false
    private var playingBeforeInterruption = false
    private var stalledSince: Date?
    private var lastStallReload: Date?
    private var artworkTask: Task<Void, Never>?
    private var nowPlaying: [String: Any] = [:]

    var normalizeVolume: Bool = UserDefaults.standard.bool(forKey: "normalizeVolume") {
        didSet {
            UserDefaults.standard.set(normalizeVolume, forKey: "normalizeVolume")
            applyNormalization()
        }
    }

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        setUpAudioSession()
        observeSession()
        setUpRemoteCommands()
        attachClock()
        AudioEffects.shared.applyStored()
        restoreQueue()
        sessionObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistQueue() }
        })
    }

    private func attachClock() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Saved queue

    private var lastPersist = Date.distantPast

    /// The queue and position, saved so the next launch resumes where this one stopped (paused).
    private func persistQueue() {
        guard !queue.isEmpty else { return }
        lastPersist = Date()
        Library.shared.saveQueue(.init(tracks: queue, index: index, position: position))
    }

    private func restoreQueue() {
        guard let saved = Library.shared.savedQueue(), saved.tracks.indices.contains(saved.index) else { return }
        queue = saved.tracks
        index = saved.index
        position = saved.position
        duration = Double(current?.durationText.flatMap(Self.seconds(from:)) ?? 0)
        publishNowPlaying()
        if let track = current { loadArtwork(for: track) }
    }

    // MARK: Public transport

    /// Plays [tracks] from [startIndex]; when the queue runs out, a radio of the last song continues it.
    func play(_ tracks: [Track], startAt startIndex: Int = 0, title: String? = nil) {
        guard tracks.indices.contains(startIndex) else { return }
        if let title { queueTitle = title }
        queue = tracks
        index = startIndex
        wantsToPlay = true
        load()
    }

    func togglePlayPause() { isPlaying || (wantsToPlay && isLoading) ? pause() : resume() }

    func pause() {
        wantsToPlay = false
        finishCrossfade()
        player.pause()
        updatePlayingState()
    }

    func resume() {
        guard current != nil else { return }
        wantsToPlay = true
        if let stream, let expires = stream.expiresAt, Date() > expires.addingTimeInterval(-120) {
            // Paused for hours: googlevideo links last about six, so fetch a fresh one in place.
            load(startAt: position, forceFresh: true)
            return
        }
        if player.currentItem == nil { load(startAt: position); return }
        setActive()
        player.play()
        if rate != 1 { player.rate = rate }
        updatePlayingState()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
            load()
        } else {
            extendWithRadio(thenAdvance: true)
        }
    }

    func previous() {
        if position > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load()
        }
    }

    func toggleShuffle() {
        shuffleOn.toggle()
        guard shuffleOn, queue.count > index + 2 else { return }
        // Shuffle what is still to come; the current song keeps playing.
        let upcoming = queue[(index + 1)...].shuffled()
        queue.replaceSubrange((index + 1)..., with: upcoming)
        prefetched.removeAll()
        prefetchNext()
    }

    func cycleRepeat() { repeatMode = (repeatMode + 1) % 3 }

    // MARK: Speed and sleep timer

    func setRate(_ value: Float) {
        rate = value
        player.currentItem?.audioTimePitchAlgorithm = .spectral // keeps the pitch at other speeds
        if isPlaying { player.rate = value }
    }

    /// Pauses after [minutes], fading the volume out over the last five seconds.
    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let deadline = Date().addingTimeInterval(Double(minutes) * 60)
        sleepDeadline = deadline
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow - 5) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            for step in 1 ... 25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { self.player.volume = 1; return }
                self.player.volume = Float(cos(Double(step) / 25 * .pi / 2))
            }
            self.pause()
            self.player.volume = 1
            self.sleepDeadline = nil
        }
    }

    func setSleepTimerEndOfTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
        sleepAtEndOfTrack = false
        player.volume = 1
    }

    func jump(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        wantsToPlay = true
        load()
    }

    func seek(to seconds: Double) {
        // Past the real end lies only the inflated tail AVFoundation imagines.
        let target = duration > 0 ? min(max(0, seconds), duration - 0.5) : max(0, seconds)
        finishCrossfade()
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        publishNowPlaying()
    }

    // MARK: Loading

    private func load(startAt start: Double = 0, forceFresh: Bool = false) {
        guard let track = current else { return }
        loadTask?.cancel()
        finishCrossfade()
        player.pause()
        isLoading = true
        position = start
        duration = Double(track.durationText.flatMap(Self.seconds(from:)) ?? 0)
        stalledSince = nil
        publishNowPlaying()
        loadArtwork(for: track)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream: AudioStream
                if let local = Downloads.localFile(for: track.id) {
                    // Offline copy first: no network, no expiring link.
                    stream = AudioStream(url: local, durationMs: Int(self.duration * 1000), loudnessDb: nil, expiresAt: nil)
                } else if !forceFresh, let cached = self.prefetched.removeValue(forKey: track.id) {
                    stream = cached
                } else {
                    stream = try await self.resolveWithRetry(track.id)
                }
                guard !Task.isCancelled, self.current?.id == track.id else { return }
                try await self.start(stream, startAt: start)
            } catch is CancellationError {
            } catch {
                guard self.current?.id == track.id else { return }
                self.isLoading = false
                self.errorMessage = "Não foi possível tocar \"\(track.title)\""
                NSLog("SimpNative: load failed for \(track.id): \(error)")
            }
        }
    }

    /// A fresh stream, retried while the connection is down (about half a minute).
    private func resolveWithRetry(_ id: String) async throws -> AudioStream {
        var lastError: Error = InnerTubeError.badResponse
        for attempt in 0 ..< 6 {
            do { return try await InnerTube.shared.audioStream(for: id) } catch {
                lastError = error
                if case InnerTubeError.unplayable = error, attempt > 0 { throw error }
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        throw lastError
    }

    private func start(_ stream: AudioStream, startAt start: Double) async throws {
        self.stream = stream
        if stream.durationMs > 0 { duration = Double(stream.durationMs) / 1000 }
        if duration <= 0, stream.url.isFileURL, let d = try? await AVURLAsset(url: stream.url).load(.duration), d.seconds.isFinite {
            duration = d.seconds
        }
        let asset = AVURLAsset(url: stream.url)
        // The audio chain goes on BEFORE the item plays: attaching it to a playing item makes
        // AVFoundation stop, rebuild and resume its pipeline — an audible hiccup.
        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        let item = AVPlayerItem(asset: asset)
        if let audio = tracks?.first, let mix = Self.audioMix(for: audio, slot: currentSlot) { item.audioMix = mix }
        applyNormalization()
        player.replaceCurrentItem(with: item)
        if start > 0 { await player.seek(to: CMTime(seconds: start, preferredTimescale: 1000)) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        isLoading = false
        item.audioTimePitchAlgorithm = .spectral
        if wantsToPlay {
            setActive()
            player.play()
            if rate != 1 { player.rate = rate }
        }
        updatePlayingState()
        publishNowPlaying()
        prefetchNext()
        if let track = current { Library.shared.addRecent(track) }
        persistQueue()
        NSLog("SimpNative: playing \(current?.id ?? "?") dur=\(Int(duration))s")
    }

    private static func audioMix(for track: AVAssetTrack, slot: Int32) -> AVAudioMix? {
        guard let tap = simp_create_tap(slot) else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private func prefetchNext() {
        guard index + 1 < queue.count else {
            extendWithRadio(thenAdvance: false)
            return
        }
        let next = queue[index + 1]
        guard prefetched[next.id] == nil else { return }
        Task { [weak self] in
            if let s = try? await InnerTube.shared.audioStream(for: next.id) { self?.prefetched = [next.id: s] }
        }
    }

    /// Endless playback: appends YouTube Music's radio for the current song to the queue.
    private func extendWithRadio(thenAdvance: Bool) {
        guard let seed = current else { return }
        Task { [weak self] in
            guard let self else { return }
            let more = (try? await InnerTube.shared.radio(for: seed.id)) ?? []
            let known = Set(self.queue.map(\.id))
            let fresh = more.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else { return }
            self.queue.append(contentsOf: fresh)
            if thenAdvance {
                self.index += 1
                self.load()
            } else {
                self.prefetchNext()
            }
        }
    }

    private func trackEnded() {
        position = duration
        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            pause()
            return
        }
        if repeatMode == 2 {
            seek(to: 0)
            player.play()
            return
        }
        if index + 1 >= queue.count, repeatMode == 1, !queue.isEmpty {
            index = 0
            load()
            return
        }
        if index + 1 < queue.count {
            index += 1
            load()
        } else {
            extendWithRadio(thenAdvance: true)
        }
    }

    // MARK: Crossfade

    /// Starts the next song [crossfadeSeconds] before this one ends and overlaps the two on an
    /// equal-power curve. Skipped for short songs (under three fade lengths) or when the next
    /// stream is not resolved yet — then the song just ends and the next starts as usual.
    private func maybeStartCrossfade() {
        guard crossfadeEnabled, fadingOut == nil, crossfadeTask == nil, wantsToPlay, isPlaying, !isLoading else { return }
        let fade = min(max(crossfadeSeconds, 1), 12)
        guard duration >= fade * 3, position >= duration - fade, index + 1 < queue.count else { return }
        let next = queue[index + 1]
        let localURL = Downloads.localFile(for: next.id)
        guard localURL != nil || prefetched[next.id] != nil else { return }
        let stream = localURL.map { AudioStream(url: $0, durationMs: 0, loudnessDb: nil, expiresAt: nil) } ?? prefetched.removeValue(forKey: next.id)!
        crossfadeTask = Task { [weak self] in await self?.runCrossfade(to: next, stream: stream, fade: fade) }
    }

    private func runCrossfade(to next: Track, stream: AudioStream, fade: Double) async {
        defer { crossfadeTask = nil }
        let slot: Int32 = currentSlot == 0 ? 1 : 0
        let asset = AVURLAsset(url: stream.url)
        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        let item = AVPlayerItem(asset: asset)
        if let audio = tracks?.first, let mix = Self.audioMix(for: audio, slot: slot) { item.audioMix = mix }
        let incoming = AVPlayer(playerItem: item)
        incoming.volume = 0
        var waited = 0.0
        while item.status != .readyToPlay {
            if item.status == .failed || waited > fade / 2 || Task.isCancelled { prefetched[next.id] = stream; return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        guard wantsToPlay, !Task.isCancelled else { prefetched[next.id] = stream; return }
        // Swap: the incoming player becomes the current one; the old one fades out.
        let outgoing = player
        if let timeObserver { outgoing.removeTimeObserver(timeObserver) }
        fadingOut = outgoing
        player = incoming
        currentSlot = slot
        attachClock()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        index += 1
        self.stream = stream
        position = 0
        duration = stream.durationMs > 0 ? Double(stream.durationMs) / 1000 : Double(next.durationText.flatMap(Self.seconds(from:)) ?? 0)
        incoming.play()
        applyNormalization()
        loadArtwork(for: next)
        publishNowPlaying()
        Library.shared.addRecent(next)
        let steps = 50
        let startVolume = outgoing.volume
        for step in 1 ... steps {
            try? await Task.sleep(nanoseconds: UInt64(fade / Double(steps) * 1_000_000_000))
            guard fadingOut === outgoing else { return }
            let t = Double(step) / Double(steps)
            outgoing.volume = startVolume * Float(cos(t * .pi / 2))
            incoming.volume = Float(sin(t * .pi / 2))
        }
        finishCrossfade()
        prefetchNext()
        persistQueue()
    }

    /// Ends a crossfade at once: the outgoing song stops and the current one gets full volume.
    private func finishCrossfade() {
        guard let outgoing = fadingOut else { crossfadeTask?.cancel(); crossfadeTask = nil; return }
        fadingOut = nil
        crossfadeTask?.cancel()
        crossfadeTask = nil
        outgoing.pause()
        outgoing.replaceCurrentItem(with: nil)
        player.volume = 1
    }

    // MARK: Clock and stalls

    private func tick() {
        guard player.currentItem != nil else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { position = seconds }
        updatePlayingState()
        if isPlaying, Date().timeIntervalSince(lastPersist) > 10 { persistQueue() }
        // With the inflated length AVPlayer may keep "playing" past the real end, or wait for
        // bytes that don't exist just before it: either way, that is the end of the track.
        if duration > 0, position >= duration + 1.5 { trackEnded(); return }
        maybeStartCrossfade()
        let waiting = wantsToPlay && player.timeControlStatus == .waitingToPlayAtSpecifiedRate && !isLoading
        if !waiting { stalledSince = nil; return }
        let since = stalledSince ?? Date()
        stalledSince = since
        let stalled = Date().timeIntervalSince(since)
        if duration > 0, position >= duration - 2, stalled >= 0.75 { stalledSince = nil; trackEnded(); return }
        // Mid-track: the network. AVPlayer recovers by itself unless the URL expired meanwhile.
        if stalled >= 15, Date().timeIntervalSince(lastStallReload ?? .distantPast) >= 15 {
            lastStallReload = Date()
            stalledSince = nil
            load(startAt: position, forceFresh: true)
        }
    }

    private func updatePlayingState() {
        let playing = player.timeControlStatus == .playing
        if playing != isPlaying {
            isPlaying = playing
            publishNowPlaying()
        }
    }

    // MARK: Audio session and everyday situations

    private func setUpAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func setActive() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeSession() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.interruption(note) }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.routeChange(note) }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setUpAudioSession()
                if self.current != nil { self.load(startAt: self.position) }
            }
        })
        sessionObservers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            URLCache.shared.removeAllCachedResponses()
        })
    }

    /// A call, FaceTime, alarm, timer or Siri: iOS has already silenced the player when this
    /// begins; when it ends it says whether the music should come back (ShouldResume).
    private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            playingBeforeInterruption = wantsToPlay
            wantsToPlay = false
            finishCrossfade()
            player.pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume), playingBeforeInterruption { resume() }
            playingBeforeInterruption = false
        @unknown default: break
        }
        updatePlayingState()
    }

    /// Headphones unplugged or a Bluetooth device gone: pause instead of playing out loud.
    private func routeChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        pause()
    }

    // MARK: Normalization

    private func applyNormalization() {
        var gain: Float = 1
        if normalizeVolume, let db = stream?.loudnessDb {
            gain = min(max(Float(pow(10, -db / 20)), 0.25), 2)
        }
        simp_normalize_set(gain)
    }

    // MARK: Lock screen / Dynamic Island

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func publishNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        nowPlaying[MPMediaItemPropertyTitle] = track.title
        nowPlaying[MPMediaItemPropertyArtist] = track.artist
        nowPlaying[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlaying[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
        nowPlaying[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
    }

    private func loadArtwork(for track: Track) {
        nowPlaying[MPMediaItemPropertyArtwork] = nil
        artworkTask?.cancel()
        guard let url = track.artworkLarge else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            guard let self, self.current?.id == track.id else { return }
            self.nowPlaying[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.publishNowPlaying()
        }
    }

    // MARK: Helpers

    static func seconds(from text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
