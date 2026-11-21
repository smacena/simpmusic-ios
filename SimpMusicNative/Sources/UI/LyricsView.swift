import SwiftUI

/// Synced lyrics: the current line is highlighted and kept in view; tapping a line seeks to it.
struct LyricsView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var lines: [LyricLine]?
    @State private var loadedFor: String?

    var body: some View {
        NavigationStack {
            Group {
                if let lines, !lines.isEmpty {
                    let current = lines.lastIndex { $0.time >= 0 && $0.time <= player.position } ?? -1
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(lines) { line in
                                    Text(line.text.isEmpty ? "♪" : line.text)
                                        .font(.title3.weight(line.id == current ? .bold : .regular))
                                        .foregroundStyle(line.id == current ? Color.primary : Color.secondary)
                                        .id(line.id)
                                        .onTapGesture { if line.time >= 0 { player.seek(to: line.time) } }
                                }
                            }
                            .padding(24)
                        }
                        .onChange(of: current) { _, value in
                            withAnimation(.easeInOut) { proxy.scrollTo(value, anchor: .center) }
                        }
                    }
                } else if lines == nil {
                    ProgressView()
                } else {
                    Text("Letra não encontrada").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(player.current?.title ?? "Letra")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: player.current?.id) {
            guard let track = player.current, loadedFor != track.id else { return }
            lines = nil
            loadedFor = track.id
            lines = await Lyrics.fetch(for: track, duration: player.duration) ?? []
        }
    }
}
