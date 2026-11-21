import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var query = ""
    @State private var scope = 0 // 0 songs, 1 albums, 2 artists, 3 playlists
    @State private var songs: [Track] = []
    @State private var collections: [InnerTube.Collection] = []
    @State private var searching = false
    @State private var failed = false
    @State private var lastQuery = ""

    var body: some View {
        List {
            Picker("", selection: $scope) {
                Text("Músicas").tag(0)
                Text("Álbuns").tag(1)
                Text("Artistas").tag(2)
                Text("Playlists").tag(3)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            if searching { ProgressView().frame(maxWidth: .infinity) }
            if failed { Text("Falha na busca. Verifique a internet.").foregroundStyle(.secondary) }
            if scope == 0 {
                ForEach(Array(songs.enumerated()), id: \.element.id) { offset, track in
                    Button { player.play(songs, startAt: offset, title: "Busca: \(lastQuery)") } label: { TrackRow(track: track, highlighted: player.current?.id == track.id) }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.background)
                }
            } else {
                ForEach(collections, id: \.browseId) { collection in
                    NavigationLink {
                        if scope == 2 { ArtistView(browseId: collection.browseId, fallbackName: collection.title) } else { CollectionView(collection: collection) }
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: collection.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                                .frame(width: 52, height: 52)
                                .clipShape(scope == 2 ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collection.title).font(Theme.poppins(16, .medium)).foregroundStyle(.white).lineLimit(1)
                                Text(collection.subtitle).font(Theme.bodyMedium).foregroundStyle(Theme.body).lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Theme.background)
                }
            }
            Color.clear.frame(height: 160).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .environment(\.defaultMinListRowHeight, 60)
        .navigationTitle("Buscar")
        .searchable(text: $query, prompt: "Músicas, álbuns, artistas")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: scope) { _, _ in Task { await search() } }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        lastQuery = text
        searching = true
        failed = false
        defer { searching = false }
        do {
            switch scope {
            case 0: songs = try await InnerTube.shared.searchSongs(text)
            case 1: collections = try await InnerTube.shared.searchCollections(text, kind: .albums)
            case 2: collections = try await InnerTube.shared.searchCollections(text, kind: .artists)
            default: collections = try await InnerTube.shared.searchCollections(text, kind: .playlists)
            }
        } catch { failed = true }
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
                Text(track.title).font(Theme.poppins(16, .medium)).lineLimit(1).foregroundStyle(highlighted ? Theme.seed : .white)
                Text(track.artist).font(Theme.bodyMedium).foregroundStyle(Theme.body).lineLimit(1)
            }
            Spacer()
            if let d = track.durationText { Text(d).font(Theme.bodySmall).foregroundStyle(Theme.body) }
        }
        .contentShape(Rectangle())
    }
}
