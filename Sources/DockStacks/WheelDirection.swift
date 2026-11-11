import AppKit
import SwiftUI

// MARK: - Mouse Scroll Direction
//
// macOS has one scroll direction for everything: natural on the trackpad means backwards on
// a wheel mouse. This keeps the trackpad as macOS has it and flips only the wheel, in the
// spirit of Scroll Reverser. An event tap sees each scroll before apps do; wheel clicks come
// as non-continuous events, trackpad and Magic Mouse swipes as continuous ones, and only the
// first are turned round. Turning it off removes the tap.
//
// Smooth Wheel, in the spirit of Mos, rides the same tap: each wheel click is held back and
// glided out as a run of small pixel scrolls over about a tenth of a second, the way a
// trackpad scrolls. Atelier's own glide events carry a mark so the tap lets them pass.
//
// The scroll fields used here (delta, fixed-point delta, point delta per axis, and
// scrollWheelEventIsContinuous) have been public and unchanged since Mac OS X 10.5 and read the
// same on 14 through 27, Intel and Apple silicon. A mouse tap needs Accessibility to modify
// events (not Input Monitoring, which only keyboards ask for), and Secure Input does not touch
// scrolling, so this keeps working in password fields.

/// Read by the tap's C callback, which runs outside any actor.
private nonisolated(unsafe) var flipVertical = false
private nonisolated(unsafe) var flipHorizontal = false
private nonisolated(unsafe) var flippedCount = 0
private nonisolated(unsafe) var wheelTap: CFMachPort?
private nonisolated(unsafe) var smoothOn = false
private nonisolated(unsafe) var smoothSpeed = 2.5
/// Pixels still to glide, per axis.
private nonisolated(unsafe) var glideY = 0.0
private nonisolated(unsafe) var glideX = 0.0
private nonisolated(unsafe) var glidedCount = 0
/// Stamped on Atelier's glide events, so the tap does not catch its own scrolling.
private let glideMark: Int64 = 0x41544C52

private func wheelCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                           _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        TapRevoke.disabled(type)
        if let wheelTap { CGEvent.tapEnable(tap: wheelTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel, event.getIntegerValueField(.eventSourceUserData) != glideMark,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
        return Unmanaged.passUnretained(event)
    }
    // Setting one delta field recomputes the others, so all three are read before any is set.
    func flip(_ line: CGEventField, _ fixed: CGEventField, _ point: CGEventField) {
        let (l, f, p) = (event.getIntegerValueField(line), event.getDoubleValueField(fixed), event.getIntegerValueField(point))
        event.setIntegerValueField(line, value: -l)
        event.setDoubleValueField(fixed, value: -f)
        event.setIntegerValueField(point, value: -p)
    }
    if flipVertical { flip(.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1) }
    if flipHorizontal { flip(.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2) }
    if flipVertical || flipHorizontal { flippedCount += 1 }
    if smoothOn {
        glideY += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * smoothSpeed
        glideX += Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * smoothSpeed
        // The tap's run loop source is on the main run loop, so this is the main thread.
        MainActor.assumeIsolated { WheelDirection.shared.glide() }
        return nil
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class WheelDirection: ObservableObject {
    static let shared = WheelDirection()

    @Published var reverse: Bool { didSet { store.set(reverse, forKey: "wheel.reverse"); apply() } }
    @Published var horizontal: Bool { didSet { store.set(horizontal, forKey: "wheel.horizontal"); apply() } }
    @Published var smooth: Bool { didSet { store.set(smooth, forKey: "wheel.smooth"); apply() } }
    /// How far one wheel click glides, as a multiple of macOS's own step.
    @Published var speed: Double { didSet { store.set(speed, forKey: "wheel.speed"); smoothSpeed = speed } }

    private let store = UserDefaults.standard
    private var source: CFRunLoopSource?

    /// For tests: how many wheel events have been turned round since launch.
    var flipped: Int { flippedCount }
    /// For tests: glide events posted since launch.
    var glided: Int { glidedCount }
    private var glideTimer: Timer?
    private var carryY = 0.0, carryX = 0.0
    var tapActive: Bool { wheelTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Whether the trackpad scrolls naturally, as System Settings has it. The wheel then runs
    /// the other way once reversed.
    var naturalTrackpad: Bool {
        (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
    }

    private init() {
        reverse = UserDefaults.standard.bool(forKey: "wheel.reverse")
        horizontal = UserDefaults.standard.bool(forKey: "wheel.horizontal")
        smooth = UserDefaults.standard.bool(forKey: "wheel.smooth")
        speed = UserDefaults.standard.object(forKey: "wheel.speed") as? Double ?? 2.5
        smoothSpeed = speed
    }

    func resume() {
        InputTrust.watch()
        if reverse || smooth { apply() }
    }

    /// Lets out what the wheel has banked, a fraction each frame: fast at first, easing to a stop.
    fileprivate func glide() {
        guard glideTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { WheelDirection.shared.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
        step()
    }

    private func step() {
        let share = 1 - exp(-(1 / 120) / 0.075)
        let dy = glideY * share + carryY, dx = glideX * share + carryX
        glideY -= glideY * share
        glideX -= glideX * share
        let (y, x) = (dy.rounded(.towardZero), dx.rounded(.towardZero))
        carryY = dy - y
        carryX = dx - x
        if y != 0 || x != 0, let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                  wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) {
            event.setIntegerValueField(.eventSourceUserData, value: glideMark)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.post(tap: .cghidEventTap)
            glidedCount += 1
        }
        if abs(glideY) < 0.5 && abs(glideX) < 0.5 {
            glideY = 0; glideX = 0; carryY = 0; carryX = 0
            glideTimer?.invalidate()
            glideTimer = nil
        }
    }

    private func apply() {
        flipVertical = reverse
        flipHorizontal = reverse && horizontal
        smoothOn = smooth
        if reverse || smooth {
            guard wheelTap == nil, AXIsProcessTrusted() else { return }
            let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: wheelCallback, userInfo: nil) else { TapRevoke.creationFailed(); return }
            wheelTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
            CGEvent.tapEnable(tap: tap, enable: true)
        } else if let tap = wheelTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            wheelTap = nil
            source = nil
        }
        objectWillChange.send()
    }
}

// MARK: - Card and stage

/// A hero plate's miniature clock: still at rest, running only while the pointer is over the
/// plate, and never under Reduce Motion. The content gets the seconds since the hover began, or
/// nil for its resting frame, so every plate has one deliberate still pose.
struct PlateTimeline<Content: View>: View {
    var active: Bool
    var content: (Double?) -> Content
    @State private var since: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(active: Bool = true, @ViewBuilder content: @escaping (Double?) -> Content) {
        self.active = active
        self.content = content
    }

    var body: some View {
        let running = since != nil && active && !reduceMotion
        TimelineView(.animation(minimumInterval: 1 / 120, paused: !running)) { context in
            content(running ? max(context.date.timeIntervalSince(since ?? context.date), 0) : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { since = $0 ? .now : nil }
    }
}

/// Smooth Wheel and Reverse Mouse Wheel, one hero: the wheel mouse made to feel like a trackpad.
struct WheelDirectionCard: View {
    @ObservedObject private var wheel = WheelDirection.shared
    private var trusted: Bool { AXIsProcessTrusted() }
    private let hue = DS.Spectrum.input

    var body: some View {
        // On means the wheel is Atelier's in any way; turning the hero on starts with the glide.
        let on = Binding(get: { wheel.smooth || wheel.reverse },
                         set: { on in
                             if on { wheel.smooth = true } else { wheel.smooth = false; wheel.reverse = false }
                         })
        let glideOnly = wheel.reverse && !wheel.smooth
        HeroCard("Wheel", pitch: "A wheel mouse that glides like a trackpad, and turns the other way if you want.",
                 isOn: on, hue: hue,
                 readout: glideOnly ? "Flipped" : String(format: "%.1f×", wheel.speed),
                 readoutCaption: glideOnly ? "wheel only" : "glide",
                 preview: .overlay("input.smoothWheel", "Smooth Wheel", isOn: wheel.smooth) { size in SmoothWheelPreview(size: size) }) {
            WheelPlate(smooth: wheel.smooth, reverse: wheel.reverse, speed: wheel.speed, hue: hue)
        } controls: {
            VStack(alignment: .leading, spacing: 0) {
                if !AXIsProcessTrusted() {
                    AvailabilityNote(availability: InputTrust.availability).padding(.bottom, DS.Space.s)
                }
                SettingRow(title: "Smooth Wheel", detail: "Each wheel click glides instead of jumping.", density: .compact) {
                    LuxSwitch(isOn: $wheel.smooth, label: "Smooth Wheel", tint: hue)
                }
                HStack(spacing: 12) {
                    Text("Distance").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 58, alignment: .leading)
                    LuxSlider(value: $wheel.speed, range: 1...5, label: "Glide distance", tint: hue)
                    Text(String(format: "%.1f×", wheel.speed)).font(DS.Typo.value)
                        .foregroundStyle(DS.Ink.secondary).frame(width: 40, alignment: .trailing)
                }
                .frame(height: 32)
                .disabled(!wheel.smooth)
                .opacity(wheel.smooth ? 1 : 0.4)
                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5).padding(.vertical, 6)
                SettingRow(title: "Reverse Mouse Wheel", detail: "Flip only the wheel. The trackpad keeps its direction.",
                           density: .compact) {
                    LuxSwitch(isOn: $wheel.reverse, label: "Reverse Mouse Wheel", tint: hue)
                }
                .stagePreview(.overlay("input.wheel", "Reverse Mouse Wheel", isOn: wheel.reverse) { size in WheelPreview(size: size) })
                SettingRow(title: "Sideways Too", detail: "Also flip tilt wheels and Shift-scroll.", density: .compact) {
                    LuxSwitch(isOn: $wheel.horizontal, label: "Sideways Too", tint: hue)
                }
                .disabled(!wheel.reverse)
                .opacity(wheel.reverse ? 1 : 0.4)
                Text(trusted ? "Trackpad: \(wheel.naturalTrackpad ? "natural" : "standard"). Magic Mouse counts as a trackpad here."
                             : "Accessibility lets Atelier see scrolling before apps do.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Space.s)
            }
        }
    }
}

/// The plate: two pages and the wheel between them. Three clicks scroll both; macOS's page jumps
/// a notch at a time, Atelier's glides, and runs the other way when the wheel is reversed.
private struct WheelPlate: View {
    let smooth: Bool
    let reverse: Bool
    let speed: Double
    let hue: Color

    var body: some View {
        PlateTimeline { elapsed in
            Canvas { context, size in
                let t = elapsed.map { $0.truncatingRemainder(dividingBy: 2.4) }
                let clicks = [0.25, 0.58, 0.91]
                let stepped = t.map { now in Double(clicks.filter { now >= $0 }.count) } ?? 0
                // The same easing the glide uses, stretched a little so the eye can follow it.
                let glided = t.map { now in
                    clicks.reduce(0.0) { sum, start in now < start ? sum : sum + (1 - exp(-(now - start) / 0.12)) }
                } ?? 0
                let mine = (smooth ? glided : stepped) * (smooth ? speed / 2.5 : 1) * (reverse ? -1 : 1)
                let pageW = 92.0, pageH = 96.0, gap = 34.0
                let total = pageW * 2 + gap * 2 + 30
                let originX = (size.width - total) / 2, top = (size.height - pageH) / 2 - 4
                page(in: &context, x: originX, y: top, w: pageW, h: pageH, scroll: stepped, lit: false, label: "macOS")
                page(in: &context, x: originX + pageW + gap * 2 + 30, y: top, w: pageW, h: pageH, scroll: mine,
                     lit: smooth || reverse, label: smooth ? "Smooth" : "Atelier")
                mouse(in: &context, center: CGPoint(x: originX + pageW + gap + 15, y: top + pageH / 2), turn: stepped)
            }
        }
    }

    private func page(in context: inout GraphicsContext, x: Double, y: Double, w: Double, h: Double,
                      scroll: Double, lit: Bool, label: String) {
        let frame = CGRect(x: x, y: y, width: w, height: h)
        let shape = Path(roundedRect: frame, cornerRadius: 8, style: .continuous)
        context.fill(shape, with: .color(.white.opacity(0.05)))
        context.stroke(shape, with: .color(lit ? hue.opacity(0.7) : .white.opacity(0.14)), lineWidth: lit ? 1 : 0.5)
        var inner = context
        inner.clip(to: Path(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerRadius: 7, style: .continuous))
        // A page that never runs out: lines repeat every six, and scrolling wraps through them.
        let line = 11.0, notch = line * 1.6
        let shift = (scroll * notch).truncatingRemainder(dividingBy: line * 6)
        let widths = [0.8, 0.55, 0.7, 0.4, 0.75, 0.6]
        for i in -7..<16 {
            let ly = y + 10 + Double(i) * line - shift
            guard ly > y - line, ly < y + h + line else { continue }
            let index = ((i % 6) + 6) % 6
            let bar = CGRect(x: x + 10, y: ly, width: (w - 20) * widths[index], height: 4)
            inner.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(index == 0 ? (lit ? hue.opacity(0.75) : .white.opacity(0.38)) : .white.opacity(0.2)))
        }
        context.draw(Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(lit ? hue : DS.Ink.secondary),
                     at: CGPoint(x: x + w / 2, y: y + h + 11))
    }

    private func mouse(in context: inout GraphicsContext, center: CGPoint, turn: Double) {
        let body = CGRect(x: center.x - 15, y: center.y - 24, width: 30, height: 48)
        let shape = Path(roundedRect: body, cornerRadius: 15, style: .continuous)
        context.fill(shape, with: .linearGradient(Gradient(colors: [Color(white: 0.3), Color(white: 0.16)]),
                                                  startPoint: CGPoint(x: body.midX, y: body.minY), endPoint: CGPoint(x: body.midX, y: body.maxY)))
        context.stroke(shape, with: .color(.white.opacity(0.22)), lineWidth: 0.5)
        let lit = smooth || reverse
        let slot = CGRect(x: center.x - 2.5, y: center.y - 16, width: 5, height: 13)
        if lit {
            let glow = slot.insetBy(dx: -9, dy: -9)
            context.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [hue.opacity(0.55), .clear]),
                                                                    center: CGPoint(x: glow.midX, y: glow.midY), startRadius: 0, endRadius: 14))
        }
        context.fill(Path(roundedRect: slot, cornerRadius: 2.5), with: .color(lit ? hue : .white.opacity(0.45)))
        // Ridges on the wheel roll by with each click.
        var ridges = context
        ridges.clip(to: Path(roundedRect: slot, cornerRadius: 2.5))
        let phase = (turn * 4).truncatingRemainder(dividingBy: 4)
        for i in -1..<5 {
            let ry = slot.minY + (Double(i) + phase) * 3.4
            ridges.fill(Path(CGRect(x: slot.minX, y: ry, width: slot.width, height: 1)), with: .color(.black.opacity(0.35)))
        }
        if reverse {
            context.draw(Text(Image(systemName: "arrow.up.arrow.down")).font(.system(size: 9, weight: .bold)).foregroundStyle(hue),
                         at: CGPoint(x: center.x, y: center.y + 36))
        }
    }
}

/// A mouse and a trackpad side by side, each with the way the page goes when you roll or
/// swipe down. The page in the window scrolls along.
struct WheelPreview: View {
    @ObservedObject private var wheel = WheelDirection.shared
    let size: CGSize

    var body: some View {
        let natural = wheel.naturalTrackpad
        let wheelNatural = wheel.reverse ? !natural : natural
        let w = size.width * 0.5
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let wave = sin(t * .pi * 2)
            ZStack {
                MockWindow(width: w, title: "Safari") {
                    BrowserContent(width: w)
                        .offset(y: wave * w * 0.06 * (wheelNatural ? -1 : 1))
                        .frame(height: w * 0.5).clipped()
                }
                HStack(spacing: w * 0.08) {
                    device("computermouse", "Wheel", natural: wheelNatural, wave: wave)
                    device("rectangle.and.hand.point.up.left", "Trackpad", natural: natural, wave: wave)
                }
                .offset(y: w * 0.42)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func device(_ symbol: String, _ name: String, natural: Bool, wave: Double) -> some View {
        let s = size.width * 0.03
        return HStack(spacing: s * 0.4) {
            Image(systemName: symbol).font(.system(size: s, weight: .medium))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: s * 0.55, weight: .semibold))
                Text(natural ? "Natural" : "Standard").font(.system(size: s * 0.45)).opacity(0.7)
            }
            Image(systemName: "arrow.down").font(.system(size: s * 0.6, weight: .bold))
                .offset(y: wave * s * 0.15)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, s * 0.6).padding(.vertical, s * 0.35)
        .background(.black.opacity(0.45), in: .capsule)
    }
}

/// Two pages scrolled by the same three wheel clicks: macOS's jumps on the left, the glide on
/// the right. The glide follows the same easing Atelier uses.
struct SmoothWheelPreview: View {
    @ObservedObject private var wheel = WheelDirection.shared
    let size: CGSize

    var body: some View {
        let w = size.width * 0.34
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            // Three clicks a third of a second apart, then a pause, on a loop.
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)
            let clicks = (0..<3).map { Double($0) * 0.33 }
            let stepped = clicks.filter { t >= $0 }.count
            let glided = clicks.reduce(0.0) { sum, start in
                t < start ? sum : sum + (1 - exp(-(t - start) / 0.075))
            }
            HStack(spacing: size.width * 0.05) {
                page("macOS", offset: Double(stepped), width: w)
                page("Smooth Wheel", offset: glided * (wheel.speed / 2.5), width: w)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func page(_ title: String, offset: Double, width w: Double) -> some View {
        VStack(spacing: w * 0.04) {
            MockWindow(width: w, title: "Safari") {
                // A long page, so each click's travel is plain to see.
                VStack(spacing: w * 0.03) {
                    ForEach(0..<4, id: \.self) { _ in BrowserContent(width: w) }
                }
                .offset(y: -offset * w * 0.16)
                .frame(height: w * 0.62, alignment: .top).clipped()
            }
            Text(title).font(.system(size: w * 0.042, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, w * 0.04).padding(.vertical, w * 0.015)
                .background(.black.opacity(0.45), in: .capsule)
        }
    }
}
