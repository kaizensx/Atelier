import AppKit
import DockCore
import SwiftUI

// MARK: - Hold ⌘Q to Quit
//
// ⌘Q sits next to ⌘W and ⌘Tab, and one slip closes an app with all its windows. In the spirit
// of SlowQuitApps, a keyboard tap holds the shortcut back: a ring fills while you keep it
// down, and only a full ring quits, by passing the very same ⌘Q on to the app, marked so the
// tap lets it through. Let go early and nothing happens. Turning it off removes the tap.
//
// The tap is an active keyboard tap, so it needs Accessibility on every release from 14 to 27.
// In a password field with Secure Input on, macOS keeps keystrokes from taps: ⌘Q there quits at
// once, as it would without Atelier, and a key-up lost that way must not leave the guard stuck
// (see `QuitHoldDecision`).

private nonisolated(unsafe) var guardTap: CFMachPort?
/// Whether a ⌘Q is being held back right now; read by the tap, set on the main thread.
private nonisolated(unsafe) var holding = false
/// Stamped on the ⌘Q Atelier passes on, so the tap does not catch it again.
private let quitMark: Int64 = 0x41545151

private let qKey: Int64 = 12

private func quitCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                          _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let guardTap { CGEvent.tapEnable(tap: guardTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard event.getIntegerValueField(.eventSourceUserData) != quitMark else { return Unmanaged.passUnretained(event) }
    let flags = event.flags
    switch type {
    case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == qKey:
        let others: CGEventFlags = [.maskShift, .maskAlternate, .maskControl]
        let decision = QuitHoldDecision.keyDown(command: flags.contains(.maskCommand), otherModifiers: !flags.intersection(others).isEmpty,
                                                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, holding: holding)
        switch decision {
        case .pass: return Unmanaged.passUnretained(event)
        case .swallowRepeat: return nil  // key repeat while the ring fills
        case .begin:
            // The tap's source is on the main run loop, so this is the main thread. A fresh press
            // while a hold seemed to be on means its key-up was lost: that hold is dropped first.
            let guarded = MainActor.assumeIsolated { () -> Bool in
                if holding { QuitGuard.shared.abandon() }
                return QuitGuard.shared.begin()
            }
            return guarded ? nil : Unmanaged.passUnretained(event)
        }
    case .keyUp where event.getIntegerValueField(.keyboardEventKeycode) == qKey && holding:
        MainActor.assumeIsolated { QuitGuard.shared.release() }
        return nil
    case .flagsChanged where holding && !flags.contains(.maskCommand):
        MainActor.assumeIsolated { QuitGuard.shared.release() }
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

@MainActor
final class QuitGuard: ObservableObject {
    static let shared = QuitGuard()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "quitGuard.enabled"); apply() } }
    /// Seconds ⌘Q must be held.
    @Published var hold: Double { didSet { store.set(hold, forKey: "quitGuard.hold") } }

    /// For tests: presses held back, and apps quit after a full hold.
    private(set) var stopped = 0
    private(set) var quits = 0
    var tapActive: Bool { guardTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private let store = UserDefaults.standard
    private var source: CFRunLoopSource?
    private var hud: NSPanel?
    private var timer: Timer?
    private var target: NSRunningApplication?
    /// After a quit, the rest of the press (repeats, the key coming up) is swallowed.
    private var spent = false

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "quitGuard.enabled")
        hold = UserDefaults.standard.object(forKey: "quitGuard.hold") as? Double ?? 0.8
    }

    func resume() {
        InputTrust.watch()
        if enabled { apply() }
    }

    /// Drops a hold whose key-up never came.
    fileprivate func abandon() {
        spent = false
        cancel()
    }

    private func apply() {
        if enabled {
            guard guardTap == nil, AXIsProcessTrusted() else { return }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
                                   | 1 << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: quitCallback, userInfo: nil) else { return }
            guardTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
            CGEvent.tapEnable(tap: tap, enable: true)
        } else if let tap = guardTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            guardTap = nil
            source = nil
            cancel()
        }
        objectWillChange.send()
    }

    /// A fresh ⌘Q. Returns false when it should go straight through: the Finder, which has
    /// no Quit, or no app in front.
    fileprivate func begin() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.apple.finder" else { return false }
        holding = true
        spent = false
        target = app
        stopped += 1
        show(app)
        timer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { _ in
            MainActor.assumeIsolated { QuitGuard.shared.complete() }
        }
        return true
    }

    /// The key came up, or ⌘ was let go.
    fileprivate func release() {
        if spent {
            holding = false
            spent = false
            return
        }
        cancel()
    }

    private func cancel() {
        holding = false
        timer?.invalidate()
        timer = nil
        target = nil
        hideHUD()
    }

    private func complete() {
        timer = nil
        spent = true
        hideHUD()
        guard let app = target, !app.isTerminated else { return }
        quits += 1
        // The same ⌘Q the app would have had, so it asks about unsaved work as usual.
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(qKey), keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: quitMark)
            event.postToPid(app.processIdentifier)
        }
        target = nil
    }

    // MARK: The ring

    private func show(_ app: NSRunningApplication) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let size = CGSize(width: 260, height: 200)
        let panel = hud ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
            hud = panel
            return panel
        }()
        panel.contentView = NSHostingView(rootView: QuitRing(name: app.localizedName ?? "App", icon: app.icon, hold: hold, started: .now))
        panel.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                       display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hideHUD() {
        guard let hud else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            hud.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if !holding { QuitGuard.shared.hud?.orderOut(nil) }
            }
        }
    }
}

/// The glass card in the middle of the screen: the app's icon inside a ring that fills while
/// ⌘Q is held.
struct QuitRing: View {
    let name: String
    let icon: NSImage?
    let hold: Double
    let started: Date
    var looping = false

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(started)
            let t = looping ? elapsed.truncatingRemainder(dividingBy: hold + 0.6) : elapsed
            let progress = min(max(t / hold, 0), 1)
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 6)
                    Circle().trim(from: 0, to: progress)
                        .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if let icon {
                        Image(nsImage: icon).resizable().frame(width: 58, height: 58)
                    }
                }
                .frame(width: 96, height: 96)
                Text("Hold ⌘Q to Quit \(name)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .atelierGlass(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 26))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Card

struct QuitGuardCard: View {
    @ObservedObject private var quit = QuitGuard.shared

    var body: some View {
        HeroCard("Hold ⌘Q to Quit", pitch: "A slip of ⌘Q does nothing. Keep it down until the ring fills.",
                 isOn: $quit.enabled, hue: DS.Spectrum.surfaces,
                 readout: String(format: "%.1f s", quit.hold), readoutCaption: "Hold",
                 preview: .overlay("apps.quitGuard", "Hold ⌘Q to Quit", isOn: quit.enabled) { size in
                     QuitRing(name: "Safari", icon: QuitPlate.safari, hold: quit.hold, started: .now, looping: true)
                         .frame(width: 260, height: 200)
                         .scaleEffect(size.width / 1100)
                         .frame(width: size.width, height: size.height)
                 }) {
            LivePlate { size, since in QuitPlate(size: size, hold: quit.hold, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                AvailabilityNote(availability: InputTrust.availability)
                HeroSlider(title: "Hold for", value: $quit.hold, range: 0.4...2, hue: DS.Spectrum.surfaces) {
                    String(format: "%.1f s", $0)
                }
                if AXIsProcessTrusted() {
                    Text("The Finder is left alone. In password fields macOS keeps keystrokes private, so ⌘Q quits there at once.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The hero plate: the ⌘ and Q keys beside the ring around the app's icon. At rest the keys
/// are down and the ring is two thirds full; on hover it fills, the app "quits", and again.
struct QuitPlate: View {
    @MainActor static let safari: NSImage? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        .map { NSWorkspace.shared.icon(forFile: $0.resolvingSymlinksInPath().path) }

    let size: CGSize
    let hold: Double
    let since: Date?

    var body: some View {
        let cycle = hold + 0.9
        PlateClock(since: since, rest: hold * 0.66) { time in
            scene(time.truncatingRemainder(dividingBy: cycle))
        }
    }

    private func scene(_ t: Double) -> some View {
        let progress = min(max(t / hold, 0), 1)
        let done = t >= hold
        // After the ring fills, the keys come up and the app's icon fades as it quits.
        let after = min(max((t - hold) / 0.3, 0), 1)
        return HStack(spacing: 22) {
            HStack(spacing: 6) {
                keycap("⌘", down: !done)
                keycap("Q", down: !done)
            }
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 5)
                Circle().trim(from: 0, to: done ? 1 : progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(1 - after)
                Group {
                    if let icon = Self.safari {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "safari").resizable().scaledToFit().foregroundStyle(.white)
                    }
                }
                .frame(width: 46, height: 46)
                .scaleEffect(1 - 0.12 * after)
                .opacity(1 - 0.7 * after)
            }
            .frame(width: 80, height: 80)
        }
        .frame(width: size.width, height: size.height)
    }

    private func keycap(_ key: String, down: Bool) -> some View {
        Text(key)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(down ? 1 : 0.7))
            .frame(width: 40, height: 38)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: down ? 0.2 : 0.26), Color(white: down ? 0.14 : 0.18)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(down ? DS.Spectrum.surfaces.opacity(0.7) : .white.opacity(0.18), lineWidth: 0.75)
                    }
            }
            // Pressed keys sit a point lower; a transform, so nothing is laid out again.
            .offset(y: down ? 1.5 : 0)
    }
}
