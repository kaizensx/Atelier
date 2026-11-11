import Foundation

// MARK: - Typing sound synthesis
//
// Every typing sound Atelier plays is made here, from damped sines (the case and plate
// resonances) and filtered noise (the plastic and metal transients). Nothing is sampled or
// recorded. Buffers are rendered once per pack, a few variants per key class, and played as
// they are; the app adds a small random gain per press, so CPU at typing time is nil.

/// A typing sound pack. Raw values are stored in defaults; append, never rename.
public enum TypingVoice: String, CaseIterable, Identifiable, Sendable {
    case thock, click, typewriter, bubble
    case linear, tactile, topre, laptop, terminal

    public var id: String { rawValue }

    /// The order the picker shows them in: switches first, then the characters.
    public static let ordered: [TypingVoice] = [.thock, .linear, .tactile, .click, .topre, .laptop, .typewriter, .terminal, .bubble]

    public var title: String {
        switch self {
        case .thock: "Thock"
        case .linear: "Linear"
        case .tactile: "Tactile"
        case .click: "Clicky"
        case .topre: "Topre"
        case .laptop: "Laptop"
        case .typewriter: "Typewriter"
        case .terminal: "Terminal"
        case .bubble: "Bubble"
        }
    }

    public var detail: String {
        switch self {
        case .thock: "Deep and lubed, a heavy board."
        case .linear: "Smooth red switches, a clean clack."
        case .tactile: "Brown switches: a soft bump, then the bottom."
        case .click: "Blue switches: a crisp click on every key."
        case .topre: "Rubber domes under a spring: a muted thock."
        case .laptop: "Quiet scissor keys, short and light."
        case .typewriter: "Type bars on a platen. Return rings the bell."
        case .terminal: "Buckling springs with their metal ping."
        case .bubble: "Soft rising pops."
        }
    }

    /// The pitch the plate's waveform and rings are drawn from.
    public var pitch: Double {
        switch self {
        case .thock: 160
        case .linear: 480
        case .tactile: 380
        case .click: 3600
        case .topre: 260
        case .laptop: 1600
        case .typewriter: 1180
        case .terminal: 2450
        case .bubble: 520
        }
    }

    /// How long one key press rings, in seconds, for the plate.
    public var ring: Double { TypingSynth.length(self, .key) }
}

/// Which sound a key makes. Real boards sound different under the big keys.
public enum TypingKeyClass: Int, CaseIterable, Sendable {
    case key, space, returnKey, backspace, modifier

    /// Carbon virtual key codes (kVK_*), kept as numbers so DockCore needs no Carbon.
    public static func of(keyCode: Int) -> TypingKeyClass {
        switch keyCode {
        case 49: .space
        case 36, 76: .returnKey
        case 51, 117: .backspace
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63: .modifier
        default: .key
        }
    }

    /// The device-independent modifier bit a flagsChanged key code sets, or nil.
    /// Caps Lock (57) toggles, so it counts as pressed whenever it changes.
    public static func modifierMask(keyCode: Int) -> UInt? {
        switch keyCode {
        case 56, 60: 1 << 17   // Shift
        case 59, 62: 1 << 18   // Control
        case 58, 61: 1 << 19   // Option
        case 54, 55: 1 << 20   // Command
        case 63: 1 << 23       // Fn
        default: nil
        }
    }
}

public enum TypingSynth {
    public static let sampleRate = 48_000.0
    /// Pre-rendered variants per key class; one is picked at random per press.
    public static let variants = 6

    /// The loudest sample a rendered buffer reaches. Several keys overlap while typing fast,
    /// so single buffers stay well under full scale.
    public static func peak(_ voice: TypingVoice, _ kind: TypingKeyClass) -> Float {
        let base: Float = switch kind {
        case .key, .backspace: 0.5
        case .space, .returnKey: 0.55
        case .modifier: 0.36
        }
        let pack: Float = switch voice {
        case .laptop: 0.75
        case .bubble: 0.8
        case .typewriter where kind == .returnKey: 0.62 / 0.55
        default: 1
        }
        return base * pack
    }

    /// Seconds.
    public static func length(_ voice: TypingVoice, _ kind: TypingKeyClass) -> Double {
        let base: Double = switch voice {
        case .thock: 0.12
        case .linear: 0.1
        case .tactile: 0.11
        case .click: 0.11
        case .topre: 0.12
        case .laptop: 0.055
        case .typewriter: 0.2
        case .terminal: 0.26
        case .bubble: 0.09
        }
        if voice == .typewriter, kind == .returnKey { return 1.1 }
        switch kind {
        case .space: return base * 1.3
        case .returnKey: return base * 1.15
        case .modifier: return base * 0.9
        default: return base
        }
    }

    /// Renders every variant of every class of a pack: `[class.rawValue][variant]`.
    public static func renderPack(_ voice: TypingVoice, sampleRate: Double = sampleRate) -> [[[Float]]] {
        TypingKeyClass.allCases.map { kind in (0..<variants).map { render(voice, kind, variant: $0, sampleRate: sampleRate) } }
    }

    /// One buffer, mono, peak-normalised to `peak(voice, kind)`, faded at both ends.
    public static func render(_ voice: TypingVoice, _ kind: TypingKeyClass, variant: Int, sampleRate: Double = sampleRate) -> [Float] {
        var voiceSeed = UInt64(0x9E37_79B9)
        for byte in voice.rawValue.utf8 { voiceSeed = voiceSeed &* 31 &+ UInt64(byte) }
        var random = TypingRandom(seed: voiceSeed &+ UInt64(kind.rawValue) &* 1_000_003 &+ UInt64(variant) &* 7919)
        var synth = Voice(count: Int(length(voice, kind) * sampleRate), sampleRate: sampleRate, random: random.next())
        // Each press differs a little: pitch within ±3 %, levels within ±12 %.
        let detune = 1 + (random.unit() - 0.5) * 0.06
        let pitch: Double = detune * {
            switch kind {
            case .key: 1
            case .space: 0.72
            case .returnKey: 0.85
            case .backspace: 0.93
            case .modifier: 1.08
            }
        }()
        synth.pitch = pitch
        synth.jitter = { 1 + (random.unit() - 0.5) * 0.24 }
        recipe(voice, kind, &synth)
        return synth.finish(peak: peak(voice, kind))
    }

    // MARK: Recipes

    private static func recipe(_ voice: TypingVoice, _ kind: TypingKeyClass, _ s: inout Voice) {
        let big = kind == .space || kind == .returnKey
        switch voice {
        case .thock:
            s.mode(160, decay: 42, amp: 1)
            s.mode(420, decay: 95, amp: 0.32)
            s.noise(amp: 0.5, decay: 120, lowpass: 1800)
            if big { rattle(&s, lowpass: 2200) }
            s.mode(210, decay: 85, amp: 0.22, at: 0.055)
            s.noise(amp: 0.14, decay: 220, lowpass: 2600, at: 0.055)
        case .linear:
            s.mode(480, decay: 70, amp: 0.6)
            s.mode(1250, decay: 140, amp: 0.28)
            s.noise(amp: 0.8, decay: 260, lowpass: 4500, highpass: 300)
            if big { rattle(&s, lowpass: 3500) }
            s.noise(amp: 0.3, decay: 320, lowpass: 5000, highpass: 300, at: 0.045)
            s.mode(900, decay: 160, amp: 0.14, at: 0.045)
        case .tactile:
            // The bump, then the bottom-out a few milliseconds later.
            s.noise(amp: 0.25, decay: 420, lowpass: 2500, attack: 0.0015)
            s.mode(380, decay: 75, amp: 0.55, at: 0.009)
            s.mode(1050, decay: 150, amp: 0.24, at: 0.009)
            s.noise(amp: 0.6, decay: 230, lowpass: 3500, highpass: 250, at: 0.009)
            if big { rattle(&s, lowpass: 3000, from: 0.014) }
            s.noise(amp: 0.2, decay: 300, lowpass: 4000, at: 0.052)
        case .click:
            // The click jacket snaps twice, then the stem bottoms out.
            s.noise(amp: 1, decay: 900, lowpass: 9000, highpass: 2500)
            s.mode(3600, decay: 520, amp: 0.34)
            s.noise(amp: 0.5, decay: 1000, lowpass: 9000, highpass: 2800, at: 0.007)
            s.mode(520, decay: 90, amp: 0.34, at: 0.014)
            s.noise(amp: 0.4, decay: 250, lowpass: 4000, at: 0.014)
            if big { rattle(&s, lowpass: 3500, from: 0.018) }
            s.noise(amp: 0.45, decay: 900, lowpass: 9000, highpass: 2500, at: 0.06)
        case .topre:
            // A rubber dome softens the attack and swallows the highs.
            s.mode(260, decay: 55, amp: 0.9, attack: 0.0015)
            s.mode(620, decay: 120, amp: 0.3, attack: 0.0015)
            s.noise(amp: 0.35, decay: 150, lowpass: 1200, attack: 0.001)
            if big { rattle(&s, lowpass: 1600) }
            s.mode(300, decay: 100, amp: 0.2, at: 0.06, attack: 0.002)
        case .laptop:
            s.noise(amp: 0.6, decay: 450, lowpass: 3000, highpass: 400)
            s.mode(1600, decay: 220, amp: 0.25)
            s.mode(700, decay: 180, amp: 0.25)
        case .typewriter:
            if kind == .returnKey {
                // The bell, then the carriage running back on its ratchet and stopping.
                s.mode(2093, decay: 4.5, amp: 0.7, pitched: false)
                s.mode(2093 * 2.76, decay: 7, amp: 0.3, pitched: false)
                s.mode(2093 * 5.4, decay: 10, amp: 0.15, pitched: false)
                s.noise(amp: 0.25, decay: 1200, lowpass: 8000, highpass: 2000)
                var t = 0.16, level = 0.5
                while t < 0.5 {
                    s.noise(amp: level, decay: 700, lowpass: 6000, highpass: 900, at: t)
                    t += 0.011; level *= 0.96
                }
                s.noise(amp: 0.18, decay: 6, lowpass: 600, at: 0.16, attack: 0.03)
                s.mode(120, decay: 40, amp: 0.7, at: 0.52)
                s.noise(amp: 0.5, decay: 200, lowpass: 2500, at: 0.52)
            } else if kind == .space {
                // The escapement steps, no type bar.
                s.mode(110, decay: 50, amp: 0.7)
                for (i, t) in [0.0, 0.018, 0.036].enumerated() {
                    s.noise(amp: 0.6 - Double(i) * 0.15, decay: 800, lowpass: 7000, highpass: 1200, at: t)
                }
            } else {
                // The type bar strikes the platen: a hard tick, metal ringing, a thump.
                s.noise(amp: 1, decay: 500, lowpass: 10000, highpass: 1500)
                s.mode(1180, decay: 45, amp: 0.25)
                s.mode(2730, decay: 60, amp: 0.18)
                s.mode(4150, decay: 80, amp: 0.12)
                s.mode(140, decay: 60, amp: 0.6)
                s.noise(amp: 0.35, decay: 700, lowpass: 7000, highpass: 1200, at: 0.03)
            }
        case .terminal:
            // A buckling spring: the click, the spring's metal ping, the bottom-out, the return.
            s.noise(amp: 0.9, decay: 700, lowpass: 9000, highpass: 2000)
            s.mode(2450, decay: 18, amp: 0.16)
            s.mode(3900, decay: 26, amp: 0.09)
            s.mode(300, decay: 60, amp: 0.5, at: 0.004)
            s.noise(amp: 0.5, decay: 200, lowpass: 2500, at: 0.004)
            if big { rattle(&s, lowpass: 3500, from: 0.008) }
            s.noise(amp: 0.4, decay: 700, lowpass: 9000, highpass: 2000, at: 0.07)
            s.mode(2450, decay: 22, amp: 0.07, at: 0.07)
        case .bubble:
            s.glide(520, to: 520 * 1.6, over: 0.025, decay: 45, amp: 1)
            s.glide(1040, to: 1040 * 1.6, over: 0.025, decay: 90, amp: 0.18)
            s.noise(amp: 0.12, decay: 1500, lowpass: 10000, highpass: 3000)
        }
    }

    /// Stabiliser wires under a long key: two small knocks just after the press.
    private static func rattle(_ s: inout Voice, lowpass: Double, from start: Double = 0) {
        s.noise(amp: 0.3, decay: 300, lowpass: lowpass, at: start + 0.005)
        s.noise(amp: 0.2, decay: 320, lowpass: lowpass, at: start + 0.011)
    }
}

// MARK: - The little synth

/// A float buffer with two kinds of sound added into it. Doubles inside, Float out.
private struct Voice {
    var out: [Double]
    let rate: Double
    var pitch = 1.0
    var jitter: () -> Double = { 1 }
    private var random: TypingRandom

    init(count: Int, sampleRate: Double, random seed: UInt64) {
        out = [Double](repeating: 0, count: max(count, 1))
        rate = sampleRate
        random = TypingRandom(seed: seed)
    }

    /// A damped sine: one resonance of the case, the plate or the stem.
    /// `pitched: false` keeps a bell in tune however the key class shifts the pack.
    mutating func mode(_ frequency: Double, decay: Double, amp: Double, at start: Double = 0,
                       attack: Double = 0.0003, pitched: Bool = true) {
        glide(frequency, to: frequency, over: 0, decay: decay, amp: amp, at: start, attack: attack, pitched: pitched)
    }

    /// A damped sine whose pitch slides, for bubbles.
    mutating func glide(_ from: Double, to: Double, over: Double, decay: Double, amp: Double,
                        at start: Double = 0, attack: Double = 0.0003, pitched: Bool = true) {
        let scale = pitched ? pitch : 1
        let level = amp * jitter()
        let first = Int(start * rate)
        guard first < out.count else { return }
        var phase = random.unit() * 0.2
        let nyquist = rate * 0.45
        for i in first..<out.count {
            let t = Double(i - first) / rate
            let slide = over > 0 ? min(t / over, 1) : 1
            let f = min((from + (to - from) * slide) * scale, nyquist)
            phase += 2 * .pi * f / rate
            let envelope = exp(-t * decay) * min(t / attack, 1)
            if envelope < 1e-5, t > attack { break }
            out[i] += sin(phase) * envelope * level
        }
    }

    /// A burst of filtered noise: plastic, metal or felt, depending on the band.
    mutating func noise(amp: Double, decay: Double, lowpass: Double, highpass: Double = 0,
                        at start: Double = 0, attack: Double = 0.0002) {
        let level = amp * jitter()
        let first = Int(start * rate)
        guard first < out.count else { return }
        let cutoff = min(lowpass * pitch.squareRoot(), rate * 0.45)
        let a = 1 - exp(-2 * .pi * cutoff / rate)
        let h = highpass > 0 ? 1 - exp(-2 * .pi * highpass * pitch.squareRoot() / rate) : 0
        var low1 = 0.0, low2 = 0.0, base = 0.0
        for i in first..<out.count {
            let t = Double(i - first) / rate
            let envelope = exp(-t * decay) * min(t / attack, 1)
            if envelope < 1e-5, t > attack { break }
            let white = random.unit() * 2 - 1
            low1 += a * (white - low1)
            low2 += a * (low1 - low2)
            var sample = low2
            if h > 0 { base += h * (sample - base); sample -= base }
            out[i] += sample * envelope * level * 2.2
        }
    }

    /// Takes out any offset, normalises to `peak`, and fades the ends so nothing clicks.
    func finish(peak: Float) -> [Float] {
        var samples = out
        // A one-pole high-pass at 30 Hz removes the slow offset a glide or a thump leaves.
        let h = 1 - exp(-2 * .pi * 30 / rate)
        var base = 0.0
        for i in samples.indices { base += h * (samples[i] - base); samples[i] -= base }
        let fadeOut = min(Int(0.004 * rate), samples.count / 4)
        for k in 0..<fadeOut { samples[samples.count - 1 - k] *= Double(k) / Double(fadeOut) }
        let loudest = samples.reduce(0) { max($0, abs($1)) }
        let gain = loudest > 0 ? Double(peak) / loudest : 0
        return samples.map { Float($0 * gain) }
    }
}

/// A tiny deterministic generator, so a pack sounds the same on every launch and in tests.
struct TypingRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 ..< 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
