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
                                Image(icon: "plus").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
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

    /// Settings → "Juntar curtidas": local favourites followed by the account's liked songs.
    private var favoritesMerged: [Track] {
        guard UserDefaults.standard.bool(forKey: "likes.merge"), let account = accountLikes else { return library.favorites }
        let local = Set(library.favorites.map(\.id))
        return library.favorites + account.filter { !local.contains($0.id) }
    }

    /// The library's "Most played" dynamic playlist: this device's plays, by count, last 90 days.
    private var mostPlayed: [Track] {
        let since = Date().addingTimeInterval(-90 * 86400)
        let groups = Dictionary(grouping: library.plays.filter { $0.date >= since }, by: \.track.id)
        return groups.values.sorted { $0.count > $1.count }.prefix(100).map(\.[0].track)
    }

    var body: some View {
        List {
            Picker("", selection: $section) {
                Text("Favoritas").tag(0)
                Text("Baixadas").tag(1)
                Text("Recentes").tag(2)
                Text("Mais tocadas").tag(4)
                if account.isSignedIn { Text("YouTube").tag(3) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
            NavigationLink { StatsView() } label: {
                Label("Estatísticas de escuta", systemImage: "chart.bar.fill").font(Theme.poppins(16, .medium)).foregroundStyle(.white)
            }
            .listRowBackground(Theme.surface)
            if Library.trackingEnabled, !library.plays.isEmpty {
                NavigationLink { WrappedLibraryView() } label: {
                    Label("Wrapped e retrospectivas do mês", systemImage: "sparkles.rectangle.stack").font(Theme.poppins(16, .medium)).foregroundStyle(.white)
                }
                .listRowBackground(Theme.surface)
            }
            if account.isSignedIn {
                NavigationLink { MixForYouView() } label: {
                    Label("Mix para você", systemImage: "sparkles").font(Theme.poppins(16, .medium)).foregroundStyle(.white)
                }
                .listRowBackground(Theme.surface)
            }
            playlistsSection
            let tracks = section == 0 ? favoritesMerged : section == 1 ? library.downloaded : section == 2 ? library.recent : section == 4 ? mostPlayed : (accountLikes ?? [])
            if section == 3, accountLikes == nil { ProgressView().frame(maxWidth: .infinity) }
            if tracks.isEmpty {
                Text(section == 0 ? "Toque no coração no player para guardar músicas aqui." :
                    section == 1 ? "Músicas baixadas tocam sem internet." : "O que você ouvir aparece aqui.")
                    .font(Theme.bodyMedium)
                    .foregroundStyle(Theme.body)
                    .listRowBackground(Theme.background)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                Button { player.play(tracks, startAt: offset, title: ["Favoritas", "Baixadas", "Recentes", "Curtidas no YouTube", "Mais tocadas"][min(section, 4)]) } label: { TrackRow(track: track, highlighted: player.current?.id == track.id) }
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
            let wantsAccount = section == 3 || (section == 0 && UserDefaults.standard.bool(forKey: "likes.merge"))
            if wantsAccount, account.isSignedIn, accountLikes == nil { accountLikes = (try? await InnerTube.shared.collectionTracks("FEmusic_liked_videos")) ?? [] }
        }
    }
}


/// YouTube Music's "Mix for you" playlists (FEmusic_mixed_for_you), like the original's tab.
struct MixForYouView: View {
    @State private var shelves: [InnerTube.Shelf] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if loading { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 80) }
                if !loading && shelves.isEmpty {
                    Text("O YouTube não mandou mixes para esta conta.").font(Theme.bodyMedium).foregroundStyle(Theme.body).padding()
                }
                ForEach(shelves) { ShelfView(shelf: $0) }
                Color.clear.frame(height: 160)
            }
            .padding(.top, 8)
        }
        .background(Theme.background)
        .navigationTitle("Mix para você")
        .refreshable { await load() }
        .task { if shelves.isEmpty { await load() } }
    }

    private func load() async {
        shelves = (try? await InnerTube.shared.shelves(browseId: "FEmusic_mixed_for_you")) ?? []
        loading = false
    }
}


/// The Library's Wrapped chip (LibraryWrappedTab.kt): the year's Wrapped, then one recap playlist
/// per month with plays, newest first, at most twelve — each the month's songs by listening time.
struct WrappedLibraryView: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var library = Library.shared
    @State private var showWrapped = false

    private var months: [(key: DateComponents, title: String, tracks: [Track])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: library.plays) { cal.dateComponents([.year, .month], from: $0.date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "LLLL 'de' yyyy"
        return groups.compactMap { key, events -> (DateComponents, String, [Track])? in
            guard let date = cal.date(from: key) else { return nil }
            let byTrack = Dictionary(grouping: events, by: \.track.id).values
                .sorted { $0.reduce(0) { $0 + $1.seconds } > $1.reduce(0) { $0 + $1.seconds } }
            return (key, formatter.string(from: date).capitalized, byTrack.prefix(50).map(\.[0].track))
        }
        .sorted { ($0.0.year ?? 0, $0.0.month ?? 0) > ($1.0.year ?? 0, $1.0.month ?? 0) }
        .prefix(12).map { $0 }
    }

    var body: some View {
        List {
            Button { showWrapped = true } label: {
                HStack {
                    Image(icon: "sparkles")
                    Text("SimpMusic Wrapped \(String(Calendar.current.component(.year, from: Date())))").font(Theme.poppins(17, .bold))
                    Spacer()
                    Image(icon: "chevron.right")
                }
                .foregroundStyle(.white).padding(16)
                .background(LinearGradient(colors: [Theme.seed.opacity(0.8), .purple.opacity(0.6)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 14))
            }
            .listRowBackground(Theme.background)
            Section("Retrospectivas do mês") {
                ForEach(months, id: \.title) { month in
                    NavigationLink {
                        List {
                            ForEach(Array(month.tracks.enumerated()), id: \.element.id) { offset, track in
                                Button { player.play(month.tracks, startAt: offset, title: month.title) } label: { TrackRow(track: track) }
                                    .buttonStyle(.plain).listRowBackground(Theme.background)
                            }
                        }
                        .listStyle(.plain).scrollContentBackground(.hidden).background(Theme.background)
                        .navigationTitle(month.title)
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistCover(tracks: Array(month.tracks.prefix(4))).frame(width: 56, height: 56)
                            VStack(alignment: .leading) {
                                Text(month.title).font(Theme.poppins(16, .medium)).foregroundStyle(.white)
                                Text("\(month.tracks.count) músicas").font(Theme.bodySmall).foregroundStyle(Theme.body)
                            }
                        }
                    }
                    .listRowBackground(Theme.background)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Wrapped")
        .fullScreenCover(isPresented: $showWrapped) { WrappedView() }
    }
}
