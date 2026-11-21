import SwiftUI

struct ArtistView: View {
    @EnvironmentObject private var player: PlayerEngine
    let browseId: String
    let fallbackName: String
    @State private var page: InnerTube.ArtistPage?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 10) {
                    AsyncImage(url: page?.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.25) }
                        .frame(width: 180, height: 180)
                        .clipShape(Circle())
                    Text(page?.name.isEmpty == false ? page!.name : fallbackName).font(Theme.poppins(28, .bold)).foregroundStyle(.white)
                    if let songs = page?.songs, !songs.isEmpty {
                        HStack(spacing: 14) {
                            Button { player.play(songs) } label: { Label("Tocar", systemImage: "play.fill").frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent)
                            Button { player.play(songs.shuffled()) } label: { Label("Aleatório", systemImage: "shuffle").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered)
                        }
                        .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity)
                if page == nil && !failed { ProgressView().frame(maxWidth: .infinity) }
                if failed { Text("Não foi possível carregar o artista.").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                if let songs = page?.songs, !songs.isEmpty {
                    Text("Músicas").font(Theme.headline).foregroundStyle(.white).padding(.horizontal)
                    VStack(spacing: 10) {
                        ForEach(Array(songs.prefix(10).enumerated()), id: \.element.id) { offset, track in
                            Button { player.play(songs, startAt: offset) } label: { TrackRow(track: track, highlighted: player.current?.id == track.id) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                ForEach(page?.shelves ?? []) { shelf in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(shelf.title).font(Theme.headline).foregroundStyle(.white).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(shelf.items) { item in
                                    switch item {
                                    case let .song(track):
                                        Button { player.play([track]) } label: { Tile(url: track.artworkLarge ?? track.thumbnail, title: track.title, subtitle: track.artist) }
                                            .buttonStyle(.plain)
                                    case let .collection(c):
                                        NavigationLink {
                                            if c.browseId.hasPrefix("UC") { ArtistView(browseId: c.browseId, fallbackName: c.title) } else { CollectionView(collection: c) }
                                        } label: { Tile(url: c.thumbnail, title: c.title, subtitle: c.subtitle) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                Color.clear.frame(height: 160)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard page == nil else { return }
            do { page = try await InnerTube.shared.artist(browseId) } catch { failed = true }
        }
    }
}
