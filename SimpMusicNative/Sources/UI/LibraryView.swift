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
            .listRowBackground(Theme.background)
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
