import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var effects: AudioEffects
    @EnvironmentObject private var player: PlayerEngine
    @State private var normalize = PlayerEngine.shared.normalizeVolume

    var body: some View {
        Form {
            Section("Áudio") {
                Toggle("Normalizar volume", isOn: $normalize)
                    .onChange(of: normalize) { _, value in player.normalizeVolume = value }
            }
            Section("Equalizador") {
                Toggle("Ativado", isOn: $effects.eqEnabled)
                if effects.eqEnabled {
                    Picker("Predefinição", selection: Binding(
                        get: { AudioEffects.presets.firstIndex { $0.gains == effects.gains } ?? -1 },
                        set: { if AudioEffects.presets.indices.contains($0) { effects.gains = AudioEffects.presets[$0].gains } }
                    )) {
                        Text("Personalizado").tag(-1)
                        ForEach(AudioEffects.presets.indices, id: \.self) { Text(AudioEffects.presets[$0].name).tag($0) }
                    }
                    ForEach(0 ..< 10, id: \.self) { band in
                        HStack {
                            Text(AudioEffects.bandLabels[band]).font(.caption.monospacedDigit()).frame(width: 34, alignment: .leading)
                            Slider(value: Binding(get: { effects.gains[band] }, set: { effects.gains[band] = $0.rounded() }), in: -12 ... 12)
                            Text("\(Int(effects.gains[band]))").font(.caption.monospacedDigit()).frame(width: 28)
                        }
                    }
                }
            }
            Section("Eco (Delay)") {
                Toggle("Ativado", isOn: $effects.delayEnabled)
                if effects.delayEnabled {
                    LabeledSlider(title: "Tempo", value: $effects.delayTimeMs, range: 50 ... 1000, unit: "ms")
                    LabeledSlider(title: "Repetição", value: $effects.delayFeedback, range: 0 ... 0.9, unit: "")
                    LabeledSlider(title: "Mistura", value: $effects.delayMix, range: 0 ... 1, unit: "")
                }
            }
        }
        .navigationTitle("Ajustes")
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(title): \(unit == "ms" ? "\(Int(value)) ms" : String(format: "%.2f", value))").font(.caption)
            Slider(value: $value, in: range)
        }
    }
}
