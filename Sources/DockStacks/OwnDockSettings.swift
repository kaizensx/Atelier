import AppKit
import DockCore
import SwiftUI

// MARK: - Settings

/// A second, private field that runs in the settings panel, so the lens can be felt here.
@MainActor
private final class OwnDockSim: ObservableObject {
    @Published var scene = DockScene()
    var field = DockField()
    var metrics = DockMetrics()
    @Published var pointer: CGPoint? {
        didSet {
            // The lens still has to close after the pointer leaves.
            if pointer == nil, oldValue != nil { playing = true }
            if pointer != nil, oldValue == nil { last = nil }
        }
    }
    /// A launch or the lens closing is still on screen.
    @Published private(set) var playing = false
    private var last: Date?
    /// The preview runs a clock only while the pointer is over it or something is still moving.
    var active: Bool { pointer != nil || playing }

    /// A scale model shows the bar as it stands: no launches or bounces of its own, and
    /// changes land at once instead of animating with nobody watching.
    func configure(slots: [DockSlot], size: CGSize, edge: OwnDockEdge, tile: Double, large: Double, magnify: Bool,
                   look: DockAppearance, scale: Double) {
        field.motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        field.bounce = look.bounce
        field.launchPulse = look.launch == .pulse
        metrics = DockMetrics(edge: edge, tile: tile, large: large, magnify: magnify, panel: size)
        metrics.apply(look, scale: scale)
        let still = slots.map { slot -> DockSlot in
            var slot = slot
            slot.launching = false
            slot.attention = false
            return slot
        }
        field.sync(still, instant: !active)
        scene = field.scene(metrics)
    }

    func tick(_ date: Date) {
        let elapsed = last.map { date.timeIntervalSince($0) } ?? 1.0 / 60
        last = date
        field.hovering = pointer != nil
        field.pointer = pointer.map { Double($0.x) }
        field.step(elapsed, metrics)
        scene = field.scene(metrics)
        if playing, pointer == nil, field.settled() {
            playing = false
            last = nil
        }
    }

    func tryLaunch() {
        guard let id = field.slots.first(where: { $0.kind == .app })?.id else { return }
        playing = true
        last = nil
        let middle = field.slots.filter { $0.kind == .app }.dropFirst(field.slots.count / 3).first?.id ?? id
        // A launch that finishes at once: the slot opens, then the light leaves it.
        if let index = field.slots.firstIndex(where: { $0.id == middle }) {
            field.slots[index].launching = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let index = self.field.slots.firstIndex(where: { $0.id == middle }) else { return }
                    self.field.slots[index].launching = false
                    self.field.ignite(middle, tile: self.field.fitted(self.metrics).tile)
                    self.playing = true
                }
            }
        }
        if field.bounce { field.pulse(middle, strength: 0.9, tile: field.fitted(metrics).tile) }
        scene = field.scene(metrics)
    }
}

struct OwnDockPreview: View {
    @ObservedObject var dock: OwnDock
    @ObservedObject var live: OwnDockLive
    let theme: DockTheme
    let slots: [DockSlot]
    var height = 132.0
    /// Each change plays one launch on the preview. The button that asks for it lives with the
    /// hero's controls, so the plate itself stays one big switch.
    var launch = 0
    @StateObject private var sim = OwnDockSim()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 120, paused: !sim.active)) { context in
                OwnDockBar(scene: sim.scene, theme: theme, vitals: dock.vitals)
                    .onChange(of: context.date) { _, date in sim.tick(date) }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): sim.pointer = point
                case .ended: sim.pointer = nil
                }
            }
            .onAppear { configure(geometry.size) }
            .onChange(of: geometry.size) { _, size in configure(size) }
            .onChange(of: slots) { configure(geometry.size) }
            .onChange(of: live.version) { configure(geometry.size) }
            .onChange(of: dock.sections) { configure(geometry.size) }
            .onChange(of: dock.options) { configure(geometry.size) }
            .onChange(of: dock.tile) { configure(geometry.size) }
            .onChange(of: dock.large) { configure(geometry.size) }
            .onChange(of: dock.magnify) { configure(geometry.size) }
            .onChange(of: dock.appearance) { configure(geometry.size) }
        }
        .frame(height: height)
        .clipped()
        .onChange(of: launch) { sim.tryLaunch() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock preview")
    }

    private func configure(_ size: CGSize) {
        // The preview is a scale model, so it has to fit the card however wide that is.
        let scale = min(dock.tile, 52) / dock.tile
        sim.configure(slots: dock.slots(), size: size, edge: .bottom, tile: dock.tile * scale, large: dock.large * scale,
                      magnify: dock.magnify, look: dock.appearance, scale: scale)
    }
}

/// The Atelier Dock as the stage draws it: the same layout engine, at stage scale, still.
/// It shows what the real dock shows: badges, Atelier tiles, recent apps, minimised windows.
struct OwnDockMiniature: View {
    @ObservedObject var dock: OwnDock
    let edge: OwnDockEdge
    /// The visible part of the screen, in stage points.
    let area: CGSize
    let scale: Double
    @ObservedObject private var live = OwnDock.shared.live
    @StateObject private var sim = OwnDockSim()

    /// The stage camera is flying: draw the cheap stand-ins until it lands.
    var moving = false

    init(dock: OwnDock, edge: OwnDockEdge, area: CGSize, scale: Double, moving: Bool = false) {
        self.moving = moving
        self.dock = dock
        self.edge = edge
        self.area = area
        self.scale = scale
    }

    /// A dock setting under the pointer, shown on this dock only.
    @ObservedObject private var preview = StageDockOverride.shared
    @State private var sweep: Task<Void, Never>?

    private var theme: DockTheme {
        guard let look = preview.look else { return dock.currentTheme }
        return dock.theme(for: look.appearance, design: look.design)
    }

    /// The bar and its clock, with what drives it from outside: the stage's pointer and previews.
    private var bar: some View {
        // Runs a clock only while the pointer is on it or the lens is still closing.
        // Holds still while the stage camera flies: the bar under a resting pointer would
        // otherwise rebuild on every frame of the move.
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: !sim.active || moving)) { context in
            OwnDockBar(scene: sim.scene, theme: theme, vitals: dock.vitals, flat: moving, rowShadow: !moving)
                .onChange(of: context.date) { _, date in sim.tick(date) }
        }
        .onReceive(StageDockPointer.shared.$point) { point in if sweep == nil { sim.pointer = point } }
        .onChange(of: preview.look != nil) { _, on in
            configure()
            on ? startSweep() : stopSweep()
        }
        .onChange(of: preview.look?.appearance) { configure() }
        .onChange(of: preview.look?.design) { configure() }
    }

    var body: some View {
        bar
            .frame(width: area.width, height: area.height)
            .allowsHitTesting(false)
            .onAppear(perform: configure)
            .onChange(of: area) { configure() }
            .onChange(of: edge) { configure() }
            .onChange(of: dock.tile) { configure() }
            .onChange(of: dock.large) { configure() }
            .onChange(of: dock.magnify) { configure() }
            .onChange(of: dock.appearance) { configure() }
            .onChange(of: dock.items) { configure() }
            .onChange(of: dock.customs) { configure() }
            .onChange(of: dock.trashFull) { configure() }
            .onChange(of: dock.replaceSystem) { configure() }
            .onChange(of: dock.showRunning) { configure() }
            .onChange(of: dock.showVitals) { configure() }
            .onChange(of: dock.sections) { configure() }
            .onChange(of: dock.options) { configure() }
            .onChange(of: dock.smart) { configure() }
            .onChange(of: dock.hub.sectionStyle) { configure() }
            .onChange(of: dock.arranging) { configure() }
            .onChange(of: live.version) { configure() }
            .accessibilityHidden(true)
    }

    private func configure() {
        let look = preview.look
        sim.configure(slots: dock.slots(), size: area, edge: look?.edge ?? edge, tile: (look?.tile ?? dock.tile) * scale,
                      large: (look?.large ?? dock.large) * scale, magnify: look?.magnify ?? dock.magnify,
                      look: look?.appearance ?? dock.appearance, scale: scale)
    }

    /// While a dock setting is previewed, a pointer glides along the bar and back, so the lens,
    /// its curve and the icons' motion show without anyone reaching for the stage.
    private func startSweep() {
        stopSweep()
        let bar = sim.scene.bar
        guard bar.width > 0 else { return }
        sweep = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                let x = bar.midX + bar.width * 0.42 * sin(t * 1.6)
                sim.pointer = CGPoint(x: x, y: bar.midY)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopSweep() {
        sweep?.cancel()
        sweep = nil
        sim.pointer = StageDockPointer.shared.point
    }
}

struct DockPillButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 30)
            .background(DS.Ink.fillStrong, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(Pressable())
    }
}

/// One glass finish, drawn as a tiny bar over a tiny desktop.
struct DockStyleChip: View {
    let style: DockStyle
    let theme: DockTheme
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color(red: 0.22, green: 0.3, blue: 0.62), Color(red: 0.62, green: 0.32, blue: 0.5),
                                            Color(red: 0.95, green: 0.62, blue: 0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    HStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(.white.opacity(index == 1 ? 0.9 : 0.62))
                                .frame(width: 9, height: 9)
                        }
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    // A flat stand-in for glass at chip size: six live glass layers inside the
                    // panel's own glass were re-blurred on every frame the panel moved.
                    .background((theme.tint ?? .white).opacity(theme.tint == nil ? 0.22 : 0.35), in: .rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(LinearGradient(colors: theme.rim, startPoint: .topLeading, endPoint: .bottomTrailing),
                                          lineWidth: min(theme.rimWidth, 1))
                    }
                    .overlay {
                        // The glow as a soft second rim: a gradient stroke, never a blur.
                        if let glow = theme.glow {
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .strokeBorder(glow.opacity(0.55), lineWidth: 1.5)
                                .padding(-1.5)
                        }
                    }
                    .padding(.bottom, 5)
                }
                .frame(width: 84, height: 52)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                Text(style.title).font(DS.caption).foregroundStyle(selected ? DS.Ink.primary : DS.Ink.secondary)
            }
            .padding(4)
            .modifier(DockHubPickFrame(selected: selected, hover: hover))
            .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hover = $0 }
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DockAccentSwatch: View {
    let accent: DockAccent
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(accent.color)
                .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay { Circle().strokeBorder(selected ? Color.white.opacity(0.9) : .clear, lineWidth: 1.5) }
                .contentShape(.circle)
        }
        .buttonStyle(Pressable(scale: 0.9))
        .accessibilityLabel(accent.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A compact slider row: its title, the slider in the Dock's light, and its value.
struct DockSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String
    var tint: Color = DockHubHue.tint

    var body: some View {
        // The stage's dock shows the value as it moves, with the lens sweeping along it.
        row.stagePreview(.dock("slider." + title, title, detail: text) { _ in })
    }

    private var row: some View {
        HStack(spacing: DS.Space.m) {
            Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                .frame(width: DockHubLayout.labelWidth, alignment: .leading)
            LuxSlider(value: $value, range: range, label: title, tint: tint)
                .accessibilityElement()
                .accessibilityLabel(title)
                .accessibilityValue(text)
                .accessibilityAdjustableAction { direction in
                    let step = (range.upperBound - range.lowerBound) / 20
                    switch direction {
                    case .increment: value = min(value + step, range.upperBound)
                    case .decrement: value = max(value - step, range.lowerBound)
                    @unknown default: break
                    }
                }
            Text(text).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
                .fixedSize()
                .frame(minWidth: 56, alignment: .trailing)
        }
        .frame(minHeight: 36)
    }
}


/// A pill that is on or off, for the tiles a dock can hold.
struct DockTogglePill: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark" : symbol).font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(on ? Color.black.opacity(0.85) : DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 30)
            .background(on ? AnyShapeStyle(DockHubHue.tint) : AnyShapeStyle(DS.Ink.fillStrong), in: .capsule)
            .contentShape(.capsule)
            .animation(DS.Motion.settle, value: on)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel(title)
        .accessibilityValue(on ? "In the dock" : "Not in the dock")
    }
}

/// A small menu that reads like a pill, for choices too long for segments.
struct DockMenuPill<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button(label) { selection = value }
            }
        } label: {
            HStack(spacing: 5) {
                Text(options.first { $0.0 == selection }?.1 ?? "—").font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 11).frame(height: 28)
            .background(DS.Ink.fillStrong, in: .capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// A heading inside a card, in the section voice.
struct DockSubhead: View {
    let text: String
    var body: some View {
        Text(text).font(DS.Typo.section).foregroundStyle(DS.Ink.primary.opacity(0.92))
    }
}

/// The Atelier Dock's old chapter in Tools. Every setting now lives in the Dock chapter
/// only, so this just points there instead of repeating its cards.
struct OwnDockChapter: View {
    var body: some View {
        RowGroup {
            SettingRow(title: "Atelier Dock", detail: "Its settings are in the Dock chapter, with the macOS Dock's.", density: .compact) {
                DockPillButton(title: "Open Dock", symbol: "arrow.right") { ManagerWindow.shared.show(chapter: Chapter.dock.rawValue) }
            }
            .dockHubRow()
        }
    }
}

// MARK: - Hero: the Atelier Dock

/// Show This Dock and Replace System Dock, with the live dock as its plate: hover it and the
/// lens follows the pointer with the real physics.
struct OwnDockSwitchCard: View {
    @ObservedObject private var dock = OwnDock.shared
    @ObservedObject private var permissions = DockPermissions.shared
    @State private var launches = 0
    private let hue = DockHubHue.tint

    var body: some View {
        let kept = dock.items.count
        HeroCard("Atelier Dock",
                 pitch: "A dock of its own in place of the macOS one: spring magnification, ten designs, live tiles.",
                 isOn: $dock.enabled, hue: hue,
                 readout: "\(kept)", readoutCaption: kept == 1 ? "Tile kept" : "Tiles kept") {
            // Lifted off the plate's floor, so the readout in the corner has its own space.
            OwnDockPreview(dock: dock, live: dock.live, theme: dock.currentTheme, slots: dock.slots(),
                           height: 104, launch: launches)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
                .padding(.trailing, 56)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingRow(title: "Replace System Dock", detail: "The macOS Dock hides while this one is on.", density: .compact) {
                    HStack(spacing: 6) {
                        if dock.replaceSystem {
                            ApplyHint(kind: .restart, sentence: "The macOS Dock restarts once each time this changes. Its own settings are saved first and put back exactly. Badges keep coming through while it is hidden.")
                        }
                        LuxSwitch(isOn: $dock.replaceSystem, label: "Replace System Dock", tint: hue)
                    }
                }
                .help("The macOS Dock stays out of sight while this Dock is on. Turning it off, quitting Atelier, or a crash puts it back.")
                if let error = dock.replaceError {
                    Text(error).font(DS.caption).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Minimise into this Dock takes a picture of the window, so it rides on Screen
                // Recording, which macOS 15 and later ask about again from time to time.
                if dock.replaceSystem, MinimizeRedirect.shared.enabledPreference,
                   let note = DockCompat.minimizeNote(major: MacPlatform.major) {
                    AvailabilityNote(availability: .limited(note))
                }
                // Without these, minimised windows fly to the hidden macOS Dock instead.
                if dock.replaceSystem, MinimizeRedirect.shared.enabledPreference, !permissions.trusted {
                    DockPermissionNote(kind: .accessibility,
                                       sentence: "Minimise into this Dock needs Accessibility. Until then windows go to the hidden macOS Dock.")
                }
                if dock.replaceSystem, MinimizeRedirect.shared.enabledPreference, permissions.trusted, !permissions.screen {
                    DockPermissionNote(kind: .screen,
                                       sentence: "With Screen Recording a picture of the window flies into this Dock. Without it the window itself shrinks into it.")
                }
                HStack(spacing: DS.Space.m) {
                    DockPillButton(title: "Try the Launch", symbol: "play.fill") { launches &+= 1 }
                    Text("Hover the plate to feel the lens.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { dock.ensureVitals() }
    }
}

// MARK: - Hero: magnification

struct OwnDockLensHero: View {
    @ObservedObject private var dock = OwnDock.shared
    private let hue = DockHubHue.tint

    private func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }

    private var lift: Double { min(max(dock.large - dock.tile, 0) * 0.55, dock.tile * 0.7) }

    private var curveNote: String {
        switch dock.appearance.curve {
        case .gentle: "A wide, soft lens. Neighbours grow a little."
        case .classic: "The macOS shape, with a smooth edge."
        case .fisheye: "Most of the growth goes to the icon under the pointer."
        case .wave: "A wide swell that rolls along behind the pointer."
        }
    }

    var body: some View {
        let lifting = dock.appearance.hoverLift
        let look = dock.appearance
        HeroCard("Magnification",
                 pitch: "Spring physics: a fast sweep spreads the lens, a slow one tightens it.",
                 isOn: $dock.magnify, hue: hue,
                 readout: lifting ? "+" + points(lift) : points(dock.large),
                 readoutCaption: lifting ? "Lift" : "Magnify to",
                 preview: .dock("magnify", "Magnification", detail: dock.magnify ? "On → Off" : "Off → On") { $0.magnify.toggle() }) {
            LivePlate { size, since in
                // The lens keeps clear of the readout in the bottom-right corner.
                DockLensPlate(size: CGSize(width: size.width, height: size.height - 40), since: since, curve: look.curve,
                              reach: look.reach * look.curve.reachScale,
                              growth: max(dock.large / max(dock.tile, 1), 1), lift: lifting, hue: hue)
                    .frame(width: size.width, height: size.height - 40)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DockSliderRow(title: lifting ? "Lift" : "Magnify to", value: $dock.large, range: 48...160,
                              text: lifting ? points(lift) : points(dock.large))
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                    Text("Curve").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        .frame(width: DockHubLayout.labelWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Segments(selection: $dock.appearance.curve, options: DockCurve.allCases.map { ($0, $0.title) }) { curve in
                            .dock("curve." + curve.title, "Curve", detail: curve.title) { $0.appearance.curve = curve; $0.magnify = true }
                        }
                        Text(curveNote).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                DockSliderRow(title: "Lens Width", value: $dock.appearance.reach, range: 2...5,
                              text: String(format: "%.1f icons", look.reach * look.curve.reachScale))
                if lifting {
                    Text("Hover Lift is on in Effects: icons rise instead of growing.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
            }
        }
    }
}

/// The lens over a row of your own apps, with its profile drawn above. Still at rest; while
/// the pointer is on the plate a pointer sweeps the row. The same cos² / cos⁴ the dock uses.
struct DockLensPlate: View {
    let size: CGSize
    let since: Date?
    let curve: DockCurve
    /// Lens radius, in icons.
    let reach: Double
    /// Largest size over resting size.
    let growth: Double
    let lift: Bool
    let hue: Color
    @State private var icons: [CGImage] = []

    private static let count = 11

    var body: some View {
        PlateClock(since: since) { time in
            Canvas { context, canvas in draw(&context, canvas, time: time) }
        }
        .task { icons = Self.loadIcons() }
        .accessibilityHidden(true)
    }

    @MainActor private static func loadIcons() -> [CGImage] {
        let paths = OwnDock.shared.slots().filter { $0.kind == .app && !$0.path.isEmpty }.prefix(count).map(\.path)
        let list = paths.isEmpty ? ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app",
                                    "/System/Applications/Mail.app", "/System/Applications/Music.app"] : Array(paths)
        return list.compactMap { BitmapIcons.cgImage(DockIcons.image($0), pixels: 128) }
    }

    /// Where the lens sits, in icons: off-centre at rest, sweeping while hovered.
    private func pointer(_ time: Double) -> Double {
        let mid = Double(Self.count - 1) / 2, rest = mid + 1.6, amp = mid * 0.9
        let phase = asin(min(max((rest - mid) / amp, -1), 1))
        return mid + amp * sin(time * 1.25 + phase)
    }

    private func falloff(_ distance: Double) -> Double {
        let d = abs(distance)
        guard reach > 0, d < reach else { return 0 }
        return pow(cos(.pi / 2 * d / reach), Double(curve.power))
    }

    private func draw(_ context: inout GraphicsContext, _ canvas: CGSize, time: Double) {
        let n = Self.count
        let p = pointer(time)
        let base = min(canvas.height * 0.17, 24)
        let gap = base * 0.24
        let grow = min(growth, 2.4)
        var sizes: [Double] = []
        var rises: [Double] = []
        for index in 0..<n {
            let f = falloff(Double(index) - p)
            sizes.append(lift ? base : base * (1 + (grow - 1) * f))
            rises.append(lift ? base * 0.7 * f : 0)
        }
        let total = sizes.reduce(0, +) + gap * Double(n - 1)
        let originX = canvas.width * 0.44 - total / 2
        let baseline = canvas.height - 20
        let pad = base * 0.22

        // The bar: a flat glass stand-in, as wide as the row it holds.
        let bar = CGRect(x: originX - pad, y: baseline - base - pad, width: total + pad * 2, height: base + pad * 2)
        let barShape = Path(roundedRect: bar, cornerRadius: (base + pad * 2) * 0.32, style: .continuous)
        context.fill(barShape, with: .color(.white.opacity(0.08)))
        context.stroke(barShape, with: .color(.white.opacity(0.16)), lineWidth: 0.5)

        // The lens's profile, floating over the row: how much each place would grow.
        var profile = Path()
        let top = 40.0, depth = 26.0
        let steps = 64
        for step in 0...steps {
            let x = bar.minX + bar.width * Double(step) / Double(steps)
            // Back from points to icon units along the row.
            let unit = (x - originX) / (base + gap) - 0.5
            let y = top + depth * (1 - falloff(unit - p))
            if step == 0 { profile.move(to: CGPoint(x: x, y: y)) } else { profile.addLine(to: CGPoint(x: x, y: y)) }
        }
        var under = profile
        under.addLine(to: CGPoint(x: bar.maxX, y: top + depth))
        under.addLine(to: CGPoint(x: bar.minX, y: top + depth))
        under.closeSubpath()
        context.fill(under, with: .linearGradient(Gradient(colors: [hue.opacity(0.28), hue.opacity(0)]),
                                                  startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: top + depth)))
        context.stroke(profile, with: .color(hue.opacity(0.85)), lineWidth: 1.2)

        // The icons, bottom-aligned on the bar, growing (or rising) under the lens.
        var x = originX
        var pointerX = originX
        for index in 0..<n {
            let side = sizes[index]
            let rect = CGRect(x: x, y: baseline - side - rises[index], width: side, height: side)
            if icons.isEmpty {
                context.fill(Path(roundedRect: rect, cornerRadius: side * 0.24, style: .continuous),
                             with: .linearGradient(Gradient(colors: [.white.opacity(0.42), .white.opacity(0.18)]),
                                                   startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                   endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            } else {
                context.draw(Image(decorative: icons[index % icons.count], scale: 1), in: rect)
            }
            if Double(index) <= p { pointerX = x + side * min(p - Double(index), 1) }
            x += side + gap
        }
        // Where the pointer is: a small light under the bar.
        let dot = CGRect(x: pointerX - 2.5, y: bar.maxY + 5, width: 5, height: 5)
        context.fill(Path(ellipseIn: dot), with: .color(hue))
    }
}

// MARK: - Size and place

struct OwnDockPlaceCard: View {
    @ObservedObject private var dock = OwnDock.shared
    @State private var screens: [String] = []
    private let hue = DockHubHue.tint

    private func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }
    private func seconds(_ value: Double) -> String { value < 0.01 ? "At once" : String(format: "%.2f s", value) }

    var body: some View {
        RowGroup {
            DockSliderRow(title: "Icons", value: $dock.tile, range: 32...96, text: points(dock.tile))
            // Four positions do not fit beside a title in the panel: the title goes above.
            DockHubWideRow("Position") {
                Segments(selection: $dock.edge, options: OwnDockEdge.allCases.map { ($0, $0.title) }) { edge in
                    .dock("edge." + edge.title, "Position", detail: edge.title) { $0.edge = edge }
                }
            }
            if screens.count > 1 { displays }
            DockSliderRow(title: "Distance from Edge", value: $dock.appearance.gap, range: 0...32,
                          text: points(dock.appearance.gap))
            SettingRow(title: "Auto-hide", detail: "Slides away until the pointer reaches that edge.", density: .compact) {
                LuxSwitch(isOn: $dock.autoHide, label: "Auto-hide", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("dock.autohide", "Auto-hide", isOn: dock.autoHide, region: StageRegion.ownDock(OwnDock.shared.edge), Demos.autoHide))
            if dock.autoHide {
                DockSliderRow(title: "Show After", value: $dock.hub.revealDelay, range: 0...1.5, text: seconds(dock.hub.revealDelay))
                DockSliderRow(title: "Hide After", value: $dock.hub.hideDelay, range: 0...2, text: seconds(dock.hub.hideDelay))
                DockHubWideRow("Slide Speed") {
                    Segments(selection: $dock.hub.hideSpeed, options: DockHideSpeed.allCases.map { ($0, $0.title) })
                }
            }
            SettingRow(title: "On Every Desktop", detail: "Stays put when you switch Spaces.", density: .compact) {
                LuxSwitch(isOn: $dock.hub.allSpaces, label: "On Every Desktop", tint: hue)
            }
            .dockHubRow()
            .help("Off, it stays on the desktop it was shown on.")
            .stagePreview(.demo("dock.spaces", "On Every Desktop", isOn: dock.hub.allSpaces, region: nil, Demos.everyDesktop))
            SettingRow(title: "Over Full-Screen Apps", detail: "Comes up from the edge over a full-screen app, like the macOS Dock. Off, it stays away.", density: .compact) {
                LuxSwitch(isOn: $dock.hub.fullScreen, label: "Over Full-Screen Apps", tint: hue)
            }
            .dockHubRow()
            .help("In a full-screen app the dock hides either way; with this on, moving to the edge brings it up.")
        }
        .onAppear { screens = dock.screenNames }
        Card { DockReserveSettings() }
    }

    @ViewBuilder private var displays: some View {
        DockHubWideRow("Display", detail: dock.display == .pointer ? "Moves to a display when the pointer presses its edge."
                                                                   : "Each display can keep its own edge.") {
            Segments(selection: $dock.display, options: OwnDockDisplay.allCases.map { ($0, $0.title) })
        }
        if dock.display == .chosen {
            // Display names are long ("Built-in Retina Display"): a menu, not segments.
            SettingRow(title: "Show On", density: .compact) {
                DockMenuPill(selection: Binding(get: { dock.screenName ?? screens[0] }, set: { dock.screenName = $0 }),
                             options: screens.map { ($0, $0) })
            }
            .dockHubRow()
        }
        ForEach(screens, id: \.self) { name in
            SettingRow(title: name, detail: "Its own edge", symbol: "display", density: .compact) {
                DockMenuPill(selection: Binding(
                    get: { dock.edgeOverrides[name].map(\.rawValue) ?? "" },
                    set: { dock.edgeOverrides[name] = OwnDockEdge(rawValue: $0) }),
                             options: [("", "Same as above")] + OwnDockEdge.allCases.map { ($0.rawValue, $0.title) })
            }
            .dockHubRow()
        }
    }
}

// MARK: - Behaviour

struct OwnDockBehaviourCard: View {
    @ObservedObject private var dock = OwnDock.shared
    @ObservedObject private var permissions = DockPermissions.shared
    private let hue = DockHubHue.tint

    var body: some View {
        RowGroup {
            SettingRow(title: "Focus Mode", detail: "Apps other than the one in front fade back.", density: .compact) {
                LuxSwitch(isOn: $dock.hub.focusMode, label: "Focus Mode", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("dock.focus", "Focus Mode", isOn: dock.hub.focusMode, region: StageRegion.ownDock(OwnDock.shared.edge), Demos.focusMode))
            if dock.hub.focusMode {
                DockSliderRow(title: "Fade", value: $dock.hub.focusDim, range: 0.15...0.85,
                              text: "\(Int((dock.hub.focusDim * 100).rounded()))%")
            }
            SettingRow(title: "Badges", detail: "Apps' red counts, even while the macOS Dock is hidden.", density: .compact) {
                LuxSwitch(isOn: $dock.appearance.badges, label: "Badges", tint: hue)
            }
            .dockHubRow()
            .help("The red counts apps put on their icons, read from the macOS Dock, even while it is hidden.")
            .stagePreview(.dock("badges", "Badges", detail: dock.appearance.badges ? "On → Off" : "Off → On") { $0.appearance.badges.toggle() })
            if SystemDockAX.readsBounces {
                SettingRow(title: "Attention Bounce", detail: "Hops when an app asks for you, as the macOS Dock does.", density: .compact) {
                    LuxSwitch(isOn: $dock.appearance.attention, label: "Attention Bounce", tint: hue)
                }
                .dockHubRow()
                .help("Seen by watching the macOS Dock's own tile, so a single short bounce can be missed.")
                .stagePreview(.demo("dock.attention", "Attention Bounce", isOn: dock.appearance.attention, region: StageRegion.ownDock(OwnDock.shared.edge), Demos.attentionBounce))
            } else {
                // macOS 27 gives no sign that an app asks for attention (OwnDockBounce in DockCore).
                SettingRow(title: "Attention Bounce", detail: "Not available on macOS 27. Badges still show.", density: .compact) {
                    Text("Not available").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
                .dockHubRow()
                .help("macOS 27 no longer tells other apps when one asks for attention, so the Atelier Dock can't hop for it.")
            }
            if !permissions.trusted, dock.appearance.badges || (dock.appearance.attention && SystemDockAX.readsBounces) {
                DockNeedsAccess().dockHubRow()
            }
            SettingRow(title: "Click to Hide", detail: "Clicking the app in front hides it.", density: .compact) {
                LuxSwitch(isOn: $dock.appearance.clickToHide, label: "Click to Hide", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("dock.clickhide", "Click to Hide", isOn: dock.appearance.clickToHide, region: nil, Demos.clickToHide))
            SettingRow(title: "Scroll for Windows", detail: "Scroll on an icon to bring its windows forward.", density: .compact) {
                LuxSwitch(isOn: $dock.appearance.scrollWindows, label: "Scroll for Windows", tint: hue)
            }
            .dockHubRow()
            .help("Scrolling on an app's icon brings its windows forward one by one.")
            .stagePreview(.demo("dock.scroll", "Scroll for Windows", isOn: dock.appearance.scrollWindows, region: nil, Demos.scrollWindows))
        }
        .watchingDockAccess()
    }
}

/// Accessibility and Screen Recording for Atelier, as the Dock chapter shows them. While either
/// is missing and a card that needs it is on screen, both are read again every two seconds, so a
/// grant in System Settings shows (and the feature works) without a relaunch.
@MainActor
final class DockAccessWatch: ObservableObject {
    static let shared = DockAccessWatch()
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var recording = CGPreflightScreenCaptureAccess()
    private var timer: Timer?
    private var users = 0

    private init() {}

    func hold() {
        users += 1
        check()
        schedule()
    }

    func release() {
        users = max(users - 1, 0)
        if users == 0 { stopTimer() }
    }

    func check() {
        let nowTrusted = AXIsProcessTrusted(), nowRecording = CGPreflightScreenCaptureAccess()
        if nowTrusted != trusted { trusted = nowTrusted }
        if nowRecording != recording { recording = nowRecording }
        if trusted, recording { stopTimer() }
    }

    /// Shows the system's prompt, then System Settings at Accessibility.
    func grantAccessibility() {
        // PermissionCenter: the prompt once, the pane, and the stale-entry help if it never lands.
        PermissionCenter.shared.request(.accessibility)
        schedule()
    }

    func grantRecording() {
        PermissionCenter.shared.request(.screenRecording)
        check()
        schedule()
    }

    private func schedule() {
        guard timer == nil, users > 0, !(trusted && recording) else { return }
        let tick = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { DockAccessWatch.shared.check() }
        }
        tick.tolerance = 0.4
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Keeps `DockAccessWatch` reading while this view is on screen.
private struct DockAccessWatching: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { DockAccessWatch.shared.hold() }
            .onDisappear { DockAccessWatch.shared.release() }
    }
}

extension View {
    func watchingDockAccess() -> some View { modifier(DockAccessWatching()) }
}

/// "Needs Accessibility" with a way to grant it. Gone the moment Atelier is trusted.
struct DockNeedsAccess: View {
    @ObservedObject private var access = DockAccessWatch.shared

    var body: some View {
        DockPermissionNote(kind: .accessibility, sentence: "Needs Accessibility for Atelier, in System Settings, Privacy & Security.")
    }
}

// MARK: - Profiles

struct OwnDockProfilesCard: View {
    @ObservedObject private var dock = OwnDock.shared
    @ObservedObject private var profiles = OwnDockProfiles.shared
    @State private var profileName = ""
    private let hue = DockHubHue.tint

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: 8) {
                    TextField("Name, like Work or Evening", text: $profileName)
                        .textFieldStyle(.plain)
                        .font(DS.body)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(DS.Ink.fill, in: .capsule)
                        .onSubmit(saveProfile)
                    DockPillButton(title: "Save This Dock", symbol: "square.and.arrow.down", action: saveProfile)
                }
                if profiles.profiles.isEmpty {
                    Text("No profiles yet. Save this dock to make the first.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(profiles.profiles) { profile in
                            if profile.id != profiles.profiles.first?.id {
                                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                            }
                            profileRow(profile).padding(.vertical, DS.Space.s)
                        }
                    }
                }
            }
        }
        if !profiles.profiles.isEmpty {
            RowGroup {
                SettingRow(title: "Switch by Desktop",
                           detail: profiles.space.map { "Now on \($0.label). Tie a profile to it with This Desktop." }
                               ?? "Tie a profile to a desktop with This Desktop.",
                           density: .compact) {
                    LuxSwitch(isOn: $profiles.rules.bySpace, label: "Switch by Desktop", tint: hue)
                }
                .dockHubRow()
                SettingRow(title: "Switch by Time of Day", detail: "Changes as each period starts; a hand pick stays until then.",
                           density: .compact) {
                    LuxSwitch(isOn: $profiles.rules.byTime, label: "Switch by Time of Day", tint: hue)
                }
                .dockHubRow()
                if profiles.rules.byTime {
                    SettingRow(title: "Day", symbol: "sun.max", density: .compact) {
                        HStack(spacing: 6) {
                            Text("from").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            DockMenuPill(selection: $profiles.rules.dayStarts, options: hours)
                            DockMenuPill(selection: $profiles.rules.day, options: profileOptions)
                        }
                    }
                    .dockHubRow()
                    SettingRow(title: "Night", symbol: "moon", density: .compact) {
                        HStack(spacing: 6) {
                            Text("from").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            DockMenuPill(selection: $profiles.rules.nightStarts, options: hours)
                            DockMenuPill(selection: $profiles.rules.night, options: profileOptions)
                        }
                    }
                    .dockHubRow()
                }
            }
        }
    }

    private var profileOptions: [(UUID?, String)] {
        [(nil, "None")] + profiles.profiles.map { (Optional($0.id), $0.name) }
    }

    private var hours: [(Int, String)] {
        (0..<24).map { ($0, String(format: "%02d:00", $0)) }
    }

    private func profileRow(_ profile: OwnDockProfile) -> some View {
        let spaces = profiles.spaces(for: profile.id)
        let here = profiles.space.map { profiles.rules.spaces[$0.key] == profile.id } ?? false
        let look = profile.setup.appearance
        let active = profiles.active == profile.id
        return HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(active ? hue : DS.Ink.glyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                Text(([profile.setup.items.count == 1 ? "1 item" : "\(profile.setup.items.count) items",
                       (profile.setup.design?.design ?? .liquidGlass).title + " " + look.accent.title] + spaces).joined(separator: " · "))
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Menu {
                Section("Glass Finish") {
                    ForEach(DockStyle.allCases) { style in
                        Button { profiles.setLook(profile.id, style: style) } label: {
                            if look.style == style { Label(style.title, systemImage: "checkmark") } else { Text(style.title) }
                        }
                    }
                }
                Section("Design") {
                    ForEach(DockDesign.allCases) { design in
                        let current = profile.setup.design?.design ?? .liquidGlass
                        Button { profiles.setDesign(profile.id, design) } label: {
                            if current == design { Label(design.title, systemImage: "checkmark") } else { Text(design.title) }
                        }
                    }
                }
                Section("Colour") {
                    ForEach(DockAccent.allCases) { accent in
                        Button { profiles.setLook(profile.id, accent: accent) } label: {
                            if look.accent == accent { Label(accent.title, systemImage: "checkmark") } else { Text(accent.title) }
                        }
                    }
                }
            } label: {
                Circle().fill(look.accent.color).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                    .frame(width: 30, height: 30).background(DS.Ink.fillStrong, in: .circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Theme for \(profile.name)")
            DockPillButton(title: "Use") { profiles.apply(profile.id) }
            Menu {
                Button("Save Current Dock Into It") { profiles.update(profile.id) }
                if SpaceProbe.available {
                    Button(here ? "Untie from This Desktop" : "Use on This Desktop") {
                        profiles.assignCurrentSpace(here ? nil : profile.id)
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { profiles.delete(profile.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.secondary)
                    .frame(width: 30, height: 30).background(DS.Ink.fillStrong, in: .circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(profile.name)")
        }
    }

    private func saveProfile() {
        profiles.saveCurrent(named: profileName)
        profileName = ""
    }
}

/// Wraps its children like text.
struct FlowRow: Layout {
    var spacing = 8.0

    private func rows(_ subviews: Subviews, width: Double) -> [[(LayoutSubview, CGSize)]] {
        var rows: [[(LayoutSubview, CGSize)]] = [[]]
        var used = 0.0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if used + size.width > width, !(rows.last?.isEmpty ?? true) {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append((subview, size))
            used += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let rows = rows(subviews, width: width)
        let height = rows.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + spacing * Double(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for (subview, size) in row {
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += (row.map(\.1.height).max() ?? 0) + spacing
        }
    }
}


/// Where the pointer is over the stage's Atelier Dock, in the dock's own coordinates. Only the
/// stage's dock watches it, so moving over the stage never redraws the rest of the stage.
@MainActor
final class StageDockPointer: ObservableObject {
    static let shared = StageDockPointer()
    @Published var point: CGPoint?
}
