import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var failed = false

    var body: some View {
        List {
            if searching { ProgressView().frame(maxWidth: .infinity) }
            if failed { Text("Falha na busca. Verifique a internet.").foregroundStyle(.secondary) }
            ForEach(Array(results.enumerated()), id: \.element.id) { offset, track in
                Button { player.play(results, startAt: offset) } label: { TrackRow(track: track, highlighted: player.current?.id == track.id) }
                    .buttonStyle(.plain)
            }
            Color.clear.frame(height: 80).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .navigationTitle("Buscar")
        .searchable(text: $query, prompt: "Músicas, artistas")
        .onSubmit(of: .search) { Task { await search() } }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        failed = false
        defer { searching = false }
        do { results = try await InnerTube.shared.searchSongs(text) } catch {
            failed = true
            results = []
        }
    }
}

struct TrackRow: View {
    let track: Track
    var highlighted = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: track.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1).foregroundStyle(highlighted ? Color.accentColor : .primary)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let d = track.durationText { Text(d).font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }
}
