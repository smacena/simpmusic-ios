import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var shelves: [InnerTube.Shelf] = []
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if shelves.isEmpty && !failed { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                if failed {
                    VStack(spacing: 12) {
                        Text("Não foi possível carregar o início.").foregroundStyle(.secondary)
                        Button("Tentar de novo") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(shelves) { shelf in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(shelf.title).font(.title2.weight(.bold)).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(shelf.items) { item in cell(item, in: shelf) }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                Color.clear.frame(height: 90)
            }
        }
        .navigationTitle("Início")
        .refreshable { await load() }
        .task { if shelves.isEmpty { await load() } }
    }

    @ViewBuilder
    private func cell(_ item: InnerTube.ShelfItem, in shelf: InnerTube.Shelf) -> some View {
        switch item {
        case let .song(track):
            Button {
                let songs = shelf.items.compactMap { if case let .song(t) = $0 { t } else { nil } }
                player.play(songs, startAt: songs.firstIndex(of: track) ?? 0)
            } label: { Tile(url: track.artworkLarge ?? track.thumbnail, title: track.title, subtitle: track.artist) }
                .buttonStyle(.plain)
        case let .collection(collection):
            NavigationLink { CollectionView(collection: collection) } label: {
                Tile(url: collection.thumbnail, title: collection.title, subtitle: collection.subtitle)
            }
            .buttonStyle(.plain)
        }
    }

    private func load() async {
        failed = false
        do { shelves = try await InnerTube.shared.home() } catch { failed = shelves.isEmpty }
    }
}

struct Tile: View {
    let url: URL?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.25) }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150)
    }
}

struct CollectionView: View {
    @EnvironmentObject private var player: PlayerEngine
    let collection: InnerTube.Collection
    @State private var tracks: [Track]?

    var body: some View {
        List {
            VStack(spacing: 10) {
                AsyncImage(url: collection.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.25) }
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(collection.title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                Text(collection.subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let tracks, !tracks.isEmpty {
                    HStack(spacing: 14) {
                        Button { player.play(tracks) } label: { Label("Tocar", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                        Button { player.play(tracks.shuffled()) } label: { Label("Aleatório", systemImage: "shuffle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            if tracks == nil { ProgressView().frame(maxWidth: .infinity) }
            ForEach(Array((tracks ?? []).enumerated()), id: \.element.id) { offset, track in
                Button { player.play(tracks ?? [], startAt: offset) } label: { TrackRow(track: track, highlighted: player.current?.id == track.id) }
                    .buttonStyle(.plain)
            }
            Color.clear.frame(height: 80).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .task { if tracks == nil { tracks = (try? await InnerTube.shared.collectionTracks(collection.browseId)) ?? [] } }
    }
}
