import AppKit
import SwiftUI
import DockCore

// MARK: - Hyper Key
//
// Caps Lock becomes a fifth modifier: held, it is ⌃⌥⇧⌘ all at once, a combination no app
// claims, so it is free for your own shortcuts; tapped on its own, it is Escape. It works in
// two steps, both public and both undone when the switch goes off. First, Apple's hidutil
// remaps Caps Lock to F18 (TN2450), a key no Mac keyboard has, which also stops Caps Lock
// from toggling capitals. Then a keyboard event tap swallows F18, and while it is held adds
// the four modifiers to every other key. A short press with nothing else in between is sent
// on as Escape, marked so the tap lets it pass.
//
// hidutil keeps one list of mappings and replaces it whole on every set, so Remap Keys and
// Hyper Key both write it through `KeyMapping.write`, which always sends the two together.
//
// Across Macs and releases: `hidutil property --set` with UserKeyMapping works without root
// from macOS 10.12 (TN2450) through 27, on Intel and Apple silicon, and applies to every
// keyboard, built-in and external. It is not kept across restarts, and macOS 14.2 and later
// have been seen keeping a mapping in the list without applying it to a keyboard until that
// keyboard reconnects (Apple forums thread 255340598, FB13465290). So the list is written again
// after every wake, and the tap watches for a real Caps Lock getting through while the mapping
// should be in place: it rewrites once, and if Caps Lock still leaks, says so on the card.
//
// Permissions: an active (modifying) keyboard tap needs Accessibility, which also covers
// listening; Input Monitoring alone is only enough for a listen-only tap. That is the same on
// 14, 15, 26 and 27. While a password field has Secure Input on, macOS keeps keystrokes from
// every tap: Caps Lock then arrives in the app as a plain F18 (which does nothing), and its
// key-up can be missed, which `HyperKeyState.reconcile` repairs from the HID system's own
// record of the key.

/// Read by the tap's C callback, which runs outside any actor.
private nonisolated(unsafe) var hyperTap: CFMachPort?
private nonisolated(unsafe) var hyperState = HyperKeyState()
private nonisolated(unsafe) var hyperTapEscape = true
private nonisolated(unsafe) var hyperChordCount = 0
private nonisolated(unsafe) var hyperEscapeCount = 0
/// Whether hidutil last accepted Caps Lock → F18, mirrored for the tap.
private nonisolated(unsafe) var hyperMappedNow = false
/// Whether the HID system's key state has been seen to track the remapped key (F18 read as
/// down while its key-down was in hand). Lost key-ups are only repaired from that record once
/// it has proved reliable on this Mac, so a release where it does not follow hidutil's mapping
/// can never strip the modifiers from a real chord.
private nonisolated(unsafe) var hyperStateTracksF18 = false
/// Stamped on the Escape Atelier sends for a tap, so the tap does not catch it again.
private let hyperMark: Int64 = 0x4154484B

private let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

private func hyperCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                           _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let hyperTap { CGEvent.tapEnable(tap: hyperTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .flagsChanged {
        // A real Caps Lock reaching the tap means macOS is not applying the mapping.
        if hyperMappedNow, event.getIntegerValueField(.keyboardEventKeycode) == HyperMappingWatch.capsLockKeycode {
            MainActor.assumeIsolated { HyperKey.shared.capsLockLeaked() }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp,
          event.getIntegerValueField(.eventSourceUserData) != hyperMark else { return Unmanaged.passUnretained(event) }
    let down = type == .keyDown
    let f18Down = { CGEventSource.keyState(.hidSystemState, key: CGKeyCode(HyperKeyState.hyperKeycode)) }
    if event.getIntegerValueField(.keyboardEventKeycode) == HyperKeyState.hyperKeycode {
        if down && f18Down() { hyperStateTracksF18 = true }
    } else if hyperState.held, hyperStateTracksF18 {
        // The key-up may have been lost to Secure Input: ask the HID system whether F18 is down.
        hyperState.reconcile(hyperDown: f18Down())
    }
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    if event.getIntegerValueField(.keyboardEventKeycode) == HyperKeyState.hyperKeycode, !isRepeat { radialHyperKey(down: down) }
    let verdict = hyperState.key(code: event.getIntegerValueField(.keyboardEventKeycode), down: down, isRepeat: isRepeat,
                                 now: DispatchTime.now().uptimeNanoseconds, tapForEscape: hyperTapEscape)
    switch verdict {
    case .pass:
        return Unmanaged.passUnretained(event)
    case .passWithHyper:
        event.flags = event.flags.union(hyperFlags)
        if down && !isRepeat { hyperChordCount += 1 }
        return Unmanaged.passUnretained(event)
    case .swallow:
        return nil
    case .swallowAndEscape:
        hyperEscapeCount += 1
        postHyperEscape()
        return nil
    }
}

/// A plain Escape press, with no modifiers, whatever the keyboard's state.
private func postHyperEscape() {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(HyperKeyState.escapeKeycode), keyDown: down)
        else { continue }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: hyperMark)
        event.post(tap: .cghidEventTap)
    }
}

@MainActor
final class HyperKey: ObservableObject {
    static let shared = HyperKey()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "hyperKey.enabled"); apply() } }
    /// Whether a lone tap of Caps Lock sends Escape.
    @Published var tapEscape: Bool {
        didSet { store.set(tapEscape, forKey: "hyperKey.tapEscape"); hyperTapEscape = tapEscape }
    }
    /// Whether hidutil last confirmed Caps Lock → F18. Set by `KeyMapping.write`.
    @Published fileprivate(set) var mapped = false
    @Published fileprivate(set) var notice: String?

    private let store = UserDefaults.standard
    private var source: CFRunLoopSource?
    private var watch = HyperMappingWatch()
    private var wakeObserver: NSObjectProtocol?

    var tapActive: Bool { hyperTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    /// For tests: keys sent on with ⌃⌥⇧⌘ added, and taps turned into Escape, since launch.
    var chords: Int { hyperChordCount }
    var escapes: Int { hyperEscapeCount }
    var diagnostics: String {
        "hyperTap=\(tapActive) hyperMapped=\(mapped) hyperChords=\(chords) hyperEscapes=\(escapes)"
    }

    /// The Remap Keys entry that already uses Caps Lock. Hyper Key gives way to it.
    var conflict: KeyRemap? { HyperMapping.conflict(in: KeyMapping.activeRemaps) }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "hyperKey.enabled")
        tapEscape = UserDefaults.standard.object(forKey: "hyperKey.tapEscape") as? Bool ?? true
        hyperTapEscape = tapEscape
    }

    /// Call once at launch. hidutil's mappings end with each restart, so the mapping is set
    /// again here along with the tap.
    func resume() {
        InputTrust.watch()
        if enabled { apply() }
    }

    /// Needs Accessibility for its tap; it stays switchable without it and starts once granted.
    var availability: FeatureAvailability { InputTrust.availability }

    /// From the tap: Caps Lock got through although hidutil accepted the mapping.
    fileprivate func capsLockLeaked() {
        switch watch.flagsChanged(keycode: HyperMappingWatch.capsLockKeycode, mapped: mapped, now: DispatchTime.now().uptimeNanoseconds) {
        case .none: break
        case .rewrite: KeyMapping.write()
        case .report:
            notice = "macOS isn’t applying the Caps Lock mapping to this keyboard. Reconnect the keyboard, or restart the Mac."
        }
    }

    /// For `applicationWillTerminate`: without the tap, Caps Lock would be a dead F18, so the
    /// mapping is taken back before Atelier goes. The switch stays on for the next launch.
    func restoreOnQuit() {
        guard enabled else { return }
        _ = KeyMapping.run(KeyMapping.json(hyper: false))
    }

    private func apply() {
        hyperTapEscape = tapEscape
        if enabled {
            if hyperTap == nil, AXIsProcessTrusted() {
                let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
                                       | 1 << CGEventType.flagsChanged.rawValue)
                if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: hyperCallback, userInfo: nil) {
                    hyperTap = tap
                    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                    self.source = source
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            // hidutil's list can be dropped across sleep; it is written again on every wake.
            wakeObserver = wakeObserver ?? NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard HyperKey.shared.enabled else { return }
                    HyperKey.shared.watch.reset()
                    // A moment's wait: keyboards come back a little after the Mac does.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { KeyMapping.write() }
                }
            }
        } else if let tap = hyperTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            hyperTap = nil
            source = nil
            hyperState.reset()
        }
        if !enabled, let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        // Without the tap, F18 would do nothing, so Caps Lock is only remapped once the tap is in.
        KeyMapping.write()
        objectWillChange.send()
    }

    fileprivate func noteWrite(ok: Bool, hyper: Bool) {
        mapped = ok && hyper
        hyperMappedNow = mapped
        if !ok { notice = "hidutil refused the mapping." } else if !hyper || !watch.reported { notice = nil }
    }
}

// MARK: - Accessibility, shared by the input taps

/// Hyper Key, Wheel, Hold ⌘Q and the mouse buttons all need an active event tap, and macOS
/// lets an app create one only with Accessibility. Each feature's switch stays usable without
/// it, so the person can turn it on first and grant access after; this watcher notices the
/// grant (macOS posts "com.apple.accessibility.api" when the list changes) and starts the taps
/// that were waiting, so no relaunch is needed. Ad-hoc signed builds lose the grant on every
/// rebuild, which is why the check runs again each time.
@MainActor
enum InputTrust {
    private static var observer: NSObjectProtocol?
    private static var wasTrusted = AXIsProcessTrusted()

    /// The cards' note; limited rather than unavailable, so the switch can still be set.
    static var availability: FeatureAvailability {
        AXIsProcessTrusted() ? .available
            : .limited("Needs Accessibility in System Settings › Privacy & Security, to read and change input")
    }

    /// Idempotent; every input feature calls it from `resume()`.
    static func watch() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            // The list changes a moment before the process's trust does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { changed() } }
        }
    }

    private static func changed() {
        let trusted = AXIsProcessTrusted()
        defer { wasTrusted = trusted }
        guard trusted, !wasTrusted else { return }
        HyperKey.shared.resume()
        WheelDirection.shared.resume()
        QuitGuard.shared.resume()
        MousePrecision.shared.resume()
    }
}

// MARK: - The shared hidutil list

/// The one writer of hidutil's UserKeyMapping, shared by Remap Keys and Hyper Key. Each write
/// sends the full list as it stands at the moment of the call, on one serial queue, so the
/// last change always lands last and neither feature erases the other's entries.
@MainActor
enum KeyMapping {
    private static let queue = DispatchQueue(label: "net.dasantos.atelier.hidutil")

    static var activeRemaps: [KeyRemap] { KeyRemap.allCases.filter(KeyRemapper.shared.active.contains) }

    /// Whether Caps Lock → F18 belongs in the list now: Hyper is on, its tap is in, and Remap
    /// Keys does not already use Caps Lock.
    static var hyperWanted: Bool { HyperKey.shared.enabled && hyperTap != nil && HyperKey.shared.conflict == nil }

    static func json(hyper: Bool) -> String { HyperMapping.json(remaps: activeRemaps, hyper: hyper) }

    /// Sends the current list to hidutil. `done` reports whether hidutil accepted it.
    static func write(_ done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let hyper = hyperWanted
        let json = json(hyper: hyper)
        queue.async {
            let ok = run(json)
            Task { @MainActor in
                HyperKey.shared.noteWrite(ok: ok, hyper: hyper)
                done?(ok)
            }
        }
    }

    /// Runs `hidutil property --set` and waits for it. Safe from any thread.
    nonisolated static func run(_ json: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - Card and stage

struct HyperKeyCard: View {
    @ObservedObject private var hyper = HyperKey.shared
    @ObservedObject private var remapper = KeyRemapper.shared
    private let hue = DS.Spectrum.input

    var body: some View {
        let conflict = hyper.conflict
        // Turning it off stays possible, so a conflict never traps the switch on.
        let on = Binding(get: { hyper.enabled }, set: { wanted in
            if wanted && conflict != nil { return }
            hyper.enabled = wanted
        })
        HeroCard("Hyper Key",
                 pitch: conflict.map { "Caps Lock is already set by “\($0.title)” in Remap Keys. Turn that off first." }
                     ?? "Hold Caps Lock for ⌃⌥⇧⌘ at once, a chord no app uses, free for your own shortcuts.",
                 isOn: on, hue: hue, readout: "⌃⌥⇧⌘", readoutCaption: hyper.tapEscape ? "tap for esc" : "caps lock",
                 preview: .overlay("input.hyperKey", "Hyper Key", isOn: hyper.enabled) { size in
                     HyperKeyPreview(size: size, tapEscape: hyper.tapEscape)
                 }) {
            HyperPlate(on: hyper.enabled, tapEscape: hyper.tapEscape, hue: hue)
        } controls: {
            VStack(alignment: .leading, spacing: 8) {
                if conflict == nil { AvailabilityNote(availability: hyper.availability) }
                SettingRow(title: "Tap for Escape", detail: "A quick press on its own sends Escape.", density: .compact) {
                    LuxSwitch(isOn: $hyper.tapEscape, label: "Tap for Escape", tint: hue)
                }
                if conflict == nil, AXIsProcessTrusted() {
                    Text("Caps Lock no longer types capitals while this is on. Turn it off and Caps Lock is back as it was. In password fields macOS keeps keystrokes private, so Hyper pauses there.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = hyper.notice { Text(notice).font(DS.caption).foregroundStyle(.orange) }
            }
        }
    }
}

/// The hero's plate: the home row, Caps Lock lit in the hue while Hyper is on, and above it what
/// the key now sends. At rest it holds still; under the pointer it plays a hold, a chord and a tap.
private struct HyperPlate: View {
    let on: Bool
    let tapEscape: Bool
    let hue: Color

    private let u = 26.0
    // Four letters leave the plate's bottom-right corner to the readout.
    private let letters = ["A", "S", "D", "F"]

    var body: some View {
        PlateTimeline { elapsed in
            let t = elapsed.map { $0.truncatingRemainder(dividingBy: 3.2) }
            // At rest: Caps Lock simply shows what it is now.
            let holding = t.map { $0 < 1.6 } ?? on
            let chord = t.map { $0 > 0.55 && $0 < 1.15 } ?? false
            let tapping = t.map { $0 > 2.2 && $0 < 2.45 } ?? false
            let esc = tapEscape && (t.map { $0 > 2.45 && $0 < 3.0 } ?? false)
            let lit = on && (holding || tapping)
            VStack(alignment: .leading, spacing: 10) {
                Text(output(lit: lit, chord: chord, esc: esc))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(on ? .white : DS.Ink.secondary)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(on && (chord || esc) ? AnyShapeStyle(hue.opacity(0.4)) : AnyShapeStyle(.black.opacity(0.4)), in: .capsule)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                    .padding(.leading, 6)
                HStack(spacing: 5) {
                    key("caps lock", width: u * 2, lit: lit, pressed: on && (chord || tapping))
                    ForEach(letters, id: \.self) { letter in
                        key(letter, width: u, lit: false, pressed: on && letter == "A" && chord, chorded: on && letter == "A" && chord)
                    }
                }
                .padding(6)
                .background(.black.opacity(0.4), in: .rect(cornerRadius: 9, style: .continuous))
            }
            .padding(.leading, 18).padding(.top, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(DS.Motion.hover, value: lit)
            .animation(DS.Motion.hover, value: chord)
        }
    }

    private func output(lit: Bool, chord: Bool, esc: Bool) -> String {
        guard on else { return "⇪  types capitals" }
        if esc { return "esc" }
        if chord { return "⌃⌥⇧⌘ A" }
        return lit ? "⌃⌥⇧⌘ held" : (tapEscape ? "tap: esc" : "⌃⌥⇧⌘")
    }

    private func key(_ label: String, width: Double, lit: Bool, pressed: Bool, chorded: Bool = false) -> some View {
        Text(label)
            .font(.system(size: label.count > 1 ? 8.5 : 11, weight: .medium))
            .foregroundStyle(lit ? Color.black.opacity(0.75) : .white.opacity(chorded ? 1 : 0.7))
            .padding(label.count > 1 ? 4 : 0)
            .frame(width: width, height: u, alignment: label.count > 1 ? .bottomLeading : .center)
            .background(lit ? AnyShapeStyle(hue) : (chorded ? AnyShapeStyle(hue.opacity(0.55)) : AnyShapeStyle(Color.white.opacity(0.12))),
                        in: .rect(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(lit ? 0.35 : 0.1), lineWidth: 0.5)
            }
            .background {
                // A glow drawn as a gradient behind the key: no shadow, so lighting it is opacity only.
                RadialGradient(colors: [hue.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: width * 0.9)
                    .frame(width: width * 2, height: u * 2.2)
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .offset(y: pressed ? 1.5 : 0)
    }
}

/// A row of the keyboard with Caps Lock glowing while held, the four modifiers it stands for
/// lighting above it, and, between holds, a tap that turns into Escape.
struct HyperKeyPreview: View {
    let size: CGSize
    let tapEscape: Bool

    var body: some View {
        let u = size.width * 0.034
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            // A hold with A pressed, then a quick tap, on a loop.
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2)
            let holding = t < 1.6
            let chord = t > 0.55 && t < 1.15
            let tapping = t > 2.2 && t < 2.45
            let escShown = tapEscape && t > 2.45 && t < 3.0
            let glow = holding || tapping
            VStack(spacing: u * 0.7) {
                HStack(spacing: u * 0.3) {
                    ForEach(["⌃", "⌥", "⇧", "⌘"], id: \.self) { symbol in
                        Text(symbol).font(.system(size: u * 0.62, weight: .semibold))
                            .frame(width: u * 1.15, height: u * 1.0)
                            .foregroundStyle(.white.opacity(holding ? 1 : 0.35))
                            .background((holding ? DS.Ink.accent.opacity(0.85) : Color.white.opacity(0.08)), in: .rect(cornerRadius: u * 0.25))
                    }
                    Text(escShown ? "esc" : (chord ? "⌃⌥⇧⌘A" : "Tap: Esc"))
                        .font(.system(size: u * 0.48, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, u * 0.4).frame(height: u * 1.0)
                        .background(.black.opacity(escShown || chord ? 0.6 : 0.4), in: .capsule)
                        .opacity(tapEscape || !escShown ? 1 : 0.4)
                }
                HStack(spacing: u * 0.18) {
                    key("caps lock", width: u * 2.0, unit: u, lit: glow)
                    ForEach(["A", "S", "D", "F", "G", "H", "J", "K", "L"], id: \.self) { letter in
                        key(letter, width: u, unit: u, lit: letter == "A" && chord)
                    }
                }
                .padding(u * 0.3)
                .background(.black.opacity(0.45), in: .rect(cornerRadius: u * 0.35))
            }
            .animation(.easeOut(duration: 0.12), value: glow)
            .animation(.easeOut(duration: 0.12), value: chord)
        }
        .frame(width: size.width, height: size.height)
    }

    private func key(_ label: String, width: Double, unit u: Double, lit: Bool) -> some View {
        Text(label)
            .font(.system(size: u * (label.count > 1 ? 0.3 : 0.42), weight: .medium))
            .foregroundStyle(.white.opacity(lit ? 1 : 0.7))
            .frame(width: width, height: u, alignment: label.count > 1 ? .bottomLeading : .center)
            .padding(label.count > 1 ? u * 0.12 : 0)
            .frame(width: width, height: u)
            .background(lit ? DS.Ink.accent : Color.white.opacity(0.12), in: .rect(cornerRadius: u * 0.18))
            .shadow(color: lit ? DS.Ink.accent.opacity(0.9) : .clear, radius: u * 0.4)
    }
}
