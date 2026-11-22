import SwiftUI

/// SimpMusic's own icons (Material Symbols Rounded, from its ui/icon folder) as symbol assets, so
/// they look exactly like the Android app and still size with the font like SF Symbols. Any name
/// without a Material twin falls back to the SF Symbol.
extension Image {
    init(icon name: String) {
        if let material = Image.materialNames[name] { self.init("ms.\(material)") } else { self.init(systemName: name) }
    }

    static let materialNames: [String: String] = [
        "shuffle": "Shuffle", "repeat": "Repeat", "repeat.1": "RepeatOne",
        "play.fill": "PlayArrow", "pause.fill": "Pause", "forward.fill": "FastForward", "backward.fill": "FastRewind",
        "forward.end.fill": "SkipNext", "backward.end.fill": "SkipPrevious", "ellipsis": "MoreVert",
        "chevron.down": "KeyboardArrowDown", "list.bullet": "QueueMusic", "headphones": "Headphones",
        "heart": "FavoriteBorder", "heart.fill": "Favorite", "star": "StarBorder", "star.fill": "Star",
        "info.circle": "Info", "info.circle.fill": "Info", "text.badge.plus": "PlaylistAdd",
        "quote.bubble": "Lyrics", "text.bubble.fill": "Lyrics", "music.note": "MusicNote",
        "play.rectangle": "Movie", "play.rectangle.fill": "Movie", "magnifyingglass": "Search",
        "gearshape.fill": "Settings", "music.note.list": "LibraryMusic", "person.fill": "Person",
        "xmark": "Close", "square.and.arrow.up": "Share", "speaker.fill": "VolumeDown", "speaker.wave.3.fill": "VolumeUp",
        "plus": "Add", "checkmark": "Check", "arrow.down.circle": "DownloadForOfflineOutlined",
        "arrow.down.circle.fill": "DownloadForOffline", "chevron.right": "ArrowForwardIos", "house.fill": "Home",
    ]
}
