import Foundation

/// Equalizer and Delay settings, stored on the device and published to the C audio chain.
/// Same filters and tap layout as the SimpMusic apps (ten peaking bands at 31.25·2^i Hz, Q 1.41;
/// ffmpeg aecho-style echo taps), so a curve sounds the same everywhere.
@MainActor
final class AudioEffects: ObservableObject {
    static let shared = AudioEffects()

    static let bandLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    static let presets: [(name: String, gains: [Double])] = [
        ("Plano", Array(repeating: 0, count: 10)),
        ("Graves", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Agudos", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Vocal", [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        ("Pop", [-1, 1, 3, 4, 3, 1, -1, -1, 1, 2]),
        ("Rock", [4, 3, 1, -1, -1, 1, 3, 4, 4, 4]),
        ("Eletrônica", [5, 4, 1, 0, -2, 1, 1, 2, 4, 5]),
    ]

    @Published var eqEnabled: Bool { didSet { save(); applyEqualizer() } }
    @Published var gains: [Double] { didSet { save(); applyEqualizer() } }
    @Published var preamp: Double { didSet { save(); applyEqualizer() } }
    @Published var delayEnabled: Bool { didSet { save(); applyDelay() } }
    @Published var delayTimeMs: Double { didSet { save(); applyDelay() } }
    @Published var delayFeedback: Double { didSet { save(); applyDelay() } }
    @Published var delayMix: Double { didSet { save(); applyDelay() } }
    @Published var reverbEnabled: Bool { didSet { save(); applyReverb() } }
    @Published var reverbPreset: ReverbPreset { didSet { save(); applyReverb() } }
    @Published var reverbMix: Double { didSet { save(); applyReverb() } }

    private let defaults = UserDefaults.standard

    private init() {
        eqEnabled = defaults.bool(forKey: "eq.enabled")
        gains = (defaults.array(forKey: "eq.gains") as? [Double]).flatMap { $0.count == 10 ? $0 : nil } ?? Array(repeating: 0, count: 10)
        preamp = defaults.double(forKey: "eq.preamp")
        delayEnabled = defaults.bool(forKey: "delay.enabled")
        delayTimeMs = defaults.object(forKey: "delay.time") as? Double ?? 300
        delayFeedback = defaults.object(forKey: "delay.feedback") as? Double ?? 0.35
        delayMix = defaults.object(forKey: "delay.mix") as? Double ?? 0.3
        reverbEnabled = defaults.bool(forKey: "reverb.enabled")
        reverbPreset = ReverbPreset(rawValue: defaults.string(forKey: "reverb.preset") ?? "") ?? .hall
        reverbMix = defaults.object(forKey: "reverb.mix") as? Double ?? 0.35
    }

    func applyStored() {
        applyEqualizer()
        applyDelay()
        applyReverb()
    }

    private func save() {
        defaults.set(eqEnabled, forKey: "eq.enabled")
        defaults.set(gains, forKey: "eq.gains")
        defaults.set(preamp, forKey: "eq.preamp")
        defaults.set(delayEnabled, forKey: "delay.enabled")
        defaults.set(delayTimeMs, forKey: "delay.time")
        defaults.set(delayFeedback, forKey: "delay.feedback")
        defaults.set(delayMix, forKey: "delay.mix")
        defaults.set(reverbEnabled, forKey: "reverb.enabled")
        defaults.set(reverbPreset.rawValue, forKey: "reverb.preset")
        defaults.set(reverbMix, forKey: "reverb.mix")
    }

    private var reverbGeneration = 0

    /// The impulse response and its spectra take tens of milliseconds: built off the main thread,
    /// and the reverb already playing keeps playing until the new one is swapped in.
    private func applyReverb() {
        reverbGeneration += 1
        guard reverbEnabled else {
            simp_reverb_set(nil, nil, 0, 0)
            return
        }
        let generation = reverbGeneration
        let preset = reverbPreset
        let mix = Float(min(max(reverbMix, 0), 1))
        let rate = Int(simp_sample_rate())
        Task.detached(priority: .utility) {
            let ir = ReverbImpulse.generate(preset, sampleRate: rate)
            let current = await MainActor.run { AudioEffects.shared.reverbGeneration }
            guard current == generation else { return }
            var left = ir.left, right = ir.right
            _ = simp_reverb_set(&left, &right, Int32(min(left.count, right.count)), mix)
        }
    }

    private func applyEqualizer() {
        if eqEnabled {
            var g = gains.map { min(max($0, -12), 12) }
            simp_eq_set(&g, Int32(g.count), min(max(preamp, -15), 15))
        } else {
            simp_eq_set(nil, 0, 0)
        }
    }

    /// aecho's feed-forward taps: echoes at k·T with decays mix·fb^k until about −26 dB, the dry
    /// path scaled by 1 − mix, and the sum normalised so it can never clip.
    private func applyDelay() {
        guard delayEnabled else {
            simp_echo_set(nil, nil, 0, 1, 1)
            return
        }
        let time = min(max(delayTimeMs, 20), 2000)
        let fb = min(max(delayFeedback, 0), 0.9)
        let wet = Float(min(max(delayMix, 0), 1))
        let count = fb <= 0 ? 1 : min(12, max(1, Int(ceil(log(0.05) / log(fb)))))
        var delays = (0 ..< count).map { time * Double($0 + 1) }
        var decays = (0 ..< count).map { max(wet * Float(pow(fb, Double($0 + 1))), 0.001) }
        let inGain = 1 - wet
        let outGain = 1 / max(1, inGain + decays.reduce(0, +))
        simp_echo_set(&delays, &decays, Int32(count), inGain, outGain)
    }
}
