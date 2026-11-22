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
        .contextMenu { TrackMenuItems(track: track) }
    }
}

/// The per-song actions (long press on any song, or the ⋯ button in the player).
struct TrackMenuItems: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: Downloads
    let track: Track

    var body: some View {
        Button { player.playNext(track) } label: { Label("Tocar a seguir", systemImage: "text.insert") }
        Button { player.addToQueue(track) } label: { Label("Adicionar à fila", systemImage: "text.append") }
        Button { player.startRadio(track) } label: { Label("Iniciar rádio", systemImage: "dot.radiowaves.left.and.right") }
        Button { ArtistRouter.shared.open(name: track.artist) } label: { Label("Ir ao artista", systemImage: "person.circle") }
        Button { library.toggleFavorite(track) } label: {
            Label(library.isFavorite(track) ? "Remover dos favoritos" : "Favoritar", systemImage: library.isFavorite(track) ? "heart.slash" : "heart")
        }
        Button { AddToPlaylistRouter.shared.track = track } label: { Label("Adicionar à playlist", systemImage: "text.badge.plus") }
        if Downloads.localFile(for: track.id) == nil {
            Button { downloads.download(track) } label: { Label("Baixar", systemImage: "arrow.down.circle") }
        }
        ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(track.id)")!) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
    }
}

/// Opens an artist page from anywhere (songs carry only the artist's name).
@MainActor final class ArtistRouter: ObservableObject {
    static let shared = ArtistRouter()
    struct Target: Identifiable { let id: String; let name: String }
    @Published var target: Target?

    func open(name: String) {
        let first = name.components(separatedBy: CharacterSet(charactersIn: ",&•")).first?.trimmingCharacters(in: .whitespaces) ?? name
        Task {
            if let hit = try? await InnerTube.shared.searchCollections(first, kind: .artists).first {
                target = Target(id: hit.browseId, name: hit.title)
            }
        }
    }
}

@MainActor final class AddToPlaylistRouter: ObservableObject {
    static let shared = AddToPlaylistRouter()
    @Published var track: Track?
}


/// Presents the artist page / add-to-playlist sheet requested from a song menu. Attached to the
/// root and to the full-screen player; only the topmost presenter is enabled.
struct RouterSheets: ViewModifier {
    @ObservedObject private var artist = ArtistRouter.shared
    @ObservedObject private var add = AddToPlaylistRouter.shared
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: enabled ? $artist.target : .constant(nil)) { t in
                NavigationStack { ArtistView(browseId: t.id, fallbackName: t.name) }.preferredColorScheme(.dark)
            }
            .sheet(item: enabled ? $add.track : .constant(nil)) { track in
                AddToPlaylistSheet(track: track).presentationDetents([.medium, .large]).preferredColorScheme(.dark)
            }
    }
}

extension View {
    func routerSheets(enabled: Bool = true) -> some View { modifier(RouterSheets(enabled: enabled)) }
}
