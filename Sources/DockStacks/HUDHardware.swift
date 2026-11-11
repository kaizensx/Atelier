import AppKit
import CoreAudio
import DockCore

// MARK: - What Atelier HUD turns
//
// Once Atelier swallows a media key, nothing else acts on it, so Atelier has to make the
// change itself: CoreAudio for the volume, DisplayServices for the screen, CoreBrightness's
// KeyboardBrightnessClient for the key light. Each says honestly when it cannot, and the HUD
// then lets the key through to macOS untouched.

/// The default output device's volume and mute, through CoreAudio's public HAL properties.
enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector, element: UInt32 = kAudioObjectPropertyElementMain,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static var device: AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func settable(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    /// Where the volume lives: one main control, or (for many USB and HDMI devices) a control
    /// per channel. Empty for a device with no volume of its own, such as a digital output;
    /// macOS then shows its own "no volume" HUD, so the key goes through.
    private static func elements(_ device: AudioObjectID) -> [UInt32] {
        if settable(device, address(kAudioDevicePropertyVolumeScalar)) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { settable(device, address(kAudioDevicePropertyVolumeScalar, element: $0)) }
    }

    static var controllable: Bool { !elements(device).isEmpty }

    /// 0 to 1; with one control per channel, the louder one, so balance is kept in mind.
    static var level: Double {
        let device = device
        let values = elements(device).map { element -> Float32 in
            var address = address(kAudioDevicePropertyVolumeScalar, element: element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            return value
        }
        return Double(values.max() ?? 0)
    }

    @discardableResult
    static func set(_ level: Double) -> Bool {
        let device = device
        var ok = false
        for element in elements(device) {
            var address = address(kAudioDevicePropertyVolumeScalar, element: element)
            var value = Float32(min(max(level, 0), 1))
            ok = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr || ok
        }
        return ok
    }

    static var canMute: Bool { settable(device, address(kAudioDevicePropertyMute)) }

    static var muted: Bool {
        var address = address(kAudioDevicePropertyMute)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func setMuted(_ on: Bool) {
        var address = address(kAudioDevicePropertyMute)
        var value: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// The click macOS plays after a volume change when "Play feedback when volume is changed"
    /// is on. Swallowing the key silences Apple's, so Atelier plays the same file. ⇧ flips it,
    /// as on a stock Mac.
    @MainActor static func feedback(shift: Bool) {
        let on = (CFPreferencesCopyAppValue("com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication) as? Int ?? 0) == 1
        guard on != shift else { return }
        feedbackSound?.stop()
        feedbackSound?.play()
    }

    @MainActor private static let feedbackSound = NSSound(
        contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff", byReference: true)
}

/// Screen brightness through the private DisplayServices framework (no permission needed;
/// returns 0 on success). It is what Control Center's slider uses on Apple displays.
enum DisplayBrightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Can = @convention(c) (CGDirectDisplayID) -> Bool

    nonisolated(unsafe) private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setter = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
    private static let can = library.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }.map { unsafeBitCast($0, to: Can.self) }

    static func canChange(_ display: CGDirectDisplayID) -> Bool {
        guard let can, getter != nil, setter != nil else { return false }
        return can(display)
    }

    /// The display the brightness keys should act on: the one under the pointer when Atelier
    /// can drive it, else the built-in panel. Nil when no display answers (an external
    /// monitor without DDC support in DisplayServices), and the key then goes through.
    @MainActor static var target: CGDirectDisplayID? {
        let pointer = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        if let id = pointer?.displayID, canChange(id) { return id }
        return NSScreen.screens.compactMap(\.displayID).first { CGDisplayIsBuiltin($0) != 0 && canChange($0) }
    }

    static func level(_ display: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard let getter, getter(display, &value) == 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    static func set(_ level: Double, on display: CGDirectDisplayID) -> Bool {
        guard let setter else { return false }
        return setter(display, Float(min(max(level, 0), 1))) == 0
    }
}

/// CoreBrightness's KeyboardBrightnessClient, called through its Objective-C runtime methods.
/// It talks to corebrightnessd over XPC and needs no permission. Every Intel MacBook macOS 14
/// runs on (2018 and later) has a T2 chip and the same client; the pre-T2 AppleLMUController
/// path is deliberately not used, since it would be untestable here and those Macs cannot run
/// macOS 14. A Mac where the client lists no keyboard simply has no control. Each method's type
/// encoding is checked against the types it is called with before it is used (measured on
/// macOS 27.3: IDs unsigned long long, levels float, idle time double), so a release that
/// changes one turns that control off instead of passing it the wrong arguments.
@MainActor
final class KeyboardBacklight {
    private let client: NSObject
    let keyboard: UInt64

    /// The method's implementation, if the class has it with the expected types.
    private static func implementation(_ client: NSObject, _ name: String, _ expected: String, setter: Bool = false) -> IMP? {
        let selector = NSSelectorFromString(name)
        guard client.responds(to: selector), let method = class_getInstanceMethod(type(of: client), selector),
              let encoding = method_getTypeEncoding(method).map({ String(cString: $0) }) else { return nil }
        let fits = setter ? ObjCSignature.matchesArguments(encoding, expected) : ObjCSignature.matches(encoding, expected)
        return fits ? method_getImplementation(method) : nil
    }

    private func implementation(_ name: String, _ expected: String, setter: Bool = false) -> IMP? {
        Self.implementation(client, name, expected, setter: setter)
    }

    init?() {
        // The class lives in a private framework nothing else in Atelier links; load it first,
        // or NSClassFromString finds nothing.
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = type.init()
        let copyIDs = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let copy = Self.implementation(client, "copyKeyboardBacklightIDs", "@@:") else { return nil }
        typealias CopyIDs = @convention(c) (NSObject, Selector) -> Unmanaged<NSArray>?
        // "copy" hands back a retained array; taking it unretained leaks one tiny array once,
        // which is safer than an over-release if the framework ever returns it autoreleased.
        let ids = (unsafeBitCast(copy, to: CopyIDs.self)(client, copyIDs)?.takeUnretainedValue() as? [NSNumber])?
            .map(\.uint64Value) ?? []
        // A desktop, or a Mac whose keyboard has no light: no IDs, no control.
        guard !ids.isEmpty else { return nil }
        self.client = client
        // The built-in keyboard first: an external one with a backlight is the rare case.
        let builtIn = NSSelectorFromString("isKeyboardBuiltIn:")
        typealias Flag = @convention(c) (NSObject, Selector, UInt64) -> Bool
        let isBuiltIn = Self.implementation(client, "isKeyboardBuiltIn:", "B@:Q").map { unsafeBitCast($0, to: Flag.self) }
        keyboard = ids.first { isBuiltIn?(client, builtIn, $0) == true } ?? ids[0]
    }

    private func flag(_ name: String) -> Bool {
        guard let imp = implementation(name, "B@:Q") else { return false }
        typealias F = @convention(c) (NSObject, Selector, UInt64) -> Bool
        return unsafeBitCast(imp, to: F.self)(client, NSSelectorFromString(name), keyboard)
    }

    @discardableResult
    private func set(_ name: String, _ on: Bool) -> Bool {
        guard let imp = implementation(name, "B@:BQ", setter: true) else { return false }
        typealias F = @convention(c) (NSObject, Selector, Bool, UInt64) -> Void
        unsafeBitCast(imp, to: F.self)(client, NSSelectorFromString(name), on, keyboard)
        return true
    }

    var brightness: Double {
        guard let imp = implementation("brightnessForKeyboard:", "f@:Q") else { return 0 }
        typealias F = @convention(c) (NSObject, Selector, UInt64) -> Float
        return Double(unsafeBitCast(imp, to: F.self)(client, NSSelectorFromString("brightnessForKeyboard:"), keyboard))
    }

    /// `commit: false` changes the light without saving it, for a slider still being dragged.
    /// Falls back to the plain setter, which always saves, where the fading one is missing.
    @discardableResult
    func setBrightness(_ value: Double, commit: Bool) -> Bool {
        let level = Float(min(max(value, 0), 1))
        if let imp = implementation("setBrightness:fadeSpeed:commit:forKeyboard:", "B@:fiBQ", setter: true) {
            typealias F = @convention(c) (NSObject, Selector, Float, Int32, Bool, UInt64) -> Void
            unsafeBitCast(imp, to: F.self)(client, NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:"), level, 0, commit, keyboard)
            return true
        }
        guard let imp = implementation("setBrightness:forKeyboard:", "B@:fQ", setter: true) else { return false }
        typealias F = @convention(c) (NSObject, Selector, Float, UInt64) -> Void
        unsafeBitCast(imp, to: F.self)(client, NSSelectorFromString("setBrightness:forKeyboard:"), level, keyboard)
        return true
    }

    var autoBrightness: Bool { flag("isAutoBrightnessEnabledForKeyboard:") }
    func setAutoBrightness(_ on: Bool) { set("enableAutoBrightness:forKeyboard:", on) }

    var ambientAvailable: Bool { flag("isAmbientFeatureAvailableOnKeyboard:") }
    var idleSuspended: Bool { flag("isIdleDimmingSuspendedOnKeyboard:") }
    /// Keeps the light on however long the keyboard sits idle. Not saved by CoreBrightness,
    /// so Atelier sets it again at launch.
    func suspendIdleDimming(_ on: Bool) { set("suspendIdleDimming:forKeyboard:", on) }
    var canSuspendIdle: Bool { implementation("suspendIdleDimming:forKeyboard:", "B@:BQ", setter: true) != nil }

    var idleDimTime: Double {
        guard let imp = implementation("idleDimTimeForKeyboard:", "d@:Q") else { return 0 }
        typealias F = @convention(c) (NSObject, Selector, UInt64) -> Double
        return unsafeBitCast(imp, to: F.self)(client, NSSelectorFromString("idleDimTimeForKeyboard:"), keyboard)
    }

    var canSetIdle: Bool { implementation("setIdleDimTime:forKeyboard:", "B@:dQ", setter: true) != nil }

    func setIdleDimTime(_ seconds: Double) {
        guard let imp = implementation("setIdleDimTime:forKeyboard:", "B@:dQ", setter: true) else { return }
        typealias F = @convention(c) (NSObject, Selector, Double, UInt64) -> Void
        unsafeBitCast(imp, to: F.self)(client, NSSelectorFromString("setIdleDimTime:forKeyboard:"), seconds, keyboard)
    }
}
