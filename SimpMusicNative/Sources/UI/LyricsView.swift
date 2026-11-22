import SwiftUI

/// Full-screen synced lyrics over the cover's colour: the sung line bright and large, the rest
/// dimmed, kept centred as the song moves; tapping a line seeks to it.
struct LyricsView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lyrics = LyricsStore.shared
    @ObservedObject private var artwork = ArtworkColor.shared

    var body: some View {
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
                }
                .padding(.horizontal, 12)
                content
            }
        }
        .foregroundStyle(.white)
        .onAppear { lyrics.load(for: player.current, duration: player.duration) }
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
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(Theme.poppins(line.id == current ? 28 : 24, .bold))
                                if let reading = Romanizer.reading(for: line.text) {
                                    Text(reading).font(Theme.poppins(line.id == current ? 18 : 16, .medium)).opacity(0.75)
                                }
                            }
                                .foregroundStyle(.white.opacity(line.id == current ? 1 : (lyrics.isSynced ? 0.35 : 0.85)))
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
