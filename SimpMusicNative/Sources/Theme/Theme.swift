import SwiftUI
import UIKit

/// SimpMusic's look: Poppins, near-black surfaces, the light-blue seed colour (#8ECAE6) and the
/// grey body text (#A8A8A8) the Compose app uses (ui/theme/Typo.kt, Color.kt).
enum Theme {
    static let background = Color(red: 0.07, green: 0.075, blue: 0.08)
    static let surface = Color(red: 0.13, green: 0.14, blue: 0.15)
    static let surfaceHigh = Color(red: 0.18, green: 0.19, blue: 0.2)
    /// Accent colour; chosen in Settings → Aparência (read once at launch).
    static let seed: Color = {
        let key = UserDefaults.standard.string(forKey: "theme.accent") ?? "seed"
        return accents.first { $0.key == key }?.color ?? accents[0].color
    }()

    static let accents: [(key: String, name: String, color: Color)] = [
        ("seed", "Azul SimpMusic", Color(red: 0x8E / 255, green: 0xCA / 255, blue: 0xE6 / 255)),
        ("red", "Vermelho", Color(red: 0.98, green: 0.36, blue: 0.40)),
        ("green", "Verde", Color(red: 0.40, green: 0.85, blue: 0.55)),
        ("purple", "Roxo", Color(red: 0.72, green: 0.56, blue: 0.98)),
        ("orange", "Laranja", Color(red: 1.0, green: 0.65, blue: 0.30)),
        ("pink", "Rosa", Color(red: 1.0, green: 0.50, blue: 0.75)),
    ]
    static let body = Color(red: 0xA8 / 255, green: 0xA8 / 255, blue: 0xA8 / 255)

    static func poppins(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black, .semibold: name = "FzPoppins-Bold"
        case .medium: name = "FzPoppins-Medium"
        default: name = "FzPoppins-Regular"
        }
        return .custom(name, size: size)
    }

    // Typo.kt sizes
    static let headline = poppins(25, .bold)      // section titles
    static let titleLarge = poppins(23, .bold)    // player title
    static let titleMedium = poppins(18, .medium) // tile titles
    static let bodyMedium = poppins(14)
    static let bodySmall = poppins(13)
    static let labelSmall = poppins(11)
}

/// The dominant colour of an artwork, for the player background (the Compose app tints the
/// Now Playing screen from the cover's palette the same way).
@MainActor
final class ArtworkColor: ObservableObject {
    static let shared = ArtworkColor()
    @Published private(set) var color: Color = Theme.surface
    private var loadedFor: URL?
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func update(_ url: URL?) {
        guard let url, url != loadedFor else { return }
        loadedFor = url
        Task {
            guard let (data, _) = try? await Net.session.data(from: url), let image = CIImage(data: data) else { return }
            let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])
            guard let output = filter?.outputImage else { return }
            var px = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            guard loadedFor == url else { return }
            // Darkened and slightly saturated so white text always reads on it.
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let tuned = UIColor(hue: h, saturation: min(1, s * 1.25), brightness: min(b, 0.55), alpha: 1)
            withAnimation(.easeInOut(duration: 0.6)) { color = Color(tuned) }
        }
    }
}
