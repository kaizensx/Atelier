import AppKit
import CoreAudio
import DockCore

// MARK: - External Monitor Control
//
// Real brightness, contrast, volume, mute and input on external monitors, over DDC/CI
// (DDCTransport.swift). macOS has no slider for any of it. Monitors that answer nothing get a
// software dimmer instead: a per-display scale on the gamma table, which LightEngine owns, so
// it composes with Below Black and Candlelight rather than fighting them.
//
// Keys: Atelier HUD already owns the brightness and volume keys; when the pointer is on a
// monitor this engine drives (or the sound goes to a monitor's speakers), HUD hands the key
// here and draws its own overlay. Apple displays (Studio Display, Pro Display XDR) answer
// DisplayServices and stay on HUD's own path; the built-in panel is never addressed over DDC.
//
// Reversible: off drops every channel and every software dim at once. A monitor keeps the
// hardware values it was given, as it would from its own buttons; "Put back" writes the values
// each monitor had when Atelier first met it.

@MainActor
final class ExternalMonitors: ObservableObject {
    static let shared = ExternalMonitors()

    enum Keys {
        static let enabled = "ddc.enabled"
        static let keys = "ddc.keys"
        static let software = "ddc.software"
    }

    enum Route: String {
        /// Hardware controls over DDC/CI.
        case ddc
        /// No answer over DDC: brightness is a gamma scale.
        case software
        /// An Apple display: HUD drives it through DisplayServices.
        case native
        /// Nothing Atelier can do.
        case none
    }

    struct Monitor: Identifiable, Equatable {
        let id: CGDirectDisplayID
        var name: String
        var memoryKey: String
        var route: Route
        var transport: String
        var probing = true
        var brightness = 1.0
        var contrast: Double?
        var volume: Double?
        var muted: Bool?
        var input: UInt16?
        var maxima: [UInt8: UInt16] = [:]

        var hasHardware: Bool { route == .ddc }
        var routeLabel: String {
            switch route {
            case .ddc: "DDC/CI"
            case .software: "Software dim"
            case .native: "Apple display"
            case .none: "No control"
            }
        }
    }

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: Keys.enabled); enabled ? start() : stop() } }
    @Published var keysEnabled: Bool { didSet { store.set(keysEnabled, forKey: Keys.keys) } }
    @Published var softwareFallback: Bool {
        didSet { store.set(softwareFallback, forKey: Keys.software); if enabled { reprobeSoftware() } }
    }
    @Published private(set) var monitors: [Monitor] = []
    /// Displays left alone, and why ("built-in panel", "virtual display"…).
    @Published private(set) var skipped: [(id: CGDirectDisplayID, reason: String)] = []
    @Published private(set) var lastNote: String?

    private let store = UserDefaults.standard
    private var links: [CGDirectDisplayID: DDCLink] = [:]
    private var glides: [CGDirectDisplayID: Timer] = [:]
    /// Where a running glide is heading, so quick key presses build on each other.
    private var glideTargets: [CGDirectDisplayID: Double] = [:]
    private var observers: [NSObjectProtocol] = []
    private var refreshPending = false
    private var survey = (embedded: 0, external: 0)

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Keys.enabled)
        keysEnabled = defaults.object(forKey: Keys.keys) as? Bool ?? true
        softwareFallback = defaults.object(forKey: Keys.software) as? Bool ?? true
    }

    func resume() { if enabled { start() } }

    /// For `applicationWillTerminate`: glides stop. The software dims go with LightEngine's own
    /// restore (and with the process: macOS drops its gamma tables); asking LightEngine again
    /// here would make it write a table after it restored them. Monitors keep their values.
    func restoreOnQuit() {
        for timer in glides.values { timer.invalidate() }
        glides = [:]
    }

    var availability: FeatureAvailability {
        if !enabled { return .available }
        if monitors.isEmpty { return .limited("No external monitor connected") }
        return .available
    }

    /// Whether any monitor takes brightness from Atelier, for HUD's own availability line.
    var drivesAny: Bool { enabled && monitors.contains { $0.route == .ddc || $0.route == .software } }

    // MARK: Lifecycle

    private func start() {
        refresh()
        guard observers.isEmpty else { return }
        let later: @Sendable (Notification) -> Void = { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { ExternalMonitors.shared.refresh(rereadAll: true) }
            }
        }
        observers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ExternalMonitors.shared.scheduleRefresh() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                              object: nil, queue: .main, using: later),
        ]
    }

    private func stop() {
        for timer in glides.values { timer.invalidate() }
        glides = [:]
        glideTargets = [:]
        for monitor in monitors where monitor.route == .software { LightEngine.shared.setMonitorDim(nil, for: monitor.id) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        links = [:]
        DDCCounters.shared.external = 0
        monitors = []
        skipped = []
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                ExternalMonitors.shared.refreshPending = false
                ExternalMonitors.shared.refresh()
            }
        }
    }

    // MARK: Discovery

    /// Finds the monitors, keeps the ones already known and probes the new ones.
    func refresh(rereadAll: Bool = false) {
        guard enabled else { return }
        let displays = LightEngine.displays()
        let found = DDCDiscovery.survey()
        survey = (found.services.filter { !$0.external }.count, found.services.filter(\.external).count)
        var skips: [(CGDirectDisplayID, String)] = []
        var candidates: [(id: UInt32, facts: DDCDisplayFacts)] = []
        var natives: Set<CGDirectDisplayID> = []
        for id in displays {
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let virtual = VirtualDisplays.shared.isVirtual(id)
            let hiddenMirror = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            let facts = DDCDiscovery.displayFacts(id)
            let service = found.services.max { DDCMatch.score(facts, $0) < DDCMatch.score(facts, $1) }
            let dummy = service.map { DDCEligibility.isDummy(manufacturer: $0.manufacturer, product: $0.productName) } ?? false
            let verdict = DDCEligibility.verdict(builtIn: builtIn, virtual: virtual, mirrorHidden: hiddenMirror,
                                                 appleNative: !builtIn && DisplayBrightness.canChange(id),
                                                 serviceLocation: nil, dummy: dummy)
            switch verdict {
            case .skip(let reason): skips.append((id, reason))
            case .native: natives.insert(id)
            case .ddc: candidates.append((id, facts))
            }
        }
        skipped = skips
        // Channels: Apple silicon by match against External AV services only; Intel through
        // the framebuffer when this Mac has no AV services at all.
        let external = found.services.filter(\.external)
        let assigned = DDCMatch.assign(displays: candidates, services: external)
        var newLinks: [CGDirectDisplayID: DDCLink] = [:]
        for candidate in candidates {
            if let old = links[candidate.id] { newLinks[candidate.id] = old; continue }
            if let index = assigned[candidate.id], let service = found.avServices[index] {
                newLinks[candidate.id] = DDCLink(display: candidate.id, channel: AVServiceChannel(service: service))
            } else if found.services.isEmpty, let framebuffer = DDCDiscovery.framebuffer(for: candidate.id),
                      let channel = FramebufferChannel(framebuffer: framebuffer) {
                newLinks[candidate.id] = DDCLink(display: candidate.id, channel: channel)
            }
        }
        // A single unmatched External service and a single candidate left: MonitorControl's
        // fallback for adapters that hide the EDID UUID.
        if external.count == 1, candidates.count == 1, newLinks.isEmpty, let service = found.avServices.values.first {
            newLinks[candidates[0].id] = DDCLink(display: candidates[0].id, channel: AVServiceChannel(service: service))
        }
        links = newLinks
        DDCCounters.shared.external = newLinks.count

        // Monitors: keep the known ones, drop the gone ones, add and probe the new ones.
        let wanted = candidates.map(\.id) + natives.sorted()
        for gone in monitors where !wanted.contains(gone.id) && gone.route == .software {
            LightEngine.shared.setMonitorDim(nil, for: gone.id)
        }
        var next: [Monitor] = []
        for id in wanted {
            if var known = monitors.first(where: { $0.id == id }) {
                if rereadAll, known.route == .ddc { links[id]?.forgetWritten(); probe(id) ; known.probing = true }
                next.append(known)
                continue
            }
            let facts = candidates.first { $0.id == id }?.facts ?? DDCDiscovery.displayFacts(id)
            let name = Self.name(of: id, facts: facts)
            let key = DDCMemory.key(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                    serial: CGDisplaySerialNumber(id), name: name)
            var monitor = Monitor(id: id, name: name, memoryKey: key, route: .none, transport: links[id]?.kind ?? "-")
            if natives.contains(id) {
                monitor.route = .native
                monitor.probing = false
                monitor.brightness = DisplayBrightness.level(id) ?? 1
            } else if links[id] != nil {
                probe(id)
            } else {
                monitor.probing = false
                applyNoAnswer(&monitor)
            }
            next.append(monitor)
        }
        monitors = next
    }

    private static func name(of id: CGDirectDisplayID, facts: DDCDisplayFacts) -> String {
        if let screen = NSScreen.screens.first(where: { $0.displayID == id }) { return screen.localizedName }
        return facts.name.isEmpty ? "Display \(id)" : facts.name
    }

    /// Reads what the monitor has now. Brightness first, with short timings: a monitor that
    /// does not answer it gets the software dimmer and is not asked again.
    private func probe(_ id: CGDirectDisplayID) {
        guard let link = links[id] else { return }
        link.read(.brightness, probe: true) { reply in
            MainActor.assumeIsolated { ExternalMonitors.shared.probed(id, .brightness, reply, first: true) }
        }
    }

    private func probed(_ id: CGDirectDisplayID, _ code: VCPCode, _ reply: DDCPacket.Reply, first: Bool = false) {
        guard let index = monitors.firstIndex(where: { $0.id == id }) else { return }
        var monitor = monitors[index]
        switch reply {
        case .value(let current, let maximum):
            monitor.maxima[code.rawValue] = maximum
            let fraction = DDCScale.fraction(current, maximum: maximum)
            switch code {
            case .brightness: monitor.brightness = fraction
            case .contrast: monitor.contrast = fraction
            case .volume: monitor.volume = fraction
            case .mute: monitor.muted = DDCScale.isMuted(current)
            case .input: monitor.input = DDCInput.normalized(current)
            }
            rememberOriginal(monitor.memoryKey, code, current)
            if first {
                monitor.route = .ddc
                // The rest, one after another on the monitor's queue.
                for next in [VCPCode.contrast, .volume, .mute, .input] {
                    links[id]?.read(next) { reply in
                        MainActor.assumeIsolated { ExternalMonitors.shared.probed(id, next, reply) }
                    }
                }
            }
            // Probing ends with the last read of the round, input, whatever it answers.
            if code == .input { monitor.probing = false }
        case .unsupported, .invalid:
            if first {
                monitor.probing = false
                applyNoAnswer(&monitor)
            } else if code == .input {
                monitor.probing = false
            }
        }
        monitors[index] = monitor
    }

    private func applyNoAnswer(_ monitor: inout Monitor) {
        guard softwareFallback else {
            monitor.route = .none
            return
        }
        monitor.route = .software
        monitor.brightness = store.object(forKey: monitor.memoryKey + ".software") as? Double ?? 1
        LightEngine.shared.setMonitorDim(DDCScale.softwareScale(monitor.brightness), for: monitor.id)
    }

    private func reprobeSoftware() {
        for index in monitors.indices where monitors[index].route == .software || monitors[index].route == .none {
            var monitor = monitors[index]
            LightEngine.shared.setMonitorDim(nil, for: monitor.id)
            applyNoAnswer(&monitor)
            monitors[index] = monitor
        }
    }

    // MARK: Memory

    private func rememberOriginal(_ key: String, _ code: VCPCode, _ raw: UInt16) {
        guard code != .input else { return }
        var original = store.dictionary(forKey: key + ".original") as? [String: Int] ?? [:]
        guard original[code.key] == nil else { return }
        original[code.key] = Int(raw)
        store.set(original, forKey: key + ".original")
    }

    /// Writes back what each monitor had when Atelier first met it, and lifts every software dim.
    func restoreMonitors() {
        for monitor in monitors {
            switch monitor.route {
            case .ddc:
                let original = store.dictionary(forKey: monitor.memoryKey + ".original") as? [String: Int] ?? [:]
                for code in [VCPCode.brightness, .contrast, .volume, .mute] {
                    guard let raw = original[code.key], let link = links[monitor.id] else { continue }
                    link.push(code, UInt16(clamping: raw))
                }
            case .software:
                store.removeObject(forKey: monitor.memoryKey + ".software")
                glide(software: monitor.id, to: 1)
            case .native, .none: break
            }
        }
        lastNote = "Put back each monitor's own settings."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { ExternalMonitors.shared.refresh(rereadAll: true) }
        }
    }

    // MARK: Setting values

    func monitor(_ id: CGDirectDisplayID) -> Monitor? { monitors.first { $0.id == id } }

    /// From a slider (no glide: the drag is the motion) or a key (a short glide).
    func set(_ code: VCPCode, _ fraction: Double, on id: CGDirectDisplayID, glide: Bool = false) {
        guard let index = monitors.firstIndex(where: { $0.id == id }) else { return }
        let f = min(max(fraction, 0), 1)
        let monitor = monitors[index]
        switch (monitor.route, code) {
        case (.software, .brightness):
            store.set(f, forKey: monitor.memoryKey + ".software")
            if glide { self.glide(software: id, to: f) } else {
                cancelGlide(id)
                softwareNow[id] = f
                LightEngine.shared.setMonitorDim(DDCScale.softwareScale(f), for: id)
            }
            monitors[index].brightness = f
        case (.ddc, .brightness), (.ddc, .contrast), (.ddc, .volume):
            guard let link = links[id] else { return }
            let maximum = monitor.maxima[code.rawValue] ?? 100
            if glide, code == .brightness {
                self.glide(ddc: link, from: monitor.brightness, to: f, maximum: maximum)
            } else {
                link.push(code, DDCScale.raw(f, maximum: maximum))
            }
            switch code {
            case .brightness: monitors[index].brightness = f
            case .contrast: monitors[index].contrast = f
            default: monitors[index].volume = f
            }
        default: break
        }
    }

    func setMuted(_ muted: Bool, on id: CGDirectDisplayID) {
        guard let index = monitors.firstIndex(where: { $0.id == id }), monitors[index].route == .ddc,
              monitors[index].muted != nil, let link = links[id] else { return }
        link.push(.mute, DDCScale.muteValue(muted))
        monitors[index].muted = muted
    }

    /// Switching input usually takes the monitor away from this Mac; the card says so.
    func setInput(_ raw: UInt16, on id: CGDirectDisplayID) {
        guard let index = monitors.firstIndex(where: { $0.id == id }), monitors[index].route == .ddc, let link = links[id] else { return }
        link.push(.input, raw)
        monitors[index].input = raw
    }

    private func cancelGlide(_ id: CGDirectDisplayID) {
        glides[id]?.invalidate()
        glides[id] = nil
        glideTargets[id] = nil
        glideSteps[id] = nil
        softwareGlide[id] = nil
    }

    /// DDC: a handful of eased steps at 20 Hz; the link's coalescer drops any the bus cannot keep up with.
    private func glide(ddc link: DDCLink, from start: Double, to end: Double, maximum: UInt16) {
        let id = link.display
        cancelGlide(id)
        var steps = DDCGlide.steps(from: start, to: end, maximum: maximum)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let last = steps.last { steps = [last] }
        guard !steps.isEmpty else { return }
        link.push(.brightness, steps.removeFirst())
        guard !steps.isEmpty else { return }
        glideSteps[id] = steps
        glideTargets[id] = end
        let timer = Timer(timeInterval: 1 / 20, repeats: true) { _ in
            MainActor.assumeIsolated { ExternalMonitors.shared.ddcGlideStep(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        glides[id] = timer
    }

    private var glideSteps: [CGDirectDisplayID: [UInt16]] = [:]

    private func ddcGlideStep(_ id: CGDirectDisplayID) {
        guard var steps = glideSteps[id], !steps.isEmpty, let link = links[id] else {
            cancelGlide(id)
            return
        }
        link.push(.brightness, steps.removeFirst())
        glideSteps[id] = steps
    }

    /// Software: the gamma scale eased at 60 Hz over a quarter of a second.
    private func glide(software id: CGDirectDisplayID, to end: Double) {
        let start = softwareNow[id] ?? monitor(id)?.brightness ?? 1
        cancelGlide(id)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            softwareNow[id] = end
            LightEngine.shared.setMonitorDim(DDCScale.softwareScale(end), for: id)
            return
        }
        glideTargets[id] = end
        softwareGlide[id] = (start, end, CACurrentMediaTime())
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { ExternalMonitors.shared.softwareGlideStep(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        glides[id] = timer
        softwareGlideStep(id)
    }

    private var softwareGlide: [CGDirectDisplayID: (start: Double, end: Double, began: Double)] = [:]

    private func softwareGlideStep(_ id: CGDirectDisplayID) {
        guard let glide = softwareGlide[id] else { cancelGlide(id); return }
        let t = min((CACurrentMediaTime() - glide.began) / 0.25, 1)
        let eased = 1 - pow(1 - t, 3)
        let level = glide.start + (glide.end - glide.start) * eased
        softwareNow[id] = level
        LightEngine.shared.setMonitorDim(DDCScale.softwareScale(level), for: id)
        if t >= 1 { cancelGlide(id) }
    }

    /// Where the software dim of each display is right now, mid-glide included.
    private var softwareNow: [CGDirectDisplayID: Double] = [:]

    // MARK: Keys, for Atelier HUD

    private var pointerDisplay: CGDirectDisplayID? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }?.displayID
    }

    /// The monitor the brightness keys should move: the one under the pointer, when Atelier
    /// drives it. Nil leaves the key to HUD's own path (built-in, Apple displays) or macOS.
    var brightnessKeyTarget: CGDirectDisplayID? {
        guard enabled, keysEnabled, let id = pointerDisplay,
              let monitor = monitor(id), monitor.route == .ddc || monitor.route == .software else { return nil }
        return id
    }

    /// One brightness key: the next step, glided. Returns the new level for the HUD.
    func stepBrightness(_ id: CGDirectDisplayID, up: Bool, fine: Bool) -> Double? {
        guard let monitor = monitor(id) else { return nil }
        let current = glideTargets[id] ?? monitor.brightness
        let next = HUDStep.step(current, up: up, fine: fine)
        set(.brightness, next, on: id, glide: true)
        return next
    }

    /// The monitor whose speakers the sound goes to: when the output is HDMI or DisplayPort
    /// audio with no volume of its own, the monitor of that name, else the one under the
    /// pointer, else the only one with a volume control.
    var volumeKeyTarget: CGDirectDisplayID? {
        guard enabled, keysEnabled, !SystemVolume.controllable, MonitorAudio.outputIsDisplay else { return nil }
        let candidates = monitors.filter { $0.route == .ddc && $0.volume != nil }
        let name = MonitorAudio.outputName
        if let match = candidates.first(where: { DDCAudio.matches(device: name, display: $0.name) }) { return match.id }
        if let pointer = pointerDisplay, candidates.contains(where: { $0.id == pointer }) { return pointer }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    /// A volume key: up or down, or mute when `up` is nil. Returns level and mute for the HUD.
    func stepVolume(_ id: CGDirectDisplayID, up: Bool?, fine: Bool) -> (level: Double, muted: Bool)? {
        guard let monitor = monitor(id), let level = monitor.volume else { return nil }
        guard let up else {
            guard let muted = monitor.muted else { return nil }
            setMuted(!muted, on: id)
            return (level, !muted)
        }
        let next = HUDStep.step(level, up: up, fine: fine)
        set(.volume, next, on: id)
        // Any volume key brings the sound back, as on a stock Mac.
        if monitor.muted == true { setMuted(false, on: id) }
        return (next, false)
    }

    // MARK: Diagnostics and tests

    var diagnostics: String {
        let list = monitors.map { m in
            "\(m.id):\(m.route.rawValue):b=\(String(format: "%.2f", m.brightness))"
                + (m.contrast.map { String(format: ":c=%.2f", $0) } ?? "")
                + (m.volume.map { String(format: ":v=%.2f", $0) } ?? "")
                + (m.input.map { ":in=" + DDCInput.name($0).replacingOccurrences(of: " ", with: "") } ?? "")
        }.joined(separator: ",")
        let skips = skipped.map { "\($0.id):\($0.reason.replacingOccurrences(of: " ", with: "-"))" }.joined(separator: ",")
        let counters = DDCCounters.shared
        return "ddcOn=\(enabled) ddcKeys=\(keysEnabled) ddcSoftware=\(softwareFallback) ddcAV=\(DDCPrivate.avAvailable) "
            + "ddcServices=embedded:\(survey.embedded)/external:\(survey.external) ddcLinks=\(links.count) "
            + "ddcMonitors=\(list.isEmpty ? "-" : list) ddcSkipped=\(skips.isEmpty ? "-" : skips) "
            + "ddcReads=\(counters.reads) ddcWrites=\(counters.writes) ddcRefused=\(counters.refused)"
    }

    private static let reportPath = NSTemporaryDirectory() + "atelier-ddc.txt"

    private func report(_ lines: [String], append: Bool = false) {
        var text = lines.joined(separator: "\n") + "\n"
        if append, let old = try? String(contentsOfFile: Self.reportPath, encoding: .utf8) { text = old + text }
        try? text.write(toFile: Self.reportPath, atomically: true, encoding: .utf8)
    }

    /// `atelier://ddc?list` (also the default) writes every display, its verdict and route to
    /// $TMPDIR/atelier-ddc.txt; `?read=0x10[&display=ID]` reads one code (the answer is
    /// appended when it comes); `?set=0x10&value=50[&display=ID]` writes a raw value straight
    /// to the bus; `?brightness=0.4` (or contrast=, volume=) goes through the engine with
    /// glide, memory and the software fallback; `?refresh`; `on=1|0`, `keys=1|0`,
    /// `software=1|0` and `restore=1` change the settings. Writes are refused, and logged, with
    /// no external display or a code outside the allowed five.
    func handleTest(_ items: [URLQueryItem]) {
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let on = value("on") { enabled = on == "1" }
        if let on = value("keys") { keysEnabled = on == "1" }
        if let on = value("software") { softwareFallback = on == "1" }
        if value("restore") != nil { restoreMonitors() }
        let command = DDCCommand.parse(items.map { ($0.name, $0.value) })
        func target(_ display: UInt32?) -> CGDirectDisplayID? {
            if let display { return display }
            return monitors.first { $0.route == .ddc }?.id ?? monitors.first?.id
        }
        switch command {
        case .list, .refresh:
            if case .refresh = command { refresh(rereadAll: true) }
            report(listing())
        case .invalid(let why):
            DDCCounters.shared.refuse()
            report(["refused: \(why)"] + listing())
        case .read(let code, let display):
            guard let id = target(display), let link = links[id] else {
                report(["read \(code.key): no DDC channel\(display.map { " on display \($0)" } ?? "") — nothing sent"] + listing())
                return
            }
            report(["read \(code.key) on \(id): sent"])
            link.read(code) { reply in
                MainActor.assumeIsolated {
                    ExternalMonitors.shared.report(["read \(code.key) on \(id): \(reply)"], append: true)
                    ExternalMonitors.shared.probed(id, code, reply)
                }
            }
        case .set(let code, let raw, let display):
            guard DDCCounters.shared.external > 0, let id = target(display), let link = links[id] else {
                DDCCounters.shared.refuse()
                report(["set \(code.key)=\(raw): refused, no external display with DDC — nothing sent"] + listing())
                return
            }
            report(["set \(code.key)=\(raw) on \(id): queued"])
            link.push(code, raw) { ok in
                MainActor.assumeIsolated { ExternalMonitors.shared.report(["set \(code.key)=\(raw) on \(id): \(ok ? "bus took it" : "failed")"], append: true) }
            }
        case .level(let code, let fraction, let display):
            guard let id = target(display), monitor(id) != nil else {
                report(["\(code.key)=\(fraction): no monitor Atelier drives — nothing sent"] + listing())
                return
            }
            set(code, fraction, on: id, glide: code == .brightness)
            report(["\(code.key)=\(fraction) on \(id) via \(monitor(id)?.route.rawValue ?? "-")"])
        }
    }

    private func listing() -> [String] {
        let found = DDCDiscovery.survey()
        var lines = ["ddc enabled=\(enabled) keys=\(keysEnabled) software=\(softwareFallback) avSymbols=\(DDCPrivate.avAvailable)"]
        for service in found.services {
            lines.append("service #\(service.index) location=\(service.location) product=\(service.productName.isEmpty ? "-" : service.productName) avOpened=\(found.avServices[service.index] != nil)")
        }
        for id in LightEngine.displays() {
            let facts = DDCDiscovery.displayFacts(id)
            let state = monitors.first { $0.id == id }.map { "route=\($0.route.rawValue) transport=\($0.transport) probing=\($0.probing) brightness=\(String(format: "%.3f", $0.brightness))" }
                ?? skipped.first { $0.id == id }.map { "skipped=\($0.reason)" } ?? (enabled ? "not handled" : "feature off")
            lines.append("display \(id) \"\(facts.name)\" builtin=\(CGDisplayIsBuiltin(id) != 0) vendor=\(String(facts.vendor, radix: 16)) link=\(links[id] != nil) \(state)")
        }
        lines.append(diagnostics)
        return lines
    }
}

/// The default output device's name and transport, to tell when the sound goes to a monitor.
enum MonitorAudio {
    static var outputIsDisplay: Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(SystemVolume.device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
    }

    static var outputName: String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(SystemVolume.device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "" }
        return value as String
    }
}
