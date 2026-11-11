import Foundation
import Testing
@testable import DockCore

// MARK: Gain law

@Test func mixerGainLawIsContinuousAndBoostsByDecibels() {
    #expect(SoundMixerGain.gain(forVolume: 0) == 0)
    #expect(abs(SoundMixerGain.gain(forVolume: 1) - 1) < 1e-12)
    #expect(abs(SoundMixerGain.gain(forVolume: 0.5) - 0.25) < 1e-12)          // −12 dB
    // 150 % is +12 dB; 125 % is half of that in dB.
    #expect(abs(20 * log10(SoundMixerGain.gain(forVolume: 1.5)) - SoundMixerGain.boostDB) < 1e-9)
    #expect(abs(20 * log10(SoundMixerGain.gain(forVolume: 1.25)) - SoundMixerGain.boostDB / 2) < 1e-9)
    // Out of range is clamped.
    #expect(SoundMixerGain.gain(forVolume: -1) == 0)
    #expect(SoundMixerGain.gain(forVolume: 9) == SoundMixerGain.gain(forVolume: 1.5))
    // Monotonic across the whole slider, and continuous through 100 %.
    var last = -1.0
    for i in 0...150 {
        let g = SoundMixerGain.gain(forVolume: Double(i) / 100)
        #expect(g > last)
        last = g
    }
    #expect(abs(SoundMixerGain.gain(forVolume: 1.0001) - SoundMixerGain.gain(forVolume: 0.9999)) < 1e-3)
    #expect(SoundMixerGain.decibels(forVolume: 0) == nil)
}

@Test func mixerSliderSnapsToUnity() {
    #expect(SoundMixerGain.snapped(0.98) == 1)
    #expect(SoundMixerGain.snapped(1.02) == 1)
    #expect(SoundMixerGain.snapped(0.9) == 0.9)
    #expect(SoundMixerGain.snapped(2) == 1.5)
    #expect(SoundMixerGain.isUnity(SoundMixerGain.snapped(1.01)))
}

@Test func softLimiterNeverClipsAndIsTransparentBelowThreshold() {
    #expect(SoundMixerGain.softLimit(0.5) == 0.5)
    #expect(SoundMixerGain.softLimit(-0.8) == -0.8)
    var last: Float = 0
    for i in 0...400 {
        let x = Float(i) / 100            // 0…4: up to +12 dB over full scale
        let y = SoundMixerGain.softLimit(x)
        #expect(y < 1)
        #expect(y <= x)
        #expect(y >= last)                // monotonic
        #expect(abs(SoundMixerGain.softLimit(-x) + y) < 1e-7)  // odd
        last = y
    }
    // Continuous at the knee.
    let t = SoundMixerGain.limiterThreshold
    #expect(abs(SoundMixerGain.softLimit(t + 1e-4) - (t + 1e-4)) < 1e-4)
}

@Test func gainRampReachesTargetWithoutJumps() {
    // A short buffer is spread over the minimum ramp, so one buffer never jumps all the way.
    let step = SoundMixerGain.rampStep(current: 0, target: 1, frames: 128)
    #expect(abs(step - 1 / 480) < 1e-9)
    var g: Float = 0
    for _ in 0..<4 { g += SoundMixerGain.rampStep(current: g, target: 1, frames: 128) * 128 }
    #expect(g > 0.6 && g <= 1)
    // A long buffer reaches the target in one go.
    let long = SoundMixerGain.rampStep(current: 1, target: 0.25, frames: 1024)
    #expect(abs(1 + long * 1024 - 0.25) < 1e-6)
    #expect(SoundMixerGain.rampStep(current: 1, target: 1, frames: 512) == 0)
    #expect(SoundMixerGain.rampStep(current: 0, target: 1, frames: 0) == 0)
}

// MARK: EQ maths

private let rates: [Double] = [44100, 48000, 96000]

@Test func peakingBandHitsItsGainAtItsCentre() {
    for rate in rates {
        for (i, f) in SoundEQ.frequencies.enumerated() where SoundEQ.kind(ofBand: i) == .peaking {
            for gain in [-12.0, -6, 3, 12] {
                let b = SoundEQ.coefficients(kind: .peaking, frequency: f, gainDB: gain, sampleRate: rate)
                #expect(b.isStable)
                let db = 20 * log10(b.magnitude(at: f, sampleRate: rate))
                #expect(abs(db - gain) < 0.01, "band \(f) Hz at \(rate): \(db) dB, wanted \(gain)")
                // Far away it leaves the signal alone.
                let far = 20 * log10(b.magnitude(at: f < 1000 ? f * 32 : f / 32, sampleRate: rate))
                #expect(abs(far) < 0.6)
            }
        }
    }
}

@Test func shelvesReachTheirGainAtTheEnds() {
    for rate in rates {
        let low = SoundEQ.coefficients(kind: .lowShelf, frequency: 31.25, gainDB: 6, sampleRate: rate)
        #expect(low.isStable)
        #expect(abs(20 * log10(low.magnitude(at: 1, sampleRate: rate)) - 6) < 0.05)
        #expect(abs(20 * log10(low.magnitude(at: 2000, sampleRate: rate))) < 0.05)
        // At the corner frequency a shelf is at half its gain in dB.
        #expect(abs(20 * log10(low.magnitude(at: 31.25, sampleRate: rate)) - 3) < 0.05)

        let high = SoundEQ.coefficients(kind: .highShelf, frequency: 16000, gainDB: -9, sampleRate: rate)
        #expect(high.isStable)
        #expect(abs(20 * log10(high.magnitude(at: 200, sampleRate: rate))) < 0.05)
        #expect(20 * log10(high.magnitude(at: rate * 0.49, sampleRate: rate)) < -4)
    }
}

@Test func zeroGainIsIdentityAndFlatCurveIsFlat() {
    for rate in rates {
        for kind in [EQBandKind.lowShelf, .peaking, .highShelf] {
            #expect(SoundEQ.coefficients(kind: kind, frequency: 1000, gainDB: 0, sampleRate: rate) == .identity)
        }
        for f in [20.0, 100, 1000, 10000, 20000] {
            #expect(abs(SoundEQ.responseDB(gains: EQPreset.flat.gains!, frequency: f, sampleRate: rate)) < 1e-9)
        }
    }
    #expect(SoundEQ.isFlat([0, 0.01, -0.02, 0, 0, 0, 0, 0, 0, 0]))
    #expect(!SoundEQ.isFlat([0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0]))
}

@Test func everyPresetIsStableAtEveryRate() {
    for rate in rates + [32000, 22050] {
        for preset in EQPreset.allCases {
            guard let gains = preset.gains else { continue }
            #expect(gains.count == SoundEQ.bandCount)
            for section in SoundEQ.cascade(gains: gains, sampleRate: rate) {
                #expect(section.isStable, "\(preset) at \(rate)")
                #expect([section.b0, section.b1, section.b2, section.a1, section.a2].allSatisfy { $0.isFinite })
            }
            #expect(SoundEQ.vDSPCoefficients(gains: gains, sampleRate: rate).count == 50)
        }
    }
    // Extreme curves stay stable too.
    for rate in rates {
        for g in [SoundEQ.gainRange.lowerBound, SoundEQ.gainRange.upperBound] {
            #expect(SoundEQ.cascade(gains: Array(repeating: g, count: 10), sampleRate: rate).allSatisfy { $0.isStable })
        }
    }
}

@Test func eqCurveFollowsTheSliders() {
    let gains = EQPreset.bassBoost.gains!
    #expect(SoundEQ.responseDB(gains: gains, frequency: 62.5) > 5)
    #expect(SoundEQ.responseDB(gains: gains, frequency: 40) > 3)
    #expect(abs(SoundEQ.responseDB(gains: gains, frequency: 5000)) < 0.5)
    let curve = SoundEQ.responseCurve(gains: gains, points: 64)
    #expect(curve.count == 64)
    #expect(abs(curve.first!.frequency - 20) < 1e-9 && abs(curve.last!.frequency - 20000) < 1e-6)
    #expect(abs(SoundEQ.logPosition(SoundEQ.logFrequency(0.37)) - 0.37) < 1e-12)
    // Out-of-range input is clamped, short arrays padded.
    #expect(SoundEQ.normalized([30, -40]) == [12, -12, 0, 0, 0, 0, 0, 0, 0, 0])
    #expect(SoundEQ.normalized([.nan]).first == 0)
}

@Test func preampLeavesHeadroomOnlyForBoosts() {
    #expect(SoundEQ.preampDB(gains: EQPreset.bassCut.gains!) == 0)
    #expect(SoundEQ.preampDB(gains: EQPreset.flat.gains!) == 0)
    let boost = EQPreset.bassBoost.gains!
    let peak = SoundEQ.peakResponseDB(gains: boost)
    #expect(peak >= 6)                                   // neighbouring boosts add up
    #expect(abs(SoundEQ.preampDB(gains: boost) + peak / 2) < 1e-9)
    // A row of equal sliders draws a level line, not a ripple, through the middle bands.
    let level = (0..<60).map { SoundEQ.responseDB(gains: Array(repeating: 3, count: 10), frequency: SoundEQ.logFrequency(0.15 + 0.6 * Double($0) / 59)) }
    #expect(level.max()! - level.min()! < 1.5)
}

@Test func presetMatchingRoundTrips() {
    for preset in EQPreset.allCases where preset != .custom {
        #expect(EQPreset.matching(preset.gains!) == preset)
    }
    #expect(EQPreset.matching([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) == .custom)
}

// MARK: Settings

@Test func settingsRoundTripAndTolerateOldData() throws {
    var settings = SoundMixerSettings()
    settings.setRule(MixerAppRule(volume: 0.4, muted: false, deviceUID: "AirPods-UID"), for: "com.spotify.client")
    settings.setRule(MixerAppRule(), for: "us.zoom.xos")                       // neutral: not stored
    settings.eqEnabled = true
    settings.eq = EQProfile(preset: .loudness)
    settings.deviceEQ["AirPods-UID"] = EQProfile(preset: .bassCut)
    #expect(settings.apps.count == 1)

    let back = SoundMixerSettings.decoded(settings.encoded())
    #expect(back == settings)

    // Missing keys, unknown presets and garbage all decode to something sane.
    #expect(SoundMixerSettings.decoded(Data("{}".utf8)) == SoundMixerSettings())
    #expect(SoundMixerSettings.decoded(Data("nonsense".utf8)) == SoundMixerSettings())
    #expect(SoundMixerSettings.decoded(nil) == SoundMixerSettings())
    let future = Data(#"{"eqEnabled":true,"eq":{"preset":"hyperBass","gains":[6,5,3.5,2,0.5,0,0,0,0,0]},"apps":{"a":{"volume":9}}}"#.utf8)
    let decoded = SoundMixerSettings.decoded(future)
    #expect(decoded.eq.preset == .bassBoost)
    #expect(decoded.apps["a"]?.volume == SoundMixerGain.maxVolume)
}

@Test func perDeviceEQFallsBackToTheSharedCurve() {
    var settings = SoundMixerSettings(eqEnabled: true, eq: EQProfile(preset: .vocal))
    settings.deviceEQ["speakers"] = EQProfile(preset: .flat)
    #expect(settings.activeEQ(forDevice: "headphones") == EQPreset.vocal.gains)
    #expect(settings.activeEQ(forDevice: nil) == EQPreset.vocal.gains)
    #expect(settings.activeEQ(forDevice: "speakers") == nil)                    // flat: nothing runs
    settings.eqEnabled = false
    #expect(settings.activeEQ(forDevice: "headphones") == nil)
}

// MARK: Owners

@Test func helperProcessesBelongToTheirApp() {
    let apps: Set = ["com.google.Chrome", "com.apple.Safari", "com.spotify.client"]
    #expect(MixerOwner.owner(bundleID: "com.spotify.client", responsibleBundleID: nil, regularApps: apps) == "com.spotify.client")
    #expect(MixerOwner.owner(bundleID: "com.google.Chrome.helper", responsibleBundleID: nil, regularApps: apps) == "com.google.Chrome")
    #expect(MixerOwner.owner(bundleID: "com.google.Chrome.helper.Renderer", responsibleBundleID: nil, regularApps: apps) == "com.google.Chrome")
    #expect(MixerOwner.owner(bundleID: "com.apple.WebKit.WebContent", responsibleBundleID: "com.apple.Safari", regularApps: apps) == "com.apple.Safari")
    #expect(MixerOwner.owner(bundleID: "com.apple.coreaudiod", responsibleBundleID: nil, regularApps: apps) == "com.apple.coreaudiod")
    #expect(MixerOwner.owner(bundleID: nil, responsibleBundleID: nil, regularApps: apps) == nil)
}

// MARK: Planning

private func process(_ id: UInt32, _ owner: String?, playing: Bool = true) -> MixerProcessInfo {
    MixerProcessInfo(objectID: id, pid: Int32(id) + 1000, bundleID: owner, owner: owner, isRunningOutput: playing)
}

private let outputs: Set = ["speakers", "airpods"]
private let processes = [process(10, "com.spotify.client"), process(11, "us.zoom.xos"),
                         process(12, "com.google.Chrome"), process(13, "com.google.Chrome"), process(99, "own.atelier")]

private func plan(_ settings: SoundMixerSettings, enabled: Bool = true, defaultUID: String? = "speakers") -> [MixerPipelinePlan] {
    SoundMixerPlanner.plan(enabled: enabled, settings: settings, processes: processes, ownProcesses: [99],
                           defaultOutputUID: defaultUID, outputUIDs: outputs)
}

@Test func untouchedAppsAreNeverTapped() {
    // Nothing set: nothing tapped.
    #expect(plan(SoundMixerSettings()).isEmpty)
    // A rule at 100 % on the default device (as stored by an old version) is still not tapped.
    #expect(plan(SoundMixerSettings(apps: ["com.spotify.client": MixerAppRule(volume: 1, deviceUID: "speakers")])).isEmpty)
    // EQ on but flat: nothing tapped.
    #expect(plan(SoundMixerSettings(eqEnabled: true, eq: .flat)).isEmpty)
    // Off: nothing at all, whatever the settings.
    let busy = SoundMixerSettings(apps: ["com.spotify.client": MixerAppRule(volume: 0.3)], eqEnabled: true, eq: EQProfile(preset: .rock))
    #expect(plan(busy, enabled: false).isEmpty)
    #expect(plan(busy, defaultUID: nil).isEmpty)
}

@Test func volumeMuteAndRoutingEachGetOneTap() {
    let settings = SoundMixerSettings(apps: [
        "com.spotify.client": MixerAppRule(volume: 1, deviceUID: "airpods"),
        "us.zoom.xos": MixerAppRule(volume: 1, muted: true),
        "com.google.Chrome": MixerAppRule(volume: 1.5),
        "com.notrunning.app": MixerAppRule(volume: 0.2),
    ])
    let plans = plan(settings)
    #expect(plans.map(\.id) == ["app:com.google.Chrome", "app:com.spotify.client", "app:us.zoom.xos"])
    let chrome = plans[0], spotify = plans[1], zoom = plans[2]
    #expect(chrome.processes == [12, 13])
    #expect(chrome.outputUID == "speakers")
    #expect(chrome.needsLimiter)
    #expect(spotify.outputUID == "airpods")
    #expect(spotify.gain == 1 && !spotify.needsLimiter)
    #expect(zoom.gain == 0)
    #expect(plans.allSatisfy { $0.eq == nil })
}

@Test func routeToAMissingDeviceFollowsTheDefault() {
    let settings = SoundMixerSettings(apps: ["com.spotify.client": MixerAppRule(volume: 1, deviceUID: "gone")])
    #expect(plan(settings).isEmpty)
    let quieter = SoundMixerSettings(apps: ["com.spotify.client": MixerAppRule(volume: 0.5, deviceUID: "gone")])
    #expect(plan(quieter).first?.outputUID == "speakers")
}

@Test func globalEQExcludesSelfAndAppsWithTheirOwnTap() {
    var settings = SoundMixerSettings(apps: ["com.spotify.client": MixerAppRule(volume: 1, deviceUID: "airpods"),
                                            "us.zoom.xos": MixerAppRule(volume: 0.5)],
                                     eqEnabled: true, eq: EQProfile(preset: .loudness))
    settings.deviceEQ["airpods"] = EQProfile(preset: .bassCut)
    let plans = plan(settings)
    let global = plans.first { $0.kind == .global }
    #expect(global?.processes == [10, 11, 99])
    #expect(global?.outputUID == "speakers")
    #expect(global?.eq == EQPreset.loudness.gains)
    // Each own tap runs the curve of the device it plays to.
    #expect(plans.first { $0.id == "app:com.spotify.client" }?.eq == EQPreset.bassCut.gains)
    #expect(plans.first { $0.id == "app:us.zoom.xos" }?.eq == EQPreset.loudness.gains)
    // The default device's own curve flat: no global tap, apps elsewhere keep theirs.
    settings.deviceEQ["speakers"] = .flat
    let quiet = plan(settings)
    #expect(!quiet.contains { $0.kind == .global })
    #expect(quiet.first { $0.id == "app:us.zoom.xos" }?.eq == nil)
}

@Test func structureKeyIgnoresProcessesAndParameters() {
    let a = MixerPipelinePlan(kind: .app("x"), processes: [1], outputUID: "speakers", gain: 0.5, eq: nil)
    var b = a
    b.processes = [1, 2]
    b.gain = 1.2
    b.eq = EQPreset.rock.gains
    #expect(a.structureKey == b.structureKey)
    b.outputUID = "airpods"
    #expect(a.structureKey != b.structureKey)
}
