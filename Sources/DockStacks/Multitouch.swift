import AppKit
import DockCore
import os

// MARK: - MultitouchSupport, opened by hand
//
// The trackpad's raw finger stream and its haptic engine live in a private framework,
// MultitouchSupport. It is opened with dlopen and every function looked up with dlsym, so a
// macOS that renames or drops one only makes the feature unavailable; nothing is linked, and
// nothing can crash at launch. Proven on macOS 27.3 with the M5 built-in trackpad: one device,
// family 0x6f, 156 × 96 mm, about 125 frames a second while touched and none at rest; the
// actuator opens and actuates (return code 0). The same binary under Rosetta sees the same.
//
// Across Macs and releases: the MTTouch record has had the same 96-byte layout since the
// first multitouch MacBooks (MiddleClick and OpenMultitouchSupport read it identically on Intel
// and Apple silicon; int, double and float align the same on x86_64 and arm64), so the offsets
// below hold everywhere. What differs is the hardware: a Mac mini or Studio may have no
// trackpad at all, a Magic Mouse is a multitouch device too and must not trigger gestures,
// Magic Trackpad 1 and pre-2015 MacBooks have no Force Touch (no pressure, no actuator). Each
// of those is asked of the device, through functions that are themselves optional.

/// The sensor's frame callback: device, touches (96-byte records), count, timestamp, frame number.
typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

struct MultitouchAPI: @unchecked Sendable {
    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let register: @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
    let unregister: @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
    let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    let stop: @convention(c) (UnsafeMutableRawPointer) -> Int32
    /// Haptics, separately optional: a Mac can have a readable trackpad and no actuator.
    let haptics: Haptic?
    /// Questions about a device, each optional; a missing one gets a cautious default.
    let info: Info

    struct Info {
        var familyID: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32)?
        var isBuiltIn: (@convention(c) (UnsafeMutableRawPointer) -> Bool)?
        var supportsForce: (@convention(c) (UnsafeMutableRawPointer) -> Bool)?
        var supportsActuation: (@convention(c) (UnsafeMutableRawPointer) -> Bool)?
        var surface: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32)?
        var isRunning: (@convention(c) (UnsafeMutableRawPointer) -> Bool)?
    }

    struct Haptic {
        let deviceID: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
        let create: @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
        let open: @convention(c) (CFTypeRef) -> Int32
        let close: @convention(c) (CFTypeRef) -> Int32
        let actuate: @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32
    }

    /// Nil when the framework or any finger-stream function is missing.
    static let shared: MultitouchAPI? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        guard let list = sym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self),
              let register = sym("MTRegisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void).self),
              let unregister = sym("MTUnregisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void).self),
              let start = sym("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Int32).self),
              let stop = sym("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)
        else { return nil }
        var haptic: Haptic?
        if let id = sym("MTDeviceGetDeviceID", (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32).self),
           let create = sym("MTActuatorCreateFromDeviceID", (@convention(c) (UInt64) -> Unmanaged<CFTypeRef>?).self),
           let open = sym("MTActuatorOpen", (@convention(c) (CFTypeRef) -> Int32).self),
           let close = sym("MTActuatorClose", (@convention(c) (CFTypeRef) -> Int32).self),
           let actuate = sym("MTActuatorActuate", (@convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32).self) {
            haptic = Haptic(deviceID: id, create: create, open: open, close: close, actuate: actuate)
        }
        let info = Info(
            familyID: sym("MTDeviceGetFamilyID", (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32).self),
            isBuiltIn: sym("MTDeviceIsBuiltIn", (@convention(c) (UnsafeMutableRawPointer) -> Bool).self),
            supportsForce: sym("MTDeviceSupportsForce", (@convention(c) (UnsafeMutableRawPointer) -> Bool).self),
            supportsActuation: sym("MTDeviceSupportsActuation", (@convention(c) (UnsafeMutableRawPointer) -> Bool).self),
            surface: sym("MTDeviceGetSensorSurfaceDimensions",
                         (@convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self),
            isRunning: sym("MTDeviceIsRunning", (@convention(c) (UnsafeMutableRawPointer) -> Bool).self))
        return MultitouchAPI(createList: list, register: register, unregister: unregister, start: start, stop: stop,
                             haptics: haptic, info: info)
    }()

    /// One listed device and what it can do.
    struct Pad {
        let device: UnsafeMutableRawPointer
        let kind: MultitouchDeviceKind
        /// Reports pressure (Force Touch). Unknown counts as no: a firm press must never fire
        /// from contact size alone.
        let force: Bool
        /// Has a haptic actuator. Unknown counts as yes; opening the actuator is the real test.
        let actuation: Bool
    }

    func describe(_ device: UnsafeMutableRawPointer) -> Pad {
        var family: Int32 = 0
        let familyKnown = info.familyID.map { $0(device, &family) == 0 } ?? false
        var width: Int32 = 0, height: Int32 = 0
        let surfaceKnown = info.surface.map { $0(device, &width, &height) == 0 } ?? false
        let builtIn = info.isBuiltIn?(device) ?? false
        let kind = MultitouchDeviceKind.classify(family: familyKnown ? Int(family) : nil, builtIn: builtIn,
                                                 surface: surfaceKnown ? (Int(width), Int(height)) : nil)
        return Pad(device: device, kind: kind, force: info.supportsForce?(device) ?? false,
                   actuation: info.supportsActuation?(device) ?? true)
    }

    /// The trackpads in a retained list (Magic Mice left out). The list must outlive their use.
    func trackpads() -> (CFArray, [Pad])? {
        guard let (list, all) = devices() else { return nil }
        return (list, all.map(describe).filter { $0.kind == .trackpad })
    }

    /// The devices in a retained list. The list must outlive the devices' use: they are its elements.
    func devices() -> (CFArray, [UnsafeMutableRawPointer])? {
        guard let list = createList()?.takeRetainedValue() else { return nil }
        let devices = (0..<CFArrayGetCount(list)).compactMap { CFArrayGetValueAtIndex(list, $0).map { UnsafeMutableRawPointer(mutating: $0) } }
        return (list, devices)
    }
}

// MARK: - The finger stream

/// Everything the sensor's thread touches, behind one lock. The callback copies each frame in,
/// runs the pure recognizer right there (off the main thread, a few microseconds), and only
/// hops to main when a gesture fired or the hand came or went. The card reads `latest` at
/// display rate through the same lock.
struct TouchEngine {
    var recognizer = GestureRecognizer()
    var latest: [TouchSample] = []
    /// Frames that carried at least one contact: proof the stream is alive and read.
    var frames = 0
    var touching = false
    /// The device whose touch is being recognised. With a built-in trackpad and a Magic
    /// Trackpad both running, their frames would otherwise interleave into one recognizer and
    /// their path ids collide; the first to be touched owns the gesture until it lifts.
    var owner: UInt?
    /// Devices that report Force Touch pressure.
    var forceDevices: Set<UInt> = []
}

// OSAllocatedUnfairLock rather than Mutex: the same withLock shape, and it exists on macOS 14.
let touchEngine = OSAllocatedUnfairLock(initialState: TouchEngine())

private let contactCallback: MTContactCallback = { device, raw, count, timestamp, _ in
    var samples: [TouchSample] = []
    if let raw, count > 0 {
        samples.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            // MTTouch, 96 bytes: pathIndex 0x10, state 0x14, normalized x,y 0x20/0x24,
            // zTotal 0x30, majorAxis 0x3c (layout checked by static asserts in the research probe).
            let p = raw + i * 96
            samples.append(TouchSample(id: Int(p.load(fromByteOffset: 0x10, as: Int32.self)),
                                       x: Double(p.load(fromByteOffset: 0x20, as: Float.self)),
                                       y: Double(p.load(fromByteOffset: 0x24, as: Float.self)),
                                       state: Int(p.load(fromByteOffset: 0x14, as: Int32.self)),
                                       pressure: Double(p.load(fromByteOffset: 0x30, as: Float.self)),
                                       majorAxis: Double(p.load(fromByteOffset: 0x3c, as: Float.self))))
        }
    }
    let frame = TouchFrame(time: timestamp, touches: samples)
    let taken = samples
    let source = UInt(bitPattern: device)
    let (fired, changed, touching) = touchEngine.withLock { engine -> ([TrackpadGesture], Bool, Bool) in
        // Another trackpad holds the gesture in progress: this one waits its turn.
        if let owner = engine.owner, owner != source { return ([], false, engine.touching) }
        if engine.owner == nil {
            guard taken.contains(where: \.isDown) else {
                // An idle device's empty frame says nothing new.
                return ([], false, engine.touching)
            }
            engine.owner = source
            engine.recognizer.tuning.forceEnabled = engine.forceDevices.contains(source)
        }
        if !taken.isEmpty { engine.frames += 1 }
        engine.latest = taken
        let fired = engine.recognizer.feed(frame)
        if !engine.recognizer.active { engine.owner = nil }
        let touching = taken.contains(where: \.isDown)
        let changed = touching != engine.touching
        engine.touching = touching
        return (fired, changed, touching)
    }
    if !fired.isEmpty || changed {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { TrackpadGestures.shared.deliver(fired, touching: touching) }
        }
    }
    return 0
}

/// What the trackpads on this Mac can do right now, for the cards' availability notes.
struct MultitouchSurvey: Equatable {
    var frameworkLoaded = false
    var trackpads = 0
    var forceTrackpads = 0

    @MainActor static func now() -> MultitouchSurvey {
        guard let api = MultitouchAPI.shared else { return MultitouchSurvey() }
        let pads = api.trackpads()?.1 ?? []
        return MultitouchSurvey(frameworkLoaded: true, trackpads: pads.count, forceTrackpads: pads.filter(\.force).count)
    }
}

/// Starts and stops the sensor on every trackpad (the built-in one and any Magic Trackpad
/// present at start; a Magic Mouse is left alone). Stopping unregisters the callback and stops
/// each device, which is all it takes to leave the system exactly as it was.
@MainActor
final class MultitouchStream {
    private var list: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    var running: Bool { !devices.isEmpty }
    var deviceCount: Int { devices.count }

    @discardableResult
    func start() -> Bool {
        guard devices.isEmpty, let api = MultitouchAPI.shared, let (list, pads) = api.trackpads() else { return running }
        self.list = list
        var force: Set<UInt> = []
        for pad in pads {
            api.register(pad.device, contactCallback)
            // Older headers declare MTDeviceStart as returning nothing, so a nonzero return is
            // only trusted as a failure when MTDeviceIsRunning can confirm it.
            let status = api.start(pad.device, 0)
            if status == 0 || (api.info.isRunning?(pad.device) ?? true) {
                devices.append(pad.device)
                if pad.force { force.insert(UInt(bitPattern: pad.device)) }
            } else {
                api.unregister(pad.device, contactCallback)
            }
        }
        let forceSet = force
        touchEngine.withLock { $0.forceDevices = forceSet; $0.owner = nil }
        if devices.isEmpty { self.list = nil }
        return running
    }

    func stop() {
        guard let api = MultitouchAPI.shared else { return }
        for device in devices {
            api.unregister(device, contactCallback)
            _ = api.stop(device)
        }
        devices = []
        list = nil
        touchEngine.withLock {
            $0.latest = []; $0.touching = false; $0.owner = nil; $0.forceDevices = []
            $0.recognizer = GestureRecognizer(tuning: $0.recognizer.tuning)
        }
    }
}

// MARK: - Haptics

/// How firm a click the trackpad gives. The raw values are the actuator's own waveform ids:
/// 3 is its weak click, 4 medium, 6 strong (MTMR's table, felt on the M5).
enum HapticStrength: Int, CaseIterable, Identifiable, Sendable {
    case light = 3, medium = 4, firm = 6

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .light: "Light"
        case .medium: "Medium"
        case .firm: "Firm"
        }
    }
    /// The nearest public pattern, for the fallback.
    var pattern: NSHapticFeedbackManager.FeedbackPattern {
        switch self {
        case .light: .alignment
        case .medium: .levelChange
        case .firm: .generic
        }
    }
}

/// The trackpad as a speaker for touch. Other features call `Haptics.shared.tap()` when
/// something lands: a trackpad gesture, a title-bar gesture, a radial menu pick. Every one
/// goes through the owner's switch and strength; only the card's Feel It bypasses them.
///
/// The actuator is driven directly because NSHapticFeedbackManager only plays for the active
/// app, and Atelier is almost never in front when its snapping or switcher runs. Without an
/// actuator (an older Mac, a mouse, the API gone) it falls back to NSHapticFeedbackManager.
@MainActor
final class Haptics: ObservableObject {
    static let shared = Haptics()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "haptics.enabled"); if !enabled { close() } } }
    @Published var strength: HapticStrength { didSet { store.set(strength.rawValue, forKey: "haptics.strength") } }

    private let store = UserDefaults.standard
    private var actuators: [CFTypeRef] = []
    private var opened = false
    /// For diagnostics: taps played through the actuator, and through the fallback.
    private(set) var played = 0
    private(set) var fallbacks = 0

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "haptics.enabled")
        strength = HapticStrength(rawValue: UserDefaults.standard.integer(forKey: "haptics.strength")) ?? .medium
    }

    /// Whether the trackpad's own actuator can be opened. Opening plays nothing.
    var actuatorReady: Bool {
        openIfNeeded()
        return !actuators.isEmpty
    }

    /// What Haptics can do on this Mac: the actuator, the in-front-only fallback, or nothing
    /// (no Force Touch trackpad: Magic Trackpad 1, older MacBooks, a desktop with a mouse).
    var availability: FeatureAvailability {
        let survey = MultitouchSurvey.now()
        return FeatureAvailability(InputSupport.haptics(actuators: actuatorReady ? actuators.count : 0,
                                                       forceTrackpads: survey.forceTrackpads))
    }

    /// For the card: closes and reopens the actuators, so a Magic Trackpad connected since
    /// the last look is found.
    func rescan() {
        close()
        openIfNeeded()
    }

    /// One click, when the user has Haptic Feedback on, at the strength they chose. A caller's
    /// strength is only a hint and never overrides theirs: the card's setting is the setting.
    func tap(_ hint: HapticStrength? = nil) {
        guard enabled else { return }
        feel(strength)
    }

    /// Kept for callers written before `tap()`: it honours the switch and strength the same way.
    func play(_ hint: HapticStrength) { tap(hint) }

    /// One click regardless of the switch, at the given strength: the card's Feel It button.
    func feel(_ strength: HapticStrength) {
        openIfNeeded()
        guard let api = MultitouchAPI.shared?.haptics, !actuators.isEmpty else {
            NSHapticFeedbackManager.defaultPerformer.perform(strength.pattern, performanceTime: .now)
            fallbacks += 1
            return
        }
        let failed = actuators.map { api.actuate($0, Int32(strength.rawValue), 0, 0, 0) }.contains { $0 != 0 }
        played += 1
        // Actuators go stale across sleep and reconnects; reopen on the next tap.
        if failed { close() }
    }

    private func openIfNeeded() {
        guard !opened else { return }
        opened = true
        guard let api = MultitouchAPI.shared, let haptic = api.haptics, let (_, pads) = api.trackpads() else { return }
        // Only trackpads that say they have an actuator: Magic Trackpad 1 and pre-Force Touch
        // MacBooks have none, and a Magic Mouse is not a speaker.
        for pad in pads where pad.actuation {
            var id: UInt64 = 0
            guard haptic.deviceID(pad.device, &id) == 0, let actuator = haptic.create(id)?.takeRetainedValue() else { continue }
            if haptic.open(actuator) == 0 { actuators.append(actuator) }
        }
    }

    private func close() {
        if let haptic = MultitouchAPI.shared?.haptics {
            for actuator in actuators { _ = haptic.close(actuator) }
        }
        actuators = []
        opened = false
    }
}

extension FeatureAvailability {
    /// DockCore's input verdicts, as the cards show them.
    init(_ support: InputSupport) {
        switch support {
        case .available: self = .available
        case .limited(let text): self = .limited(text)
        case .unavailable(let text): self = .unavailable(text)
        }
    }
}
