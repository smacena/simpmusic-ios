import SwiftUI

/// Year in review told as stories (tap right/left, auto-advances every 6 s), from this device's
/// listening history only.
struct WrappedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var library = Library.shared
    @State private var page = 0
    @State private var progress: Double = 0
    private let year = Calendar.current.component(.year, from: Date())
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var events: [Library.PlayEvent] { library.plays.filter { Calendar.current.component(.year, from: $0.date) == year } }
    private var topSongs: [(Track, Int, Double)] {
        Dictionary(grouping: events, by: \.track.id).values
            .map { ($0[0].track, $0.count, $0.reduce(0) { $0 + $1.seconds }) }
            .sorted { $0.2 > $1.2 }
    }
    private var topArtists: [(String, Int, Double)] {
        Dictionary(grouping: events, by: \.track.artist).map { ($0.key, $0.value.count, $0.value.reduce(0) { $0 + $1.seconds }) }
            .sorted { $0.2 > $1.2 }
    }
    private var busiestDay: (Date, Double)? {
        Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.seconds }) }.max { $0.1 < $1.1 }
    }
    private var cards: Int { events.isEmpty ? 1 : 6 }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.seed.opacity(0.9), Color(red: 0.12, green: 0.05, blue: 0.25), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(0 ..< cards, id: \.self) { i in
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white).frame(width: geo.size.width * (i < page ? 1 : i == page ? progress : 0))
                        }
                        .frame(height: 3)
                    }
                }
                HStack {
                    Text("SimpMusic Wrapped \(String(year))").font(Theme.poppins(14, .medium)).opacity(0.8)
                    Spacer()
                    Button { dismiss() } label: { Image(icon: "xmark").font(.system(size: 18, weight: .bold)).frame(width: 40, height: 40) }
                }
                Spacer()
                card.transition(.opacity).id(page)
                Spacer()
            }
            .padding(20)
            .foregroundStyle(.white)
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { go(-1) }
                Color.clear.contentShape(Rectangle()).onTapGesture { go(1) }
            }
            .padding(.top, 90)
        }
        .onReceive(timer) { _ in
            progress += 0.05 / 6
            if progress >= 1 { go(1) }
        }
    }

    private func go(_ delta: Int) {
        let next = page + delta
        if next >= cards { dismiss(); return }
        withAnimation(.easeInOut(duration: 0.3)) { page = max(0, next) }
        progress = 0
    }

    @ViewBuilder
    private var card: some View {
        if events.isEmpty {
            big("Ainda não há o suficiente", "Ouça mais músicas este ano e sua retrospectiva aparece aqui.")
        } else {
            switch page {
            case 0:
                big("\(Int(events.reduce(0) { $0 + $1.seconds } / 60)) minutos", "foi quanto você ouviu em \(String(year)). \(events.count) reproduções, \(Set(events.map(\.track.id)).count) músicas diferentes.")
            case 1:
                if let top = topSongs.first {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Sua música do ano").font(Theme.poppins(20, .medium)).opacity(0.85)
                        AsyncImage(url: top.0.artworkLarge) { $0.resizable().scaledToFit() } placeholder: { Color.white.opacity(0.1) }
                            .frame(maxWidth: 300, maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 16))
                        Text(top.0.title).font(Theme.poppins(32, .bold))
                        Text("\(top.0.artist) · \(top.1) vezes").font(Theme.poppins(17)).opacity(0.8)
                    }
                }
            case 2:
                list("Top músicas", topSongs.prefix(5).map { ("\($0.0.title)", "\($0.0.artist) · \(Int($0.2 / 60)) min") })
            case 3:
                if let artist = topArtists.first {
                    big(artist.0, "foi quem você mais ouviu: \(Int(artist.2 / 60)) minutos em \(artist.1) reproduções.", caption: "Artista do ano")
                }
            case 4:
                list("Top artistas", topArtists.prefix(5).map { ($0.0, "\(Int($0.2 / 60)) min") })
            default:
                if let day = busiestDay {
                    big(day.0.formatted(.dateTime.day().month(.wide)), "foi o seu dia mais musical: \(Int(day.1 / 60)) minutos.", caption: "Dia do ano")
                }
            }
        }
    }

    private func big(_ title: String, _ subtitle: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let caption { Text(caption).font(Theme.poppins(20, .medium)).opacity(0.85) }
            Text(title).font(Theme.poppins(46, .bold)).minimumScaleFactor(0.5).lineLimit(3)
            Text(subtitle).font(Theme.poppins(19)).opacity(0.85)
        }
    }

    private func list(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(Theme.poppins(30, .bold))
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(i + 1)").font(Theme.poppins(28, .bold)).foregroundStyle(Theme.seed).frame(width: 34, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0).font(Theme.poppins(19, .bold)).lineLimit(1)
                        Text(row.1).font(Theme.poppins(14)).opacity(0.75).lineLimit(1)
                    }
                }
            }
        }
    }
}
