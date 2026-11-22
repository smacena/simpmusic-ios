import AVFoundation
import SwiftUI

/// SimpMusic's SoundCloud Now Playing (NowPlayingContentSoundCloud.kt): the artwork fills a rounded
/// card; title, artist and a "Song info" chip sit on black strips at its top-left; dismiss, output,
/// lyrics and add-to-playlist run down its top-right; the waveform slides past a playhead fixed at
/// the centre, with the current lyric above it; like, shuffle, repeat, queue and more along the
/// bottom. Playing, a tap on the card pauses; paused, the artwork blurs and dims and ⏪5 · ⏮ · ▶ ·
/// ⏭ · 5⏩ come up across the middle, and the waveform folds into a line.
struct SoundCloudPlayer: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var artwork = ArtworkColor.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var lyrics = LyricsStore.shared
    @State private var bars: [Float]?
    let onDismiss: () -> Void
    let menu: AnyView
    let onInfo: () -> Void
    let onLyrics: () -> Void
    let onQueue: () -> Void
    let onAdd: () -> Void

    var body: some View {
        let scheme = TonalScheme(seed: artwork.color)
        let paused = !player.isPlaying && !player.isLoading
        VStack(spacing: 0) {
            ZStack {
                Color.clear
                    .overlay {
                        AsyncImage(url: player.current?.artworkLarge) { $0.resizable().scaledToFill() } placeholder: { scheme.surfaceContainerHigh }
                            .blur(radius: paused ? 24 : 0)
                            .overlay(Color.black.opacity(paused ? 0.35 : 0))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { if !paused { player.togglePlayPause() } }
                VStack(alignment: .leading, spacing: 6) {
                    strip(player.current?.title ?? "", font: Theme.poppins(20, .bold), plain: paused)
                    strip(player.current?.artist ?? "", font: Theme.poppins(15), plain: paused)
                        .onTapGesture { if let a = player.current?.artist { ArtistRouter.shared.open(name: a) } }
                    Button(action: onInfo) {
                        Text("Info da música").font(Theme.poppins(12, .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(paused ? 0.0 : 0.85), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(paused ? 0.6 : 0)))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                VStack(spacing: 10) {
                    round("chevron.down", action: onDismiss)
                    ZStack { round("headphones") {}; RoutePicker().opacity(0.02).frame(width: 40, height: 40) }
                    round("quote.bubble", action: onLyrics)
                    round("text.badge.plus", action: onAdd)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(14)
                if paused {
                    HStack(spacing: 18) {
                        roundBig("gobackward.5", 44, 22) { player.seek(to: max(0, player.position - 5)) }
                        roundBig("backward.end.fill", 52, 26) { player.previous() }
                        roundBig("play.fill", 76, 38) { player.togglePlayPause() }
                        roundBig("forward.end.fill", 52, 26) { player.next() }
                        roundBig("goforward.5", 44, 22) { player.seek(to: min(player.duration, player.position + 5)) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            let index = lyrics.currentIndex(at: player.position)
            Text(index.map { lyrics.lines![$0].text } ?? " ")
                .font(Theme.poppins(15, .semibold)).lineLimit(1)
                .padding(.top, 12)
            SoundCloudWave(bars: bars, fraction: player.duration > 0 ? player.position / player.duration : 0,
                           duration: player.duration, folded: paused, played: scheme.primary) { player.seek(to: $0 * player.duration) }
                .frame(height: 96)
                .padding(.top, 6)
            HStack {
                if let track = player.current {
                    let liked = library.isFavorite(track)
                    iconButton(liked ? "heart.fill" : "heart", tint: liked ? scheme.primary : .white) { library.toggleFavorite(track) }
                }
                Spacer()
                iconButton("shuffle", tint: player.shuffleOn ? scheme.primary : .white) { player.toggleShuffle() }
                Spacer()
                iconButton(player.repeatMode == 2 ? "repeat.1" : "repeat", tint: player.repeatMode == 0 ? .white : scheme.primary) { player.cycleRepeat() }
                Spacer()
                iconButton("list.bullet", tint: .white, action: onQueue)
                Spacer()
                Menu { menu } label: { Image(icon: "ellipsis").font(.system(size: 22)).frame(width: 44, height: 44) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(scheme.background.ignoresSafeArea())
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.25), value: paused)
        .task(id: player.current?.id) { bars = await Self.waveform(for: player.current?.id) }
    }

    private func strip(_ text: String, font: Font, plain: Bool) -> some View {
        Text(text).font(font).lineLimit(1)
            .padding(.horizontal, plain ? 0 : 8).padding(.vertical, plain ? 0 : 3)
            .background(.black.opacity(plain ? 0 : 0.85))
    }

    private func round(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: icon).font(.system(size: 18, weight: .medium)).frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func roundBig(_ icon: String, _ size: CGFloat, _ iconSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: icon).font(.system(size: iconSize)).frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func iconButton(_ icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(icon: icon).font(.system(size: 22)).foregroundStyle(tint).frame(width: 44, height: 44) }
    }

    /// Peaks of a downloaded song (AVAssetReader needs a local file); nil streams draw a flat line,
    /// as the original does while it has no waveform.
    static func waveform(for id: String?) async -> [Float]? {
        guard let id, let url = Downloads.localFile(for: id) else { return nil }
        return await Task.detached(priority: .utility) { () -> [Float]? in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 4000,
            ])
            reader.add(output)
            reader.startReading()
            var peaks: [Float] = []
            var current: Float = 0
            var count = 0
            while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                guard let pointer else { continue }
                pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                    for i in 0 ..< length / 2 {
                        current = max(current, abs(Float(samples[i]) / 32768))
                        count += 1
                        if count == 1000 { peaks.append(current); current = 0; count = 0 } // 4 bars a second
                    }
                }
            }
            guard let top = peaks.max(), top > 0 else { return nil }
            return peaks.map { $0 / top }
        }.value
    }
}

/// The waveform sliding past a fixed centre playhead; dragging LEFT goes forward, like SoundCloud.
struct SoundCloudWave: View {
    let bars: [Float]?
    let fraction: Double
    let duration: Double
    let folded: Bool
    let played: Color
    let onSeek: (Double) -> Void
    @State private var dragStart: Double?
    @State private var dragFraction: Double?

    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let count = bars?.count ?? max(40, Int(duration * 4))
            let total = CGFloat(count) * (barWidth + gap)
            let shown = dragFraction ?? fraction
            let offset = geo.size.width / 2 - total * shown
            let baseline = geo.size.height * 0.62
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for i in 0 ..< count {
                        let x = offset + CGFloat(i) * (barWidth + gap)
                        guard x > -barWidth, x < size.width else { continue }
                        let h = folded || bars == nil ? 2 : max(2, CGFloat(bars![i]) * baseline * 0.95)
                        let color = x < size.width / 2 ? played : Color.white.opacity(0.85)
                        ctx.fill(Path(CGRect(x: x, y: baseline - h, width: barWidth, height: h)), with: .color(color))
                        ctx.fill(Path(CGRect(x: x, y: baseline + 1, width: barWidth, height: h * 0.35)), with: .color(color.opacity(0.3)))
                    }
                }
                Text("\(PlayerView.format(shown * duration)) | \(PlayerView.format(duration))")
                    .font(Theme.poppins(11, .medium)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.85))
                    .position(x: geo.size.width / 2, y: baseline + 14)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .onChanged { v in
                    let start = dragStart ?? fraction
                    dragStart = start
                    dragFraction = min(1, max(0, start - Double(v.translation.width / max(total, 1))))
                }
                .onEnded { _ in
                    if let f = dragFraction { onSeek(f) }
                    dragStart = nil; dragFraction = nil
                })
        }
    }
}
