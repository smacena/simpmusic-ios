import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerEngine
    let open: () -> Void

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                AsyncImage(url: track.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if player.isLoading { ProgressView() }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule().fill(Color.accentColor)
                        .frame(width: player.duration > 0 ? geo.size.width * min(1, player.position / player.duration) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 10)
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
    }
}
