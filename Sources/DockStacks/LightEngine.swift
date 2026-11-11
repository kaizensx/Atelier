import AppKit
import DockCore
import Metal
import MetalKit
import QuartzCore

// MARK: - Light Engine
//
// One owner for every display's gamma table, the curve the panel applies after everything is
// composited. Three things macOS will not do are each a multiplier on that curve, and they
// multiply into a single table written in one place, so they compose instead of overwriting
// each other:
//
// - XDR Boost: brighter than Apple's maximum. It is not a gamma curve (Apple silicon XDR keeps
//   the table off EDR pixels): one click-through window per display multiplies everything
//   beneath it by an extended-range white, so SDR content uses the light macOS keeps for HDR.
//   When and how much is XDRBoostPolicy's call: never while the display sleeps or is locked,
//   only once EDR has engaged, always as a glide, and on a curve that keeps every brightness
//   step a step.
// - Below Black: the table scaled below 1, darker than the lowest brightness step (Lunar's
//   "sub-zero" dimming). It took over from Extra Dim and keeps its settings.
// - Candlelight: per-channel gains for a black body between 2700 K and 1900 K, warmer than
//   Night Shift, which CoreBrightness clamps at 2700 K.
//
// Nothing here is permanent. macOS throws a process's gamma tables away when it exits, even by
// crashing; turning everything off calls CGDisplayRestoreColorSyncSettings at once; quitting
// does the same. Tables are reset by macOS on wake, display changes and ColorSync updates, so a
// watchdog reads them back every second and puts ours back when they drift.

private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

/// DisplayServices' brightness getter, read only, to tell the owner whether Boost has anything
/// to add. Resolved once; nil when the private framework is missing.
private let displayServicesGetBrightness: GetBrightness? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
          let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(symbol, to: GetBrightness.self)
}()

/// This Mac's model identifier ("Mac17,8"), which says whether the built-in panel is XDR.
private let lightModelIdentifier: String = {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}()

extension FeatureAvailability {
    /// DockCore's verdict for a display feature, as the cards show it.
    init(displayCompat verdict: DisplayCompatVerdict) {
        switch verdict {
        case .available: self = .available
        case .limited(let note): self = .limited(note)
        case .unavailable(let note): self = .unavailable(note)
        }
    }
}

@MainActor
final class LightEngine: ObservableObject {
    static let shared = LightEngine()

    enum Keys {
        static let boostOn = "light.boost.enabled"
        static let boostAmount = "light.boost.amount"
        // Extra Dim's keys, kept so its owners' settings carry over to Below Black.
        static let dimOn = "extraDim.enabled"
        static let dimAmount = "extraDim.amount"
        static let candleOn = "light.candle.enabled"
        static let candleKelvin = "light.candle.kelvin"
    }

    @Published var boostOn: Bool { didSet { store.set(boostOn, forKey: Keys.boostOn); boostWanted() } }
    /// How much of the headroom Boost uses, 0 to 1.
    @Published var boostAmount: Double { didSet { store.set(boostAmount, forKey: Keys.boostAmount); boostTick() } }
    @Published var dimOn: Bool { didSet { store.set(dimOn, forKey: Keys.dimOn); changed(fade: true) } }
    /// How much light Below Black takes away, 0.1 to 0.8.
    @Published var dimAmount: Double { didSet { store.set(dimAmount, forKey: Keys.dimAmount); changed(fade: false) } }
    @Published var candleOn: Bool { didSet { store.set(candleOn, forKey: Keys.candleOn); changed(fade: true) } }
    /// Candlelight's colour temperature, 1900 K to 2700 K.
    @Published var candleKelvin: Double { didSet { store.set(candleKelvin, forKey: Keys.candleKelvin); changed(fade: false) } }

    /// The EDR headroom of the best XDR display right now: how far above SDR white it can go.
    @Published private(set) var headroom: Double = 1
    /// The most headroom that display can ever offer; above 1 means it is an XDR panel.
    @Published private(set) var potentialHeadroom: Double = 1
    /// The built-in panel's brightness, 0 to 1, when DisplayServices answers.
    @Published private(set) var brightness: Double?

    private let store = UserDefaults.standard

    /// What the engine has done to one display.
    private struct Panel {
        /// The display's own curve, captured before the engine first wrote to it.
        var baseline: (red: [Float], green: [Float], blue: [Float])
        /// What reading the table back gave right after the last write. Comparing against the
        /// read-back rather than the request keeps the hardware's rounding from looking like drift.
        var written: (red: [Float], green: [Float], blue: [Float])?
    }
    private var panels: [CGDirectDisplayID: Panel] = [:]

    /// How far each feature is faded in, 0 to 1. Changes glide over half a second.
    private struct Mix: Equatable {
        var dim = 0.0, candle = 0.0
        static let zero = Mix()
    }
    private var mix = Mix.zero
    private var fadeFrom = Mix.zero
    private var fadeStart = 0.0
    private var fadeTimer: Timer?
    private var watchdog: Timer?
    private var observers: [NSObjectProtocol] = []
    private var goal: Mix { Mix(dim: dimOn ? 1 : 0, candle: candleOn ? 1 : 0) }

    var active: Bool { boostOn || dimOn || candleOn }

    /// External Monitors' software dimmer, for monitors that answer nothing over DDC: a scale
    /// per display, multiplied into the same table as Below Black and Candlelight.
    private var monitorDim: [CGDirectDisplayID: Double] = [:]

    /// Nil (or 1) lifts the dim on that display. Applied at once: the caller glides.
    func setMonitorDim(_ scale: Double?, for display: CGDirectDisplayID) {
        if let scale, scale < 0.999 { monitorDim[display] = min(max(scale, 0.05), 1) } else { monitorDim[display] = nil }
        if fadeTimer == nil { render() }
    }

    private init() {
        let defaults = UserDefaults.standard
        boostOn = defaults.bool(forKey: Keys.boostOn)
        boostAmount = defaults.object(forKey: Keys.boostAmount) as? Double ?? 0.5
        dimOn = defaults.bool(forKey: Keys.dimOn)
        dimAmount = defaults.object(forKey: Keys.dimAmount) as? Double ?? 0.35
        candleOn = defaults.bool(forKey: Keys.candleOn)
        candleKelvin = defaults.object(forKey: Keys.candleKelvin) as? Double ?? 2200
        refreshReadings()
        watchAway()
    }

    /// At launch, including the relaunch after a crash: macOS dropped the old tables with the old
    /// process, so whatever is on is simply applied again.
    func resume() {
        refreshReadings()
        if dimOn || candleOn { changed(fade: true) }
        if boostOn && boostState == .off {
            // At login the display is still settling into its profile and EDR: wait longer than
            // after a wake, then glide in, so the first thing seen is never a blown-out desktop.
            boostState = .settling(since: CACurrentMediaTime() + XDRBoostPolicy.launchExtraDelay)
            evaluateAway()
            runBoostClock()
        }
    }

    /// For `applicationWillTerminate`: the system's own curves back on every display, at once.
    func restoreOnQuit() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        finish()
        boostState = .off
        applyBoost()
        runBoostClock()
    }

    // MARK: Readings

    /// The current Boost multiplier, the dim scale and the warmth, for the cards and the stage.
    /// The headroom the cards reason with: the live one once EDR has engaged, otherwise what
    /// full brightness gives, so a card shows what Boost will do rather than 1×.
    private var readoutHeadroom: Double {
        headroom > XDRBoostPolicy.engagedHeadroom ? headroom : XDRBoostPolicy.peakNits / sdrWhite
    }
    var boostFactor: Double { boostFactor(amount: boostAmount) }
    func boostFactor(amount: Double) -> Double {
        XDRBoostPolicy.factor(amount: amount, headroom: readoutHeadroom, sdrWhite: sdrWhite)
    }
    var dimScale: Double { LightMath.dimScale(amount: dimAmount) }
    var boostedNits: Double { sdrNits * boostFactor }
    func boostedNits(amount: Double) -> Double { sdrNits * boostFactor(amount: amount) }
    var sdrNits: Double { XDRBoostPolicy.sdrNow(headroom: readoutHeadroom, sdrWhite: sdrWhite) }
    var xdrCapable: Bool { potentialHeadroom > 1.01 }

    // MARK: Compatibility

    /// Every active display, reduced to what decides which features work on it.
    private var displayInfos: [LightDisplayInfo] {
        let screens = Dictionary(NSScreen.screens.compactMap { screen in Self.displayID(of: screen).map { ($0, screen) } },
                                 uniquingKeysWith: { first, _ in first })
        return Self.displays().map { id in
            let screen = screens[id]
            return LightDisplayInfo(name: screen?.localizedName ?? "this display", builtIn: CGDisplayIsBuiltin(id) != 0,
                                    potentialHeadroom: Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1),
                                    takesGamma: Self.read(id) != nil)
        }
    }

    /// Whether this Mac has a panel Boost is made for (an XDR MacBook Pro, Pro Display XDR).
    var boostAvailability: FeatureAvailability {
        FeatureAvailability(displayCompat: LightCompat.boost(displayInfos, model: lightModelIdentifier))
    }

    /// Below Black and Candlelight: any display with a gamma table, and a word if another app
    /// (f.lux, Lunar…) writes the same table.
    var gammaAvailability: FeatureAvailability {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.localizedName)
        return FeatureAvailability(displayCompat: LightCompat.gamma(displayInfos, runningApps: running))
    }

    /// Read back from the display, never assumed: the largest red value in the main display's table.
    var gammaTop: Float {
        guard let table = Self.read(CGMainDisplayID()) else { return 0 }
        return table.red.max() ?? 0
    }

    var diagnostics: String {
        let warm = mix.candle > 0 ? LightMath.blendedKelvin(candleKelvin, mix: mix.candle) : LightMath.neutralKelvin
        let dim = 1 - (1 - dimScale) * mix.dim
        let state: String = switch boostState {
        case .off: "off"
        case .suspended: "suspended"
        case .settling: "settling"
        case .engaging: "engaging"
        case .ramping: "ramping"
        case .on: "on"
        }
        let awayWhy = [screensAsleep ? "screens" : nil, systemAsleep ? "sleep" : nil, locked ? "locked" : nil,
                       saverOn ? "saver" : nil, sessionAway ? "session" : nil,
                       CACurrentMediaTime() < reconfigUntil ? "reconfig" : nil, polledAway ? "polled" : nil,
                       boostCapable ? nil : "noEDR"]
            .compactMap { $0 }.joined(separator: ",")
        return String(format: "lightBoost=%.3f lightBoostState=%@ lightBoostTarget=%.2f lightAway=%@ lightHeadroom=%.3f lightSDR=%.0f lightDim=%.3f lightWarmK=%.0f gammaTop=%.4f lightPanels=%d lightTriggers=%d",
                      XDRBoostMachine.factor(boostState, now: CACurrentMediaTime()), state, boostTarget,
                      awayWhy.isEmpty ? "no" : awayWhy, headroom,
                      XDRBoostPolicy.sdrNow(headroom: headroom, sdrWhite: sdrWhite), dim, warm, gammaTop,
                      panels.count, overlays.count)
    }

    private func refreshReadings() {
        let best = NSScreen.screens.max { $0.maximumPotentialExtendedDynamicRangeColorComponentValue < $1.maximumPotentialExtendedDynamicRangeColorComponentValue }
        let room = Double(best?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        let potential = Double(best?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
        // Published values are only touched when they move, so the cards are not redrawn each second.
        if abs(room - headroom) > 0.005 { headroom = room }
        if abs(potential - potentialHeadroom) > 0.005 { potentialHeadroom = potential }
        var level: Float = 0
        let builtIn = Self.displays().first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
        let reading: Double? = displayServicesGetBrightness.flatMap { $0(builtIn, &level) == 0 ? Double(level) : nil }
        if reading.map({ abs($0 - (brightness ?? -1)) > 0.005 }) ?? (brightness != nil) { brightness = reading }
    }

    // MARK: Changes and fades

    private func changed(fade: Bool) {
        if fade && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fadeFrom = mix
            fadeStart = CACurrentMediaTime()
            if fadeTimer == nil {
                let timer = Timer(timeInterval: 1 / 120, repeats: true) { _ in
                    MainActor.assumeIsolated { LightEngine.shared.fadeStep() }
                }
                RunLoop.main.add(timer, forMode: .common)
                fadeTimer = timer
            }
            fadeStep()
        } else if fadeTimer == nil {
            // A slider moving during a fade is picked up by the fade's next frame.
            mix = goal
            render()
        }
    }

    private func fadeStep() {
        let t = (CACurrentMediaTime() - fadeStart) / 0.5
        let e = LightMath.ease(t), g = goal
        mix = Mix(dim: fadeFrom.dim + (g.dim - fadeFrom.dim) * e,
                  candle: fadeFrom.candle + (g.candle - fadeFrom.candle) * e)
        if t >= 1 {
            mix = g
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
        render()
    }

    private func render() {
        if mix == .zero && goal == .zero && monitorDim.isEmpty {
            finish()
        } else {
            startWatching()
            write()
        }
    }

    // MARK: Writing

    private func write() {
        let ids = Self.displays()
        for id in panels.keys where !ids.contains(id) { panels[id] = nil }
        let dim = 1 - (1 - dimScale) * mix.dim
        let kelvin = LightMath.blendedKelvin(candleKelvin, mix: mix.candle)
        for id in ids {
            // Boost is the multiplying overlay; the gamma table only carries Below Black and
            // Candlelight.
            guard var panel = panels[id] ?? Self.read(id).map({ Panel(baseline: $0) }) else { continue }
            let gains = LightMath.gains(boost: 1, dim: dim * (monitorDim[id] ?? 1), kelvin: kelvin)
            var red = LightMath.scaled(panel.baseline.red, by: gains.red)
            var green = LightMath.scaled(panel.baseline.green, by: gains.green)
            var blue = LightMath.scaled(panel.baseline.blue, by: gains.blue)
            CGSetDisplayTransferByTable(id, UInt32(red.count), &red, &green, &blue)
            panel.written = Self.read(id) ?? (red, green, blue)
            panels[id] = panel
        }
    }

    /// Below Black and Candlelight off: the system's curves back, nothing left running.
    private func finish() {
        let owned = !panels.isEmpty
        panels = [:]
        mix = .zero
        if owned { CGDisplayRestoreColorSyncSettings() }
        watchdog?.invalidate()
        watchdog = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    // MARK: Watchdog

    private func startWatching() {
        if watchdog == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { LightEngine.shared.tick() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }
        guard observers.isEmpty else { return }
        // Display changes and sleep reset the tables. The system settles first, then ours go back.
        let later: @Sendable (Notification) -> Void = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { LightEngine.shared.tick(force: true) }
            }
        }
        observers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main, using: later),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                              object: nil, queue: .main, using: later),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                              object: nil, queue: .main, using: later),
        ]
    }

    /// Once a second: has anyone replaced a table, has the headroom moved with the brightness
    /// keys, is a display new? Any of those writes the tables again.
    private func tick(force: Bool = false) {
        refreshReadings()
        guard !panels.isEmpty || dimOn || candleOn || !monitorDim.isEmpty else { return }
        var again = force || Set(panels.keys) != Set(Self.displays())
        for (id, panel) in panels {
            if let written = panel.written, let now = Self.read(id) {
                let moved = LightMath.drifted(expected: written.red, actual: now.red)
                    || LightMath.drifted(expected: written.green, actual: now.green)
                    || LightMath.drifted(expected: written.blue, actual: now.blue)
                if moved {
                    // macOS put the profile's curve back; it becomes the new baseline. Only a
                    // table that ends near 1 and never above it is adopted: a boosted, dimmed or
                    // warmed one is not, so the engine can never compound on its own output.
                    if LightMath.plausibleBaseline(now.red), LightMath.plausibleBaseline(now.green),
                       LightMath.plausibleBaseline(now.blue) {
                        panels[id]?.baseline = now
                    }
                    again = true
                }
            }
        }
        if again && fadeTimer == nil { render() }
    }

    // MARK: XDR Boost

    /// Where Boost stands; XDRBoostMachine moves it, `applyBoost` makes the screen match it.
    private var boostState: XDRBoostState = .off
    /// One overlay window per XDR display while a layer is wanted.
    private var overlays: [CGDirectDisplayID: EDRBoostOverlay] = [:]
    /// Boost's own clock: 60 Hz while lit or gliding, so the factor keeps step with the
    /// brightness keys' animation; 5 Hz while settling; 1 Hz while away. Layers are redrawn when
    /// the factor moves and at least 5 times a second, or the window server drops back to SDR.
    private var boostClock: Timer?
    private var boostClockInterval = 0.0
    /// Why the screen is away, as the notifications said. Any one suspends Boost.
    private var screensAsleep = false, systemAsleep = false, locked = false, saverOn = false, sessionAway = false
    /// Until when a display change is still settling.
    private var reconfigUntil = 0.0
    private var screenSignature = ""
    private var awayObservers: [NSObjectProtocol] = []
    /// Tests: a fixed multiplier instead of the policy's, and overlays screenshots can see.
    private var testFactor: Double?
    /// When the slower checks (session, display sleep, frames) and the keep-alive draw last ran.
    private var lastHeavyTick = 0.0
    private var lastDrawn = (factor: 0.0, time: 0.0)

    /// SDR white of the panel Boost reasons about (the built-in one when there is one).
    private var sdrWhite: Double {
        let builtIn = Self.displays().contains { CGDisplayIsBuiltin($0) != 0 }
        return XDRBoostPolicy.sdrWhite(model: lightModelIdentifier, builtIn: builtIn)
    }

    /// XDR displays now, by display ID.
    private var xdrScreens: [CGDirectDisplayID: NSScreen] {
        var out: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens where screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.01 {
            if let id = Self.displayID(of: screen) { out[id] = out[id] ?? screen }
        }
        return out
    }

    /// The display whose headroom sets the multiplier: the built-in XDR panel, else the first.
    private var referenceScreen: NSScreen? {
        let screens = xdrScreens
        return screens.first { CGDisplayIsBuiltin($0.key) != 0 }?.value ?? screens.values.first
    }

    private var boostTarget: Double {
        if let testFactor { return testFactor }
        let room = Double(referenceScreen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        return XDRBoostPolicy.factor(amount: boostAmount, headroom: room, sdrWhite: sdrWhite)
    }

    /// What the session dictionary says right now, as a check on the notifications: locked,
    /// switched away from the console, or the built-in display asleep.
    private var polledAway: Bool {
        if CGDisplayIsAsleep(referenceScreen.flatMap(Self.displayID) ?? CGMainDisplayID()) != 0 { return true }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return true }
        return false
    }

    private var away: Bool {
        screensAsleep || systemAsleep || locked || saverOn || sessionAway
            || CACurrentMediaTime() < reconfigUntil || polledAway
            // The panel stopped offering EDR (low battery, Low Power Mode, a thermal limit, a
            // display change): Boost waits for it to come back instead of switching itself off,
            // which left it off for good while its switch still said on.
            || !boostCapable
    }

    private var boostCapable: Bool { !testNoEDR && !xdrScreens.isEmpty }
    /// Test hook: pretend the panel stopped offering EDR, as it does on low battery.
    private var testNoEDR = false

    /// The switch moved: on settles in (or waits for the screen), off glides out.
    private func boostWanted() {
        if boostOn {
            boostState = XDRBoostMachine.next(boostState, .turnOn, wanted: true)
            evaluateAway()
        }
        boostTick()
    }

    /// Suspends or resumes on what the screen is doing. Called by every notification and tick.
    private func evaluateAway() {
        let wanted = boostOn
        if away {
            if boostState != .off && boostState != .suspended {
                boostState = XDRBoostMachine.next(boostState, .suspend, wanted: wanted)
                applyBoost()
            }
        } else if boostState == .suspended {
            boostState = XDRBoostMachine.next(boostState, .resume, wanted: wanted)
        }
        runBoostClock()
    }

    /// One step of the clock: the machine moves on the headroom now, then the screen follows.
    private func boostTick() {
        let now = CACurrentMediaTime()
        let heavy = now - lastHeavyTick >= 0.19 || boostClockInterval >= 0.19
        if heavy {
            lastHeavyTick = now
            refreshReadings()
            evaluateAway()
        }
        if boostState != .suspended {
            let room = Double(referenceScreen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
            let event = XDRBoostEvent.tick(now: CACurrentMediaTime(), headroom: testFactor != nil ? 16 : room, target: boostTarget)
            boostState = XDRBoostMachine.next(boostState, event, wanted: boostOn)
        }
        applyBoost(heavy: heavy)
        runBoostClock()
    }

    /// Makes the screen match the state: overlays up at the factor, or none at all.
    private func applyBoost(heavy: Bool = true) {
        guard XDRBoostMachine.showsLayer(boostState) else {
            for overlay in overlays.values { overlay.close() }
            overlays = [:]
            lastDrawn = (0, 0)
            return
        }
        let now = CACurrentMediaTime()
        let factor = XDRBoostMachine.factor(boostState, now: now)
        // Between the slower checks only a moved factor is drawn.
        guard heavy || abs(factor - lastDrawn.factor) > 0.0005 || now - lastDrawn.time > 0.19 else { return }
        lastDrawn = (factor, now)
        let screens = xdrScreens
        for (id, overlay) in overlays where screens[id] == nil {
            overlay.close()
            overlays[id] = nil
        }
        // Every band of every display changes in one Core Animation transaction, so they can
        // never be seen at different values.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, screen) in screens {
            if let overlay = overlays[id] {
                if heavy { overlay.place(on: screen) }
            } else if let overlay = EDRBoostOverlay(screen: screen, capturable: testFactor != nil) {
                overlays[id] = overlay
            }
            overlays[id]?.show(factor: factor)
        }
        CATransaction.commit()
    }

    private func runBoostClock() {
        let interval: Double? = switch boostState {
        case .off: nil
        case .suspended: 1
        case .ramping, .on: 1.0 / 60
        case .settling, .engaging: 0.2
        }
        guard interval != boostClockInterval || (interval != nil && boostClock == nil) else { return }
        boostClock?.invalidate()
        boostClock = nil
        boostClockInterval = interval ?? 0
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { LightEngine.shared.boostTick() }
        }
        timer.tolerance = interval < 0.1 ? 0 : interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        boostClock = timer
    }

    /// Displays added, removed or rearranged: the overlays go at once and come back once the
    /// arrangement has settled, instead of sitting at old frames meanwhile.
    private func screensChanged() {
        let signature = NSScreen.screens.map { "\(Self.displayID(of: $0) ?? 0):\($0.frame)" }.sorted().joined(separator: "|")
        guard signature != screenSignature else { return }
        let first = screenSignature.isEmpty
        screenSignature = signature
        guard !first else { return }
        reconfigUntil = CACurrentMediaTime() + 0.6
        evaluateAway()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            MainActor.assumeIsolated { LightEngine.shared.evaluateAway() }
        }
    }

    /// The notifications that say the screen is going away or coming back. Registered once, for
    /// the app's whole life; cheap, and Boost can be switched on at any time.
    private func watchAway() {
        screenSignature = ""
        screensChanged()
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (LightEngine) -> Void) {
            awayObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    change(LightEngine.shared)
                    LightEngine.shared.evaluateAway()
                }
            })
        }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        on(workspace, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        on(workspace, NSWorkspace.didWakeNotification) { $0.systemAsleep = false; $0.screensAsleep = false }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionAway = true }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionAway = false }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false; $0.saverOn = false }
        on(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.saverOn = true }
        on(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.saverOn = false }
        on(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
    }

    /// `atelier://light?simulate=lock|unlock|sleep|wake|saver|unsaver|reconfig` walks Boost
    /// through what the notifications would do; `factor=0.5` (or `factor=off`) pins the
    /// multiplier and lets screenshots see the overlay, so a test can measure it.
    func handleTest(_ items: [URLQueryItem]) {
        for item in items {
            switch (item.name, item.value ?? "") {
            case ("simulate", "lock"): locked = true
            case ("simulate", "unlock"): locked = false
            case ("simulate", "sleep"): screensAsleep = true
            case ("simulate", "wake"): screensAsleep = false
            case ("simulate", "saver"): saverOn = true
            case ("simulate", "unsaver"): saverOn = false
            case ("simulate", "noedr"): testNoEDR = true
            case ("simulate", "edr"): testNoEDR = false
            case ("simulate", "reconfig"):
                reconfigUntil = CACurrentMediaTime() + 0.6
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    MainActor.assumeIsolated { LightEngine.shared.evaluateAway() }
                }
            case ("factor", "off"):
                testFactor = nil
                for overlay in overlays.values { overlay.close() }
                overlays = [:]
            case ("factor", let value):
                if let factor = Double(value) {
                    testFactor = factor
                    for overlay in overlays.values { overlay.close() }
                    overlays = [:]
                }
            default: break
            }
        }
        evaluateAway()
        boostTick()
    }

    // MARK: Display helpers

    static func displays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func read(_ id: CGDirectDisplayID) -> (red: [Float], green: [Float], blue: [Float])? {
        // 256 entries, not the display's full capacity: on macOS 27 a 1024-entry table is clamped
        // to 1.0 when written, which silently flattens XDR Boost, while a 256-entry table keeps
        // values above 1 (measured on an M5 Pro XDR panel: ×2 reads back 1.9999 at 256, 1.0 at 1024).
        let capacity: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(capacity)), green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success, count > 1 else { return nil }
        let n = Int(count)
        return (Array(red.prefix(n)), Array(green.prefix(n)), Array(blue.prefix(n)))
    }
}

// MARK: - XDR Boost overlay

/// XDR Boost on one display. Two click-through bands (top and bottom half) of extended-range
/// white are multiplied over everything below, so the desktop rises past SDR white into the
/// panel's headroom; a single layer covering the whole display is treated by macOS as
/// full-screen HDR and pulled back. One pixel of plain extended-range white in the corner keeps
/// the display in EDR whatever the bands show.
///
/// Each band has to be its window's content view: as a subview inside a container the multiply
/// blends with the container's empty group and turns the screen black (measured). So the bands
/// are windows, but one unit: the bottom band and the pixel are child windows of the top one,
/// ordered and moved with it, all three drawn in the same transaction, and never re-ordered on a
/// timer, so app switches, Spaces and Mission Control cannot show one half without the other.
@MainActor
final class EDRBoostOverlay {
    private let windows: [NSWindow]
    private let bands: [EDRTriggerView]
    private let pixel: EDRTriggerView

    init?(screen: NSScreen, capturable: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let top = EDRTriggerView(device: device, value: 1, multiply: true),
              let bottom = EDRTriggerView(device: device, value: 1, multiply: true),
              let pixel = EDRTriggerView(device: device, value: 1.6) else { return nil }
        bands = [top, bottom]
        self.pixel = pixel
        let frames = Self.frames(of: screen.frame)
        windows = zip([top, bottom, pixel], frames).map { view, rect in
            let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .canJoinAllApplications, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.canHide = false
            window.animationBehavior = .none
            window.isExcludedFromWindowsMenu = true
            // Screenshots and recordings show the desktop as it is, not multiplied.
            window.sharingType = capturable ? .readOnly : .none
            window.contentView = view
            window.setFrame(rect, display: false)
            return window
        }
        windows[0].orderFrontRegardless()
        windows[0].addChildWindow(windows[1], ordered: .above)
        windows[0].addChildWindow(windows[2], ordered: .above)
    }

    /// Top band, bottom band, corner pixel.
    private static func frames(of frame: CGRect) -> [CGRect] {
        let top = (frame.height / 2).rounded(.down)
        return [CGRect(x: frame.minX, y: frame.maxY - top, width: frame.width, height: top),
                CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - top),
                CGRect(x: frame.minX, y: frame.maxY - 1, width: 1, height: 1)]
    }

    /// Follows the display's frame. Brought to the front only when something took it off
    /// screen: re-ordering on every tick made the halves flicker against other windows.
    func place(on screen: NSScreen) {
        for (window, rect) in zip(windows, Self.frames(of: screen.frame)) where window.frame != rect {
            window.setFrame(rect, display: false)
        }
        if windows.contains(where: { !$0.isVisible }) {
            windows[0].orderFrontRegardless()
            for child in windows.dropFirst() where !child.isVisible { child.orderFront(nil) }
        }
    }

    /// Draws every layer at the factor. The caller wraps all overlays in one transaction.
    func show(factor: Double) {
        for band in bands { band.set(value: factor) }
        for band in bands { band.draw() }
        pixel.draw()
    }

    func close() {
        for child in windows.dropFirst() { windows[0].removeChildWindow(child) }
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
    }
}

/// One extended-range layer: a solid colour in extended linear sRGB, as a 1×1 drawable scaled to
/// the view. The owner draws it (a few times a second, or every frame while gliding): the window
/// server drops back to SDR when HDR content stops arriving. Drawables present with the Core
/// Animation transaction, so several layers drawn in one transaction appear together.
final class EDRTriggerView: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue

    init?(device: MTLDevice, value: Double = 1.6, multiply: Bool = false) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1), device: device)
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        clearColor = MTLClearColorMake(value, value, value, 1)
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        if let layer = layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            layer.pixelFormat = .rgba16Float
            layer.presentsWithTransaction = true
            // Multiplied over everything beneath: each pixel, already composited, is scaled into
            // the extended range. This path is the one that works where the display pipeline
            // keeps the gamma table off EDR pixels (GCPBypassesEDRPixels on Apple silicon XDR).
            if multiply { layer.compositingFilter = "multiply" }
        }
    }

    /// The extended-range value of the next draw.
    func set(value: Double) {
        guard abs(clearColor.red - value) > 0.0005 else { return }
        clearColor = MTLClearColorMake(value, value, value, 1)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.commit()
        // With presentsWithTransaction the drawable is presented in the current transaction,
        // once the GPU has the work scheduled.
        buffer.waitUntilScheduled()
        drawable.present()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
