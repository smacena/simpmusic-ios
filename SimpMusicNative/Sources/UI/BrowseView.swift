import SwiftUI
import CoreImage

/// Opens what a section's "More" button points to (navigateToMoreEndpoint): YouTube names the page
/// type on the endpoint, so an album, playlist, artist or podcast opens its own screen, an artist
/// discography opens More albums, and an unnamed one (`FEmusic_*`) is the generic Browse page.
struct MoreDestination: View {
    let more: InnerTube.MoreEndpoint
    let title: String

    var body: some View {
        switch more.pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK", "MUSIC_PAGE_TYPE_PLAYLIST", "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE":
            CollectionView(collection: InnerTube.Collection(browseId: more.browseId, title: title, subtitle: "", thumbnail: nil))
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            ArtistView(browseId: more.browseId, fallbackName: title)
        case "MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY":
            MoreAlbumsView(browseId: more.browseId, params: more.params ?? "")
        default:
            BrowseView(browseId: more.browseId, params: more.params, title: title)
        }
    }
}

/// BrowseScreen.kt: every shelf of the page flattened into justified rows — each card keeps its own
/// shape (16:9 video, square otherwise), every thumbnail in a row is the same height and the number
/// of cards per row follows the shapes in it — under the mood buttons, with Mix for you's ambient
/// glow tinted from the first item and a bar that frosts once the list scrolls.
struct BrowseView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    let browseId: String
    let params: String?
    let title: String?

    @State private var page: InnerTube.BrowsePage?
    @State private var failed = false
    @State private var glow: Color = Theme.background
    @State private var atTop = true

    static let rowGap: CGFloat = 10
    static let targetThumbnailHeight: CGFloat = 180
    static let cardHorizontalPadding: CGFloat = 20
    static let moodCellWidth: CGFloat = 170

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            if let page {
                GeometryReader { geo in
                    let width = geo.size.width
                    ScrollView {
                        VStack(alignment: .leading, spacing: Self.rowGap) {
                            GeometryReader { g in
                                Color.clear.preference(key: BrowseScrollKey.self, value: g.frame(in: .named("browse")).minY)
                            }
                            .frame(height: 0)
                            let columns = max(1, Int((width + Self.rowGap) / (Self.moodCellWidth + Self.rowGap)))
                            ForEach(Array(stride(from: 0, to: page.moods.count, by: columns)), id: \.self) { start in
                                HStack(spacing: Self.rowGap) {
                                    ForEach(page.moods[start ..< min(start + columns, page.moods.count)]) { mood in
                                        NavigationLink { MoodView(params: mood.params, fallbackTitle: mood.title) } label: { MoodButton(mood: mood) }
                                            .buttonStyle(.plain)
                                    }
                                    ForEach(0 ..< (columns - min(columns, page.moods.count - start)), id: \.self) { _ in
                                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                                    }
                                }
                            }
                            ForEach(Array(Self.justifyRows(page.contents, rowWidth: width).enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top, spacing: Self.rowGap) {
                                    ForEach(row, id: \.card.id) { cell in
                                        BrowseCardView(card: cell.card, width: cell.width, all: page.contents, pageTitle: page.title ?? title ?? "")
                                    }
                                }
                            }
                            Text("Fim da página").font(Theme.bodySmall).foregroundStyle(Theme.body)
                                .frame(maxWidth: .infinity).padding(.vertical, 20)
                            Color.clear.frame(height: 140)
                        }
                        .padding(.top, 64)
                        .background(alignment: .top) {
                            // Mix for you's ambient glow: drawn behind the first rows and scrolled away with them.
                            LinearGradient(colors: [glow, Theme.background], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(height: 380)
                                .overlay(alignment: .bottom) {
                                    LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom).frame(height: 180)
                                }
                                .padding(.top, -200)
                        }
                    }
                    .coordinateSpace(name: "browse")
                    .onPreferenceChange(BrowseScrollKey.self) { y in atTop = y >= -0.5 }
                    .scrollIndicators(.hidden)
                }
            } else if failed {
                VStack(spacing: 12) {
                    Text("Não foi possível carregar.").font(Theme.bodyMedium).foregroundStyle(Theme.body)
                    Button("Tentar de novo") { Task { await load() } }.font(Theme.poppins(15, .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            topBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { if page == nil { await load() } }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).frame(width: 42, height: 42)
            }
            Text(page?.title ?? title ?? "").font(Theme.poppins(18, .medium)).foregroundStyle(.white).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 56)
        .background {
            // Transparent while the list sits at pixel zero, frosted the moment it scrolls.
            Rectangle().fill(.ultraThinMaterial).opacity(atTop ? 0 : 1).ignoresSafeArea(edges: .top)
                .animation(.easeInOut(duration: 0.3), value: atTop)
        }
    }

    private func load() async {
        failed = false
        do {
            let result = try await InnerTube.shared.browsePage(browseId: browseId, params: params)
            page = result
            if let first = result.contents.first { await tint(from: first) }
        } catch {
            AppLog.e("Browse", "browse \(browseId) failed", error)
            failed = true
        }
    }

    /// The glow takes the first item's dominant colour, dimmed to 30% as rgbFactor(0.3f) does.
    private func tint(from card: InnerTube.BrowseCard) async {
        let url: URL? = switch card.item {
        case let .song(t): t.thumbnail
        case let .collection(c): c.thumbnail
        }
        guard let url, let (data, _) = try? await URLSession.shared.data(from: url), let image = CIImage(data: data) else { return }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])
        guard let output = filter?.outputImage else { return }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        withAnimation(.easeInOut(duration: 0.5)) {
            glow = Color(red: Double(px[0]) / 255 * 0.3, green: Double(px[1]) / 255 * 0.3, blue: Double(px[2]) / 255 * 0.3)
        }
    }

    struct Cell { let card: InnerTube.BrowseCard; let width: CGFloat }

    /// justifyRows: greedy line breaking. A row closes when the next card would take its height below
    /// the target — with or without that card, whichever lands closer. The last row keeps the target
    /// height instead of stretching to fill.
    static func justifyRows(_ contents: [InnerTube.BrowseCard], rowWidth: CGFloat) -> [[Cell]] {
        let target = targetThumbnailHeight
        var rows: [[Cell]] = []
        var current: [InnerTube.BrowseCard] = []
        func heightOf(_ row: [InnerTube.BrowseCard]) -> CGFloat {
            let fixed = cardHorizontalPadding * CGFloat(row.count) + rowGap * CGFloat(row.count - 1)
            return max(1, (rowWidth - fixed) / row.reduce(0) { $0 + $1.aspectRatio })
        }
        func close(_ row: [InnerTube.BrowseCard], _ height: CGFloat) {
            rows.append(row.map { Cell(card: $0, width: cardHorizontalPadding + $0.aspectRatio * height) })
        }
        for card in contents {
            let candidate = current + [card]
            let height = heightOf(candidate)
            if height > target {
                current = candidate
            } else if !current.isEmpty, heightOf(current) - target < target - height {
                close(current, heightOf(current))
                current = [card]
            } else {
                close(candidate, height)
                current = []
            }
        }
        if !current.isEmpty { close(current, min(target, heightOf(current))) }
        return rows
    }
}

private struct BrowseScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Home's card filling a justified cell: 10 pt each side of the thumbnail, title and subtitle under it.
/// A song plays its radio (Content.playRadio); anything else opens its page; long press = song menu.
private struct BrowseCardView: View {
    @EnvironmentObject private var player: PlayerEngine
    let card: InnerTube.BrowseCard
    let width: CGFloat
    let all: [InnerTube.BrowseCard]
    let pageTitle: String

    var body: some View {
        let thumbWidth = width - BrowseView.cardHorizontalPadding
        switch card.item {
        case let .song(track):
            Button { player.startRadio(track) } label: {
                content(url: card.aspectRatio > 1 ? track.thumbnail : (track.artworkLarge ?? track.thumbnail), title: track.title, subtitle: track.artist, thumbWidth: thumbWidth)
            }
            .buttonStyle(.plain)
            .contextMenu { TrackMenuItems(track: track) }
        case let .collection(c):
            NavigationLink {
                if c.browseId.hasPrefix("UC") { ArtistView(browseId: c.browseId, fallbackName: c.title) } else { CollectionView(collection: c) }
            } label: {
                content(url: c.thumbnail, title: c.title, subtitle: c.subtitle, thumbWidth: thumbWidth, round: c.browseId.hasPrefix("UC"))
            }
            .buttonStyle(.plain)
        }
    }

    private func content(url: URL?, title: String, subtitle: String, thumbWidth: CGFloat, round: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Theme.surfaceHigh }
                .frame(width: thumbWidth, height: thumbWidth / card.aspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: round ? thumbWidth / 2 : 8))
            Text(title).font(Theme.titleMedium).foregroundStyle(.white).lineLimit(1)
            Text(subtitle).font(Theme.bodyMedium).foregroundStyle(Theme.body).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// MoodMomentAndGenreHomeItem: a 50-tall elevated card with the API's stripe colour on the left.
struct MoodButton: View {
    let mood: InnerTube.Mood

    var body: some View {
        let c = mood.stripeColor
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color(red: Double((c >> 16) & 0xFF) / 255, green: Double((c >> 8) & 0xFF) / 255, blue: Double(c & 0xFF) / 255))
                .frame(width: 10)
            Text(mood.title).font(Theme.poppins(14, .medium)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(Theme.surfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// MoodScreen.kt: a mood / genre's page — its header and each section as a carousel.
struct MoodView: View {
    let params: String
    let fallbackTitle: String
    @State private var title = ""
    @State private var shelves: [InnerTube.Shelf]?
    @State private var failed = false

    var body: some View {
        Group {
            if let shelves {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(shelves) { ShelfView(shelf: $0) }
                        Color.clear.frame(height: 160)
                    }
                    .padding(.top, 10)
                }
                .scrollIndicators(.hidden)
            } else if failed {
                Text("Não foi possível carregar.").font(Theme.bodyMedium).foregroundStyle(Theme.body)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(title.isEmpty ? fallbackTitle : title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard shelves == nil else { return }
            do {
                let page = try await InnerTube.shared.moodPage(params: params)
                title = page.title
                shelves = page.shelves
                if page.shelves.isEmpty { failed = true; shelves = nil }
            } catch {
                AppLog.e("Mood", "mood page failed", error)
                failed = true
            }
        }
    }
}
