import AppKit
import DockCore
import SwiftUI

// MARK: - Atelier HUD
//
// Apple's volume and brightness overlay cannot be restyled, moved or turned off. Atelier HUD
// takes the keys instead: an active session tap sees the NX_SYSDEFINED media keys before
// macOS acts on them, swallows the ones it was asked to own, makes the change itself
// (HUDHardware.swift) and draws its own overlay. A key Atelier cannot honour (a digital output
// with no volume, a monitor DisplayServices cannot drive) is let through untouched, so macOS
// handles it exactly as before. Turning every option off removes the tap.
//
// Why not hide Apple's HUD by stopping OSDUIHelper: that means signalling a system process,
// and on macOS 27 the overlay no longer lives there. Swallowing the key is the dependable route.

private nonisolated(unsafe) var hudTap: CFMachPort?
/// Which keys the tap owns; read by its C callback, set on the main thread.
private nonisolated(unsafe) var ownVolume = false
private nonisolated(unsafe) var ownBrightness = false
private nonisolated(unsafe) var ownKeyboard = false
private nonisolated(unsafe) var swallowedCount = 0
/// Media key presses that reached the tap, by kind, whether or not they were taken. Lets the
/// card say honestly whether a key arrives on this Mac at all.
private nonisolated(unsafe) var seenVolume = 0
private nonisolated(unsafe) var seenBrightness = 0
private nonisolated(unsafe) var seenKeyboard = 0
/// Keys whose press was swallowed, so their release is swallowed too and no app sees half a press.
private nonisolated(unsafe) var heldKeys: Set<Int> = []

private func hudCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let hudTap { CGEvent.tapEnable(tap: hudTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
          let key = MediaKeyEvent.decode(subtype: Int(ns.subtype.rawValue), data1: ns.data1) else {
        return Unmanaged.passUnretained(event)
    }
    let owned: Bool
    switch key.key.kind {
    case .volume: owned = ownVolume; if key.down { seenVolume += 1 }
    case .brightness: owned = ownBrightness; if key.down { seenBrightness += 1 }
    case .keyboard: owned = ownKeyboard; if key.down { seenKeyboard += 1 }
    }
    guard owned else { return Unmanaged.passUnretained(event) }
    guard key.down else {
        return heldKeys.remove(key.key.rawValue) != nil ? nil : Unmanaged.passUnretained(event)
    }
    let flags = event.flags
    let shift = flags.contains(.maskShift), option = flags.contains(.maskAlternate)
    // ⌥ alone opens Sound or Displays settings on a stock Mac; that stays Apple's.
    if option && !shift { return Unmanaged.passUnretained(event) }
    // The tap's source is on the main run loop, so this is the main thread.
    let handled = MainActor.assumeIsolated { AtelierHUD.shared.handle(key.key, fine: option && shift, shift: shift) }
    guard handled else { return Unmanaged.passUnretained(event) }
    heldKeys.insert(key.key.rawValue)
    swallowedCount += 1
    return nil
}

enum HUDStyle: String, CaseIterable, Identifiable {
    case pill, island, classic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pill: "Pill"
        case .island: "Island"
        case .classic: "Classic"
        }
    }
}

/// What the overlay is showing right now. One instance drives the real panel.
@MainActor
final class HUDState: ObservableObject {
    @Published var kind: HUDKind = .volume
    @Published var level = 0.5
    @Published var muted = false
    @Published var visible = false
    @Published var style: HUDStyle = .pill
    /// The notch on the screen the HUD is on, in points; a stand-in on screens without one.
    @Published var notch = CGSize(width: 185, height: 32)
}

@MainActor
final class AtelierHUD: ObservableObject {
    static let shared = AtelierHUD()

    @Published var volume: Bool { didSet { store.set(volume, forKey: "hud.volume"); apply() } }
    @Published var brightness: Bool { didSet { store.set(brightness, forKey: "hud.brightness"); apply() } }
    @Published var keyboard: Bool { didSet { store.set(keyboard, forKey: "hud.keyboard"); apply() } }
    @Published var style: HUDStyle { didSet { store.set(style.rawValue, forKey: "hud.style"); state.style = style; placed = nil } }

    /// For tests: changes Atelier made from a key, by kind.
    private(set) var volumeCount = 0
    private(set) var brightnessCount = 0
    private(set) var keyboardCount = 0
    /// Brightness jumps of a whole step that no key reaching the tap explains: the sign that
    /// this Mac's own brightness keys go straight to the display, past every event tap.
    @Published private(set) var brightnessUnseen = 0
    var tapActive: Bool { hudTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var swallowed: Int { swallowedCount }
    var seen: (volume: Int, brightness: Int, keyboard: Int) { (seenVolume, seenBrightness, seenKeyboard) }

    let state = HUDState()
    private let store = UserDefaults.standard
    private var source: CFRunLoopSource?
    private var panel: HUDPanel?
    /// The screen and style the panel was last laid out for; the frame only moves when they change.
    private var placed: (screen: CGDirectDisplayID, style: HUDStyle)?
    private var hideTask: Task<Void, Never>?
    private var watch: Timer?
    private var lastBrightness: Double?
    private var lastBrightnessKey = Date.distantPast
    private var ramp: Timer?

    private init() {
        volume = UserDefaults.standard.bool(forKey: "hud.volume")
        brightness = UserDefaults.standard.bool(forKey: "hud.brightness")
        keyboard = UserDefaults.standard.bool(forKey: "hud.keyboard")
        style = HUDStyle(rawValue: UserDefaults.standard.string(forKey: "hud.style") ?? "") ?? .pill
        state.style = style
    }

    func resume() {
        if volume || brightness || keyboard { apply() }
    }

    /// The tap can only be made once Accessibility is granted. A person who grants it after
    /// switching the HUD on comes back to the card, which calls this, and the keys start working
    /// without a relaunch.
    func retryIfTrusted() {
        if (volume || brightness || keyboard), hudTap == nil, AXIsProcessTrusted() { apply() }
    }

    /// Whether any display answers DisplayServices: Apple's built-in panels, Studio Display and
    /// Pro Display XDR do; most third-party monitors do not, and their keys stay with macOS.
    var brightnessDrivable: Bool { DisplayBrightness.target != nil || ExternalMonitors.shared.drivesAny }

    var availability: FeatureAvailability {
        if !AXIsProcessTrusted() { return .limited("Needs Accessibility, to see the keys before macOS does") }
        if !brightnessDrivable { return .limited("No display here takes brightness from Atelier; those keys stay with macOS") }
        return .available
    }

    var diagnostics: String {
        let light = KeyboardLight.shared
        return "hudTap=\(tapActive) hudVol=\(volumeCount) hudBright=\(brightnessCount) hudKbd=\(keyboardCount) hudSwallowed=\(swallowed) " +
            "hudSeen=\(seenVolume)/\(seenBrightness)/\(seenKeyboard) hudBrightUnseen=\(brightnessUnseen) hudStyle=\(style.rawValue) " +
            "kbdLevel=\(light.available ? String(format: "%.3f", light.level) : "-") kbdIdle=\(light.available ? (light.neverDim ? "never" : String(Int(light.idle))) : "-") " +
            "kbdAuto=\(light.auto)"
    }

    private func apply() {
        ownVolume = volume
        ownBrightness = brightness
        ownKeyboard = keyboard
        if volume || brightness || keyboard {
            if hudTap == nil, AXIsProcessTrusted() {
                let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED: media keys, and nothing else.
                if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: hudCallback, userInfo: nil) {
                    hudTap = tap
                    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                    self.source = source
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        } else if let tap = hudTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            hudTap = nil
            source = nil
            heldKeys = []
        }
        watchBrightness(brightness && hudTap != nil)
        objectWillChange.send()
    }

    // MARK: Keys

    /// Makes the change a key asks for and shows it. False lets the key through to macOS.
    fileprivate func handle(_ key: MediaKey, fine: Bool, shift: Bool) -> Bool {
        switch key.kind {
        case .volume:
            // Sound going to a monitor's speakers: its own volume, over DDC.
            if let monitor = ExternalMonitors.shared.volumeKeyTarget {
                guard let result = ExternalMonitors.shared.stepVolume(monitor, up: key.raises, fine: fine) else { return false }
                volumeCount += 1
                show(.volume, level: result.level, muted: result.muted)
                return true
            }
            guard SystemVolume.controllable else { return false }
            var level = SystemVolume.level
            var muted = SystemVolume.canMute && SystemVolume.muted
            if let up = key.raises {
                level = HUDStep.step(level, up: up, fine: fine)
                SystemVolume.set(level)
                // Any volume key brings the sound back, as on a stock Mac.
                if muted { SystemVolume.setMuted(false); muted = false }
                SystemVolume.feedback(shift: shift && !fine)
            } else {
                guard SystemVolume.canMute else { return false }
                muted.toggle()
                SystemVolume.setMuted(muted)
            }
            volumeCount += 1
            show(.volume, level: level, muted: muted)
        case .brightness:
            // The pointer on an external monitor Atelier drives: DDC or the software dimmer.
            if let monitor = ExternalMonitors.shared.brightnessKeyTarget {
                guard let next = ExternalMonitors.shared.stepBrightness(monitor, up: key.raises ?? true, fine: fine) else { return false }
                brightnessCount += 1
                show(.brightness, level: next)
                return true
            }
            guard let display = DisplayBrightness.target, let current = ramping ?? DisplayBrightness.level(display) else { return false }
            let next = HUDStep.step(current, up: key.raises ?? true, fine: fine)
            glide(display, from: DisplayBrightness.level(display) ?? current, to: next)
            lastBrightness = next
            lastBrightnessKey = .now
            brightnessCount += 1
            show(.brightness, level: next)
        case .keyboard:
            guard let next = KeyboardLight.shared.step(up: key.raises ?? true, fine: fine) else { return false }
            keyboardCount += 1
            show(.keyboard, level: next)
        }
        return true
    }

    /// The brightness a glide is heading for, so quick presses build on each other.
    private var rampTarget: Double?
    private var ramping: Double? { ramp == nil ? nil : rampTarget }

    /// Eases the screen to its new brightness over a sixth of a second instead of jumping,
    /// the way Apple's keys do.
    private func glide(_ display: CGDirectDisplayID, from start: Double, to end: Double) {
        ramp?.invalidate()
        rampTarget = end
        let began = Date.now, duration = 0.16
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = min(Date.now.timeIntervalSince(began) / duration, 1)
                let eased = 1 - pow(1 - t, 3)
                DisplayBrightness.set(start + (end - start) * eased, on: display)
                if t >= 1 {
                    AtelierHUD.shared.ramp?.invalidate()
                    AtelierHUD.shared.ramp = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ramp = timer
    }

    /// Once a second while Atelier owns the brightness keys: a whole-step jump with no key
    /// behind it means the keys bypass event taps here. Auto-brightness drifts smoothly and
    /// off the step grid, so it is not mistaken for a key.
    private func watchBrightness(_ on: Bool) {
        guard on else { watch?.invalidate(); watch = nil; return }
        guard watch == nil else { return }
        lastBrightness = DisplayBrightness.target.flatMap(DisplayBrightness.level)
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AtelierHUD.shared.checkBrightness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func checkBrightness() {
        guard let now = DisplayBrightness.target.flatMap(DisplayBrightness.level) else { return }
        defer { lastBrightness = now }
        guard let last = lastBrightness, ramp == nil, Date.now.timeIntervalSince(lastBrightnessKey) > 1.5 else { return }
        let onGrid = abs(now * 16 - (now * 16).rounded()) < 0.02
        if abs(now - last) >= 0.05, onGrid { brightnessUnseen += 1 }
    }

    // MARK: The overlay

    /// Shows the HUD with what is set now, changing nothing. For the card's Try It and for tests.
    func preview(kind: HUDKind) {
        switch kind {
        case .volume: show(.volume, level: SystemVolume.level, muted: SystemVolume.canMute && SystemVolume.muted)
        case .brightness:
            let external = ExternalMonitors.shared.brightnessKeyTarget.flatMap { ExternalMonitors.shared.monitor($0)?.brightness }
            show(.brightness, level: external ?? DisplayBrightness.target.flatMap(DisplayBrightness.level) ?? 0.6)
        case .keyboard: show(.keyboard, level: KeyboardLight.shared.available ? KeyboardLight.shared.level : 0.5)
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func show(_ kind: HUDKind, level: Double, muted: Bool = false) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        place(panel, on: screen)
        let wasVisible = state.visible
        if state.kind != kind || !wasVisible {
            state.kind = kind
        }
        // The level springs inside the views; only appearing and disappearing are animated here.
        state.level = level
        state.muted = muted
        // The panel is invisible to VoiceOver, so say what changed, as Apple's overlay does.
        if NSWorkspace.shared.isVoiceOverEnabled {
            let name = ["volume": "Volume", "brightness": "Brightness", "keyboard": "Keyboard brightness"][kind.rawValue] ?? ""
            let spoken = kind == .volume && muted ? "Volume muted" : "\(name) \(HUDStep.percent(level)) percent"
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        if !wasVisible || !panel.isVisible {
            panel.orderFrontRegardless()
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.72)) {
                state.visible = true
            }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.9)) {
                self.state.visible = false
            }
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, !self.state.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the menu bar, so the Island can sit in the notch.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary, .transient]
        panel.contentView = NSHostingView(rootView: HUDOverlay(state: state))
        self.panel = panel
        return panel
    }

    /// Sizes and places the panel for the style on the screen under the pointer.
    private func place(_ panel: HUDPanel, on screen: NSScreen) {
        let id = screen.displayID ?? 0
        if let placed, placed.screen == id, placed.style == style { return }
        placed = (id, style)
        let frame = screen.frame
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        state.notch = Self.notch(of: screen)
        let size: CGSize
        let origin: CGPoint
        switch style {
        case .pill:
            size = CGSize(width: 380, height: 96)
            origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - menuBar - size.height)
        case .island:
            size = CGSize(width: state.notch.width + 2 * IslandHUD.wing + 2 * IslandHUD.ear + 40, height: state.notch.height + 80)
            origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height)
        case .classic:
            size = CGSize(width: 260, height: 260)
            origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.12)
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
    }

    /// The camera housing, from the strips either side of it that macOS reports as usable.
    /// Screens without one get a stand-in the size of a 14-inch MacBook Pro's.
    static func notch(of screen: NSScreen) -> CGSize {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width > 40 { return CGSize(width: width, height: top) }
        }
        return CGSize(width: 185, height: 32)
    }
}

/// Never takes focus, and may sit over the menu bar and the notch: borderless windows are
/// otherwise pushed below the menu bar when their frame is set.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - The three styles

/// The live overlay: the chosen style, fed by the shared state.
struct HUDOverlay: View {
    @ObservedObject var state: HUDState

    var body: some View {
        HUDBody(style: state.style, kind: state.kind, level: state.level, muted: state.muted,
                visible: state.visible, notch: state.notch)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.style == .classic ? .center : .top)
    }
}

/// One HUD drawn from plain values, so the real panel and the stage replica share it.
struct HUDBody: View {
    let style: HUDStyle
    let kind: HUDKind
    let level: Double
    let muted: Bool
    let visible: Bool
    let notch: CGSize

    var body: some View {
        switch style {
        case .pill: PillHUD(kind: kind, level: level, muted: muted, visible: visible)
        case .island: IslandHUD(kind: kind, level: level, muted: muted, visible: visible, notch: notch)
        case .classic: ClassicHUD(kind: kind, level: level, muted: muted, visible: visible)
        }
    }
}

/// How a new level travels: quick, with a little overshoot, and interruptible by the next press.
private let levelSpring = Animation.spring(response: 0.28, dampingFraction: 0.78)

struct HUDSymbolView: View {
    let kind: HUDKind
    let level: Double
    let muted: Bool
    let size: Double

    var body: some View {
        Image(systemName: HUDSymbol.name(kind, level: level, muted: muted))
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace.offUp))
            .frame(width: size * 1.45, height: size * 1.2)
    }
}

/// A level bar whose fill springs to its value and glows at the edge.
struct LevelBar: View {
    let level: Double
    let muted: Bool
    var height = 6.0

    var body: some View {
        GeometryReader { geometry in
            let shown = muted ? 0 : min(max(level, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.82), .white], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(shown > 0 ? height : 0, geometry.size.width * shown))
                    .shadow(color: .white.opacity(0.45), radius: 5)
                    .animation(levelSpring, value: shown)
            }
        }
        .frame(height: height)
    }
}

struct PercentLabel: View {
    let level: Double
    let muted: Bool
    var size = 13.0

    var body: some View {
        let value = muted ? 0 : HUDStep.percent(level)
        Text("\(value)")
            .font(.system(size: size, weight: .semibold).monospacedDigit())
            .contentTransition(.numericText(value: Double(value)))
            .animation(levelSpring, value: value)
    }
}

/// A slim glass capsule under the menu bar: icon, a live bar, the percentage.
struct PillHUD: View {
    let kind: HUDKind
    let level: Double
    let muted: Bool
    let visible: Bool

    var body: some View {
        HStack(spacing: 12) {
            HUDSymbolView(kind: kind, level: level, muted: muted, size: 15)
            LevelBar(level: level, muted: muted).frame(width: 168)
            PercentLabel(level: level, muted: muted).frame(width: 30, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.leading, 14).padding(.trailing, 18)
        .frame(height: 44)
        .atelierGlass(.regular.tint(.black.opacity(0.28)), in: .capsule)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .scaleEffect(visible ? 1 : 0.55, anchor: .top)
        .offset(y: visible ? 10 : -24)
        .opacity(visible ? 1 : 0)
        .blur(radius: visible ? 0 : 6)
    }
}

/// Black, flush with the top of the screen, with concave shoulders where it meets the bezel,
/// like the camera housing it grows out of.
struct IslandShape: Shape {
    var ear: Double
    var radius: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, e = ear, r = min(radius, h / 2, (w - 2 * e) / 2)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: e, y: e), control: CGPoint(x: e, y: 0))
        path.addLine(to: CGPoint(x: e, y: h - r))
        path.addQuadCurve(to: CGPoint(x: e + r, y: h), control: CGPoint(x: e, y: h))
        path.addLine(to: CGPoint(x: w - e - r, y: h))
        path.addQuadCurve(to: CGPoint(x: w - e, y: h - r), control: CGPoint(x: w - e, y: h))
        path.addLine(to: CGPoint(x: w - e, y: e))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - e, y: 0))
        path.closeSubpath()
        return path
    }
}

/// Grows out of the notch: the icon and percentage either side of the camera, the bar below it.
/// Hidden, it is exactly the notch, so it seems to retract into the hardware.
struct IslandHUD: View {
    static let wing = 74.0
    static let ear = 9.0
    let kind: HUDKind
    let level: Double
    let muted: Bool
    let visible: Bool
    let notch: CGSize

    var body: some View {
        let width = visible ? notch.width + 2 * Self.wing : notch.width
        let height = visible ? notch.height + 30 : notch.height
        ZStack(alignment: .top) {
            IslandShape(ear: Self.ear, radius: visible ? 20 : 10)
                .fill(.black)
                .frame(width: width + 2 * Self.ear, height: height)
                .shadow(color: .black.opacity(visible ? 0.35 : 0), radius: 14, y: 6)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HUDSymbolView(kind: kind, level: level, muted: muted, size: 14)
                        .frame(width: Self.wing - 8, alignment: .center)
                    Spacer(minLength: notch.width)
                    PercentLabel(level: level, muted: muted, size: 14)
                        .frame(width: Self.wing - 8, alignment: .center)
                }
                .frame(height: notch.height)
                LevelBar(level: level, muted: muted, height: 5)
                    .padding(.horizontal, 22)
                    .frame(height: 22)
            }
            .frame(width: notch.width + 2 * Self.wing)
            .foregroundStyle(.white)
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 4)
            .scaleEffect(visible ? 1 : 0.8, anchor: .top)
            // Only the contents are held inside the island while it grows and retracts. Clipping
            // the whole view cut the island's shadow off at the frame, a hard-edged dark box
            // around it on the screen and on the stage.
            .mask(alignment: .top) {
                IslandShape(ear: Self.ear, radius: visible ? 20 : 10)
                    .frame(width: width + 2 * Self.ear, height: height)
            }
        }
        .frame(width: width + 2 * Self.ear, height: height, alignment: .top)
        .opacity(visible ? 1 : 0.001)
    }
}

/// The Mac's own square, redrawn in Liquid Glass, with a fill that flows through the sixteen chiclets.
struct ClassicHUD: View {
    let kind: HUDKind
    let level: Double
    let muted: Bool
    let visible: Bool

    var body: some View {
        VStack(spacing: 22) {
            HUDSymbolView(kind: kind, level: level, muted: muted, size: 62)
                .frame(height: 96)
            ChicletRow(level: muted ? 0 : level)
                .frame(width: 150, height: 8)
                .animation(levelSpring, value: muted ? 0 : level)
        }
        .foregroundStyle(.white)
        .frame(width: 200, height: 200)
        .atelierGlass(.regular.tint(.black.opacity(0.22)), in: .rect(cornerRadius: 40, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
        .scaleEffect(visible ? 1 : 0.86)
        .opacity(visible ? 1 : 0)
        .blur(radius: visible ? 0 : 8)
    }
}

/// Sixteen chiclets; the animated level fills them one into the next, quarter steps included.
struct ChicletRow: View, @MainActor Animatable {
    var level: Double
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let fills = HUDStep.chiclets(level)
            let gap = 2.0
            let width = (size.width - gap * Double(fills.count - 1)) / Double(fills.count)
            for (index, fill) in fills.enumerated() {
                let x = Double(index) * (width + gap)
                let cell = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: cell, cornerRadius: 1.5), with: .color(.white.opacity(0.18)))
                if fill > 0 {
                    let lit = CGRect(x: x, y: 0, width: width * fill, height: size.height)
                    context.fill(Path(roundedRect: lit, cornerRadius: 1.5), with: .color(.white))
                }
            }
        }
    }
}

// MARK: - Card and stage

struct AtelierHUDCard: View {
    @ObservedObject private var hud = AtelierHUD.shared
    @ObservedObject private var light = KeyboardLight.shared
    private var trusted: Bool { AXIsProcessTrusted() }
    private var anyOn: Bool { hud.volume || hud.brightness || hud.keyboard }

    /// The hero's switch: on takes every key the Mac has, off gives them all back to Apple.
    private var allKeys: Binding<Bool> {
        Binding(get: { anyOn }, set: { on in
            hud.volume = on
            hud.brightness = on
            hud.keyboard = on && light.available
        })
    }

    var body: some View {
        let availability = hud.availability
        HeroCard("Atelier HUD",
                 pitch: "Atelier's own volume and brightness overlay in place of Apple's, in the style you pick.",
                 isOn: allKeys, hue: DS.Spectrum.surfaces,
                 readout: "64 steps", readoutCaption: "Quarter steps with ⌥⇧",
                 preview: .overlay("hud", "Atelier HUD", isOn: anyOn) { size in HUDStagePreview(size: size, kind: .volume) }) {
            HUDPlate(style: hud.style).displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: 12) {
                    Text("Style").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 52, alignment: .leading)
                    Segments(selection: $hud.style, options: HUDStyle.allCases.map { ($0, $0.title) }) { style in
                        .overlay("hud.style." + style.rawValue, style.title, isOn: true) { size in
                            HUDStagePreview(size: size, kind: .volume, style: style)
                        }
                    }
                    Button("Try It") { hud.preview(kind: .volume) }
                        .buttonStyle(Pressable(scale: 0.96))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.primary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        .accessibilityHint("Shows the HUD at the current volume without changing it")
                }
                SettingRow(title: "Volume", detail: "Apple's sixteen steps, set by Atelier. ⌥⇧ still moves a quarter step.", density: .compact) {
                    LuxSwitch(isOn: $hud.volume, label: "Atelier HUD for volume", tint: DS.Spectrum.surfaces)
                }
                .stagePreview(.overlay("hud.volume", "Volume HUD", isOn: hud.volume) { size in HUDStagePreview(size: size, kind: .volume) })
                SettingRow(title: "Display Brightness", detail: brightnessNote, density: .compact) {
                    LuxSwitch(isOn: $hud.brightness, label: "Atelier HUD for brightness", tint: DS.Spectrum.surfaces)
                }
                .disabled(!hud.brightnessDrivable && !hud.brightness)
                .opacity(hud.brightnessDrivable || hud.brightness ? 1 : 0.4)
                .stagePreview(.overlay("hud.brightness", "Brightness HUD", isOn: hud.brightness) { size in HUDStagePreview(size: size, kind: .brightness) })
                SettingRow(title: "Keyboard Light", detail: keyboardNote, density: .compact) {
                    LuxSwitch(isOn: $hud.keyboard, label: "Atelier HUD for the keyboard light", tint: DS.Spectrum.surfaces)
                }
                .disabled(!light.available)
                .opacity(light.available ? 1 : 0.4)
                .stagePreview(.overlay("hud.keyboard", "Keyboard Light HUD", isOn: hud.keyboard) { size in HUDStagePreview(size: size, kind: .keyboard) })
                Text(footnote).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { hud.retryIfTrusted() }
    }

    private var footnote: String {
        if !trusted { return "Needs Accessibility, to see the keys before macOS does." }
        switch hud.style {
        case .pill: return "A slim glass capsule under the menu bar, on the display with the pointer."
        case .island:
            return MacPlatform.hasNotch ? "Grows out of the notch. On a display without one, it drops from the top edge."
                                        : "Drops from the top edge, as if from a notch. On a MacBook with one, it grows out of the camera housing."
        case .classic: return "Apple's square, in Liquid Glass, with a fill that flows from chiclet to chiclet."
        }
    }

    /// Honest about this Mac: built-in brightness keys on Apple silicon can go straight to the
    /// display without ever becoming an event Atelier could see.
    private var brightnessNote: String {
        guard hud.brightnessDrivable else {
            return "No display here takes brightness from Atelier (most third-party monitors), so these keys stay with macOS."
        }
        return HUDCompat.brightnessNote(appleSilicon: MacPlatform.appleSilicon, owned: hud.brightness, tapActive: hud.tapActive,
                                        seen: hud.seen.brightness, unseen: hud.brightnessUnseen)
    }

    private var keyboardNote: String {
        HUDCompat.keyboardKeysNote(appleSilicon: MacPlatform.appleSilicon, backlight: light.available,
                                   owned: hud.keyboard && hud.tapActive, seen: hud.seen.keyboard)
    }
}

/// The chosen HUD in miniature on a little desktop, drawn in plain fills (no glass, no blur, so
/// it costs nothing in a scrolling list). Still at rest; under the pointer the level rises and
/// falls in Apple's sixteen steps, the way a held volume key moves it.
private struct HUDPlate: View {
    let style: HUDStyle

    var body: some View {
        HeroLife { live in
            HeroClock(live: live, rest: 0) { t in
                let wave = (sin(t * 1.3 - .pi / 2) + 1) / 2
                let level = live ? (4 + (10 * wave).rounded()) / 16 : 10.0 / 16
                ZStack(alignment: .top) {
                    desktop
                    hud(level: level)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var desktop: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.36), Color(red: 0.05, green: 0.06, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
                .opacity(0.8)
            Rectangle().fill(.black.opacity(0.35)).frame(height: 12)
        }
        .frame(width: 230, height: 132)
        .clipShape(.rect(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder private func hud(level: Double) -> some View {
        let ink = Color.white
        switch style {
        case .pill:
            HStack(spacing: 7) {
                Image(systemName: HUDSymbol.name(.volume, level: level)).font(.system(size: 9, weight: .semibold))
                    .frame(width: 13)
                bar(level, width: 84, height: 3.5)
                Text("\(HUDStep.percent(level))").font(.system(size: 8.5, weight: .semibold)).monospacedDigit()
                    .frame(width: 16, alignment: .trailing)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color(white: 0.12).opacity(0.92), in: .capsule)
            .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
            .padding(.top, 16 + 18)
        case .island:
            let notch = CGSize(width: 46, height: 10)
            ZStack(alignment: .top) {
                IslandShape(ear: 3, radius: 10).fill(.black)
                    .frame(width: notch.width + 2 * 40 + 6, height: notch.height + 14)
                VStack(spacing: 2) {
                    HStack(spacing: 0) {
                        Image(systemName: HUDSymbol.name(.volume, level: level)).font(.system(size: 7, weight: .semibold))
                            .frame(width: 36)
                        Spacer(minLength: notch.width)
                        Text("\(HUDStep.percent(level))").font(.system(size: 7, weight: .semibold)).monospacedDigit()
                            .frame(width: 36)
                    }
                    .frame(height: notch.height)
                    bar(level, width: notch.width + 50, height: 2.5)
                }
                .frame(width: notch.width + 80)
                .foregroundStyle(ink)
            }
            .padding(.top, 16)
        case .classic:
            VStack(spacing: 8) {
                Image(systemName: HUDSymbol.name(.volume, level: level)).font(.system(size: 22, weight: .semibold))
                    .frame(height: 30)
                ChicletRow(level: level).frame(width: 52, height: 3.5)
            }
            .foregroundStyle(ink)
            .frame(width: 76, height: 76)
            .background(Color(white: 0.12).opacity(0.92), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
            .padding(.top, 16 + 32)
        }
    }

    private func bar(_ level: Double, width: Double, height: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18))
            Capsule().fill(.white).frame(width: max(height, width * level))
        }
        .frame(width: width, height: height)
    }
}

/// The chosen HUD on the replica Mac, stepping a level up and back down on a loop.
struct HUDStagePreview: View {
    @ObservedObject private var hud = AtelierHUD.shared
    let size: CGSize
    let kind: HUDKind
    var style: HUDStyle?

    var body: some View {
        let style = style ?? hud.style
        // The replica is the first screen drawn at stage size, so the HUD is drawn at that
        // screen's real points and scaled by the same factor. The Island stays true to scale so
        // it grows out of the replica's own notch (a fixed 14-inch notch at 1.25× sat over it,
        // wider and taller); the pill and the square are drawn a little larger, to be legible.
        let screen = NSScreen.screens.first
        let screenWidth = max(Double(screen?.frame.width ?? 1512), 1)
        let scale = size.width / screenWidth * (style == .island ? 1 : 1.25)
        // The replica draws a camera housing only when its screen has one; otherwise the Island
        // gets a stand-in of a 14-inch MacBook Pro's to grow from.
        let replicaNotch = MacStage.notch != nil
        let notch = screen.map(AtelierHUD.notch(of:)) ?? CGSize(width: 185, height: 32)
        TimelineView(.periodic(from: .now, by: 0.22)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.22) % 22
            // Up five steps, a pause, back down, a pause, then gone for a beat so the entrance shows too.
            let steps = [0, 1, 2, 3, 4, 5, 5, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0][tick]
            let visible = tick < 15
            let level = 7.0 / 16 + Double(steps) / 16
            HUDBody(style: style, kind: kind, level: level, muted: false, visible: visible, notch: notch)
                .animation(.spring(response: 0.38, dampingFraction: 0.72), value: visible)
                .frame(width: notch.width + 2 * IslandHUD.wing + 2 * IslandHUD.ear + 40,
                       height: style == .classic ? 260 : notch.height + 80, alignment: .top)
                .background(alignment: .top) {
                    if style == .island && !replicaNotch {
                        UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black)
                            .frame(width: notch.width, height: notch.height)
                    }
                }
                .scaleEffect(scale, anchor: style == .classic ? .center : .top)
                .frame(width: size.width, height: size.height,
                       alignment: style == .classic ? .center : .top)
                // The pill hangs under the replica's menu bar, as the real one does under the real one.
                .offset(y: style == .classic ? size.height * 0.2 : (style == .pill ? size.width * MacStage.menuBarFraction : 0))
        }
        .allowsHitTesting(false)
    }
}
