import AppKit
import IOKit.pwr_mgt
import ObjectiveC

/// Private system calls, resolved at run time. Each one checks for its symbol, so an OS
/// update that removes it turns the control off instead of crashing.
enum LiveDock {
    nonisolated(unsafe) private static let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private typealias SetFloat = @convention(c) (Float) -> Void
    private typealias SetBool = @convention(c) (Bool) -> Void
    private typealias SetPosition = @convention(c) (Int32, Int32) -> Void

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(library, name) }

    static var available: Bool { symbol("CoreDockSetTileSize") != nil }

    /// `points` runs 16 to 128, the API takes 0 to 1.
    static func setSize(_ points: Double) {
        guard let pointer = symbol("CoreDockSetTileSize") else { return }
        unsafeBitCast(pointer, to: SetFloat.self)(Float((points - 16) / 112))
    }

    static func setMagnification(_ points: Double) {
        guard let pointer = symbol("CoreDockSetMagnificationSize") else { return }
        unsafeBitCast(pointer, to: SetFloat.self)(Float((points - 16) / 112))
    }

    static func setAutoHide(_ on: Bool) {
        guard let pointer = symbol("CoreDockSetAutoHideEnabled") else { return }
        unsafeBitCast(pointer, to: SetBool.self)(on)
    }

    static func setOrientation(_ edge: String) {
        guard let pointer = symbol("CoreDockSetOrientationAndPinning") else { return }
        let value: Int32 = edge == "left" ? 3 : edge == "right" ? 4 : 2
        unsafeBitCast(pointer, to: SetPosition.self)(value, 2)
    }
}

enum Spaces {
    nonisolated(unsafe) private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private typealias Connection = @convention(c) () -> Int32
    // A "Copy" function: the array comes back retained, and may be NULL (no window server
    // session, as at the login window), so it is taken as optional and released here.
    private typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?

    static var count: Int? {
        guard let connection = dlsym(library, "SLSMainConnectionID"),
              let copy = dlsym(library, "SLSCopyManagedDisplaySpaces") else { return nil }
        let id = unsafeBitCast(connection, to: Connection.self)()
        guard let array = unsafeBitCast(copy, to: Copy.self)(id)?.takeRetainedValue() else { return nil }
        let displays = array as? [[String: Any]]
        return displays?.reduce(0) { $0 + (($1["Spaces"] as? [Any])?.count ?? 0) }
    }
}

@MainActor
final class Display: ObservableObject {
    static let shared = Display()

    @Published var nightShift = false
    @Published var warmth = 0.5
    @Published var trueTone = false
    @Published var keepAwake = false
    let nightShiftAvailable: Bool
    let trueToneAvailable: Bool

    private let blueLight: NSObject?
    private let tone: NSObject?
    private var assertion: IOPMAssertionID = 0

    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias GetStrength = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
    private typealias SetStrength = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias GetEnabled = @convention(c) (AnyObject, Selector) -> Bool

    private init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        let blueType = NSClassFromString("CBBlueLightClient") as? NSObject.Type
        let blueLight = blueType?.init()
        let tone = (NSClassFromString("CBTrueToneClient") as? NSObject.Type)?.init()
        self.blueLight = blueLight
        self.tone = tone
        // Night Shift needs a Mac and display that support it (2012 and later, most panels);
        // the class says so itself. Every method used below must be there too, or a missing one
        // would be called through the runtime's forwarding stub and throw.
        let supportsNightShift: Bool = {
            let selector = NSSelectorFromString("supportsBlueLightReduction")
            guard let blueType, (blueType as AnyObject).responds(to: selector) else { return true }
            typealias F = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast((blueType as AnyObject).method(for: selector), to: F.self)(blueType, selector)
        }()
        nightShiftAvailable = supportsNightShift
            && ["setStrength:commit:", "getBlueLightStatus:", "getStrength:", "setEnabled:"].allSatisfy {
                blueLight?.responds(to: NSSelectorFromString($0)) == true
            }
        // True Tone only exists on Macs with the ambient colour sensor (2018 MacBook Pro and
        // later, Apple silicon laptops, Studio Display); CBTrueToneClient is present everywhere,
        // so its own "supported" decides, not the presence of the class.
        trueToneAvailable = ["setEnabled:", "enabled", "supported"].allSatisfy { tone?.responds(to: NSSelectorFromString($0)) == true }
            && Self.flag(tone, "supported")
        refresh()
    }

    private static func flag(_ object: NSObject?, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let object, object.responds(to: selector) else { return false }
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: F.self)(object, selector)
    }

    func refresh() {
        if nightShiftAvailable, let blueLight {
            let selector = NSSelectorFromString("getBlueLightStatus:")
            var status = [UInt8](repeating: 0, count: 64)
            _ = unsafeBitCast(blueLight.method(for: selector), to: GetStatus.self)(blueLight, selector, &status)
            nightShift = status[1] != 0
            let strength = NSSelectorFromString("getStrength:")
            var value: Float = 0
            _ = unsafeBitCast(blueLight.method(for: strength), to: GetStrength.self)(blueLight, strength, &value)
            warmth = Double(value)
        }
        if trueToneAvailable, let tone {
            let selector = NSSelectorFromString("enabled")
            trueTone = unsafeBitCast(tone.method(for: selector), to: GetEnabled.self)(tone, selector)
        }
    }

    func setNightShift(_ on: Bool) {
        guard nightShiftAvailable, let blueLight else { return }
        let selector = NSSelectorFromString("setEnabled:")
        _ = unsafeBitCast(blueLight.method(for: selector), to: SetEnabled.self)(blueLight, selector, on)
        nightShift = on
    }

    func setWarmth(_ value: Double, commit: Bool) {
        guard nightShiftAvailable, let blueLight else { return }
        let selector = NSSelectorFromString("setStrength:commit:")
        _ = unsafeBitCast(blueLight.method(for: selector), to: SetStrength.self)(blueLight, selector, Float(value), commit)
        warmth = value
    }

    func setTrueTone(_ on: Bool) {
        guard trueToneAvailable, let tone else { return }
        let selector = NSSelectorFromString("setEnabled:")
        _ = unsafeBitCast(tone.method(for: selector), to: SetEnabled.self)(tone, selector, on)
        trueTone = on
    }

    func setKeepAwake(_ on: Bool) {
        keepAwake = on
        if on {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Atelier Keep Awake" as CFString, &assertion)
        } else if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
