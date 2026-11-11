import Foundation

// MARK: - Sound Mixer logic
//
// Everything the Sound Mixer decides that does not need Core Audio: how a volume slider maps to
// a gain (including the boost above 100 % and the soft limiter that keeps a boost from
// clipping), the 10-band EQ's biquad coefficients and its drawn response, the presets, which
// apps need a process tap at all, and the settings as they are stored.
//
// The rule that matters most lives in `SoundMixerPlanner`: an app at 100 %, unmuted, playing to
// the default output with no EQ is never tapped. Nothing is inserted into its path, so it costs
// nothing and adds no latency.

// MARK: Gain law

public enum SoundMixerGain {
    /// The slider's top: 150 %.
    public static let maxVolume = 1.5
    /// What 150 % adds, in dB. Between 100 % and 150 % the boost is linear in dB.
    public static let boostDB = 12.0
    /// Within this distance of 100 % the slider snaps to exactly 100 %, so "back to normal"
    /// is easy to hit and the app's tap can go away.
    public static let detent = 0.025
    /// Where the soft limiter starts bending the waveform: about −1 dBFS.
    public static let limiterThreshold: Float = 0.891

    /// The linear gain for a slider volume of 0…1.5.
    ///
    /// Below 100 % the taper is quadratic (−6 dB at 71 %, −12 dB at 50 %), close to how loudness
    /// is heard; a plain linear fader would crowd everything audible into its top quarter.
    /// Above 100 % every step is the same number of dB, up to `boostDB` at 150 %.
    public static func gain(forVolume volume: Double) -> Double {
        let v = min(max(volume, 0), maxVolume)
        if v <= 1 { return v * v }
        let db = boostDB * (v - 1) / (maxVolume - 1)
        return pow(10, db / 20)
    }

    /// The gain in dB, for the readout. −∞ at 0 % is reported as nil.
    public static func decibels(forVolume volume: Double) -> Double? {
        let g = gain(forVolume: volume)
        return g > 0 ? 20 * log10(g) : nil
    }

    /// The slider value after the 100 % detent.
    public static func snapped(_ volume: Double) -> Double {
        let v = min(max(volume, 0), maxVolume)
        return abs(v - 1) < detent ? 1 : v
    }

    /// Whether a volume leaves the sound exactly as the app made it.
    public static func isUnity(_ volume: Double) -> Bool { abs(volume - 1) < 1e-6 }

    /// A soft limiter: transparent below the threshold, then a tanh knee that approaches but
    /// never reaches full scale. Continuous and monotonic, so it bends peaks instead of
    /// clipping them, and it is never louder than its input.
    /// The limiter's ceiling, a hair under full scale so float rounding of the saturated
    /// knee can never land on 1.0 itself.
    public static let limiterCeiling: Float = 0.9995

    @inline(__always)
    public static func softLimit(_ x: Float, threshold t: Float = limiterThreshold) -> Float {
        let a = abs(x)
        guard a > t else { return x }
        let room = limiterCeiling - t
        let bent = t + room * tanh((a - t) / room)
        return x < 0 ? -bent : bent
    }

    /// The per-sample step of a gain ramp from `current` to `target` across one buffer, so a
    /// slider move never clicks. A change takes at least `minimumFrames` samples (10 ms at
    /// 48 kHz by default); a long buffer reaches the target within the buffer.
    public static func rampStep(current: Float, target: Float, frames: Int, minimumFrames: Int = 480) -> Float {
        guard frames > 0 else { return 0 }
        return (target - current) / Float(max(frames, minimumFrames))
    }
}

// MARK: EQ

public enum EQBandKind: String, Codable, Sendable {
    case lowShelf, peaking, highShelf
}

/// One second-order section, normalised so a0 is 1. The order vDSP_biquad wants: b0, b1, b2, a1, a2.
public struct Biquad: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Passes everything unchanged.
    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public var vDSPOrder: [Double] { [b0, b1, b2, a1, a2] }

    /// Both poles strictly inside the unit circle (the stability triangle).
    public var isStable: Bool { abs(a2) < 1 && abs(a1) < 1 + a2 }

    /// |H(e^jω)| at a frequency.
    public func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        // z^-1 = cos w − j sin w
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let den = dr * dr + di * di
        guard den > 0 else { return 0 }
        return sqrt((nr * nr + ni * ni) / den)
    }
}

public enum SoundEQ {
    /// The ten ISO octave centres.
    public static let frequencies: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    public static let bandCount = 10
    public static let gainRange: ClosedRange<Double> = -12...12
    /// One octave wide: neighbouring bands overlap enough that a row of equal sliders draws a
    /// line level within about 1 dB, and each band's centre stays close to its slider.
    public static let q = 1.414
    /// Below this, a band counts as off.
    public static let flatTolerance = 0.05

    public static func kind(ofBand index: Int) -> EQBandKind {
        index == 0 ? .lowShelf : (index == bandCount - 1 ? .highShelf : .peaking)
    }

    /// Ten gains, clamped to the range; missing bands are 0, extra ones dropped.
    public static func normalized(_ gains: [Double]) -> [Double] {
        (0..<bandCount).map { i in i < gains.count && gains[i].isFinite ? min(max(gains[i], gainRange.lowerBound), gainRange.upperBound) : 0 }
    }

    public static func isFlat(_ gains: [Double]) -> Bool {
        gains.allSatisfy { abs($0) < flatTolerance }
    }

    /// RBJ Audio-EQ-Cookbook coefficients for one band. The frequency is held below 45 % of the
    /// sample rate, so the 16 kHz band stays a valid filter at 32 kHz and below.
    public static func coefficients(kind: EQBandKind, frequency: Double, gainDB: Double,
                                    q: Double = SoundEQ.q, sampleRate: Double) -> Biquad {
        guard sampleRate > 0, abs(gainDB) >= 1e-9 else { return .identity }
        let f = min(max(frequency, 1), sampleRate * 0.45)
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let cw = cos(w0), sw = sin(w0)
        var b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peaking:
            let alpha = sw / (2 * q)
            b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
        case .lowShelf, .highShelf:
            // Shelf slope S = 1: the steepest slope with no overshoot.
            let alpha = sw / 2 * sqrt(2)
            let ra = 2 * sqrt(a) * alpha
            if kind == .lowShelf {
                b0 = a * ((a + 1) - (a - 1) * cw + ra)
                b1 = 2 * a * ((a - 1) - (a + 1) * cw)
                b2 = a * ((a + 1) - (a - 1) * cw - ra)
                a0 = (a + 1) + (a - 1) * cw + ra
                a1 = -2 * ((a - 1) + (a + 1) * cw)
                a2 = (a + 1) + (a - 1) * cw - ra
            } else {
                b0 = a * ((a + 1) + (a - 1) * cw + ra)
                b1 = -2 * a * ((a - 1) + (a + 1) * cw)
                b2 = a * ((a + 1) + (a - 1) * cw - ra)
                a0 = (a + 1) - (a - 1) * cw + ra
                a1 = 2 * ((a - 1) - (a + 1) * cw)
                a2 = (a + 1) - (a - 1) * cw - ra
            }
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// The ten sections for a curve.
    public static func cascade(gains: [Double], sampleRate: Double) -> [Biquad] {
        let g = normalized(gains)
        return (0..<bandCount).map { i in
            coefficients(kind: kind(ofBand: i), frequency: frequencies[i], gainDB: g[i], sampleRate: sampleRate)
        }
    }

    /// 50 doubles, ready for vDSP_biquad_CreateSetup / SetCoefficientsDouble.
    public static func vDSPCoefficients(gains: [Double], sampleRate: Double) -> [Double] {
        cascade(gains: gains, sampleRate: sampleRate).flatMap(\.vDSPOrder)
    }

    /// The cascade's response in dB at one frequency: what the curve drawing plots.
    public static func responseDB(gains: [Double], frequency: Double, sampleRate: Double = 48000) -> Double {
        let m = cascade(gains: gains, sampleRate: sampleRate).reduce(1.0) { $0 * $1.magnitude(at: frequency, sampleRate: sampleRate) }
        return 20 * log10(max(m, 1e-9))
    }

    /// The response sampled on a log axis from 20 Hz to 20 kHz.
    public static func responseCurve(gains: [Double], points: Int = 128, sampleRate: Double = 48000) -> [(frequency: Double, db: Double)] {
        let sections = cascade(gains: gains, sampleRate: sampleRate)
        let n = max(points, 2)
        return (0..<n).map { i in
            let f = logFrequency(Double(i) / Double(n - 1))
            let m = sections.reduce(1.0) { $0 * $1.magnitude(at: f, sampleRate: sampleRate) }
            return (f, 20 * log10(max(m, 1e-9)))
        }
    }

    /// 0…1 across the log axis 20 Hz…20 kHz, and back.
    public static func logFrequency(_ position: Double) -> Double { 20 * pow(1000, min(max(position, 0), 1)) }
    public static func logPosition(_ frequency: Double) -> Double { log10(max(frequency, 20) / 20) / 3 }

    /// The curve's highest point, in dB. Neighbouring boosts add up, so this can be above the
    /// highest slider.
    public static func peakResponseDB(gains: [Double], sampleRate: Double = 48000) -> Double {
        responseCurve(gains: gains, points: 96, sampleRate: sampleRate).map(\.db).max() ?? 0
    }

    /// Headroom taken before a boosting curve: half its highest point. Cut-only curves keep
    /// their level. The limiter catches whatever peaks remain.
    public static func preampDB(gains: [Double], sampleRate: Double = 48000) -> Double {
        guard (normalized(gains).max() ?? 0) > flatTolerance else { return 0 }
        return -max(peakResponseDB(gains: gains, sampleRate: sampleRate), 0) / 2
    }
}

// MARK: Presets

public enum EQPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case flat, bassBoost, bassCut, trebleBoost, vocal, spokenWord, loudness, electronic, acoustic, classical, rock, lateNight, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass Boost"
        case .bassCut: "Bass Cut"
        case .trebleBoost: "Treble Boost"
        case .vocal: "Vocal"
        case .spokenWord: "Spoken Word"
        case .loudness: "Loudness"
        case .electronic: "Electronic"
        case .acoustic: "Acoustic"
        case .classical: "Classical"
        case .rock: "Rock"
        case .lateNight: "Late Night"
        case .custom: "Custom"
        }
    }

    /// The preset's curve, 31 Hz to 16 kHz. Custom has none of its own.
    public var gains: [Double]? {
        switch self {
        case .flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost: [6, 5, 3.5, 2, 0.5, 0, 0, 0, 0, 0]
        case .bassCut: [-6, -5, -3.5, -2, -0.5, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 0.5, 2, 3.5, 5, 6]
        case .vocal: [-2, -2, -1, 0.5, 2.5, 3.5, 3, 1.5, 0, -1]
        case .spokenWord: [-5, -3.5, -1, 0, 1.5, 3, 3.5, 2.5, 0.5, -2]
        case .loudness: [5, 4, 1.5, 0, -1, -0.5, 0, 1.5, 3.5, 4.5]
        case .electronic: [4.5, 4, 1.5, 0, -1.5, 1, 0.5, 1.5, 4, 4.5]
        case .acoustic: [3.5, 3.5, 2.5, 1, 1.5, 1.5, 2.5, 3, 2.5, 1.5]
        case .classical: [3.5, 3, 2.5, 1.5, -1, -1, 0, 2, 3, 3.5]
        case .rock: [4.5, 3.5, 2, 0.5, -1, -1, 0.5, 2.5, 3.5, 4]
        case .lateNight: [-4, -3, -1.5, 0, 1, 1.5, 1, -0.5, -2, -3]
        case .custom: nil
        }
    }

    /// The preset a curve matches exactly, or custom.
    public static func matching(_ gains: [Double]) -> EQPreset {
        let g = SoundEQ.normalized(gains)
        return allCases.first { preset in
            preset.gains.map { zip($0, g).allSatisfy { abs($0 - $1) < 0.01 } } ?? false
        } ?? .custom
    }
}

// MARK: Settings

/// What one app has been set to. Keyed by its bundle identifier.
public struct MixerAppRule: Codable, Equatable, Sendable {
    /// 0…1.5; 1 is the app's own level.
    public var volume: Double
    public var muted: Bool
    /// The output device's UID; nil follows the system default.
    public var deviceUID: String?

    public init(volume: Double = 1, muted: Bool = false, deviceUID: String? = nil) {
        self.volume = volume
        self.muted = muted
        self.deviceUID = deviceUID
    }

    /// Changes nothing: such a rule is not stored.
    public var isNeutral: Bool { SoundMixerGain.isUnity(volume) && !muted && deviceUID == nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = min(max(try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1, 0), SoundMixerGain.maxVolume)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
    }
}

public struct EQProfile: Codable, Equatable, Sendable {
    public var preset: EQPreset
    public var gains: [Double]

    public init(preset: EQPreset = .flat, gains: [Double]? = nil) {
        self.preset = preset
        self.gains = SoundEQ.normalized(gains ?? preset.gains ?? [])
    }

    public static let flat = EQProfile()

    public var isFlat: Bool { SoundEQ.isFlat(gains) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let gains = SoundEQ.normalized(try c.decodeIfPresent([Double].self, forKey: .gains) ?? [])
        self.gains = gains
        // An unknown preset name (from a newer version) falls back to what the curve matches.
        let name = try c.decodeIfPresent(String.self, forKey: .preset) ?? ""
        preset = EQPreset(rawValue: name) ?? EQPreset.matching(gains)
    }
}

public struct SoundMixerSettings: Codable, Equatable, Sendable {
    public var apps: [String: MixerAppRule]
    public var eqEnabled: Bool
    /// The curve every output uses unless it has its own.
    public var eq: EQProfile
    /// Output device UID → that device's own curve ("AirPods: Bass Cut, speakers: Loudness").
    public var deviceEQ: [String: EQProfile]

    public init(apps: [String: MixerAppRule] = [:], eqEnabled: Bool = false, eq: EQProfile = .flat,
                deviceEQ: [String: EQProfile] = [:]) {
        self.apps = apps
        self.eqEnabled = eqEnabled
        self.eq = eq
        self.deviceEQ = deviceEQ
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = (try? c.decodeIfPresent([String: MixerAppRule].self, forKey: .apps)) ?? [:]
        eqEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .eqEnabled)) ?? false
        eq = (try? c.decodeIfPresent(EQProfile.self, forKey: .eq)) ?? .flat
        deviceEQ = (try? c.decodeIfPresent([String: EQProfile].self, forKey: .deviceEQ)) ?? [:]
    }

    public func rule(for bundleID: String) -> MixerAppRule { apps[bundleID] ?? MixerAppRule() }

    /// Sets a rule; a neutral one is removed, so the stored settings only list real changes.
    public mutating func setRule(_ rule: MixerAppRule, for bundleID: String) {
        apps[bundleID] = rule.isNeutral ? nil : rule
    }

    /// The curve an output device uses: its own if it has one, the shared one otherwise.
    public func eqProfile(forDevice uid: String?) -> EQProfile {
        uid.flatMap { deviceEQ[$0] } ?? eq
    }

    /// The gains to run on a device, or nil when the EQ is off or flat there (no processing).
    public func activeEQ(forDevice uid: String?) -> [Double]? {
        guard eqEnabled else { return nil }
        let profile = eqProfile(forDevice: uid)
        return profile.isFlat ? nil : profile.gains
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decoded(_ data: Data?) -> SoundMixerSettings {
        data.flatMap { try? JSONDecoder().decode(SoundMixerSettings.self, from: $0) } ?? SoundMixerSettings()
    }
}

// MARK: Which apps own which processes

public enum MixerOwner {
    /// The app a sound-producing process belongs to. Browsers and Electron apps play from
    /// helpers ("com.google.Chrome.helper", WebKit's WebContent): the responsible process wins
    /// when it is a regular app, then the longest bundle-ID prefix that is one, then the
    /// process's own identity.
    public static func owner(bundleID: String?, responsibleBundleID: String?, regularApps: Set<String>) -> String? {
        if let bundleID, regularApps.contains(bundleID) { return bundleID }
        if let responsibleBundleID, regularApps.contains(responsibleBundleID) { return responsibleBundleID }
        if let bundleID {
            var parts = bundleID.split(separator: ".").map(String.init)
            while parts.count > 2 {
                parts.removeLast()
                let candidate = parts.joined(separator: ".")
                if regularApps.contains(candidate) { return candidate }
            }
        }
        return responsibleBundleID ?? bundleID
    }
}

// MARK: Planning taps

/// One process Core Audio knows about, reduced to what planning needs.
public struct MixerProcessInfo: Equatable, Sendable {
    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String?
    /// The app it belongs to (see `MixerOwner`); nil for anonymous system processes.
    public var owner: String?
    public var isRunningOutput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String?, owner: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.owner = owner
        self.isRunningOutput = isRunningOutput
    }
}

/// One tap + private aggregate + IOProc the engine should be running.
public struct MixerPipelinePlan: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Hashable, Sendable {
        /// Taps one app's processes and plays them, adjusted, to its output.
        case app(String)
        /// Taps everything except `processes` and plays it, EQ'd, to the default output.
        case global
    }

    public var kind: Kind
    /// Included processes for an app pipeline; excluded ones for the global one. Sorted.
    public var processes: [UInt32]
    /// The output it plays to, resolved (never "default").
    public var outputUID: String
    /// Linear gain after the volume law, 0 when muted.
    public var gain: Double
    /// EQ gains, or nil for none.
    public var eq: [Double]?

    public init(kind: Kind, processes: [UInt32], outputUID: String, gain: Double, eq: [Double]?) {
        self.kind = kind
        self.processes = processes
        self.outputUID = outputUID
        self.gain = gain
        self.eq = eq
    }

    public var id: String {
        switch kind {
        case .app(let bundleID): "app:" + bundleID
        case .global: "global"
        }
    }

    /// What cannot change without building the aggregate again. Processes are not part of it:
    /// a tap's process list can be changed in place.
    public var structureKey: String { id + "→" + outputUID }

    /// Whether the limiter has to run: anything that can push the signal above full scale.
    public var needsLimiter: Bool { gain > 1.0001 || (eq.map { ($0.max() ?? 0) > 0 } ?? false) }
}

public enum SoundMixerPlanner {
    /// The device an app's rule plays to: its own when that device is connected, else the default.
    public static func output(for rule: MixerAppRule, defaultUID: String, available: Set<String>) -> String {
        if let uid = rule.deviceUID, available.contains(uid) { return uid }
        return defaultUID
    }

    /// Whether an app needs its own tap. Volume 100 %, unmuted, on the default device: no.
    /// An app on the default output with the EQ on needs no tap of its own: the global tap
    /// runs the default device's curve over it.
    public static func needsOwnTap(_ rule: MixerAppRule, defaultUID: String, available: Set<String>) -> Bool {
        if rule.muted || !SoundMixerGain.isUnity(rule.volume) { return true }
        return output(for: rule, defaultUID: defaultUID, available: available) != defaultUID
    }

    /// Every pipeline the engine should run, sorted by id. Empty when off, when there is no
    /// default output, or when nothing differs from how macOS would play it.
    public static func plan(enabled: Bool, settings: SoundMixerSettings, processes: [MixerProcessInfo],
                            ownProcesses: [UInt32], defaultOutputUID: String?, outputUIDs: Set<String>) -> [MixerPipelinePlan] {
        guard enabled, let defaultUID = defaultOutputUID else { return [] }
        let own = Set(ownProcesses)
        var byOwner: [String: [UInt32]] = [:]
        for process in processes where !own.contains(process.objectID) {
            guard let owner = process.owner else { continue }
            byOwner[owner, default: []].append(process.objectID)
        }

        var plans: [MixerPipelinePlan] = []
        var tapped: [UInt32] = []
        for (bundleID, rule) in settings.apps.sorted(by: { $0.key < $1.key }) {
            guard let ids = byOwner[bundleID], !ids.isEmpty else { continue }
            let out = output(for: rule, defaultUID: defaultUID, available: outputUIDs)
            guard needsOwnTap(rule, defaultUID: defaultUID, available: outputUIDs) else { continue }
            // Its own pipeline runs the curve of the device it plays to.
            let eq = settings.activeEQ(forDevice: out)
            let gain = rule.muted ? 0 : SoundMixerGain.gain(forVolume: rule.volume)
            plans.append(MixerPipelinePlan(kind: .app(bundleID), processes: ids.sorted(), outputUID: out, gain: gain, eq: eq))
            tapped += ids
        }

        if let eq = settings.activeEQ(forDevice: defaultUID) {
            let excluded = Array(own.union(tapped)).sorted()
            plans.append(MixerPipelinePlan(kind: .global, processes: excluded, outputUID: defaultUID, gain: 1, eq: eq))
        }
        return plans.sorted { $0.id < $1.id }
    }
}
