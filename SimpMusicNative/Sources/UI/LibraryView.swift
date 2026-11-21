import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var library = Library.shared
    @ObservedObject private var account = Account.shared
    @State private var section = 0
    @State private var accountLikes: [Track]?

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
            let tracks = section == 0 ? library.favorites : section == 1 ? library.downloaded : section == 2 ? library.recent : (accountLikes ?? [])
            if section == 3, accountLikes == nil { ProgressView().frame(maxWidth: .infinity) }
            if tracks.isEmpty {
                Text(section == 0 ? "Toque no coração no player para guardar músicas aqui." :
                    section == 1 ? "Músicas baixadas tocam sem internet." : "O que você ouvir aparece aqui.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                Button { player.play(tracks, startAt: offset) } label: { TrackRow(track: track, highlighted: player.current?.id == track.id) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if section == 0 { Button("Remover", role: .destructive) { library.toggleFavorite(track) } }
                        if section == 1 { Button("Apagar", role: .destructive) { library.removeDownload(track) } }
                    }
            }
            Color.clear.frame(height: 80).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .navigationTitle("Biblioteca")
        .task(id: section) {
            // The account's liked songs on YouTube Music.
            if section == 3, accountLikes == nil { accountLikes = (try? await InnerTube.shared.collectionTracks("FEmusic_liked_videos")) ?? [] }
        }
    }
}
