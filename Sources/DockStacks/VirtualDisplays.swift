import AppKit
import CoreGraphics
import DockCore

// MARK: - HiDPI Anywhere and Virtual Screens
//
// macOS offers HiDPI ("looks like" sizes drawn at twice the pixels) only on panels it considers
// dense. On a 24" 1080p or 27" 1440p monitor it does not, so text stays coarse and the scaled
// sizes are missing. CoreGraphics has a private virtual-display class family (CGVirtualDisplay,
// the one Sidecar and AirPlay use) that can make a display of any size, in HiDPI. Two features
// come out of it:
//
// - Virtual screens: headless displays for sharing, recording or testing at any size and refresh.
// - HiDPI Anywhere: a HiDPI virtual display at twice the wanted size, and the real monitor set to
//   mirror it (`CGConfigureDisplayMirrorOfDisplay`). The monitor then shows the virtual display's
//   2× framebuffer scaled to its panel: the BetterDummy / DeskPad technique.
//
// The classes are reached through @objc protocols over NSClassFromString, never linked: if a
// release drops or renames them, `available` is false and the card says so. Nothing outlives
// Atelier: a virtual display exists only while this process holds its object, so quitting or
// crashing removes it, and mirroring onto a display that no longer exists ends with it. Mirroring
// is configured `.forSession`, and at launch any mirroring recorded by a run that did not clean up
// is undone before anything else.

// The private interface, as the runtime has it (macOS 11+). Only these members are used; each
// selector is checked with `responds(to:)` before it is called.

@objc private protocol VDDescriptor: NSObjectProtocol {
    init()
    var name: String { get set }
    var maxPixelsWide: UInt32 { get set }
    var maxPixelsHigh: UInt32 { get set }
    var sizeInMillimeters: CGSize { get set }
    var serialNum: UInt32 { get set }
    var productID: UInt32 { get set }
    var vendorID: UInt32 { get set }
    func setDispatchQueue(_ queue: DispatchQueue)
}

@objc private protocol VDMode: NSObjectProtocol {
    init(width: UInt, height: UInt, refreshRate: CGFloat)
}

@objc private protocol VDSettings: NSObjectProtocol {
    init()
    var modes: [AnyObject] { get set }
    var hiDPI: UInt32 { get set }
}

@objc private protocol VDDisplay: NSObjectProtocol {
    init(descriptor: AnyObject)
    var displayID: UInt32 { get }
    @objc(applySettings:) func apply(_ settings: AnyObject) -> Bool
}

/// The runtime half: looks the classes up once and builds displays from a plan.
private enum VirtualRuntime {
    static let descriptorClass: AnyClass? = NSClassFromString("CGVirtualDisplayDescriptor")
    static let modeClass: AnyClass? = NSClassFromString("CGVirtualDisplayMode")
    static let settingsClass: AnyClass? = NSClassFromString("CGVirtualDisplaySettings")
    static let displayClass: AnyClass? = NSClassFromString("CGVirtualDisplay")

    static let available: Bool = {
        guard let descriptorClass, let modeClass, let settingsClass, let displayClass else { return false }
        let needs: [(AnyClass, String)] = [
            (descriptorClass, "setName:"), (descriptorClass, "setMaxPixelsWide:"), (descriptorClass, "setMaxPixelsHigh:"),
            (descriptorClass, "setSizeInMillimeters:"), (descriptorClass, "setSerialNum:"), (descriptorClass, "setProductID:"),
            (descriptorClass, "setVendorID:"), (descriptorClass, "setDispatchQueue:"),
            (modeClass, "initWithWidth:height:refreshRate:"),
            (settingsClass, "setModes:"), (settingsClass, "setHiDPI:"),
            (displayClass, "initWithDescriptor:"), (displayClass, "applySettings:"), (displayClass, "displayID"),
        ]
        return needs.allSatisfy { class_getInstanceMethod($0.0, NSSelectorFromString($0.1)) != nil }
    }()

    /// Atelier's vendor number on every virtual display, so they can be told apart from real ones.
    static let vendorID: UInt32 = 0x4154   // "AT"
    static let productID: UInt32 = 0x5653  // "VS"

    /// A live display, or nil. The returned object *is* the display: dropping it removes it.
    @MainActor static func make(name: String, plan: VirtualDisplayPlan, serial: UInt32) -> (object: NSObject, id: CGDirectDisplayID)? {
        guard available, let descriptorClass, let modeClass, let settingsClass, let displayClass else { return nil }
        let descriptor = unsafeBitCast(descriptorClass, to: VDDescriptor.Type.self).init()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(plan.maxPixelsWide)
        descriptor.maxPixelsHigh = UInt32(plan.maxPixelsHigh)
        descriptor.sizeInMillimeters = CGSize(width: plan.sizeInMillimeters.width, height: plan.sizeInMillimeters.height)
        descriptor.serialNum = serial
        descriptor.productID = productID
        descriptor.vendorID = vendorID

        let display = unsafeBitCast(displayClass, to: VDDisplay.Type.self).init(descriptor: descriptor)
        let id = display.displayID
        guard id != 0 else { return nil }

        let settings = unsafeBitCast(settingsClass, to: VDSettings.Type.self).init()
        settings.hiDPI = plan.hiDPI ? 1 : 0
        settings.modes = plan.modeSizes.map {
            unsafeBitCast(modeClass, to: VDMode.Type.self).init(width: UInt($0.width), height: UInt($0.height),
                                                                 refreshRate: CGFloat(plan.refreshRate))
        }
        guard display.apply(settings) else { return nil }
        return (display as AnyObject as! NSObject, id)
    }
}

@MainActor
final class VirtualDisplays: ObservableObject {
    static let shared = VirtualDisplays()

    enum Keys {
        /// Every virtual screen to bring back at launch: JSON [Spec].
        static let screens = "virtualDisplays.screens"
        /// Physical displays Atelier set mirroring on, by UUID, until it is undone.
        static let mirrored = "virtualDisplays.mirrored"
        /// Recreate the screens at launch (default on).
        static let restoreAtLaunch = "virtualDisplays.restoreAtLaunch"
    }

    /// One virtual screen, as saved. With `mirrorTarget` it is HiDPI Anywhere for that monitor.
    struct Spec: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var width: Int
        var height: Int
        var refreshRate: Double = 60
        var hiDPI: Bool = true
        /// The physical display (UUID) that mirrors this one, for HiDPI on it.
        var mirrorTarget: String?
        var mirrorTargetName: String?
        var serial: UInt32 = 1
    }

    /// A screen that exists right now.
    struct Live {
        let object: NSObject
        let displayID: CGDirectDisplayID
        var mirrored: CGDirectDisplayID?
    }

    /// A real monitor, for the HiDPI list.
    struct Monitor: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let uuid: String
        let name: String
        let builtIn: Bool
        let nativeWidth: Int
        let nativeHeight: Int
        let millimetres: CGSize
        var ppi: Double? { HiDPIMath.ppi(pixelWidth: nativeWidth, millimetres: Double(millimetres.width)) }
        var lowPPI: Bool { (ppi ?? 0) < HiDPIMath.lowPPI }
    }

    @Published private(set) var specs: [Spec] = []
    @Published private(set) var live: [UUID: Live] = [:]
    @Published private(set) var monitors: [Monitor] = []
    @Published private(set) var lastError: String?

    private let store = UserDefaults.standard
    private var observer: NSObjectProtocol?

    private init() {
        specs = store.data(forKey: Keys.screens).flatMap { try? JSONDecoder().decode([Spec].self, from: $0) } ?? []
    }

    var availability: FeatureAvailability {
        VirtualRuntime.available ? .available : .unavailable("This macOS does not offer virtual displays")
    }

    // MARK: Lifecycle

    func resume() {
        cleanUpStaleMirroring()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VirtualDisplays.shared.refreshMonitors() }
        }
        // After a crash the screens wait for a click: if making one is what crashed, bringing
        // them all back at once would crash again on every relaunch.
        let afterCrash = CommandLine.arguments.contains("--relaunched-after-crash")
        if store.object(forKey: Keys.restoreAtLaunch) as? Bool ?? true, VirtualRuntime.available, !afterCrash {
            for spec in specs { bringUp(spec) }
        } else if afterCrash, !specs.isEmpty {
            lastError = "Virtual screens were not brought back after a crash. Start them below."
        }
        refreshMonitors()
    }

    /// For `applicationWillTerminate`: mirroring undone, every virtual display released. The specs
    /// stay, so the next launch brings them back.
    func restoreOnQuit() {
        unmirrorAll()
        live.removeAll()
        store.removeObject(forKey: Keys.mirrored)
    }

    /// A run that crashed may have left a monitor mirroring a display that died with it. macOS
    /// usually ends such mirroring itself; this makes sure.
    private func cleanUpStaleMirroring() {
        let recorded = store.stringArray(forKey: Keys.mirrored) ?? []
        guard !recorded.isEmpty else { return }
        for uuid in recorded {
            guard let display = DisplayModeKit.display(withUUID: uuid) else { continue }
            let source = CGDisplayMirrorsDisplay(display)
            if source != kCGNullDirectDisplay, !live.values.contains(where: { $0.displayID == source }) {
                setMirror(display, of: kCGNullDirectDisplay)
            }
        }
        store.removeObject(forKey: Keys.mirrored)
    }

    // MARK: Virtual screens

    /// A new headless screen. `hiDPI` makes `width`×`height` the point size, at twice the pixels.
    @discardableResult
    func add(width: Int, height: Int, refreshRate: Double = 60, hiDPI: Bool = true, name: String? = nil) -> Spec? {
        lastError = nil
        let spec = Spec(name: name ?? "Atelier Screen \(width)×\(height)", width: width, height: height,
                        refreshRate: refreshRate, hiDPI: hiDPI, serial: nextSerial())
        guard bringUp(spec) else { return nil }
        specs.append(spec)
        save()
        return spec
    }

    /// Removes one screen: mirroring onto a monitor is undone first, then the display goes.
    func remove(_ id: UUID) {
        if let item = live[id], let monitor = item.mirrored { setMirror(monitor, of: kCGNullDirectDisplay) }
        live[id] = nil
        specs.removeAll { $0.id == id }
        save()
        recordMirrored()
        refreshMonitors()
    }

    /// Brings a saved screen up again (after a crash, or a monitor that came back).
    func start(_ id: UUID) {
        guard live[id] == nil, let spec = specs.first(where: { $0.id == id }) else { return }
        lastError = nil
        bringUp(spec)
    }

    func removeAll() {
        for spec in specs { remove(spec.id) }
    }

    // MARK: HiDPI Anywhere

    /// HiDPI on a real monitor at `points` ("looks like"): a HiDPI virtual display at twice that
    /// size, of the monitor's physical size, which the monitor then mirrors.
    func enableHiDPI(on monitor: Monitor, points: (width: Int, height: Int), refreshRate: Double? = nil) {
        lastError = nil
        if let existing = hiDPISpec(for: monitor) { remove(existing.id) }
        let hz = refreshRate ?? DisplayModeKit.current(monitor.id).map { $0.refreshRate > 0 ? $0.refreshRate : 60 } ?? 60
        let spec = Spec(name: "\(monitor.name) (HiDPI)", width: points.width, height: points.height, refreshRate: hz,
                        hiDPI: true, mirrorTarget: monitor.uuid, mirrorTargetName: monitor.name, serial: nextSerial())
        guard bringUp(spec) else { return }
        specs.append(spec)
        save()
    }

    func disableHiDPI(on monitor: Monitor) {
        if let spec = hiDPISpec(for: monitor) { remove(spec.id) }
    }

    func hiDPISpec(for monitor: Monitor) -> Spec? { specs.first { $0.mirrorTarget == monitor.uuid } }

    // MARK: Making displays

    /// Creates the display for `spec`, picks its size, and mirrors the monitor onto it if asked.
    @discardableResult
    private func bringUp(_ spec: Spec) -> Bool {
        guard VirtualRuntime.available else {
            lastError = "Virtual displays are not available on this macOS."
            return false
        }
        var millimetres: (width: Double, height: Double)?
        var target: CGDirectDisplayID?
        if let uuid = spec.mirrorTarget {
            guard let monitor = DisplayModeKit.display(withUUID: uuid) else {
                lastError = "\(spec.mirrorTargetName ?? "That monitor") is not connected."
                return false
            }
            target = monitor
            let size = CGDisplayScreenSize(monitor)
            if size.width > 1 { millimetres = (Double(size.width), Double(size.height)) }
        }
        guard let plan = HiDPIMath.plan(points: (spec.width, spec.height), refreshRate: spec.refreshRate,
                                        hiDPI: spec.hiDPI, millimetres: millimetres) else {
            lastError = "\(spec.width)×\(spec.height) is outside what a virtual display can be."
            return false
        }
        guard let made = VirtualRuntime.make(name: spec.name, plan: plan, serial: spec.serial) else {
            lastError = "macOS refused the virtual display."
            return false
        }
        live[spec.id] = Live(object: made.object, displayID: made.id, mirrored: nil)
        // The display arrives asynchronously; give WindowServer a moment before picking its mode.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { VirtualDisplays.shared.settle(spec, target: target) }
        }
        return true
    }

    private func settle(_ spec: Spec, target: CGDirectDisplayID?) {
        guard var item = live[spec.id] else { return }
        let scale = spec.hiDPI ? 2 : 1
        let modes = DisplayModeKit.modes(item.displayID)
        if let mode = modes.first(where: { $0.width == spec.width && $0.height == spec.height && $0.pixelWidth == spec.width * scale })
            ?? modes.first(where: { $0.width == spec.width && $0.height == spec.height }),
           DisplayModeKit.current(item.displayID) != mode {
            DisplayModeKit.apply(mode, on: item.displayID, scope: .forSession)
        }
        if let target {
            if setMirror(target, of: item.displayID) {
                item.mirrored = target
                live[spec.id] = item
                recordMirrored()
            } else {
                lastError = "Could not mirror \(spec.mirrorTargetName ?? "the monitor") onto its HiDPI screen."
            }
        }
        refreshMonitors()
    }

    /// `display` mirrors `source`; `kCGNullDirectDisplay` ends its mirroring.
    @discardableResult
    private func setMirror(_ display: CGDirectDisplayID, of source: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayMirrorOfDisplay(config, display, source) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    private func unmirrorAll() {
        for (id, item) in live {
            if let monitor = item.mirrored {
                setMirror(monitor, of: kCGNullDirectDisplay)
                live[id]?.mirrored = nil
            }
        }
    }

    private func recordMirrored() {
        let uuids = live.values.compactMap(\.mirrored).map(DisplayModeKit.uuid)
        if uuids.isEmpty { store.removeObject(forKey: Keys.mirrored) } else { store.set(uuids, forKey: Keys.mirrored) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(specs) { store.set(data, forKey: Keys.screens) }
    }

    /// A serial number per screen, so macOS remembers each one's arrangement separately.
    private func nextSerial() -> UInt32 { (specs.map(\.serial).max() ?? 0) + 1 }

    // MARK: Monitors

    func isVirtual(_ display: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(display) == VirtualRuntime.vendorID || live.values.contains { $0.displayID == display }
    }

    func refreshMonitors() {
        monitors = DisplayModeKit.onlineDisplays().filter { !isVirtual($0) }.map { id in
            let natives = DisplayModeKit.modes(id).filter(\.isNative)
            let native = natives.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
                ?? DisplayModeKit.current(id)
            let spec = specs.first { $0.mirrorTarget == DisplayModeKit.uuid(id) }
            return Monitor(id: id, uuid: DisplayModeKit.uuid(id), name: spec?.mirrorTargetName ?? DisplayModeKit.name(id),
                           builtIn: CGDisplayIsBuiltin(id) != 0,
                           nativeWidth: native?.pixelWidth ?? 0, nativeHeight: native?.pixelHeight ?? 0,
                           millimetres: CGDisplayScreenSize(id))
        }
        .sorted { ($0.builtIn ? 1 : 0, $0.id) < ($1.builtIn ? 1 : 0, $1.id) }
    }

    // MARK: Diagnostics and tests

    var diagnostics: String {
        let screens = specs.map { spec -> String in
            let item = live[spec.id]
            let mode = item.flatMap { DisplayModeKit.current($0.displayID) }
            return "\(spec.width)x\(spec.height)@\(Int(spec.refreshRate))\(spec.hiDPI ? "h" : "")"
                + ":\(item.map { String($0.displayID) } ?? "down")"
                + (mode.map { "=" + $0.signature } ?? "")
                + (item?.mirrored.map { "<-\($0)" } ?? "")
        }
        return "virtualAvailable=\(VirtualRuntime.available) virtualScreens=\(specs.count) virtualLive=\(live.count) "
            + "virtualList=\(screens.isEmpty ? "-" : screens.joined(separator: ",")) "
            + "virtualMirrored=\((store.stringArray(forKey: Keys.mirrored) ?? []).count) "
            + "virtualMonitors=\(monitors.map { "\($0.id):\($0.nativeWidth)x\($0.nativeHeight)@\(Int($0.ppi ?? 0))ppi" }.joined(separator: ",")) "
            + "virtualError=\(lastError ?? "-")"
    }

    /// `atelier://virtual?add=1920x1080[@60]&hidpi=1|0`, `?remove=all|<uuid>`,
    /// `?hidpi-on=<displayID>&size=1440x810`, `?hidpi-off=<displayID>`.
    func handleTest(_ items: [URLQueryItem]) {
        let value = { (name: String) in items.first { $0.name == name }?.value }
        refreshMonitors()
        if let text = value("add"), let size = HiDPIMath.parseSize(text) {
            add(width: size.width, height: size.height, refreshRate: size.refresh ?? 60, hiDPI: value("hidpi") != "0")
        }
        if let target = value("remove") {
            if target == "all" { removeAll() } else if let id = UUID(uuidString: target) { remove(id) }
        }
        if let id = value("hidpi-on").flatMap(UInt32.init), let monitor = monitors.first(where: { $0.id == id }),
           let size = value("size").flatMap(HiDPIMath.parseSize) {
            enableHiDPI(on: monitor, points: (size.width, size.height), refreshRate: size.refresh)
        }
        if let id = value("hidpi-off").flatMap(UInt32.init), let monitor = monitors.first(where: { $0.id == id }) {
            disableHiDPI(on: monitor)
        }
    }
}
