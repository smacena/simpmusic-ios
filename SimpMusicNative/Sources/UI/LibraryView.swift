import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var library = Library.shared
    @ObservedObject private var account = Account.shared
    @State private var section = 0
    @State private var accountLikes: [Track]?
    @State private var accountPlaylists: [InnerTube.Collection]?
    @State private var creating = false
    @State private var newName = ""

    @ViewBuilder
    private var playlistsSection: some View {
        if section == 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    Button { creating = true } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceHigh)
                                Image(systemName: "plus").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                            }
                            .frame(width: 120, height: 120)
                            Text("Nova playlist").font(Theme.poppins(14, .medium)).foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(library.playlists) { playlist in
                        NavigationLink { LocalPlaylistView(id: playlist.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PlaylistCover(tracks: playlist.tracks).frame(width: 120, height: 120)
                                Text(playlist.name).font(Theme.poppins(14, .medium)).foregroundStyle(.white).lineLimit(1)
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(accountPlaylists ?? [], id: \.browseId) { c in
                        NavigationLink { CollectionView(collection: c) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AsyncImage(url: c.thumbnail) { $0.resizable().scaledToFill() } placeholder: { Theme.surfaceHigh }
                                    .frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(c.title).font(Theme.poppins(14, .medium)).foregroundStyle(.white).lineLimit(1)
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
            .alert("Nova playlist", isPresented: $creating) {
                TextField("Nome", text: $newName)
                Button("Criar") { library.createPlaylist(newName); newName = "" }
                Button("Cancelar", role: .cancel) {}
            }
            .task {
                if account.isSignedIn, accountPlaylists == nil { accountPlaylists = (try? await InnerTube.shared.accountPlaylists()) ?? [] }
            }
        }
    }

    var body: some View {
        List {
            Picker("", selection: $section) {
                Text("Favoritas").tag(0)
                Text("Baixadas").tag(1)
                Text("Recentes").tag(2)
                if account.isSignedIn { Text("YouTube").tag(3) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
            playlistsSection
            let tracks = section == 0 ? library.favorites : section == 1 ? library.downloaded : section == 2 ? library.recent : (accountLikes ?? [])
            if section == 3, accountLikes == nil { ProgressView().frame(maxWidth: .infinity) }
            if tracks.isEmpty {
                Text(section == 0 ? "Toque no coração no player para guardar músicas aqui." :
                    section == 1 ? "Músicas baixadas tocam sem internet." : "O que você ouvir aparece aqui.")
                    .font(Theme.bodyMedium)
                    .foregroundStyle(Theme.body)
                    .listRowBackground(Theme.background)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                Button { player.play(tracks, startAt: offset, title: ["Favoritas", "Baixadas", "Recentes", "Curtidas no YouTube"][min(section, 3)]) } label: { TrackRow(track: track, highlighted: player.current?.id == track.id) }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.background)
                    .swipeActions {
                        if section == 0 { Button("Remover", role: .destructive) { library.toggleFavorite(track) } }
                        if section == 1 { Button("Apagar", role: .destructive) { library.removeDownload(track) } }
                    }
            }
            Color.clear.frame(height: 160).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Biblioteca")
        .task(id: section) {
            // The account's liked songs on YouTube Music.
            if section == 3, accountLikes == nil { accountLikes = (try? await InnerTube.shared.collectionTracks("FEmusic_liked_videos")) ?? [] }
        }
    }
}
