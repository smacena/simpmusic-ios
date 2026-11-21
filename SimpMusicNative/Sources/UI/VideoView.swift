import AVFoundation
import SwiftUI
import UIKit

/// The music video picture. Detached from the player while the app is in the background, so
/// iOS keeps the sound playing instead of pausing a video nobody can see.
struct VideoView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        let center = NotificationCenter.default
        view.observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak view] _ in view?.playerLayer.player = nil },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak view] _ in view?.playerLayer.player = player },
        ]
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}
