import AppKit
import DockCore
import IOKit
import IOKit.hidsystem
import SwiftUI

// MARK: - Mouse Precision
//
// macOS has one Tracking Speed for every mouse, always with acceleration (the toggle in System
// Settings is global too), and tops out at a speed many high-resolution mice find slow. In the
// spirit of LinearMouse, this sets acceleration and speed per device, on the device's own HID
// service in the event system:
//
// - Acceleration is the service's HIDMouseAcceleration (HIDTrackpadAcceleration on a trackpad;
//   the service says which in HIDPointerAccelerationType), in 16.16 fixed point. -1 turns it off.
//   Where the service knows HIDUseLinearScalingMouseAcceleration (macOS 14 and later), Linear
//   sets that instead, the switch behind System Settings' own "Pointer acceleration", so speed
//   still scales the pointer.
// - Speed is HIDPointerResolution: the counts per inch macOS believes the mouse has. Claim fewer
//   and the pointer goes further per count. Apple's 400 can go down to 10, far past System
//   Settings' fastest. A resolution change takes effect when acceleration is written again, so
//   acceleration is always written last.
//
// None of it persists in the system: the values live in the running event system and are gone
// when the device reconnects or the Mac restarts. So Atelier writes them again when a device
// arrives (an IOKit match notification), and writes back what it found when a device is set to
// System, the feature goes off, or Atelier quits.
//
// Reading needs the private IOHIDEventSystemClientCreate: the public simple client returns nil
// for HIDPointerResolution on this Mac. Acceleration reads back nil from either client, so the
// value to restore comes from the registry's HIDEventServiceProperties, which is what System
// Settings asked for, and failing that from the event system's global value.
//
// Across releases: HIDUseLinearScalingMouseAcceleration arrived with macOS 14 (LinearMouse
// notes it reads nil before Sonoma), and is looked for per service rather than assumed. Apple's
// own pointing devices stopped honouring a written HIDPointerResolution: the Apple silicon
// built-in trackpad first, then Magic Mouse and Magic Trackpad from macOS 15 (LinearMouse
// #270, #806, #1003, #1004). The write is harmless there, so Speed is still offered, with a
// note (`MouseDeviceInfo.pointerSpeedHonoured`). IOHIDEventSystemClientCreate resolves on Intel
// and Apple silicon alike (checked by dlsym on both slices); the simple client stands in if
// it ever goes.
//
// Buttons ride a separate event tap: buttons 3 and 4 (side) and 2 (middle) become a keystroke
// or a Mission Control action. Apple's mice and trackpads never send those buttons, so the
// remap only ever meets other makers' mice.

private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?

/// Read by the tap's C callback, which runs outside any actor.
private nonisolated(unsafe) var tapButtonMap = MouseButtonMap.standard
private nonisolated(unsafe) var buttonTap: CFMachPort?
private nonisolated(unsafe) var remappedPresses = 0
/// Stamped on the keystrokes Atelier sends for a button, so a test can tell them apart.
let mouseButtonMark: Int64 = 0x41544D42

private func buttonCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                            _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        TapRevoke.disabled(type)
        if let buttonTap { CGEvent.tapEnable(tap: buttonTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged else {
        return Unmanaged.passUnretained(event)
    }
    let action = tapButtonMap.action(for: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
    guard action != .passThrough else { return Unmanaged.passUnretained(event) }
    if type == .otherMouseDown {
        remappedPresses += 1
        // The tap's run loop source is on the main run loop, so this is the main thread.
        MainActor.assumeIsolated { MousePrecision.perform(action) }
    }
    // Down, drag and up are all swallowed, so the app never sees half a click.
    return nil
}

/// IOKit match and terminate notifications for HID event services: a mouse plugged in,
/// woken from sleep, or gone. The port runs on the main run loop.
private func hidServicesChanged(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    var service = IOIteratorNext(iterator)
    while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
    MainActor.assumeIsolated { MousePrecision.shared.servicesChanged() }
}

@MainActor
final class MousePrecision: ObservableObject {
    static let shared = MousePrecision()

    struct Device: Identifiable, Equatable {
        /// The persistent key (vendor, product, name). Settings follow it across reconnects.
        let id: String
        let name: String
        let vendor: Int?
        let product: Int?
        let builtIn: Bool
        let trackpad: Bool
        /// HIDMouseAcceleration or HIDTrackpadAcceleration.
        let accelKey: String
        /// Whether the service knows HIDUseLinearScalingMouseAcceleration.
        let linearScaling: Bool
        let registryIDs: [UInt64]
        var apple: Bool { MouseDeviceInfo.isApple(vendor: vendor, builtIn: builtIn) }
        var vendorName: String { builtIn ? "Built-in" : MouseDeviceInfo.vendorName(vendor) }
        /// Whether this macOS still applies a Pointer Speed written to this device.
        var speedHonoured: Bool {
            MouseDeviceInfo.pointerSpeedHonoured(vendor: vendor, builtIn: builtIn, trackpad: trackpad,
                                                 macOSMajor: MacPlatform.major, appleSilicon: MacPlatform.appleSilicon)
        }
    }

    struct Setting: Codable, Equatable {
        var curve: MouseCurve = .system
        /// The acceleration for `.custom`, in macOS's scale (0...3 in System Settings).
        var custom = 0.6875
        /// Pointer Speed multiplier; 1 leaves HIDPointerResolution as found.
        var speed = 1.0

        var acceleration: Double? { curve == .custom ? custom : curve.acceleration }
        var touches: Bool { curve != .system || abs(speed - 1) > 0.001 }
    }

    /// What a service had before Atelier first wrote to it, restored exactly when done.
    private struct Original {
        var accel: Int
        var linear: Int?
        var resolution: Int?
    }

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "mousePrecision.enabled"); applyAll() } }
    @Published private(set) var devices: [Device] = []
    @Published var selection: String?
    @Published private(set) var settings: [String: Setting]
    @Published var buttons: Bool { didSet { store.set(buttons, forKey: "mousePrecision.buttons"); applyTap() } }
    @Published var buttonMap: MouseButtonMap {
        didSet {
            tapButtonMap = buttonMap
            if let data = try? JSONEncoder().encode(buttonMap) { store.set(data, forKey: "mousePrecision.buttonMap") }
        }
    }

    private let store = UserDefaults.standard
    private var client: IOHIDEventSystemClient?
    private var services: [UInt64: IOHIDServiceClient] = [:]
    private var originals: [UInt64: Original] = [:]
    /// What Atelier wrote, per service, for the diagnostics line.
    private var written: [UInt64: String] = [:]
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var source: CFRunLoopSource?
    private var watchTimer: Timer?
    private var lastGlobal: [String: Int] = [:]

    /// The acceleration System Settings gives every mouse, for drawing "System".
    private(set) var systemAcceleration = 0.6875

    var tapActive: Bool { buttonTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    /// For tests: button presses turned into something else since launch.
    var remapped: Int { remappedPresses }

    var diagnostics: String {
        let linear = devices.filter { settings[$0.id]?.curve == .linear && enabled }.map(\.name)
        let accel = devices.map { device -> String in
            let values = device.registryIDs.compactMap { written[$0] }
            return "\(device.name.replacingOccurrences(of: " ", with: "_")):\(values.first ?? "system")"
        }
        return "mouseDevices=\(devices.count) mouseLinear=\(linear.isEmpty ? "-" : linear.joined(separator: ",").replacingOccurrences(of: " ", with: "_")) " +
            "mouseAccel=\(accel.isEmpty ? "-" : accel.joined(separator: ",")) mouseButtonsRemapped=\(remapped) " +
            "mouseButtonTap=\(tapActive) mouseButtonMap=\(buttonMap.remappedCount)"
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "mousePrecision.enabled")
        buttons = UserDefaults.standard.bool(forKey: "mousePrecision.buttons")
        let decoder = JSONDecoder()
        settings = (UserDefaults.standard.data(forKey: "mousePrecision.settings"))
            .flatMap { try? decoder.decode([String: Setting].self, from: $0) } ?? [:]
        buttonMap = (UserDefaults.standard.data(forKey: "mousePrecision.buttonMap"))
            .flatMap { try? decoder.decode(MouseButtonMap.self, from: $0) } ?? .standard
        tapButtonMap = buttonMap
    }

    // MARK: Lifecycle

    /// Call once at launch. Nothing is read or written unless the feature is on.
    func resume() {
        InputTrust.watch()
        if enabled { refresh() }
        if buttons { applyTap() }
    }

    /// For `applicationWillTerminate`: every service gets back what it had. The switches stay
    /// on for the next launch.
    func restoreOnQuit() {
        restoreAll()
        removeTap()
    }

    /// Starts watching for devices (once) and lists them. The card calls this as it appears.
    func refresh() {
        startWatching()
        rescan()
    }

    func setting(for id: String) -> Setting { settings[id] ?? Setting() }

    func update(_ id: String, _ change: (inout Setting) -> Void) {
        var value = setting(for: id)
        change(&value)
        guard value != settings[id] else { return }
        settings[id] = value
        if let data = try? JSONEncoder().encode(settings) { store.set(data, forKey: "mousePrecision.settings") }
        if let device = devices.first(where: { $0.id == id }) { apply(device) }
    }

    var selectedDevice: Device? { devices.first { $0.id == selection } ?? devices.first }

    // MARK: Devices

    private func makeClient() -> IOHIDEventSystemClient? {
        if let client { return client }
        if let symbol = dlsym(dlopen(nil, RTLD_NOW), "IOHIDEventSystemClientCreate") {
            client = unsafeBitCast(symbol, to: CreateClient.self)(kCFAllocatorDefault)?.takeRetainedValue()
        }
        if client == nil { client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault) }
        return client
    }

    private func startWatching() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kind, IOServiceMatching("IOHIDEventService"), hidServicesChanged, nil, &iterator) == KERN_SUCCESS {
                // Arms the notification; the services already there are not news.
                var service = IOIteratorNext(iterator)
                while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
                iterators.append(iterator)
            }
        }
        // System Settings' Tracking Speed rewrites every service, ours included. A cheap check of
        // the global value notices that and writes ours again on top.
        let timer = Timer(timeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated { MousePrecision.shared.checkGlobal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    fileprivate func servicesChanged() {
        // The event system lists a new service a moment after IOKit matches it.
        for delay in [0.4, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MousePrecision.shared.rescan() }
        }
    }

    private func rescan() {
        guard let client = makeClient() else { return }
        let all = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        var found: [String: Device] = [:]
        var order: [String] = []
        var live: [UInt64: IOHIDServiceClient] = [:]
        for service in all {
            let mouse = IOHIDServiceClientConformsTo(service, 1, 2) != 0
            let trackpad = IOHIDServiceClientConformsTo(service, 13, 5) != 0
            guard mouse || trackpad, let id = registryID(service) else { continue }
            func property(_ key: String) -> CFTypeRef? { IOHIDServiceClientCopyProperty(service, key as CFString) }
            let name = (property("Product") as? String) ?? (trackpad ? "Trackpad" : "Mouse")
            let vendor = (property("VendorID") as? NSNumber)?.intValue
            let product = (property("ProductID") as? NSNumber)?.intValue
            let builtIn = (property("Built-In") as? NSNumber)?.boolValue ?? false
            let key = MouseDeviceInfo.key(vendor: vendor, product: product, name: name)
            live[id] = service
            let accelKey = (property("HIDPointerAccelerationType") as? String) ?? "HIDMouseAcceleration"
            let linear = registryProperties(id)["HIDUseLinearScalingMouseAcceleration"] != nil
            if let existing = found[key] {
                found[key] = Device(id: key, name: name, vendor: vendor, product: product, builtIn: builtIn,
                                    trackpad: existing.trackpad, accelKey: existing.accelKey,
                                    linearScaling: existing.linearScaling, registryIDs: existing.registryIDs + [id])
            } else {
                order.append(key)
                found[key] = Device(id: key, name: name, vendor: vendor, product: product, builtIn: builtIn,
                                    trackpad: trackpad && accelKey == "HIDTrackpadAcceleration", accelKey: accelKey,
                                    linearScaling: linear, registryIDs: [id])
            }
        }
        if let global = globalValue("HIDMouseAcceleration") { systemAcceleration = Fixed1616.decode(global) }
        let arrived = live.keys.filter { services[$0] == nil }
        services = live
        // A service that went away took its values with it; forget them so a reconnect starts fresh.
        originals = originals.filter { live[$0.key] != nil }
        written = written.filter { live[$0.key] != nil }
        // Third-party mice first: they are why anyone opens this card.
        let list = order.compactMap { found[$0] }.sorted { ($0.apple ? 1 : 0, $0.trackpad ? 1 : 0) < ($1.apple ? 1 : 0, $1.trackpad ? 1 : 0) }
        if list != devices { devices = list }
        if selection == nil || !list.contains(where: { $0.id == selection }) { selection = list.first?.id }
        if enabled {
            for device in list where device.registryIDs.contains(where: arrived.contains) { apply(device) }
        }
    }

    private func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    /// The HIDEventServiceProperties on the service or the nearest driver above it: what the
    /// system last asked of this device, which per-service writes do not change.
    private func registryProperties(_ id: UInt64) -> [String: Any] {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        guard entry != 0 else { return [:] }
        defer { IOObjectRelease(entry) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        return IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "HIDEventServiceProperties" as CFString, nil, options)
            as? [String: Any] ?? [:]
    }

    private func globalValue(_ key: String) -> Int? {
        guard let client = makeClient() else { return nil }
        return (IOHIDEventSystemClientCopyProperty(client, key as CFString) as? NSNumber)?.intValue
    }

    // MARK: Writing

    private func number(_ service: IOHIDServiceClient, _ key: String) -> Int? {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
    }

    @discardableResult
    private func write(_ service: IOHIDServiceClient, _ key: String, _ value: Int) -> Bool {
        IOHIDServiceClientSetProperty(service, key as CFString, NSNumber(value: value))
    }

    private func original(for id: UInt64, _ service: IOHIDServiceClient, _ device: Device) -> Original {
        if let known = originals[id] { return known }
        let registry = registryProperties(id)
        let accel = number(service, device.accelKey)
            ?? (registry[device.accelKey] as? NSNumber)?.intValue
            ?? globalValue(device.accelKey)
            ?? Fixed1616.encode(0.6875)
        let linear = device.linearScaling
            ? number(service, "HIDUseLinearScalingMouseAcceleration") ?? (registry["HIDUseLinearScalingMouseAcceleration"] as? NSNumber)?.intValue ?? 0
            : nil
        let found = Original(accel: accel, linear: linear, resolution: number(service, "HIDPointerResolution"))
        originals[id] = found
        return found
    }

    private func applyAll() {
        if enabled {
            refresh()
            for device in devices { apply(device) }
        } else {
            restoreAll()
        }
        objectWillChange.send()
    }

    private func apply(_ device: Device) {
        let setting = setting(for: device.id)
        for id in device.registryIDs {
            guard let service = services[id] else { continue }
            guard enabled, setting.touches else { restore(id); continue }
            let base = original(for: id, service, device)
            // Order matters: resolution first, then the linear switch, then acceleration, whose
            // write is what makes the event system pick up a new resolution.
            // Speed is written only where the resolution could be read, so it can be put back.
            if let resolution = base.resolution {
                write(service, "HIDPointerResolution",
                      abs(setting.speed - 1) > 0.001 ? PointerResolution.raw(forSpeed: setting.speed) : resolution)
            }
            let linear = setting.curve == .linear
            if let baseLinear = base.linear { write(service, "HIDUseLinearScalingMouseAcceleration", linear ? 1 : baseLinear) }
            let accel: Int
            if linear {
                // With the linear switch the acceleration value is the straight line's slope, so
                // the user's own Tracking Speed is kept. Without it, -1 is the only way off.
                accel = device.linearScaling ? base.accel : Fixed1616.encode(-1)
            } else {
                accel = setting.acceleration.map(Fixed1616.encode) ?? base.accel
            }
            write(service, device.accelKey, accel)
            written[id] = (linear ? "linear" : String(format: "%.4g", Fixed1616.decode(accel)))
                + (abs(setting.speed - 1) > 0.001 ? String(format: "@%.2gx", setting.speed) : "")
        }
    }

    private func restore(_ id: UInt64) {
        guard let base = originals[id], let service = services[id],
              let device = devices.first(where: { $0.registryIDs.contains(id) }) else { return }
        if let resolution = base.resolution { write(service, "HIDPointerResolution", resolution) }
        if let linear = base.linear { write(service, "HIDUseLinearScalingMouseAcceleration", linear) }
        write(service, device.accelKey, base.accel)
        originals[id] = nil
        written[id] = nil
    }

    private func restoreAll() {
        for id in Array(originals.keys) { restore(id) }
    }

    fileprivate func checkGlobal() {
        guard enabled, !originals.isEmpty else { return }
        var changed = false
        for key in ["HIDMouseAcceleration", "HIDTrackpadAcceleration"] {
            guard let value = globalValue(key) else { continue }
            if let last = lastGlobal[key], last != value { changed = true }
            lastGlobal[key] = value
        }
        guard changed else { return }
        // The user moved Tracking Speed: that is the new value to come back to, and ours goes on top.
        for (id, var base) in originals {
            if let device = devices.first(where: { $0.registryIDs.contains(id) }), let value = globalValue(device.accelKey) {
                base.accel = value
                originals[id] = base
            }
        }
        for device in devices { apply(device) }
    }

    // MARK: Buttons

    private func applyTap() {
        tapButtonMap = buttonMap
        if buttons {
            guard buttonTap == nil, AXIsProcessTrusted() else { objectWillChange.send(); return }
            let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue
                                   | 1 << CGEventType.otherMouseDragged.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: buttonCallback, userInfo: nil) else { TapRevoke.creationFailed(); return }
            buttonTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            tapSource = source
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            removeTap()
        }
        objectWillChange.send()
    }

    private var tapSource: CFRunLoopSource?

    private func removeTap() {
        guard let tap = buttonTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        buttonTap = nil
        tapSource = nil
    }

    /// Whether any mouse that can send extra buttons is plugged in.
    var hasButtonMouse: Bool { devices.contains { !$0.apple && !$0.trackpad } }

    static func perform(_ action: MouseButtonAction) {
        if let (code, flags) = action.keystroke {
            // A private source, so modifiers the user happens to hold do not leak into the chord.
            let source = CGEventSource(stateID: .privateState)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
                event.flags = CGEventFlags(rawValue: flags)
                event.setIntegerValueField(.eventSourceUserData, value: mouseButtonMark)
                event.post(tap: .cghidEventTap)
            }
            return
        }
        switch action {
        case .missionControl: missionControl(nil)
        case .appExpose: missionControl("2")
        case .showDesktop: missionControl("1")
        default: break
        }
    }

    /// The Mission Control app takes 1 for Show Desktop and 2 for App Exposé, as Hot Corners uses it.
    private static func missionControl(_ argument: String?) {
        let binary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = argument.map { [$0] } ?? []
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Pointer speed on screen, sampled at display rate while the card is in view. Separate from
/// MousePrecision so its 60 updates a second redraw only the graph, not the whole card.
@MainActor
final class PointerSpeedMeter: ObservableObject {
    static let shared = PointerSpeedMeter()
    /// Points per second, smoothed.
    @Published private(set) var speed = 0.0
    private var timer: Timer?
    private var last: (NSPoint, TimeInterval)?
    private var watchers = 0

    func start() {
        watchers += 1
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { PointerSpeedMeter.shared.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
        last = nil
        speed = 0
    }

    private func sample() {
        let point = NSEvent.mouseLocation, now = ProcessInfo.processInfo.systemUptime
        defer { last = (point, now) }
        guard let (previous, then) = last, now > then else { return }
        let raw = hypot(point.x - previous.x, point.y - previous.y) / (now - then)
        // Fast to rise, slower to fall, so a flick reads before it fades.
        let next = raw > speed ? speed + (raw - speed) * 0.5 : speed + (raw - speed) * 0.12
        let settled = next < 1 ? 0 : next
        if abs(settled - speed) > 0.5 || (settled == 0 && speed != 0) { speed = settled }
    }
}
