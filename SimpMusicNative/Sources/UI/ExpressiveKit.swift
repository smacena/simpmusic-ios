import SwiftUI
import UIKit

/// A dark tonal colour scheme seeded from the artwork, after SimpMusic's M3 Expressive player
/// (rememberDynamicColorScheme(seed, isDark = true, style = Vibrant)): every role shares the
/// artwork's hue at a different tone/chroma.
struct TonalScheme {
    let background, surfaceContainerHigh, primary, onPrimary, primaryContainer, onPrimaryContainer: Color
    let secondaryContainer, onSecondaryContainer, onSurface, onSurfaceVariant: Color

    init(seed: Color) {
        var h: CGFloat = 0.55, s: CGFloat = 0.5, b: CGFloat = 0.5, a: CGFloat = 1
        UIColor(seed).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.08 { s = 0.08 } // grey covers still get a faint tint, like the Vibrant palette
        func tone(_ sat: CGFloat, _ bri: CGFloat) -> Color { Color(hue: h, saturation: min(1, sat), brightness: bri) }
        background = tone(s * 0.45, 0.11)
        surfaceContainerHigh = tone(s * 0.35, 0.22)
        primary = tone(max(0.35, s * 0.8), 0.92)
        onPrimary = tone(max(0.6, s), 0.24)
        primaryContainer = tone(max(0.5, s), 0.42)
        onPrimaryContainer = tone(0.22, 0.97)
        secondaryContainer = tone(s * 0.45, 0.32)
        onSecondaryContainer = tone(0.15, 0.93)
        onSurface = tone(0.05, 0.95)
        onSurfaceVariant = tone(0.10, 0.80)
    }
}

/// Seekable wavy progress bar (M3 Expressive): the played part ripples while playing and
/// flattens when paused or while scrubbing; the thumb morphs from a Ø14 circle to a 6×22 bar.
struct WavySeekBar: View {
    let fraction: Double
    let isPlaying: Bool
    let active: Color
    let track: Color
    let onSeek: (Double) -> Void
    @State private var dragging: Double?
    @State private var amplitude: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shown = min(1, max(0, dragging ?? fraction))
            let thumbW: CGFloat = dragging != nil ? 6 : 14
            let thumbH: CGFloat = dragging != nil ? 22 : 14
            ZStack(alignment: .leading) {
                TimelineView(.animation(paused: amplitude == 0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate * 2.4
                    Canvas { ctx, size in
                        let mid = size.height / 2
                        let playedEnd = max(0, size.width * shown - thumbW / 2 - 4)
                        var wave = Path()
                        wave.move(to: CGPoint(x: 0, y: mid))
                        var x: CGFloat = 0
                        while x <= playedEnd {
                            let y = mid + sin(x / 40 * .pi * 2 - phase) * 3 * amplitude
                            wave.addLine(to: CGPoint(x: x, y: y))
                            x += 1
                        }
                        ctx.stroke(wave, with: .color(active), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        let restStart = min(size.width, size.width * shown + thumbW / 2 + 4)
                        if restStart < size.width {
                            var rest = Path()
                            rest.move(to: CGPoint(x: restStart, y: mid))
                            rest.addLine(to: CGPoint(x: size.width, y: mid))
                            ctx.stroke(rest, with: .color(track), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        }
                    }
                }
                RoundedRectangle(cornerRadius: min(thumbW, thumbH) / 2)
                    .fill(active)
                    .frame(width: thumbW, height: thumbH)
                    .offset(x: (w - thumbW) * shown)
                    .animation(.easeInOut(duration: 0.25), value: dragging != nil)
            }
            .frame(height: 40)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragging = min(1, max(0, $0.location.x / max(w, 1))) }
                    .onEnded { _ in
                        if let d = dragging { onSeek(d) }
                        dragging = nil
                    }
            )
        }
        .frame(height: 40)
        .onAppear { amplitude = isPlaying ? 1 : 0 }
        .onChange(of: isPlaying) { _, playing in withAnimation(.easeInOut(duration: 0.4)) { amplitude = playing && dragging == nil ? 1 : 0 } }
        .onChange(of: dragging != nil) { _, drag in withAnimation(.easeInOut(duration: 0.3)) { amplitude = isPlaying && !drag ? 1 : 0 } }
    }
}

/// Transport: prev | play | next pills in a 68pt row (weights 0.55 / 1.2 / 0.55); the play
/// pill's corners morph 22 (playing) ↔ 34 (paused); a pressed pill grows ×1.15.
struct ExpressiveTransportRow: View {
    let scheme: TonalScheme
    let isPlaying: Bool
    let loading: Bool
    let onPrev: () -> Void
    let onPlay: () -> Void
    let onNext: () -> Void
    @State private var pressed: Int?

    var body: some View {
        GeometryReader { geo in
            let weights: [CGFloat] = [0.55, 1.2, 0.55].enumerated().map { $0.offset == pressed ? $0.element * 1.15 : $0.element }
            let total = weights.reduce(0, +)
            let usable = geo.size.width - 16
            HStack(spacing: 8) {
                pill(0, width: usable * weights[0] / total, corner: 34, fill: scheme.secondaryContainer, action: onPrev) {
                    Image(systemName: "backward.fill").font(.system(size: 26)).foregroundStyle(scheme.onSecondaryContainer)
                }
                pill(1, width: usable * weights[1] / total, corner: isPlaying ? 22 : 34, fill: scheme.primary, action: onPlay) {
                    if loading { ProgressView().tint(scheme.onPrimary) } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.system(size: 30)).foregroundStyle(scheme.onPrimary)
                    }
                }
                pill(2, width: usable * weights[2] / total, corner: 34, fill: scheme.secondaryContainer, action: onNext) {
                    Image(systemName: "forward.fill").font(.system(size: 26)).foregroundStyle(scheme.onSecondaryContainer)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressed)
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isPlaying)
        }
        .frame(height: 68)
    }

    private func pill<L: View>(_ i: Int, width: CGFloat, corner: CGFloat, fill: Color, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        label()
            .frame(width: width, height: 68)
            .background(fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, perform: action, onPressingChanged: { pressed = $0 ? i : nil })
    }
}

/// Connected button group: 48pt slots, 3pt gaps, rounded end caps (24 outer / 6 inner).
struct ConnectedGroup: View {
    struct Slot: Identifiable {
        let id = UUID()
        let icon: String
        var active = false
        var custom: AnyView? = nil
        let action: (() -> Void)?
    }
    let scheme: TonalScheme
    let slots: [Slot]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { i, slot in
                let shape = UnevenRoundedRectangle(
                    topLeadingRadius: i == 0 ? 24 : 6, bottomLeadingRadius: i == 0 ? 24 : 6,
                    bottomTrailingRadius: i == slots.count - 1 ? 24 : 6, topTrailingRadius: i == slots.count - 1 ? 24 : 6,
                    style: .continuous
                )
                Group {
                    if let custom = slot.custom { custom } else {
                        Image(systemName: slot.icon).font(.system(size: 19, weight: .medium))
                            .foregroundStyle(slot.active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(slot.active ? scheme.primaryContainer : scheme.surfaceContainerHigh, in: shape)
                .contentShape(shape)
                .onTapGesture { slot.action?() }
            }
        }
        .frame(height: 48)
    }
}
