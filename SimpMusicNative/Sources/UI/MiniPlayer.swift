import SwiftUI

/// SimpMusic's floating mini player: shuffle, previous, play/pause, next, repeat on the left,
/// the artwork and title on the right, a thin progress line under the title.
struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerEngine
    let open: () -> Void

    var body: some View {
        if let track = player.current {
            HStack(spacing: 0) {
                HStack(spacing: 18) {
                    Button { player.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffleOn ? Theme.seed : .white) }
                    Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                    Button { player.togglePlayPause() } label: {
                        Group {
                            if player.isLoading { ProgressView().tint(.white) } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26))
                            }
                        }
                        .frame(width: 30)
                    }
                    Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == 2 ? "repeat.1" : "repeat").foregroundStyle(player.repeatMode == 0 ? .white : Theme.seed)
                    }
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 16)
                Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 30).padding(.horizontal, 12)
                HStack(spacing: 10) {
                    AsyncImage(url: track.thumbnail) { image in image.resizable().scaledToFill() } placeholder: { Theme.surfaceHigh }
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(Theme.poppins(15, .medium)).foregroundStyle(.white).lineLimit(1)
                        Text(track.artist).font(Theme.poppins(13)).foregroundStyle(Theme.body).lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.15))
                                Capsule().fill(Color.white)
                                    .frame(width: player.duration > 0 ? geo.size.width * min(1, player.position / player.duration) : 0)
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 3)
                    }
                }
                .padding(.trailing, 14)
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
            }
            .frame(height: 64)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.06)))
            .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height < -20 { open() } })
        }
    }
}
