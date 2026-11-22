import Charts
import SwiftUI

/// Listening stats from this device's history: time listened, plays per day, top songs and
/// artists, for the last 7 days, 30 days, or all time.
struct StatsView: View {
    @EnvironmentObject private var player: PlayerEngine
    @ObservedObject private var library = Library.shared
    @State private var range = 0 // 0: 7 days, 1: 30 days, 2: all
    @State private var showWrapped = false

    private var events: [Library.PlayEvent] {
        let days = range == 0 ? 7 : range == 1 ? 30 : 100_000
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return library.plays.filter { $0.date >= since }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("", selection: $range) {
                    Text("7 dias").tag(0)
                    Text("30 dias").tag(1)
                    Text("Sempre").tag(2)
                }
                .pickerStyle(.segmented)
                Button { showWrapped = true } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("SimpMusic Wrapped").font(Theme.poppins(17, .bold))
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(LinearGradient(colors: [Theme.seed.opacity(0.8), .purple.opacity(0.6)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 14))
                }
                .fullScreenCover(isPresented: $showWrapped) { WrappedView() }
                let list = events
                if list.isEmpty {
                    Text("Ouça algumas músicas e as estatísticas aparecem aqui.").font(Theme.bodyMedium).foregroundStyle(Theme.body)
                } else {
                    HStack(spacing: 12) {
                        stat("Tempo ouvido", Self.duration(list.reduce(0) { $0 + $1.seconds }))
                        stat("Músicas", "\(list.count)")
                        stat("Artistas", "\(Set(list.map(\.track.artist)).count)")
                    }
                    Text("Por dia").font(Theme.poppins(20, .bold)).foregroundStyle(.white)
                    Chart(perDay(list), id: \.0) { day, minutes in
                        BarMark(x: .value("Dia", day, unit: .day), y: .value("Minutos", minutes))
                            .foregroundStyle(Theme.seed)
                            .cornerRadius(3)
                    }
                    .chartYAxisLabel("min")
                    .frame(height: 160)
                    Text("Músicas mais ouvidas").font(Theme.poppins(20, .bold)).foregroundStyle(.white)
                    let topSongs = top(list.map(\.track), by: \.id).prefix(10)
                    ForEach(Array(topSongs.enumerated()), id: \.element.0.id) { i, entry in
                        Button { player.play(topSongs.map(\.0), startAt: i, title: "Mais ouvidas") } label: {
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(Theme.poppins(18, .bold)).foregroundStyle(Theme.body).frame(width: 26)
                                TrackRow(track: entry.0)
                                Text("\(entry.1)×").font(Theme.bodySmall).foregroundStyle(Theme.body)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Artistas mais ouvidos").font(Theme.poppins(20, .bold)).foregroundStyle(.white)
                    let artists = Dictionary(grouping: list, by: \.track.artist).map { ($0.key, $0.value.reduce(0) { $0 + $1.seconds }) }.sorted { $0.1 > $1.1 }.prefix(10)
                    ForEach(Array(artists.enumerated()), id: \.element.0) { i, entry in
                        HStack {
                            Text("\(i + 1)").font(Theme.poppins(18, .bold)).foregroundStyle(Theme.body).frame(width: 26)
                            Text(entry.0).font(Theme.poppins(16, .medium)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Text(Self.duration(entry.1)).font(Theme.bodySmall).foregroundStyle(Theme.body)
                        }
                    }
                }
                Color.clear.frame(height: 160)
            }
            .padding(.horizontal, 16)
        }
        .background(Theme.background)
        .navigationTitle("Estatísticas")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Theme.poppins(20, .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(Theme.bodySmall).foregroundStyle(Theme.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func perDay(_ list: [Library.PlayEvent]) -> [(Date, Double)] {
        let cal = Calendar.current
        return Dictionary(grouping: list) { cal.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.seconds } / 60) }
            .sorted { $0.0 < $1.0 }
    }

    private func top<T: Hashable>(_ tracks: [Track], by key: KeyPath<Track, T>) -> [(Track, Int)] {
        var counts: [T: (Track, Int)] = [:]
        for t in tracks { counts[t[keyPath: key], default: (t, 0)].1 += 1 }
        return counts.values.sorted { $0.1 > $1.1 }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
