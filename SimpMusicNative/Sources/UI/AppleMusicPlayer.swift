import MediaPlayer
import SwiftUI

/// SimpMusic's Apple Music Now Playing (NowPlayingContentAppleMusic.kt): a dock
/// (Lyrics · [Output] · Queue) swaps the body between three views. MAIN puts the cover edge to
/// edge at the top dissolving into a wash of its own colours, with the title row (☆ / ⋯), the
/// current lyric, an 8.4pt thin progress bar, the transport (shuffle · ⏪ · ▶ 66 · ⏩ · repeat),
/// and the volume row; LYRICS and QUEUE stand on the frosted cover with a compact header.
struct AppleMusicPlayer: View {
    enum Pane { case main, lyrics, queue }
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var artwork = ArtworkColor.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var lyrics = LyricsStore.shared
    @State private var tab: Pane = .main
    let onDismiss: () -> Void
    let menu: AnyView
    let onInfo: () -> Void

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(.white.opacity(0.5)).frame(width: 36, height: 5).padding(.top, 6)
                    .onTapGesture(perform: onDismiss)
                Group {
                    switch tab {
                    case .main: mainBody
                    case .lyrics: VStack(spacing: 0) { compactHeader; LyricsView(embedded: true) }
                    case .queue: VStack(spacing: 0) { compactHeader; queueList }
                    }
                }
                .transition(.opacity)
                bottomCluster
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.25), value: tab)
    }

    // MARK: Backgrounds

    @ViewBuilder
    private var background: some View {
        let base = artwork.color
        if tab == .main {
            // The cover's own colours as a soft mesh: a few blurred blobs of tones of the average.
            ZStack {
                base
                Circle().fill(base.opacity(0.9)).frame(width: 420).blur(radius: 90).offset(x: -120, y: 200)
                Circle().fill(Color.black.opacity(0.35)).frame(width: 380).blur(radius: 100).offset(x: 140, y: 420)
                Circle().fill(Color.white.opacity(0.08)).frame(width: 300).blur(radius: 80).offset(x: 120, y: -40)
            }
        } else {
            Color.clear
                .overlay {
                    AsyncImage(url: player.current?.artworkLarge) { $0.resizable().scaledToFill() } placeholder: { base }
                        .blur(radius: 70).scaleEffect(1.5)
                }
                .overlay(LinearGradient(colors: [base.opacity(0.55), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .clipped()
        }
    }

    // MARK: MAIN

    private var mainBody: some View {
        VStack(spacing: 0) {
            // Edge-to-edge square cover, its lower part dissolving into the page.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if player.videoMode {
                        VideoView(player: player.videoPlayer)
                    } else {
                        AsyncImage(url: player.current?.artworkLarge) { $0.resizable().scaledToFill() } placeholder: { artwork.color }
                    }
                }
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .padding(.top, 8)
            Spacer(minLength: 4)
            titleRow
            let index = lyrics.currentIndex(at: player.position)
            Text(index.map { lyrics.lines![$0].text } ?? " ")
                .font(Theme.poppins(17, .semibold)).opacity(0.85).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 10)
                .onTapGesture { tab = .lyrics }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.title ?? "").font(Theme.poppins(22, .bold)).lineLimit(1)
                Text(player.current?.artist ?? "").font(Theme.poppins(18)).opacity(0.7).lineLimit(1)
                    .onTapGesture { if let a = player.current?.artist { ArtistRouter.shared.open(name: a) } }
            }
            Spacer()
            headerActions
        }
        .padding(.horizontal, 20)
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            if let track = player.current {
                let liked = library.isFavorite(track)
                Button { library.toggleFavorite(track) } label: {
                    Image(systemName: liked ? "star.fill" : "star").font(.system(size: 22)).frame(width: 32, height: 32)
                        .symbolEffect(.bounce, value: liked)
                }
            }
            Menu { menu } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .bold)).frame(width: 30, height: 30)
                    .background(.white.opacity(0.15), in: Circle())
            }
        }
    }

    /// LYRICS / QUEUE: small cover, title and artist, the same ☆ / ⋯ actions.
    private var compactHeader: some View {
        HStack(spacing: 12) {
            AsyncImage(url: player.current?.thumbnail) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { tab = .main }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "").font(Theme.poppins(17, .bold)).lineLimit(1)
                Text(player.current?.artist ?? "").font(Theme.poppins(15)).opacity(0.7).lineLimit(1)
            }
            Spacer()
            headerActions
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                    Button { player.jump(to: offset) } label: { TrackRow(track: track, highlighted: offset == player.index) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .id(offset)
                        .deleteDisabled(offset == player.index)
                }
                .onMove { player.moveQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo(player.index, anchor: .center) }
        }
    }

    // MARK: Shared bottom cluster

    private var bottomCluster: some View {
        VStack(spacing: 0) {
            ThinSlider(value: player.duration > 0 ? player.position / player.duration : 0) { player.seek(to: $0 * player.duration) }
                .padding(.top, 14)
            HStack {
                Text(PlayerView.format(player.position))
                Spacer()
                Text("AAC").font(Theme.poppins(11, .medium)).opacity(0.6)
                Spacer()
                Text(player.duration > 0 ? "-" + PlayerView.format(max(0, player.duration - player.position)) : "--:--")
            }
            .font(Theme.poppins(12, .medium)).opacity(0.6).padding(.top, 8)
            HStack {
                glyph(player.shuffleOn ? 1 : 0.4, "shuffle", 22) { player.toggleShuffle() }
                Spacer()
                glyph(1, "backward.fill", 30) { player.previous() }
                Spacer()
                Button { player.togglePlayPause() } label: {
                    Group {
                        if player.isLoading { ProgressView().tint(.white) } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                        }
                    }
                    .frame(width: 76, height: 76)
                }
                Spacer()
                glyph(1, "forward.fill", 30) { player.next() }
                Spacer()
                glyph(player.repeatMode == 0 ? 0.4 : 1, player.repeatMode == 2 ? "repeat.1" : "repeat", 22) { player.cycleRepeat() }
            }
            .padding(.top, 14)
            VolumeRow().padding(.top, 14)
            dock.padding(.top, 18).padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
    }

    private func glyph(_ alpha: Double, _ name: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: size)).opacity(alpha).frame(width: 52, height: 52) }
    }

    /// Lyrics (40pt circle) · capsule [Output | Info] · Queue (40pt circle).
    private var dock: some View {
        HStack {
            dockButton("quote.bubble", active: tab == .lyrics) { tab = tab == .lyrics ? .main : .lyrics }
            Spacer()
            HStack(spacing: 0) {
                ZStack {
                    Image(systemName: "headphones").font(.system(size: 19)).opacity(0.85)
                    RoutePicker().opacity(0.02)
                }
                .frame(width: 64, height: 40)
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 20)
                Button(action: onInfo) { Image(systemName: "info.circle").font(.system(size: 19)).opacity(0.85).frame(width: 64, height: 40) }
            }
            .background(.white.opacity(0.12), in: Capsule())
            Spacer()
            dockButton("list.bullet", active: tab == .queue) { tab = tab == .queue ? .main : .queue }
        }
    }

    private func dockButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium))
                .foregroundStyle(active ? Color.black.opacity(0.8) : .white.opacity(0.85))
                .frame(width: 40, height: 40)
                .background(active ? Color.white.opacity(0.85) : .clear, in: Circle())
        }
    }
}

/// 8.4pt rounded track that swells to 16.8 while touched (Apple Music style).
struct ThinSlider: View {
    let value: Double
    let onCommit: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = min(1, max(0, drag ?? value))
            let h: CGFloat = drag != nil ? 16.8 : 8.4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(drag != nil ? 1 : 0.85)).frame(width: max(h, geo.size.width * shown))
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag = min(1, max(0, $0.location.x / max(1, geo.size.width))) }
                .onEnded { _ in if let d = drag { onCommit(d) }; drag = nil })
            .animation(.easeOut(duration: 0.15), value: drag != nil)
        }
        .frame(height: 18)
    }
}

/// System volume, with the thin track: drives the hidden MPVolumeView slider (the only public way).
struct VolumeRow: View {
    @State private var volume: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    private let host = VolumeHost.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.system(size: 13)).opacity(0.6)
            ThinSlider(value: volume) { v in volume = v; host.set(Float(v)) }
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 13)).opacity(0.6)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SystemVolumeDidChange"))) { _ in
            volume = Double(AVAudioSession.sharedInstance().outputVolume)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            volume = Double(AVAudioSession.sharedInstance().outputVolume)
        }
    }
}

@MainActor final class VolumeHost {
    static let shared = VolumeHost()
    private let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 10, height: 10))

    func set(_ value: Float) {
        if view.superview == nil, let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
            window.addSubview(view)
        }
        (view.subviews.first { $0 is UISlider } as? UISlider)?.setValue(value, animated: false)
        (view.subviews.first { $0 is UISlider } as? UISlider)?.sendActions(for: .valueChanged)
    }
}
