import Foundation

// MARK: - Mouse Precision math
//
// The pure half of Mouse Precision: the numbers IOKit wants, the curves the card draws and the
// button table the event tap reads. Nothing here touches a device, so all of it is testable.

/// IOKit's 16.16 fixed point (`IOFixed`), the format of HIDMouseAcceleration,
/// HIDTrackpadAcceleration and HIDPointerResolution.
public enum Fixed1616 {
    public static let one = 65_536

    public static func encode(_ value: Double) -> Int { Int((value * Double(one)).rounded()) }
    public static func decode(_ raw: Int) -> Double { Double(raw) / Double(one) }
}

/// How a device turns hand speed into pointer speed.
public enum MouseCurve: String, Codable, CaseIterable, Sendable {
    /// Left exactly as macOS has it. Nothing is written to the device.
    case system
    /// No acceleration at all: the pointer moves a fixed distance per inch of hand travel.
    case linear
    /// A whisper of acceleration, for aim that stays predictable at speed.
    case gamer
    /// Softer than macOS: slow moves stay fine, fast ones grow less.
    case gentle
    /// macOS's own middle setting, written per device.
    case macOS
    /// The value on the card's slider.
    case custom

    public var title: String {
        switch self {
        case .system: "System"
        case .linear: "Linear"
        case .gamer: "Gamer"
        case .gentle: "Gentle"
        case .macOS: "macOS"
        case .custom: "Custom"
        }
    }

    /// The acceleration this preset writes, in macOS's own scale (0 to 3 in System Settings;
    /// IOKit accepts up to 40). -1 turns acceleration off. Nil for `.system` and `.custom`.
    public var acceleration: Double? {
        switch self {
        case .system, .custom: nil
        case .linear: -1
        case .gamer: 0.125
        case .gentle: 0.375
        case .macOS: 0.6875
        }
    }

    /// The presets the card shows as chips, in order.
    public static let presets: [MouseCurve] = [.linear, .gamer, .gentle, .macOS]
}

/// Apple's parametric acceleration curves, as the trackpad driver on this Mac publishes them
/// in `HIDAccelCurves` (decoded from 16.16). Each row is one stop of the Tracking Speed slider;
/// values between stops are interpolated. The card draws with these so its curves have the
/// shape macOS really uses; the per-device figures differ slightly, so the drawing is a guide,
/// not a measurement.
public enum MouseAccelTable {
    public struct Stop: Equatable, Sendable {
        public let index: Double, linear: Double, parabolic: Double, cubic: Double, root: Double
    }

    /// (HIDAccelIndex, GainLinear, GainParabolic, GainCubic, TangentSpeedParabolicRoot), raw 16.16.
    static let raw: [(Int, Int, Int, Int, Int)] = [
        (0, 65536, 0, 0, 1_376_256),
        (8192, 64881, 32768, 5243, 1_310_720),
        (32768, 64225, 43254, 6554, 1_245_184),
        (45056, 62915, 54395, 7864, 1_179_648),
        (57344, 61604, 65536, 9830, 1_114_112),
        (65536, 60293, 75366, 11796, 1_048_576),
        (98304, 58327, 85197, 13763, 983_040),
        (131072, 56361, 95027, 15729, 917_504),
        (163840, 54395, 108_790, 18350, 851_968),
        (196608, 65536, 123_208, 23593, 786_432),
    ]

    public static let stops: [Stop] = raw.map {
        Stop(index: Fixed1616.decode($0.0), linear: Fixed1616.decode($0.1), parabolic: Fixed1616.decode($0.2),
             cubic: Fixed1616.decode($0.3), root: Fixed1616.decode($0.4))
    }

    /// The curve for any acceleration. Past Apple's top stop (3.0) the gains keep growing at
    /// the rate of the last step, which is what "faster than macOS allows" draws as.
    public static func stop(for acceleration: Double) -> Stop {
        let a = max(acceleration, 0)
        if let exact = stops.first(where: { $0.index == a }) { return exact }
        if a > stops[stops.count - 1].index {
            let (p, q) = (stops[stops.count - 2], stops[stops.count - 1])
            let t = (a - q.index) / (q.index - p.index)
            return Stop(index: a, linear: q.linear, parabolic: q.parabolic + (q.parabolic - p.parabolic) * t,
                        cubic: q.cubic + (q.cubic - p.cubic) * t, root: max(q.root - (p.root - q.root) * t, 4))
        }
        let upper = stops.firstIndex { $0.index > a } ?? stops.count - 1
        let (p, q) = (stops[upper - 1], stops[upper])
        let t = (a - p.index) / (q.index - p.index)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return Stop(index: a, linear: mix(p.linear, q.linear), parabolic: mix(p.parabolic, q.parabolic),
                    cubic: mix(p.cubic, q.cubic), root: mix(p.root, q.root))
    }

    /// Pointer speed out for hand speed in, both in the driver's units (device counts per
    /// frame, roughly 0 to 30). The gain rises with speed up to the parabolic root, then holds,
    /// so the curve turns into a straight line there, as Apple's tangent does. `speed` is the
    /// Pointer Speed multiplier, which scales the whole curve. Acceleration -1 is a straight line.
    public static func output(_ input: Double, acceleration: Double, speed: Double = 1) -> Double {
        let v = max(input, 0)
        guard acceleration >= 0 else { return v * speed }
        let s = stop(for: acceleration)
        let x = min(v, s.root) / s.root
        let gain = s.linear + s.parabolic * x + s.cubic * x * x
        return v * gain * speed
    }

    /// The hand speed that gives `output`, by bisection; the curve only ever rises.
    public static func input(forOutput output: Double, acceleration: Double, speed: Double = 1) -> Double {
        guard output > 0, speed > 0 else { return 0 }
        var (lo, hi) = (0.0, 1.0)
        while self.output(hi, acceleration: acceleration, speed: speed) < output && hi < 1e6 { hi *= 2 }
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if self.output(mid, acceleration: acceleration, speed: speed) < output { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}

/// Pointer Speed, as HIDPointerResolution. The resolution is the counts per inch macOS assumes
/// the mouse has: claim fewer and each count goes further, so the pointer is faster. Apple
/// ships 400; IOKit takes 10 to 1995, far past the fastest Tracking Speed in System Settings.
public enum PointerResolution {
    public static let apple = 400.0
    public static let range = 10.0...1995.0
    /// The multipliers the card offers. 1 is macOS; past about 3 it is faster than Apple allows.
    public static let speedRange = 0.25...6.0

    public static func resolution(forSpeed speed: Double) -> Double {
        let s = min(max(speed, speedRange.lowerBound), speedRange.upperBound)
        return min(max(apple / s, range.lowerBound), range.upperBound)
    }

    public static func speed(forResolution resolution: Double) -> Double {
        apple / min(max(resolution, range.lowerBound), range.upperBound)
    }

    /// The raw 16.16 value to write.
    public static func raw(forSpeed speed: Double) -> Int { Fixed1616.encode(resolution(forSpeed: speed)) }
}

// MARK: - Buttons

/// What a mouse button beyond the left and right does.
public enum MouseButtonAction: Codable, Hashable, Sendable {
    case passThrough
    case back
    case forward
    case missionControl
    case appExpose
    case showDesktop
    /// A recorded shortcut: virtual key code and Carbon modifier bits, as `KeyCombo` stores them.
    case shortcut(keyCode: Int, carbonModifiers: Int)

    public var title: String {
        switch self {
        case .passThrough: "Default"
        case .back: "Back"
        case .forward: "Forward"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .showDesktop: "Show Desktop"
        case .shortcut: "Shortcut"
        }
    }

    /// The keystroke the tap sends instead, as (virtual key code, CGEventFlags raw value).
    /// Nil when the action is not a keystroke. Back and Forward are ⌘[ and ⌘], which every
    /// browser, Finder, Xcode and most document apps understand.
    public var keystroke: (keyCode: Int, flags: UInt64)? {
        switch self {
        case .back: (33, MouseButtonMap.commandFlag)
        case .forward: (30, MouseButtonMap.commandFlag)
        case let .shortcut(code, carbon): (code, MouseButtonMap.cgFlags(carbon: carbon))
        default: nil
        }
    }
}

/// The table the event tap reads: CGEvent button number to action. 0 and 1 (left, right) are
/// never remapped; 2 is the middle button or wheel click, 3 and 4 the side buttons.
public struct MouseButtonMap: Codable, Equatable, Sendable {
    public var actions: [Int: MouseButtonAction]

    public static let remappable = [2, 3, 4]
    /// What a new install starts with: side buttons go back and forward, the way they do on
    /// Windows and in Logitech's software. The middle button keeps its click.
    public static let standard = MouseButtonMap(actions: [2: .passThrough, 3: .back, 4: .forward])

    public init(actions: [Int: MouseButtonAction]) { self.actions = actions }

    public func action(for button: Int) -> MouseButtonAction {
        guard Self.remappable.contains(button) else { return .passThrough }
        return actions[button] ?? .passThrough
    }

    public var remappedCount: Int { Self.remappable.filter { action(for: $0) != .passThrough }.count }

    public static func name(of button: Int) -> String {
        switch button {
        case 2: "Middle Button"
        case 3: "Back Button"
        case 4: "Forward Button"
        default: "Button \(button + 1)"
        }
    }

    // CGEventFlags raw values, so DockCore need not import CoreGraphics.
    public static let shiftFlag: UInt64 = 0x0002_0000
    public static let controlFlag: UInt64 = 0x0004_0000
    public static let optionFlag: UInt64 = 0x0008_0000
    public static let commandFlag: UInt64 = 0x0010_0000

    /// Carbon modifier bits (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000)
    /// to CGEventFlags.
    public static func cgFlags(carbon: Int) -> UInt64 {
        var flags: UInt64 = 0
        if carbon & 0x100 != 0 { flags |= commandFlag }
        if carbon & 0x200 != 0 { flags |= shiftFlag }
        if carbon & 0x800 != 0 { flags |= optionFlag }
        if carbon & 0x1000 != 0 { flags |= controlFlag }
        return flags
    }
}

// MARK: - Devices

public enum MouseDeviceInfo {
    /// Apple's two USB vendor IDs (USB and Bluetooth). Apple mice and trackpads send no
    /// buttons past the second, so remapping is offered only for other makers' mice.
    public static let appleVendors: Set<Int> = [0x05AC, 0x004C]

    public static func isApple(vendor: Int?, builtIn: Bool) -> Bool {
        builtIn || vendor.map { appleVendors.contains($0) } ?? false
    }

    /// A key that survives unplugging, unlike the registry ID: vendor, product and name.
    public static func key(vendor: Int?, product: Int?, name: String) -> String {
        "\(vendor ?? 0):\(product ?? 0):\(name)"
    }

    /// A short name for a vendor ID, for the device chips.
    public static func vendorName(_ vendor: Int?) -> String {
        switch vendor {
        case 0x05AC?, 0x004C?: "Apple"
        case 0x046D?: "Logitech"
        case 0x1532?: "Razer"
        case 0x045E?: "Microsoft"
        case 0x1038?: "SteelSeries"
        case 0x3434?, 0x05D5?: "Keychron"
        case 0x0B05?: "ASUS"
        case 0x1E7D?: "ROCCAT"
        case 0x258A?: "Glorious"
        case 0x04F2?: "Chicony"
        case 0x0000?, nil: "Built-in"
        case let v?: String(format: "0x%04X", v)
        }
    }
}

// MARK: - What this macOS still lets a device change

extension MouseDeviceInfo {
    /// Whether Pointer Speed (HIDPointerResolution) is known to be honoured for this device on
    /// this release. Apple's own drivers stopped reading a written resolution: for the built-in
    /// trackpad of M2 and later Macs since macOS 13 (LinearMouse #270), and for Magic Mouse and
    /// Magic Trackpad from macOS 15 on (LinearMouse #806, #1003, #1004; CursorSense's FAQ). The
    /// property is still listed and accepts the write, it simply has no effect. Acceleration is
    /// unaffected, and third-party mice are not affected at all. Apple's trackpad drivers also
    /// erase the vendor and product on some Macs, so any trackpad counts as Apple's here (no
    /// other maker sells one for the Mac).
    public static func pointerSpeedHonoured(vendor: Int?, builtIn: Bool, trackpad: Bool,
                                            macOSMajor: Int, appleSilicon: Bool) -> Bool {
        let apple = isApple(vendor: vendor, builtIn: builtIn) || trackpad
        guard apple else { return true }
        if macOSMajor >= 15 { return false }
        // Sonoma: only the Apple silicon built-in trackpad is affected (M1's is not, but the
        // chip generation cannot be told apart cheaply, so the note says "may"). A trackpad whose
        // vendor was erased is the built-in one.
        return !(appleSilicon && trackpad && (builtIn || vendor == nil))
    }

    /// The sentence the card shows under Speed when `pointerSpeedHonoured` is false.
    public static let pointerSpeedLimitNote = "macOS may ignore Speed on Apple’s own mice and trackpads in this release. Acceleration still applies."
}
