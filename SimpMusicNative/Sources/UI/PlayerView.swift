import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 22) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
            Spacer(minLength: 0)
            AsyncImage(url: player.current?.artworkLarge) { image in image.resizable().scaledToFit() } placeholder: {
                RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.25))
            }
            .frame(maxWidth: 340, maxHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
            VStack(spacing: 4) {
                Text(player.current?.title ?? "").font(.title3.weight(.bold)).lineLimit(1)
                Text(player.current?.artist ?? "").font(.body).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal)
            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { scrubbing ?? player.position }, set: { scrubbing = $0 }),
                    in: 0 ... max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing, let target = scrubbing { player.seek(to: target); scrubbing = nil }
                    }
                )
                HStack {
                    Text(Self.format(scrubbing ?? player.position))
                    Spacer()
                    Text("-" + Self.format(max(0, player.duration - (scrubbing ?? player.position))))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            HStack(spacing: 44) {
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 72))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
            }
            .foregroundStyle(.primary)
            HStack {
                Spacer()
                Button { showQueue = true } label: { Label("Fila", systemImage: "list.bullet") }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        NavigationStack {
            List(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                Button { player.jump(to: offset) } label: { TrackRow(track: track, highlighted: offset == player.index) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("Fila")
        }
    }
}
