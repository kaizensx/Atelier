import AppKit
import Carbon.HIToolbox
import DockCore
import SwiftUI

// MARK: - Trackpad Gestures
//
// macOS's trackpad knows clicks, scrolls, pinches and three- and four-finger swipes, and lets
// you choose almost nothing about them. Atelier reads the trackpad's own finger stream (see
// Multitouch.swift) and adds gestures macOS has no setting for: three- and four-finger taps,
// two-finger taps in the top corners, a one-finger swipe in from the side edges and a firm
// three-finger press, each doing what you pick. The classic is MiddleClick's: three fingers
// tap, the app under the pointer gets a middle click (open link in new tab, close tab).
//
// Atelier only listens. macOS still sees every touch and still does its own gestures; the
// ones Atelier adds are taps and edge flicks, which none of Apple's swipes are.

enum GestureAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case none, middleClick, missionControl, appExpose, showDesktop, apps, screenshot, lockScreen, playPause, openApp, shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Nothing"
        case .middleClick: "Middle Click"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .showDesktop: "Show Desktop"
        case .apps: "Apps"
        case .screenshot: "Screenshot"
        case .lockScreen: "Lock Screen"
        case .playPause: "Play / Pause"
        case .openApp: "Open App…"
        case .shortcut: "Keyboard Shortcut…"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .middleClick: "computermouse"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "rectangle.stack"
        case .showDesktop: "menubar.dock.rectangle"
        case .apps: "square.grid.3x3"
        case .screenshot: "camera.viewfinder"
        case .lockScreen: "lock"
        case .playPause: "playpause"
        case .openApp: "arrow.up.forward.app"
        case .shortcut: "command"
        }
    }

    /// Actions that post input events, which macOS allows only with Accessibility.
    var postsEvents: Bool { [.middleClick, .lockScreen, .playPause, .shortcut].contains(self) }
}

struct GestureBinding: Codable, Equatable, Sendable {
    var action: GestureAction = .none
    /// For Open App: the app's path.
    var app = ""
    /// For Keyboard Shortcut: the recorded chord.
    var combo: KeyCombo?
}

extension TrackpadGesture {
    var title: String {
        switch self {
        case .threeTap: "Three-Finger Tap"
        case .fourTap: "Four-Finger Tap"
        case .topLeftTap: "Two-Finger Tap, Top Left"
        case .topRightTap: "Two-Finger Tap, Top Right"
        case .swipeFromLeft: "Swipe In from Left Edge"
        case .swipeFromRight: "Swipe In from Right Edge"
        case .threeForce: "Firm Three-Finger Press"
        }
    }

    var detail: String {
        switch self {
        case .threeTap: "Tap with three fingers at once."
        case .fourTap: "Tap with four fingers at once."
        case .topLeftTap: "Two fingers tap together in the top-left corner of the trackpad."
        case .topRightTap: "Two fingers tap together in the top-right corner of the trackpad."
        case .swipeFromLeft: "One finger flicks in from the trackpad’s left edge."
        case .swipeFromRight: "One finger flicks in from the trackpad’s right edge."
        case .threeForce: "Rest three fingers and press down firmly."
        }
    }

    /// What macOS does with the same touch, if anything. Shown under the row: Atelier adds its
    /// action, it never takes macOS's away.
    var appleOverlap: String? {
        switch self {
        case .threeTap: "macOS also uses this for Look Up when “Look up & data detectors” is set to three fingers."
        case .topLeftTap, .topRightTap: "With two-finger secondary click on, macOS also right-clicks."
        case .swipeFromLeft, .swipeFromRight: "The pointer moves too, as with any one-finger slide."
        case .threeForce: "Three-finger drag, if on, may start a drag first; press without sliding."
        case .fourTap: nil
        }
    }
}

@MainActor
final class TrackpadGestures: ObservableObject {
    static let shared = TrackpadGestures()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "gestures.enabled"); apply() } }
    @Published private(set) var bindings: [TrackpadGesture: GestureBinding]
    /// How firm the three-finger press must be, in the sensor's pressure units.
    @Published var forceThreshold: Double {
        didSet {
            store.set(forceThreshold, forKey: "gestures.force")
            let value = forceThreshold
            touchEngine.withLock { $0.recognizer.tuning.forceThreshold = value }
        }
    }
    /// A finger is on the glass: the card's live trackpad only redraws while this is true.
    @Published private(set) var touching = false
    /// The last gesture recognised, live or simulated, and when: the card and stage flash it.
    @Published private(set) var lastGesture: (gesture: TrackpadGesture, at: Date)?
    @Published var lastError: String?

    private let store = UserDefaults.standard
    private let stream = MultitouchStream()
    /// Cards on screen that want the live finger view even with the feature off.
    private var watchers = 0
    private var wakeObserver: NSObjectProtocol?
    private(set) var actionsRun = 0

    /// What the sensor survey found: the framework, the trackpads (mice excluded), Force Touch.
    @Published private(set) var survey = MultitouchSurvey.now()

    /// Unavailable without the private framework or without any trackpad (a Mac mini or iMac
    /// with only a mouse); limited without Force Touch, where the firm press cannot work.
    var availability: FeatureAvailability {
        FeatureAvailability(InputSupport.gestures(frameworkLoaded: survey.frameworkLoaded, trackpads: survey.trackpads,
                                                  forceTrackpads: survey.forceTrackpads))
    }
    var available: Bool { availability.isUsable }
    /// The firm press reads pressure, which only Force Touch trackpads report.
    var forceAvailable: Bool { survey.forceTrackpads > 0 }

    /// Looks at the trackpads again, as the card appears: a Magic Trackpad may have been paired
    /// since launch. A running stream restarts so it includes the new one.
    func resurvey() {
        let now = MultitouchSurvey.now()
        guard now != survey else { return }
        survey = now
        if stream.running { restart() } else { apply() }
    }
    var running: Bool { stream.running }
    var frames: Int { touchEngine.withLock { $0.frames } }

    var diagnostics: String {
        "gestOn=\(enabled && running) gestDevices=\(stream.deviceCount) gestFrames=\(frames) " +
        "gestFired=\(lastGesture?.gesture.rawValue ?? "-") gestActions=\(actionsRun) " +
        "hapticOK=\(Haptics.shared.actuatorReady) hapticOn=\(Haptics.shared.enabled) hapticPlayed=\(Haptics.shared.played)"
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "gestures.enabled")
        forceThreshold = UserDefaults.standard.object(forKey: "gestures.force") as? Double ?? GestureTuning.standard.forceThreshold
        let saved = UserDefaults.standard.data(forKey: "gestures.bindings")
            .flatMap { try? JSONDecoder().decode([String: GestureBinding].self, from: $0) } ?? [:]
        var bindings: [TrackpadGesture: GestureBinding] = [:]
        for gesture in TrackpadGesture.allCases { bindings[gesture] = saved[gesture.rawValue] }
        // The one everyone comes for: three fingers tap, the middle button clicks.
        if saved.isEmpty { bindings[.threeTap] = GestureBinding(action: .middleClick) }
        self.bindings = bindings
        let force = forceThreshold
        touchEngine.withLock { $0.recognizer.tuning.forceThreshold = force }
    }

    func resume() { if enabled { apply() } }

    func binding(_ gesture: TrackpadGesture) -> GestureBinding { bindings[gesture] ?? GestureBinding() }

    func set(_ binding: GestureBinding, for gesture: TrackpadGesture) {
        bindings[gesture] = binding
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { store.set(data, forKey: "gestures.bindings") }
    }

    /// The live card asks for the stream while it is on screen, so you see your fingers before
    /// deciding to turn anything on.
    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        apply()
    }

    /// Test hook: runs a gesture's action exactly as if the trackpad had recognised it, whether
    /// or not the feature is on. Used by `atelier://gesture?simulate=threeTap`.
    func simulate(_ gesture: TrackpadGesture) {
        lastGesture = (gesture, .now)
        run(gesture)
    }

    /// From the sensor callback, on main.
    func deliver(_ gestures: [TrackpadGesture], touching: Bool) {
        if self.touching != touching { self.touching = touching }
        for gesture in gestures {
            lastGesture = (gesture, .now)
            // With only the card watching, a gesture lights up on the card and does nothing else.
            if enabled { run(gesture) }
        }
    }

    private func apply() {
        if enabled || watchers > 0 {
            guard !stream.running, available else { return }
            stream.start()
            // The sensor stops delivering across sleep; starting it afresh on wake brings it back.
            wakeObserver = wakeObserver ?? NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TrackpadGestures.shared.restart() }
            }
        } else {
            stream.stop()
            if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
            wakeObserver = nil
            touching = false
        }
        objectWillChange.send()
    }

    private func restart() {
        stream.stop()
        apply()
    }

    // MARK: Actions

    private func run(_ gesture: TrackpadGesture) {
        let binding = binding(gesture)
        guard binding.action != .none else { return }
        lastError = nil
        actionsRun += 1
        Haptics.shared.tap(.light)
        switch binding.action {
        case .none: break
        case .middleClick:
            // At the pointer, like a real middle button. CGEvent(source:) gives top-left
            // global coordinates, which is what mouse events take.
            let location = CGEvent(source: nil)?.location ?? .zero
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center)?.post(tap: .cghidEventTap)
            }
        case .missionControl: Self.missionControl(nil)
        case .appExpose: Self.missionControl("2")
        case .showDesktop: Self.missionControl("1")
        case .apps:
            let apps = URL(fileURLWithPath: "/System/Applications/Apps.app")
            let launchpad = URL(fileURLWithPath: "/System/Applications/Launchpad.app")
            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: apps.path) ? apps : launchpad)
        case .screenshot:
            // ⌘⇧4: drag a region, or Space for a window; saved where macOS saves screenshots.
            Self.run("/usr/sbin/screencapture", ["-i", Self.screenshotPath()])
        case .lockScreen: Self.postKey(kVK_ANSI_Q, flags: [.maskControl, .maskCommand])
        case .playPause: Self.mediaKey(16)  // NX_KEYTYPE_PLAY
        case .openApp:
            guard !binding.app.isEmpty, FileManager.default.fileExists(atPath: binding.app) else {
                lastError = "Choose an app for \(gesture.title)."
                return
            }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: binding.app), configuration: .init())
        case .shortcut:
            guard let combo = binding.combo else { lastError = "Record a shortcut for \(gesture.title)."; return }
            var flags: CGEventFlags = []
            if combo.modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
            if combo.modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
            if combo.modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
            if combo.modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
            Self.postKey(Int(combo.keyCode), flags: flags)
        }
        if binding.action.postsEvents && !AXIsProcessTrusted() {
            lastError = "\(binding.action.title) needs Accessibility to send input."
        }
    }

    /// Where ⌘⇧4 would put it: the screencapture location if set, else the Desktop.
    private static func screenshotPath() -> String {
        let folder = (CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String)
            .map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop")
        let stamp = Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        return (folder as NSString).appendingPathComponent("Screenshot \(stamp).png")
    }

    /// The Mission Control app takes 1 for Show Desktop and 2 for App Exposé.
    private static func missionControl(_ argument: String?) {
        let binary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        if FileManager.default.isExecutableFile(atPath: binary) {
            run(binary, argument.map { [$0] } ?? [])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        }
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { TrackpadGestures.shared.lastError = "Couldn’t run \(path): \(error.localizedDescription)" }
    }

    private static func postKey(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// A media key, as the keyboard's own play key sends it: a system-defined event, subtype 8,
    /// key in the top half of data1, 0xA for down and 0xB for up.
    private static func mediaKey(_ key: Int) {
        for down in [true, false] {
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
