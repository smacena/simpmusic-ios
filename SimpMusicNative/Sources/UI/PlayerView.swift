import AVKit
import SwiftUI

/// SimpMusic's "Classic" Now Playing: background tinted from the cover, "TOCANDO AGORA" over the
/// queue's name, the cover, the current lyric line, title with the heart, the scrubber with both
/// times, the transport row, and info / output / lyrics … add / queue at the bottom.
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var artwork = ArtworkColor.shared
    @ObservedObject private var lyrics = LyricsStore.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var downloads = Downloads.shared
    @State private var scrubbing: Double?
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var showInfo = false
    @State private var showSleep = false
    @State private var addTo: Track?

    var body: some View {
        ZStack {
            LinearGradient(colors: [artwork.color, artwork.color.opacity(0.55), Theme.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                cover
                Spacer(minLength: 12)
                lyricLine
                titleRow.padding(.top, 14)
                scrubber.padding(.top, 18)
                transport.padding(.top, 14)
                bottomRow.padding(.top, 18).padding(.bottom, 10)
            }
            .padding(.horizontal, 20)
        }
        .foregroundStyle(.white)
        .gesture(DragGesture(minimumDistance: 30).onEnded { if $0.translation.height > 80 { dismiss() } })
        .onAppear { refresh() }
        .onChange(of: player.current?.id) { _, _ in refresh() }
        .sheet(isPresented: $showQueue) { QueueView().preferredColorScheme(.dark) }
        .fullScreenCover(isPresented: $showLyrics) { LyricsView() }
        .sheet(item: $addTo) { AddToPlaylistSheet(track: $0).presentationDetents([.medium, .large]).preferredColorScheme(.dark) }
        .sheet(isPresented: $showInfo) { SongInfoView().presentationDetents([.medium]).preferredColorScheme(.dark) }
        .confirmationDialog("Temporizador de sono", isPresented: $showSleep, titleVisibility: .visible) {
            ForEach([5, 15, 30, 45, 60], id: \.self) { m in Button("\(m) minutos") { player.setSleepTimer(minutes: m) } }
            Button("Fim da música") { player.setSleepTimerEndOfTrack() }
            if player.sleepDeadline != nil || player.sleepAtEndOfTrack { Button("Desligar", role: .destructive) { player.cancelSleepTimer() } }
        }
    }

    private func refresh() {
        artwork.update(player.current?.artworkLarge)
        lyrics.load(for: player.current, duration: player.duration)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44) }
            Spacer()
            VStack(spacing: 2) {
                Text("TOCANDO AGORA").font(Theme.poppins(13, .medium)).foregroundStyle(.white.opacity(0.85))
                Text(player.queueTitle).font(Theme.poppins(17, .bold)).lineLimit(1)
            }
            Spacer()
            Menu {
                if let track = player.current {
                    Button { downloads.download(track) } label: {
                        Label(Downloads.localFile(for: track.id) != nil ? "Baixada" : "Baixar", systemImage: "arrow.down.circle")
                    }
                    .disabled(Downloads.localFile(for: track.id) != nil)
                    Button { library.toggleFavorite(track) } label: {
                        Label(library.isFavorite(track) ? "Remover dos favoritos" : "Favoritar", systemImage: "heart")
                    }
                    Button { player.startRadio(track) } label: { Label("Iniciar rádio", systemImage: "dot.radiowaves.left.and.right") }
                    Button { ArtistRouter.shared.open(name: track.artist) } label: { Label("Ir ao artista", systemImage: "person.circle") }
                }
                Button { showSleep = true } label: { Label(sleepLabel, systemImage: "moon.zzz") }
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button { player.setRate(Float(rate)) } label: {
                            if player.rate == Float(rate) { Label("\(rate, specifier: "%.2g")x", systemImage: "checkmark") } else { Text("\(rate, specifier: "%.2g")x") }
                        }
                    }
                } label: { Label("Velocidade", systemImage: "speedometer") }
                Menu {
                    ForEach([-4, -3, -2, -1, 0, 1, 2, 3, 4], id: \.self) { st in
                        Button { player.setPitch(st) } label: {
                            let name = st == 0 ? "Original" : (st > 0 ? "+\(st)" : "\(st)")
                            if player.pitchSemitones == st { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: { Label("Tom", systemImage: "tuningfork") }
                if let track = player.current {
                    ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(track.id)")!) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                }
            } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 20, weight: .bold)).frame(width: 44, height: 44) }
        }
    }

    private var sleepLabel: String {
        if player.sleepAtEndOfTrack { return "Temporizador: fim da música" }
        if let d = player.sleepDeadline { return "Temporizador: \(max(1, Int(d.timeIntervalSinceNow / 60))) min" }
        return "Temporizador de sono"
    }

    @ViewBuilder
    private var cover: some View {
        if player.videoMode {
            ZStack {
                VideoView(player: player.videoPlayer)
                if !player.videoReady {
                    artworkImage
                    ProgressView().tint(.white).padding(10).background(.black.opacity(0.4), in: Circle())
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            artworkImage
        }
    }

    private var artworkImage: some View {
        AsyncImage(url: player.current?.artworkLarge) { image in image.resizable().scaledToFit() } placeholder: {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)).aspectRatio(1, contentMode: .fit)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .frame(maxHeight: 360)
    }

    @ViewBuilder
    private var lyricLine: some View {
        let index = lyrics.currentIndex(at: player.position)
        Text(index.map { lyrics.lines![$0].text } ?? " ")
            .font(Theme.poppins(17, .medium))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.25), value: index)
            .onTapGesture { showLyrics = true }
    }

    private var titleRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "").font(Theme.titleLarge).lineLimit(1)
                Text(player.current?.artist ?? "").font(Theme.poppins(17)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer()
            if let track = player.current {
                Button { library.toggleFavorite(track) } label: {
                    Image(systemName: library.isFavorite(track) ? "heart.fill" : "heart").font(.system(size: 26))
                        .foregroundStyle(library.isFavorite(track) ? Color(red: 1, green: 0.25, blue: 0.5) : .white)
                }
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { scrubbing ?? player.position }, set: { scrubbing = $0 }),
                in: 0 ... max(player.duration, 1),
                onEditingChanged: { editing in if !editing, let t = scrubbing { player.seek(to: t); scrubbing = nil } }
            )
            .tint(.white)
            HStack {
                Text(Self.format(scrubbing ?? player.position))
                Spacer()
                Text(Self.format(player.duration))
            }
            .font(Theme.poppins(14))
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var transport: some View {
        HStack {
            Button { player.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffleOn ? Theme.seed : .white) }
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 30)) }
            Spacer()
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 76, height: 76)
                    if player.isLoading { ProgressView().tint(.black) } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 32)).foregroundStyle(.black)
                    }
                }
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 30)) }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(player.repeatMode == 0 ? .white : Theme.seed)
            }
        }
        .font(.system(size: 24, weight: .semibold))
    }

    private var bottomRow: some View {
        HStack(spacing: 22) {
            Button { showInfo = true } label: { Image(systemName: "info.circle.fill") }
            RoutePicker().frame(width: 30, height: 30)
            Button { showLyrics = true } label: { Image(systemName: "text.bubble.fill") }
            Button { player.toggleVideo() } label: {
                if player.videoLoading { ProgressView().tint(.white) } else {
                    Image(systemName: player.videoMode ? "music.note" : "play.rectangle.fill").foregroundStyle(player.videoMode ? Theme.seed : .white)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            Spacer()
            if let track = player.current {
                Button { addTo = track } label: { Image(systemName: "text.badge.plus") }
            }
            Button { showQueue = true } label: { Image(systemName: "list.bullet") }
        }
        .font(.system(size: 22, weight: .semibold))
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// AirPlay / Bluetooth output picker (the headphones button in SimpMusic).
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.seed)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct SongInfoView: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        List {
            if let t = player.current {
                LabeledContent("Título", value: t.title)
                LabeledContent("Artista", value: t.artist)
                LabeledContent("Duração", value: PlayerView.format(player.duration))
                LabeledContent("ID", value: t.id)
                LabeledContent("Offline", value: Downloads.localFile(for: t.id) != nil ? "Sim" : "Não")
            }
        }
        .font(Theme.bodyMedium)
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                        Button { player.jump(to: offset) } label: { TrackRow(track: track, highlighted: offset == player.index) }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.background)
                            .id(offset)
                            .deleteDisabled(offset == player.index)
                    }
                    .onMove { player.moveQueue(from: $0, to: $1) }
                    .onDelete { player.removeFromQueue(at: $0) }
                }
                .environment(\.editMode, .constant(.active))
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .onAppear { proxy.scrollTo(player.index, anchor: .center) }
            }
            .navigationTitle("Fila")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
