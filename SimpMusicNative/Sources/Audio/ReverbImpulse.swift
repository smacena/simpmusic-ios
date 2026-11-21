import Foundation

/// The four rooms, with the same parameters (and seeds) as SimpMusic's ReverbImpulseResponse, so
/// a reverb setting sounds identical on every platform.
enum ReverbPreset: String, CaseIterable, Identifiable {
    case room, hall, plate, cathedral
    var id: String { rawValue }

    var title: String {
        switch self {
        case .room: "Sala"
        case .hall: "Salão"
        case .plate: "Placa"
        case .cathedral: "Catedral"
        }
    }

    var rt60Ms: Int { switch self { case .room: 600; case .hall: 2200; case .plate: 1500; case .cathedral: 4000 } }
    var preDelayMs: Int { switch self { case .room: 5; case .hall: 20; case .plate: 0; case .cathedral: 30 } }
    var dampingHz: Double { switch self { case .room: 6000; case .hall: 4500; case .plate: 9000; case .cathedral: 3000 } }
    var seed: UInt64 {
        switch self {
        case .room: 0x2F6E_5B1D_4C3A_9187
        case .hall: 0x51A7_C3E9_B2D4_0F63
        case .plate: 0x7B39_D85F_6C1E_2A4D
        case .cathedral: 0x4C8E_1F72_A560_D3B9
        }
    }
}

/// Generated stereo impulse responses: band-limited noise under an exponential envelope whose
/// low-pass falls two octaves over the RT60, plus five early reflections, each channel scaled to
/// unit energy. A port of ReverbImpulseResponse.kt (xorshift64*, Box–Muller), sample for sample.
enum ReverbImpulse {
    static func generate(_ preset: ReverbPreset, sampleRate: Int) -> (left: [Float], right: [Float]) {
        let rate = max(sampleRate, 1)
        let lengthMs = min(preset.preDelayMs + preset.rt60Ms, 4000)
        let total = max(1, lengthMs * rate / 1000)
        let preDelay = min(max(preset.preDelayMs * rate / 1000, 0), total - 1)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        var rngL = Xorshift64Star(seed: preset.seed)
        var rngR = Xorshift64Star(seed: preset.seed ^ 0x6A09_E667_F3BC_C909)
        renderTail(&left, preDelay, preset, rate, &rngL)
        renderTail(&right, preDelay, preset, rate, &rngR)
        addEarlyReflections(&left, &right, preDelay, preset, rate)
        normalise(&left)
        normalise(&right)
        return (left, right)
    }

    private static func renderTail(_ frames: inout [Float], _ preDelay: Int, _ preset: ReverbPreset, _ rate: Int, _ rng: inout Xorshift64Star) {
        let rt60 = Double(max(preset.rt60Ms, 1)) / 1000
        let envelopeRate = -6.907 / rt60
        let dampingRate = -1.3862943611198906 / rt60
        let twoPiOverRate = 2 * Double.pi / Double(rate)
        var lowPassed = 0.0
        for i in preDelay ..< frames.count {
            let seconds = Double(i - preDelay) / Double(rate)
            let cutoff = preset.dampingHz * exp(dampingRate * seconds)
            let coefficient = 1 - exp(-twoPiOverRate * cutoff)
            lowPassed += coefficient * (rng.nextGaussian() - lowPassed)
            frames[i] = Float(lowPassed * exp(envelopeRate * seconds))
        }
    }

    private static func addEarlyReflections(_ left: inout [Float], _ right: inout [Float], _ preDelay: Int, _ preset: ReverbPreset, _ rate: Int) {
        let count = 5
        let slice = (50 * rate / 1000) / count
        guard slice > 0 else { return }
        var rng = Xorshift64Star(seed: preset.seed ^ 0x3C6E_F372_FE94_F82B)
        var offsets = [Int](repeating: 0, count: count)
        var gains = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            offsets[i] = i * slice + Int(rng.nextDouble() * Double(slice))
            let magnitude = 0.8 * exp(-0.35 * Double(i))
            gains[i] = Float(magnitude * (2 * rng.nextDouble() - 1))
        }
        for i in 0 ..< count {
            let p = preDelay + offsets[i]
            if p >= left.count { break }
            left[p] += gains[i]
            right[p] += gains[count - 1 - i]
        }
    }

    private static func normalise(_ frames: inout [Float]) {
        var energy = 0.0
        for s in frames { energy += Double(s) * Double(s) }
        guard energy > 0 else { return }
        let scale = Float(1 / energy.squareRoot())
        for i in frames.indices { frames[i] *= scale }
    }
}

private struct Xorshift64Star {
    private var state: UInt64
    private var spare = 0.0
    private var hasSpare = false

    init(seed: UInt64) { state = seed == 0 ? 0x1066_89D4_5497_FDB5 : seed }

    private mutating func nextLong() -> UInt64 {
        var x = state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state = x
        return x &* 0x2545_F491_4F6C_DD1D
    }

    mutating func nextDouble() -> Double { Double(nextLong() >> 11) * (1.0 / 9_007_199_254_740_992.0) }

    mutating func nextGaussian() -> Double {
        if hasSpare { hasSpare = false; return spare }
        let radius = (-2 * log(1 - nextDouble())).squareRoot()
        let angle = 2 * Double.pi * nextDouble()
        spare = radius * sin(angle)
        hasSpare = true
        return radius * cos(angle)
    }
}
