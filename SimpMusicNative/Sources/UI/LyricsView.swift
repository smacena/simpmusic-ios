import SwiftUI

/// Full-screen synced lyrics over the cover's colour: the sung line bright and large, the rest
/// dimmed, kept centred as the song moves; tapping a line seeks to it.
struct LyricsView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lyrics = LyricsStore.shared
    @ObservedObject private var artwork = ArtworkColor.shared
    /// Inside another screen (the Apple Music player's Lyrics tab): no background, no header.
    var embedded = false

    var body: some View {
        if embedded {
            content.foregroundStyle(.white).onAppear { lyrics.load(for: player.current, duration: player.duration) }
        } else {
            fullScreen
        }
    }

    private var fullScreen: some View {
        ZStack {
            LinearGradient(colors: [artwork.color, Theme.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(player.current?.title ?? "").font(Theme.poppins(16, .bold)).lineLimit(1)
                        Text(player.current?.artist ?? "").font(Theme.poppins(13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    Spacer()
                    if let source = lyrics.source {
                        Text(source.rawValue).font(Theme.poppins(11, .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    ShareLyricsButton()
                }
                .padding(.horizontal, 12)
                content
            }
        }
        .foregroundStyle(.white)
        .onAppear { lyrics.load(for: player.current, duration: player.duration) }
    }

    private var appleStyle: Bool { UserDefaults.standard.string(forKey: "lyrics.style") == "apple" }

    /// The sung line lights up word by word when the source has word timing (rich sync).
    private func lineText(_ line: LyricLine, isCurrent: Bool) -> Text {
        guard isCurrent, let words = line.words, !words.isEmpty else { return Text(line.text.isEmpty ? "♪" : line.text) }
        let heard = player.position - Double(LyricsStore.offsetMs) / 1000
        return words.enumerated().reduce(Text("")) { acc, item in
            let sung = item.element.time <= heard
            let piece = Text(item.element.text + (item.offset < words.count - 1 ? " " : ""))
                .foregroundColor(sung ? .white : .white.opacity(0.4))
            return acc + piece
        }
    }

    @ViewBuilder
    private var content: some View {
        if let lines = lyrics.lines, !lines.isEmpty {
            let current = lyrics.currentIndex(at: player.position) ?? -1
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        Color.clear.frame(height: 120)
                        ForEach(lines) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                lineText(line, isCurrent: line.id == current)
                                    .font(Theme.poppins(line.id == current ? 28 : 24, .bold))
                                if let reading = Romanizer.reading(for: line.text) {
                                    Text(reading).font(Theme.poppins(line.id == current ? 18 : 16, .medium)).opacity(0.75)
                                }
                                if let translated = lyrics.translated(line) {
                                    Text(translated).font(Theme.poppins(line.id == current ? 18 : 16)).foregroundStyle(Theme.seed).opacity(0.9)
                                }
                            }
                                .foregroundStyle(.white.opacity(line.id == current ? 1 : (lyrics.isSynced ? 0.35 : 0.85)))
                                .blur(radius: appleStyle && lyrics.isSynced && current >= 0 ? min(4.5, Double(abs(line.id - current)) * 1.1) : 0)
                                .scaleEffect(appleStyle && line.id == current ? 1.03 : 1, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                                .onTapGesture { if line.time >= 0 { player.seek(to: line.time) } }
                                .animation(.easeInOut(duration: 0.3), value: current)
                        }
                        Color.clear.frame(height: 300)
                    }
                    .padding(.horizontal, 24)
                }
                .onChange(of: current) { _, value in withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(value, anchor: .center) } }
                .onAppear { if current >= 0 { proxy.scrollTo(current, anchor: .center) } }
            }
        } else if lyrics.lines == nil {
            Spacer(); ProgressView().tint(.white); Spacer()
        } else {
            Spacer(); Text("Letra não encontrada").font(Theme.bodyMedium).foregroundStyle(.white.opacity(0.7)); Spacer()
        }
    }
}

/// Shares the current lyric line as a picture: cover, line, title and artist over the cover's colour.
struct ShareLyricsButton: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var lyrics = LyricsStore.shared
    @ObservedObject private var artwork = ArtworkColor.shared
    @State private var image: Image?
    @State private var showShare = false

    var body: some View {
        Button { render() } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40) }
            .sheet(isPresented: $showShare) {
                if let image {
                    VStack(spacing: 20) {
                        image.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16)).padding()
                        ShareLink(item: image, preview: SharePreview("Letra", image: image)) { Label("Compartilhar", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).padding(.horizontal)
                    }
                    .presentationDetents([.large]).preferredColorScheme(.dark)
                }
            }
    }

    @MainActor private func render() {
        guard let track = player.current else { return }
        let index = lyrics.currentIndex(at: player.position)
        let line = index.flatMap { lyrics.lines?[$0].text } ?? lyrics.lines?.first?.text ?? ""
        Task {
            var cover: UIImage?
            if let url = track.artworkLarge, let (data, _) = try? await URLSession.shared.data(from: url) { cover = UIImage(data: data) }
            let card = VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    if let cover { Image(uiImage: cover).resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    VStack(alignment: .leading) {
                        Text(track.title).font(Theme.poppins(18, .bold)).lineLimit(1)
                        Text(track.artist).font(Theme.poppins(14)).opacity(0.75).lineLimit(1)
                    }
                }
                Text(line).font(Theme.poppins(28, .bold)).fixedSize(horizontal: false, vertical: true)
                Text("SimpMusic").font(Theme.poppins(12, .medium)).opacity(0.6)
            }
            .foregroundStyle(.white)
            .padding(28)
            .frame(width: 360, alignment: .leading)
            .background(LinearGradient(colors: [artwork.color, artwork.color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3
            if let ui = renderer.uiImage { image = Image(uiImage: ui); showShare = true }
        }
    }
}
