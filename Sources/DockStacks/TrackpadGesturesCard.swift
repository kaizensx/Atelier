import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Trackpad Gestures card
//
// The card's centrepiece is the trackpad itself, seen from above, with your real fingers on it
// as you touch: read from the sensor at its own rate and drawn in one Canvas, so it costs a
// handful of circles per frame and nothing at all while no finger is down (the timeline pauses).
// Every gesture row previews on the stage: the replica's trackpad performs the gesture and the
// screen above it does the chosen action.

/// The trackpad's surface in the sensor's proportions (156 × 96 mm on the M5 MacBook).
private let padAspect = 156.0 / 96.0

struct TrackpadGesturesCard: View {
    @ObservedObject private var gestures = TrackpadGestures.shared
    private let hue = DS.Spectrum.input

    var body: some View {
        let assigned = TrackpadGesture.allCases.filter { gestures.binding($0).action != .none }.count
        HeroCard("Trackpad Gestures",
                 pitch: "Taps, corner taps, edge flicks and a firm press that macOS has no setting for.",
                 isOn: $gestures.enabled, hue: hue,
                 readout: "\(assigned)", readoutCaption: "of \(TrackpadGesture.allCases.count) set") {
            // Your real fingers, read from the sensor while the card is on screen.
            LiveTrackpad(hue: hue)
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
        } controls: {
            VStack(alignment: .leading, spacing: 12) {
                AvailabilityNote(availability: gestures.availability)
                VStack(spacing: 2) {
                    ForEach(TrackpadGesture.allCases) { gesture in
                        GestureRow(gesture: gesture)
                            // The firm press reads pressure: without Force Touch it cannot fire.
                            .disabled(gesture.needsForceTouch && !gestures.forceAvailable)
                            .opacity(gesture.needsForceTouch && !gestures.forceAvailable ? 0.45 : 1)
                            .stagePreview(.overlay("input.gesture." + gesture.rawValue, gesture.title,
                                                   isOn: gestures.enabled && gestures.binding(gesture).action != .none) { size in
                                GestureStagePreview(gesture: gesture, action: gestures.binding(gesture).action, size: size)
                            })
                    }
                }
                if gestures.binding(.threeForce).action != .none && gestures.forceAvailable {
                    HStack(spacing: 12) {
                        Text("Firmness").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 64, alignment: .leading)
                        LuxSlider(value: $gestures.forceThreshold, range: 0.6...1.6, label: "Press firmness", tint: hue)
                        Text(String(format: "%.2f", gestures.forceThreshold)).font(DS.Typo.value)
                            .foregroundStyle(DS.Ink.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
                footnote
            }
        }
        // No sensor: nothing to switch, on the plate or the switch.
        .disabled(!gestures.available && !gestures.enabled)
        .onAppear { gestures.resurvey(); gestures.watch(true) }
        .onDisappear { gestures.watch(false) }
    }

    @ViewBuilder private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if gestures.available {
                Text("macOS keeps every gesture of its own: scrolling, pinching, and three- and four-finger swipes for Mission Control and Spaces still work. Atelier only adds taps and edge flicks, which none of those are.")
            }
            let needsAX = TrackpadGesture.allCases.contains { gestures.binding($0).action.postsEvents }
            if gestures.enabled && needsAX && !AXIsProcessTrusted() {
                Text("Middle Click, Lock Screen, Play / Pause and shortcuts need Accessibility, to send input.")
                    .foregroundStyle(.orange.opacity(0.9))
            }
            if let error = gestures.lastError {
                Text(error).foregroundStyle(.orange.opacity(0.9))
            }
        }
        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The live trackpad

/// The trackpad from above with the fingers on it now. The top-corner and side-edge zones are
/// drawn faintly, so you can see where corner taps and edge swipes start.
struct LiveTrackpad: View {
    @ObservedObject private var gestures = TrackpadGestures.shared
    var hue: Color = DS.Ink.accent

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, geometry.size.height * padAspect)
            let pad = CGSize(width: width, height: width / padAspect)
            ZStack {
                TimelineView(.animation(minimumInterval: 1 / 120, paused: !gestures.touching)) { _ in
                    Canvas { context, size in
                        // Paused between touches, the last frame stays up; show the glass empty then,
                        // not the rings of fingers that already left.
                        let touches = gestures.touching ? touchEngine.withLock { $0.latest } : []
                        TrackpadArt.draw(touches, in: context, size: size, hue: hue)
                    }
                }
                if !gestures.touching {
                    Text(gestures.available ? "Touch the trackpad to see your fingers here" : "No trackpad to read")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .transition(.opacity)
                }
                GestureFlash(hue: hue)
            }
            .frame(width: pad.width, height: pad.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(DS.Motion.exit, value: gestures.touching)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live trackpad")
        .accessibilityValue(gestures.touching ? "Touched" : "Not touched")
    }
}

/// The trackpad's glass and the dots on it, shared by the card (real touches) and the stage
/// (synthetic ones).
enum TrackpadArt {
    static func draw(_ touches: [TouchSample], in context: GraphicsContext, size: CGSize, zones: Bool = true,
                     hue: Color = DS.Ink.accent) {
        let rect = CGRect(origin: .zero, size: size)
        let radius = size.width * 0.045
        let body = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius, style: .continuous)
        context.fill(body, with: .linearGradient(Gradient(colors: [Color(white: 0.24), Color(white: 0.14)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(body, with: .linearGradient(Gradient(colors: [.white.opacity(0.28), .white.opacity(0.05)]),
                                                   startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)), lineWidth: 1)
        if zones {
            let tuning = GestureTuning.standard
            let corner = CGSize(width: size.width * tuning.cornerSize, height: size.height * tuning.cornerSize)
            let zone = GraphicsContext.Shading.color(.white.opacity(0.035))
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: corner), cornerRadius: radius, style: .continuous), with: zone)
            context.fill(Path(roundedRect: CGRect(x: size.width - corner.width, y: 0, width: corner.width, height: corner.height),
                              cornerRadius: radius, style: .continuous), with: zone)
            let edge = size.width * tuning.edgeZone
            context.fill(Path(CGRect(x: 0, y: radius, width: edge, height: size.height - radius * 2)), with: zone)
            context.fill(Path(CGRect(x: size.width - edge, y: radius, width: edge, height: size.height - radius * 2)), with: zone)
        }
        let accent = hue
        for touch in touches {
            // The sensor's y runs up from the edge nearest you; the screen's runs down.
            let center = CGPoint(x: touch.x * size.width, y: (1 - touch.y) * size.height)
            let r = max(6, touch.majorAxis) * size.width / 156 * 1.6
            if touch.isDown {
                let firm = min(max((touch.pressure - 0.2) / 1.0, 0), 1)
                let glow = CGRect(x: center.x - r * 2.2, y: center.y - r * 2.2, width: r * 4.4, height: r * 4.4)
                context.fill(Path(ellipseIn: glow), with: .radialGradient(Gradient(colors: [accent.opacity(0.35 + 0.4 * firm), .clear]),
                                                                        center: center, startRadius: 0, endRadius: r * 2.2))
                let dot = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: dot), with: .radialGradient(Gradient(colors: [.white, accent.opacity(0.9)]),
                                                                       center: CGPoint(x: center.x - r * 0.3, y: center.y - r * 0.3),
                                                                       startRadius: 0, endRadius: r * 1.3))
            } else {
                // Arriving or leaving: a faint ring where the finger hovers.
                let ring = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.25)), lineWidth: 1)
            }
        }
    }
}

/// The name of the gesture just recognised, blooming over the trackpad and fading.
private struct GestureFlash: View {
    @ObservedObject private var gestures = TrackpadGestures.shared
    var hue: Color = DS.Ink.accent

    var body: some View {
        if let last = gestures.lastGesture {
            let action = gestures.binding(last.gesture).action
            HStack(spacing: 6) {
                Image(systemName: action.symbol).font(.system(size: 11, weight: .semibold))
                Text(gestures.enabled ? "\(last.gesture.title) → \(action.title)" : last.gesture.title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(hue.opacity(0.55), in: .capsule)
            .keyframeAnimator(initialValue: 0.0, trigger: last.at) { view, t in
                view.opacity(t).scaleEffect(0.9 + 0.1 * t)
            } keyframes: { _ in
                MoveKeyframe(0)
                SpringKeyframe(1, duration: 0.25)
                LinearKeyframe(1, duration: 0.9)
                LinearKeyframe(0, duration: 0.35)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 10)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Rows

private struct GestureRow: View {
    let gesture: TrackpadGesture
    @ObservedObject private var gestures = TrackpadGestures.shared

    var body: some View {
        let binding = gestures.binding(gesture)
        HStack(alignment: .top, spacing: 12) {
            GestureGlyph(gesture: gesture).frame(width: 40, height: 25).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(gesture.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                Text(gesture.detail).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                if let overlap = gesture.appleOverlap {
                    Text(overlap).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                ActionMenu(gesture: gesture, binding: binding)
                if binding.action == .openApp { AppChooser(gesture: gesture, binding: binding) }
                if binding.action == .shortcut { GestureChordRecorder(gesture: gesture, binding: binding) }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct ActionMenu: View {
    let gesture: TrackpadGesture
    let binding: GestureBinding

    var body: some View {
        Menu {
            ForEach(GestureAction.allCases) { action in
                Button {
                    var changed = binding
                    changed.action = action
                    TrackpadGestures.shared.set(changed, for: gesture)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: binding.action.symbol).font(.system(size: 11, weight: .semibold))
                Text(binding.action.title).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
            }
            .foregroundStyle(binding.action == .none ? DS.Ink.secondary : DS.Ink.primary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(binding.action == .none ? DS.Ink.fill : DS.Ink.fillStrong, in: .rect(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(Pressable(scale: 0.97))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(gesture.title) action")
        .accessibilityValue(binding.action.title)
    }
}

private struct AppChooser: View {
    let gesture: TrackpadGesture
    let binding: GestureBinding

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 5) {
                if !binding.app.isEmpty {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: binding.app)).resizable().frame(width: 16, height: 16)
                }
                Text(binding.app.isEmpty ? "Choose App…" : FileManager.default.displayName(atPath: binding.app))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(DS.Ink.fill, in: .rect(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.97))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var changed = binding
        changed.app = url.path
        TrackpadGestures.shared.set(changed, for: gesture)
    }
}

/// Click, then press the keys the gesture should send. Escape cancels; Delete clears.
private struct GestureChordRecorder: View {
    let gesture: TrackpadGesture
    let binding: GestureBinding
    @StateObject private var model = RecorderModel()

    var body: some View {
        Button {
            if model.recording {
                model.end()
            } else {
                model.begin { combo in
                    var changed = TrackpadGestures.shared.binding(gesture)
                    changed.combo = combo
                    TrackpadGestures.shared.set(changed, for: gesture)
                }
            }
        } label: {
            Text(model.recording ? (model.rejected ? "Add ⌘, ⌥ or ⌃" : "Type shortcut…") : binding.combo?.display ?? "Set Shortcut")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(DS.Ink.primary)
                .frame(minWidth: 86).frame(height: 26).padding(.horizontal, 8)
                .background(model.recording ? AnyShapeStyle(DS.Ink.accent.opacity(0.55)) : AnyShapeStyle(DS.Ink.fill),
                            in: .rect(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.96))
        .animation(DS.Motion.settle, value: model.recording)
        .onDisappear { model.end() }
        .accessibilityLabel("\(gesture.title) shortcut")
        .accessibilityValue(binding.combo?.display ?? "None")
    }
}

/// A thumbnail trackpad with the gesture's fingers on it.
private struct GestureGlyph: View {
    let gesture: TrackpadGesture

    var body: some View {
        Canvas { context, size in
            TrackpadArt.draw([], in: context, size: size, zones: false)
            let points = GesturePaths.points(gesture, t: gesture == .swipeFromLeft || gesture == .swipeFromRight ? 0.5 : 1)
            for (x, y) in points {
                let c = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                context.fill(Path(ellipseIn: CGRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2)), with: .color(DS.Ink.accent))
            }
            if gesture == .swipeFromLeft || gesture == .swipeFromRight {
                let y = size.height * 0.5
                var arrow = Path()
                let from = gesture == .swipeFromLeft ? 2.0 : size.width - 2
                arrow.move(to: CGPoint(x: from, y: y))
                arrow.addLine(to: CGPoint(x: size.width * 0.5, y: y))
                context.stroke(arrow, with: .color(DS.Ink.accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
            if gesture == .threeForce {
                for (x, y) in points {
                    let c = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)),
                                   with: .color(DS.Ink.accent.opacity(0.5)), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Where each gesture's fingers sit, in sensor coordinates; `t` runs the swipes from the edge in.
enum GesturePaths {
    static func points(_ gesture: TrackpadGesture, t: Double) -> [(Double, Double)] {
        switch gesture {
        case .threeTap, .threeForce: [(0.38, 0.46), (0.5, 0.54), (0.62, 0.46)]
        case .fourTap: [(0.27, 0.44), (0.41, 0.54), (0.57, 0.54), (0.72, 0.44)]
        case .topLeftTap: [(0.09, 0.86), (0.19, 0.8)]
        case .topRightTap: [(0.81, 0.8), (0.91, 0.86)]
        case .swipeFromLeft: [(0.03 + 0.4 * t, 0.5)]
        case .swipeFromRight: [(0.97 - 0.4 * t, 0.5)]
        }
    }
}

// MARK: - Stage

/// The stage shows the Mac with its trackpad below the screen: fingers come down and do the
/// gesture, a ripple runs from the trackpad, and the screen does the action, on a loop.
struct GestureStagePreview: View {
    let gesture: TrackpadGesture
    let action: GestureAction
    let size: CGSize

    private static let loop = 2.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.loop) / Self.loop
            // 0–0.15 fingers arrive, 0.15–0.42 the gesture, then the action holds the stage.
            let touch = min(max((t - 0.15) / 0.27, 0), 1)
            let fired = min(max((t - 0.42) / 0.12, 0), 1)
            let fade = t > 0.9 ? (1 - t) / 0.1 : 1
            let padWidth = size.width * 0.24
            ZStack {
                ActionScene(action: action, progress: fired * fade, width: size.width)
                VStack(spacing: size.width * 0.008) {
                    Spacer()
                    Canvas { ctx, padSize in
                        TrackpadArt.draw(Self.touches(gesture, t: t, touch: touch), in: ctx, size: padSize)
                    }
                    .frame(width: padWidth, height: padWidth / padAspect)
                    .overlay {
                        // The ripple from the trackpad the moment it fires.
                        Circle().strokeBorder(DS.Ink.accent.opacity(0.7 * (1 - fired)), lineWidth: 3)
                            .frame(width: padWidth * (0.3 + fired * 1.2), height: padWidth * (0.3 + fired * 1.2))
                            .opacity(fired > 0 && fired < 1 ? 1 : 0)
                            .blendMode(.plusLighter)
                    }
                    Text(gesture.title)
                        .font(.system(size: size.width * 0.013, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, size.width * 0.01).padding(.vertical, size.width * 0.004)
                        .background(.black.opacity(0.45), in: .capsule)
                }
                .padding(.bottom, size.height * 0.05)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// Fingers for the moment `t` of the loop: they land, tap (lift at the end) or slide or press.
    private static func touches(_ gesture: TrackpadGesture, t: Double, touch: Double) -> [TouchSample] {
        guard t > 0.08 && t < 0.62 else { return [] }
        let landing = t < 0.15
        let isTap = [.threeTap, .fourTap, .topLeftTap, .topRightTap].contains(gesture)
        // A tap is short: down for the middle of the gesture window only.
        let down = !landing && (!isTap || (touch > 0.2 && touch < 0.7)) && t < 0.5
        let swipeT = gesture == .swipeFromLeft || gesture == .swipeFromRight ? touch : 1
        let pressure = gesture == .threeForce ? 0.35 + touch * 1.0 : 0.4
        return GesturePaths.points(gesture, t: swipeT).enumerated().map { i, p in
            TouchSample(id: i, x: p.0, y: p.1, state: down ? TouchPhase.touching.rawValue : TouchPhase.hoverInRange.rawValue,
                        pressure: pressure, majorAxis: gesture == .threeForce ? 7 + touch * 2 : 7)
        }
    }
}

/// What the action does, drawn on the replica's screen at `progress` (0 nothing, 1 fully there).
private struct ActionScene: View {
    let action: GestureAction
    let progress: Double
    let width: Double

    var body: some View {
        let w = width * 0.3
        ZStack {
            switch action {
            case .missionControl, .appExpose:
                // Windows step back and spread out, as Mission Control lays them side by side.
                ForEach(0..<3, id: \.self) { i in
                    let spread = Double(i - 1) * w * 0.75 * progress
                    MockWindow(width: w * (1 - 0.35 * progress), title: ["Safari", "Notes", "Mail"][i]) {
                        BrowserContent(width: w * (1 - 0.35 * progress)).frame(height: w * 0.35).clipped()
                    }
                    .offset(x: spread, y: Double(i - 1) * w * 0.05 * (1 - progress) - w * 0.1 * progress)
                    .opacity(action == .appExpose && i == 1 ? 1 - 0.6 * progress : 1)
                }
            case .showDesktop:
                // Windows slide off to the screen's edges, the desktop shows.
                ForEach(0..<2, id: \.self) { i in
                    MockWindow(width: w, title: i == 0 ? "Safari" : "Notes") {
                        BrowserContent(width: w).frame(height: w * 0.35).clipped()
                    }
                    .offset(x: (i == 0 ? -1 : 1) * (w * 0.3 + width * 0.5 * progress), y: -w * 0.1)
                }
            case .screenshot:
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(.white.opacity(0.08))
                    .frame(width: w * 1.2 * progress, height: w * 0.7 * progress)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus").font(.system(size: w * 0.06, weight: .light)).foregroundStyle(.white)
                            .offset(x: w * 0.03, y: w * 0.03)
                    }
                    .offset(y: -w * 0.15)
            case .lockScreen:
                Rectangle().fill(.black.opacity(0.6 * progress))
            case .middleClick:
                MockWindow(width: w * 1.2, title: "Safari") {
                    BrowserContent(width: w * 1.2).frame(height: w * 0.45).clipped()
                }
                .overlay {
                    Image(systemName: "cursorarrow").font(.system(size: w * 0.08)).foregroundStyle(.white)
                        .shadow(radius: 2)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(1 - progress), lineWidth: 2)
                                .frame(width: w * 0.25 * progress, height: w * 0.25 * progress)
                        }
                }
                .offset(y: -w * 0.15)
                .opacity(0.35 + 0.65 * progress)
            default:
                EmptyView()
            }
            if action == .none {
                tile(symbol: "circle.dashed", title: "Pick an action")
                    .opacity(progress)
            } else {
                tile(symbol: action.symbol, title: action.title)
                    .scaleEffect(0.85 + 0.15 * progress)
                    .opacity(progress)
                    .offset(y: action == .lockScreen ? 0 : w * 0.42)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(symbol: String, title: String) -> some View {
        let s = width * 0.022
        return HStack(spacing: s * 0.5) {
            Image(systemName: symbol).font(.system(size: s, weight: .medium))
            Text(title).font(.system(size: s * 0.7, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, s * 0.9).padding(.vertical, s * 0.5)
        .atelierGlass(.regular.tint(.black.opacity(0.3)), in: .capsule)
    }
}

// MARK: - Haptics card

struct HapticsCard: View {
    @ObservedObject private var haptics = Haptics.shared
    @State private var ready: Bool?
    @State private var availability: FeatureAvailability = .available
    /// Each "Feel It" sends one ring across the plate, on the same frame as the click.
    @State private var pulses = 0
    private let hue = DS.Spectrum.sound

    var body: some View {
        HeroCard("Haptics", pitch: "A soft click from the trackpad itself when a trackpad gesture, a title-bar gesture or a radial menu pick lands.",
                 isOn: $haptics.enabled, hue: hue,
                 readout: haptics.strength.title, readoutCaption: "click",
                 preview: .overlay("input.haptics", "Haptic Feedback", isOn: haptics.enabled) { size in
                     HapticStagePreview(strength: haptics.strength, size: size)
                 }) {
            HapticPlate(strength: haptics.strength, pulses: pulses, hue: hue)
        } controls: {
            VStack(alignment: .leading, spacing: 12) {
                AvailabilityNote(availability: availability)
                HStack(spacing: 10) {
                    Segments(selection: $haptics.strength, options: HapticStrength.allCases.map { ($0, $0.title) })
                    Button {
                        haptics.feel(haptics.strength)
                        pulses += 1
                    } label: {
                        Label("Feel It", systemImage: "hand.tap")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.primary)
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(DS.Ink.fillStrong, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                    }
                    .buttonStyle(Pressable(scale: 0.95))
                    .accessibilityHint("Plays one click on the trackpad")
                }
                if availability.isUsable {
                    Text(ready == false
                         ? "No trackpad actuator could be opened. Atelier uses macOS’s own haptics instead, which play only while Atelier is in front."
                         : "Played by the trackpad’s actuator directly, so it works while other apps are in front.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Nothing can play the click without a Force Touch trackpad; turning it off stays possible.
        .disabled(!availability.isUsable && !haptics.enabled)
        .onAppear {
            haptics.rescan()
            ready = haptics.actuatorReady
            availability = haptics.availability
        }
    }
}

/// The hero's plate: the trackpad from above, still at rest with one faint ring of its last
/// click. Under the pointer it beats at the chosen strength; "Feel It" sends a ring of its own.
private struct HapticPlate: View {
    let strength: HapticStrength
    let pulses: Int
    let hue: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let force = Double(strength.rawValue) / 6
        let pad = CGSize(width: 150, height: 150 / padAspect)
        PlateTimeline { elapsed in
            Canvas { context, size in
                let beat = elapsed.map { $0.truncatingRemainder(dividingBy: 0.9) / 0.9 }
                // Rings first, so the glass sits on them.
                for ring in 0..<2 {
                    let lag: Double = Double(ring) * 0.12
                    let rest: Double = ring == 0 ? 0.3 : 1
                    let r: Double = beat.map { (b: Double) -> Double in min(max(b - lag, 0), 1) } ?? rest
                    let grow: Double = 1 + r * (0.25 + 0.5 * force)
                    let rect = CGRect(x: size.width / 2 - pad.width * grow / 2, y: size.height / 2 - pad.height * grow / 2,
                                      width: pad.width * grow, height: pad.height * grow)
                    context.stroke(Path(roundedRect: rect, cornerRadius: pad.width * 0.045 * grow, style: .continuous),
                                   with: .color(hue.opacity((1 - r) * (0.35 + 0.6 * force))), lineWidth: 1.5 + 2.5 * force)
                }
                // The glass gives a hair under each click.
                let squeeze: Double = 0.015 * force
                let press: Double = beat.map { (b: Double) -> Double in 1 - squeeze * max(0, 1 - b * 6) } ?? 1
                var glass = context
                glass.translateBy(x: size.width / 2, y: size.height / 2)
                glass.scaleBy(x: press, y: press)
                glass.translateBy(x: -pad.width / 2, y: -pad.height / 2)
                TrackpadArt.draw([], in: glass, size: pad, zones: false, hue: hue)
            }
        }
        .overlay {
            // One ring for each "Feel It", in step with the actuator.
            RoundedRectangle(cornerRadius: 150 * 0.045, style: .continuous)
                .strokeBorder(hue, lineWidth: 2 + 3 * force)
                .frame(width: pad.width, height: pad.height)
                .keyframeAnimator(initialValue: 1.0, trigger: pulses) { view, r in
                    view.scaleEffect(reduceMotion ? 1 : 1 + r * 0.6).opacity((1 - r) * 0.9)
                } keyframes: { _ in
                    MoveKeyframe(0)
                    CubicKeyframe(1, duration: 0.6)
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
    }
}

/// The trackpad below the screen pulses with rings, stronger for a firmer click, each one
/// labelled with the moment that plays it.
struct HapticStagePreview: View {
    let strength: HapticStrength
    let size: CGSize

    var body: some View {
        let padWidth = size.width * 0.24
        let moments = ["Trackpad gesture", "Title-bar gesture", "Radial menu"]
        TimelineView(.animation(minimumInterval: 1 / 120)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let beat = time.truncatingRemainder(dividingBy: 0.9) / 0.9
            let index = Int(time / 0.9) % moments.count
            let force = Double(strength.rawValue) / 6
            VStack(spacing: size.width * 0.01) {
                Spacer()
                Text(moments[index])
                    .font(.system(size: size.width * 0.014, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, size.width * 0.012).padding(.vertical, size.width * 0.005)
                    .atelierGlass(.regular.tint(.black.opacity(0.3)), in: .capsule)
                    .opacity(1 - beat * 0.6)
                Canvas { ctx, padSize in TrackpadArt.draw([], in: ctx, size: padSize, zones: false) }
                    .frame(width: padWidth, height: padWidth / padAspect)
                    .scaleEffect(1 - 0.012 * force * max(0, 1 - beat * 6))
                    .overlay {
                        ForEach(0..<2, id: \.self) { ring in
                            let r = min(max(beat - Double(ring) * 0.12, 0), 1)
                            RoundedRectangle(cornerRadius: padWidth * 0.05, style: .continuous)
                                .strokeBorder(DS.Ink.accent.opacity((1 - r) * (0.4 + 0.6 * force)), lineWidth: 2 + 3 * force)
                                .frame(width: padWidth * (1 + r * 0.5 * force), height: padWidth / padAspect * (1 + r * 0.5 * force))
                                .blendMode(.plusLighter)
                        }
                    }
            }
            .padding(.bottom, size.height * 0.06)
            .frame(width: size.width, height: size.height)
        }
    }
}
