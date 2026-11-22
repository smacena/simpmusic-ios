import SwiftUI

/// SimpMusic's home: avatar, "Todos / Mood" chips, add and settings buttons, then big carousels
/// over a backdrop blurred from the first artwork.
struct HomeView: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var account = Account.shared
    @State private var shelves: [InnerTube.Shelf] = []
    @State private var moods: [InnerTube.Shelf] = []
    @State private var charts: [InnerTube.Shelf] = []
    @State private var chip = 0
    @State private var failed = false
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                let content = chip == 0 ? shelves : (chip == 1 ? moods : charts)
                if content.isEmpty && !failed { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 80) }
                if failed {
                    VStack(spacing: 12) {
                        Text("Não foi possível carregar.").font(Theme.bodyMedium).foregroundStyle(Theme.body)
                        Button("Tentar de novo") { Task { await load() } }.font(Theme.poppins(15, .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(content) { shelf in ShelfView(shelf: shelf) }
                Color.clear.frame(height: 160)
            }
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(alignment: .top) { backdrop }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { if shelves.isEmpty { await load() } }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() }.preferredColorScheme(.dark) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { showSettings = true } label: {
                Image(systemName: account.isSignedIn ? "person.crop.circle.fill.badge.checkmark" : "person.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceHigh, in: Circle())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chipButton("Todos", 0)
                    chipButton("Mood", 1)
                    chipButton("Charts", 2)
                }
                .padding(1)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 22)).foregroundStyle(.white).frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
    }

    private func chipButton(_ title: String, _ value: Int) -> some View {
        Button {
            chip = value
            if value == 1, moods.isEmpty { Task { moods = (try? await InnerTube.shared.moodsAndGenres()) ?? [] } }
            if value == 2, charts.isEmpty { Task { charts = (try? await InnerTube.shared.charts()) ?? [] } }
        } label: {
            Text(title)
                .font(Theme.poppins(15, .medium))
                .foregroundStyle(chip == value ? Color.black.opacity(0.85) : .white)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(chip == value ? Theme.seed : .clear, in: Capsule())
                .overlay(Capsule().stroke(chip == value ? .clear : Color.white.opacity(0.35)))
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        let url: URL? = shelves.first?.items.first.flatMap {
            switch $0 {
            case let .song(t): t.artworkLarge
            case let .collection(c): c.thumbnail
            }
        }
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            .frame(height: 360)
            .blur(radius: 50)
            .opacity(0.55)
            .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))
            .clipped()
            .ignoresSafeArea()
    }

    private func load() async {
        failed = false
        do { shelves = try await InnerTube.shared.home() } catch { failed = shelves.isEmpty }
    }
}

struct ShelfView: View {
    @EnvironmentObject private var player: PlayerEngine
    let shelf: InnerTube.Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !shelf.strapline.isEmpty {
                Text(shelf.strapline.uppercased()).font(Theme.poppins(13, .medium)).foregroundStyle(Theme.body).padding(.horizontal, 16)
            }
            Text(shelf.title).font(Theme.headline).foregroundStyle(.white).padding(.horizontal, 16).padding(.bottom, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.items) { item in
                        switch item {
                        case let .song(track):
                            Button {
                                let songs = shelf.items.compactMap { if case let .song(t) = $0 { t } else { nil } }
                                player.play(songs, startAt: songs.firstIndex(of: track) ?? 0, title: shelf.title)
                            } label: { Tile(url: track.artworkLarge ?? track.thumbnail, title: track.title, subtitle: track.artist) }
                                .buttonStyle(.plain)
                        case let .collection(c):
                            NavigationLink {
                                if c.browseId.hasPrefix("UC") { ArtistView(browseId: c.browseId, fallbackName: c.title) } else { CollectionView(collection: c) }
                            } label: { Tile(url: c.thumbnail, title: c.title, subtitle: c.subtitle) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct Tile: View {
    let url: URL?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Theme.surfaceHigh }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title).font(Theme.titleMedium).foregroundStyle(.white).lineLimit(1)
            Text(subtitle).font(Theme.bodyMedium).foregroundStyle(Theme.body).lineLimit(1)
        }
        .frame(width: 160)
    }
}

struct CollectionView: View {
    @EnvironmentObject private var player: PlayerEngine
    let collection: InnerTube.Collection
    @State private var tracks: [Track]?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                AsyncImage(url: collection.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Theme.surfaceHigh }
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    .padding(.top, 10)
                Text(collection.title).font(Theme.poppins(24, .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
                Text(collection.subtitle).font(Theme.bodyMedium).foregroundStyle(Theme.body).multilineTextAlignment(.center).padding(.horizontal)
                if let tracks, !tracks.isEmpty {
                    HStack(spacing: 18) {
                        Button { player.play(tracks.shuffled(), title: collection.title) } label: {
                            Image(systemName: "shuffle").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 52, height: 52).background(Theme.surfaceHigh, in: Circle())
                        }
                        Button { player.play(tracks, title: collection.title) } label: {
                            Label("Tocar", systemImage: "play.fill").font(Theme.poppins(18, .medium)).foregroundStyle(.black)
                                .frame(width: 140, height: 52).background(Color.white, in: Capsule())
                        }
                        Button { Downloads.shared.downloadAll(tracks) } label: {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(.white)
                                .frame(width: 52, height: 52).background(Theme.surfaceHigh, in: Circle())
                        }
                    }
                    Text("\(tracks.count) faixas").font(Theme.poppins(15, .medium)).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                }
                if tracks == nil { ProgressView().tint(.white).padding(.top, 30) }
                LazyVStack(spacing: 4) {
                    ForEach(Array((tracks ?? []).enumerated()), id: \.element.id) { offset, track in
                        Button { player.play(tracks ?? [], startAt: offset, title: collection.title) } label: {
                            TrackRow(track: track, highlighted: player.current?.id == track.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                Color.clear.frame(height: 160)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { if tracks == nil { tracks = (try? await InnerTube.shared.collectionTracks(collection.browseId)) ?? [] } }
    }
}
