import SwiftUI

/// One of the user's own playlists: play, shuffle, reorder, remove, rename, delete.
struct LocalPlaylistView: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var library = Library.shared
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var renaming = false
    @State private var newName = ""

    private var playlist: Library.LocalPlaylist? { library.playlists.first { $0.id == id } }

    var body: some View {
        List {
            if let playlist {
                VStack(spacing: 12) {
                    PlaylistCover(tracks: playlist.tracks).frame(width: 200, height: 200)
                    Text(playlist.name).font(Theme.poppins(24, .bold)).foregroundStyle(.white)
                    Text("\(playlist.tracks.count) faixas").font(Theme.bodyMedium).foregroundStyle(Theme.body)
                    if !playlist.tracks.isEmpty {
                        HStack(spacing: 18) {
                            Button { player.play(playlist.tracks.shuffled(), title: playlist.name) } label: {
                                Image(systemName: "shuffle").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 52, height: 52).background(Theme.surfaceHigh, in: Circle())
                            }
                            Button { player.play(playlist.tracks, title: playlist.name) } label: {
                                Label("Tocar", systemImage: "play.fill").font(Theme.poppins(18, .medium)).foregroundStyle(.black)
                                    .frame(width: 140, height: 52).background(Color.white, in: Capsule())
                            }
                            Button { Downloads.shared.downloadAll(playlist.tracks) } label: {
                                Image(systemName: "arrow.down.circle").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 52, height: 52).background(Theme.surfaceHigh, in: Circle())
                            }
                        }
                    } else {
                        Text("Adicione músicas pelo botão + no player.").font(Theme.bodyMedium).foregroundStyle(Theme.body)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
                ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { offset, track in
                    Button { player.play(playlist.tracks, startAt: offset, title: playlist.name) } label: { TrackRow(track: track, highlighted: player.current?.id == track.id) }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.background)
                }
                .onDelete { library.remove(at: $0, from: id) }
                .onMove { library.move(from: $0, to: $1, in: id) }
                Color.clear.frame(height: 160).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = playlist?.name ?? ""; renaming = true } label: { Label("Renomear", systemImage: "pencil") }
                    EditButton()
                    Button(role: .destructive) { library.deletePlaylist(id); dismiss() } label: { Label("Apagar playlist", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Renomear playlist", isPresented: $renaming) {
            TextField("Nome", text: $newName)
            Button("Salvar") { library.renamePlaylist(id, to: newName) }
            Button("Cancelar", role: .cancel) {}
        }
    }
}

/// A 2×2 mosaic of the first covers, like SimpMusic's local playlist art.
struct PlaylistCover: View {
    let tracks: [Track]

    var body: some View {
        let urls = Array(tracks.prefix(4).compactMap(\.thumbnail))
        GeometryReader { geo in
            if urls.count >= 4 {
                let half = geo.size.width / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) { cell(urls[0], half); cell(urls[1], half) }
                    HStack(spacing: 0) { cell(urls[2], half); cell(urls[3], half) }
                }
            } else if let first = urls.first {
                cell(first, geo.size.width)
            } else {
                ZStack {
                    LinearGradient(colors: [Theme.seed.opacity(0.7), Theme.surfaceHigh], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note.list").font(.system(size: geo.size.width / 3)).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func cell(_ url: URL, _ size: CGFloat) -> some View {
        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Theme.surfaceHigh }
            .frame(width: size, height: size).clipped()
    }
}

/// "Adicionar à playlist" sheet opened from the player.
struct AddToPlaylistSheet: View {
    @ObservedObject private var library = Library.shared
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Button { creating = true } label: { Label("Nova playlist", systemImage: "plus.circle.fill").font(Theme.poppins(16, .medium)) }
                    .listRowBackground(Theme.surface)
                ForEach(library.playlists) { playlist in
                    Button {
                        library.add(track, to: playlist.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistCover(tracks: playlist.tracks).frame(width: 44, height: 44)
                            VStack(alignment: .leading) {
                                Text(playlist.name).font(Theme.poppins(16, .medium)).foregroundStyle(.white)
                                Text("\(playlist.tracks.count) faixas").font(Theme.bodySmall).foregroundStyle(Theme.body)
                            }
                            Spacer()
                            if playlist.tracks.contains(where: { $0.id == track.id }) { Image(systemName: "checkmark").foregroundStyle(Theme.seed) }
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Adicionar à playlist")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Nova playlist", isPresented: $creating) {
                TextField("Nome", text: $name)
                Button("Criar") {
                    let playlist = library.createPlaylist(name)
                    library.add(track, to: playlist.id)
                    dismiss()
                }
                Button("Cancelar", role: .cancel) {}
            }
        }
    }
}
