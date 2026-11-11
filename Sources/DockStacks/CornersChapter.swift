import AppKit
import DockCore
import SwiftUI

/// The Corners chapter: Atelier's own hot corners and edges first, as the hero and its editor;
/// macOS hot corners below.
struct CornersChapter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var corners = HotCorners.shared
    @ObservedObject private var engine = WindowEngine.shared
    @State private var selected: HotSpot = .topLeft
    private let hue = DockHubHue.tint

    var body: some View {
        masterCard
        SectionHeader("Spots", symbol: "rectangle.dashed",
                      detail: "Rest the pointer in a corner, or at the middle of an edge, and something happens. Click a spot to choose what.",
                      hue: hue)
        Group {
            CornersDiagram(selected: $selected)
            CornerEditor(spot: selected)
                .id(selected)
        }
        .disabled(!corners.enabled)
        .opacity(corners.enabled ? 1 : 0.5)
        if needsAccess && !engine.trusted { accessCard }
        SectionHeader("Behaviour", symbol: "slider.horizontal.3", hue: hue)
        behaviourCard
        SectionHeader("macOS Hot Corners", symbol: "rectangle.inset.topleft.filled",
                      detail: "The system's own four corners. They work without Atelier running.", hue: DS.Ink.secondary)
        AppleCornersCard(model: model)
        PersonalRows(area: .corners)
        Text("Notification Centre and Do Not Disturb have no public switch for apps. Use a macOS hot corner for Notification Centre, or Run Shortcut with a Focus shortcut.")
            .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.xs)
    }

    private var needsAccess: Bool {
        corners.bindings.values.contains { [.lockScreen, .layout, .shuffle].contains($0.action) }
    }

    private var masterCard: some View {
        let set = corners.bindings.values.filter(\.isActive).count
        return HeroCard("Atelier Hot Corners",
                        pitch: "Eight spots, not four: corners and edge middles, each with its own keys and wait.",
                        isOn: $corners.enabled, hue: hue,
                        readout: "\(set)", readoutCaption: "of 8 spots set",
                        preview: .demo("corners.on", "Atelier Hot Corners", isOn: corners.enabled, region: nil, Demos.corner("Mission Control"))) {
            LivePlate { size, since in CornersPlate(size: size, since: since, hue: hue) }
        } controls: {
            Text(corners.hasActiveSpots ? "The pointer is watched only while this is on."
                                        : "Nothing is watched until a spot has an action.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
        }
    }

    private var accessCard: some View {
        RowGroup {
            SettingRow(title: "One permission", detail: "Lock Screen and window actions need Accessibility access.", density: .compact) {
                Chip(engine.awaitingGrant ? "Ask Again" : "Grant Access") { engine.requestAccess() }
            }
            .dockHubRow()
        }
    }

    private var behaviourCard: some View {
        RowGroup {
            HStack(spacing: DS.Space.m) {
                Text("Cooldown").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    .frame(width: DockHubLayout.labelWidth, alignment: .leading)
                LuxSlider(value: $corners.cooldown, range: 0.3...3, label: "Cooldown", tint: hue)
                Text(String(format: "%.1f s", corners.cooldown)).font(DS.Typo.value)
                    .foregroundStyle(DS.Ink.secondary).frame(minWidth: 44, alignment: .trailing)
            }
            .frame(minHeight: 36)
            .help("How long a spot rests after it fires.")
            SettingRow(title: "Pause in Full Screen", detail: "Games, films and slides keep their edges.", density: .compact) {
                LuxSwitch(isOn: $corners.pauseFullScreen, label: "Pause in Full Screen", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("corners.fs", "Pause in Full Screen", isOn: corners.pauseFullScreen, region: nil, Demos.pauseFullScreen))
            SettingRow(title: "Pause While Dragging", detail: "Dragging a file or window into a corner does nothing.", density: .compact) {
                LuxSwitch(isOn: $corners.pauseDragging, label: "Pause While Dragging", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("corners.drag", "Pause While Dragging", isOn: corners.pauseDragging, region: nil, Demos.pauseDragging))
            SettingRow(title: "Ripple", detail: "A ring of light blooms from the spot that fired.", density: .compact) {
                LuxSwitch(isOn: $corners.flourish, label: "Ripple", tint: hue)
            }
            .dockHubRow()
            .stagePreview(.demo("corners.ripple", "Ripple", isOn: corners.flourish, region: nil, Demos.corner("Ripple", ripple: true)))
        }
    }
}

// MARK: - Hero plate

/// A small screen with its lit spots. Still at rest; while hovered a pointer visits each set
/// spot in turn and a ring blooms where it arrives.
private struct CornersPlate: View {
    let size: CGSize
    let since: Date?
    let hue: Color
    @ObservedObject private var corners = HotCorners.shared

    var body: some View {
        let spots = HotSpot.allCases.filter { corners.binding($0).isActive }
        PlateClock(since: since) { time in
            Canvas { context, canvas in draw(&context, canvas, time: time, spots: spots) }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, _ canvas: CGSize, time: Double, spots: [HotSpot]) {
        let height = canvas.height - 26
        let width = height * 1.6
        let screen = CGRect(x: canvas.width * 0.42 - width / 2, y: 13, width: width, height: height)
        let shape = Path(roundedRect: screen, cornerRadius: 8, style: .continuous)
        context.fill(shape, with: .linearGradient(Gradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.3),
                                                                    Color(red: 0.32, green: 0.2, blue: 0.36)]),
                                                  startPoint: CGPoint(x: screen.minX, y: screen.minY),
                                                  endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
        context.fill(Path(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 6)), with: .color(.black.opacity(0.3)))
        context.fill(Path(roundedRect: CGRect(x: screen.midX - screen.width * 0.2, y: screen.maxY - 12, width: screen.width * 0.4, height: 7),
                          cornerRadius: 3.5), with: .color(.white.opacity(0.18)))
        context.stroke(shape, with: .color(.white.opacity(0.16)), lineWidth: 0.5)

        let inset = 12.0
        func point(_ spot: HotSpot) -> CGPoint {
            CGPoint(x: screen.minX + inset + spot.unit.x * (screen.width - inset * 2),
                    y: screen.minY + inset + spot.unit.y * (screen.height - inset * 2))
        }
        func edge(_ spot: HotSpot) -> CGPoint {
            CGPoint(x: screen.minX + spot.unit.x * screen.width, y: screen.minY + spot.unit.y * screen.height)
        }
        let lit = corners.enabled
        for spot in HotSpot.allCases {
            let active = spots.contains(spot)
            let center = point(spot)
            if active {
                let radius = screen.width * (spot.isCorner ? 0.2 : 0.14)
                let glow = edge(spot)
                context.fill(Path(ellipseIn: CGRect(x: glow.x - radius, y: glow.y - radius, width: radius * 2, height: radius * 2)),
                             with: .radialGradient(Gradient(colors: [hue.opacity(lit ? 0.55 : 0.3), .clear]),
                                                   center: glow, startRadius: 0, endRadius: radius))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)), with: .color(hue))
                let symbol = corners.binding(spot).action.symbol
                context.draw(Text(Image(systemName: symbol)).font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.8)),
                             at: center)
            } else {
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                               with: .color(.white.opacity(0.28)), lineWidth: 0.75)
            }
        }

        // The pointer's tour, only while hovered.
        guard time > 0 else { return }
        let stops = spots.isEmpty ? [HotSpot.topLeft, .topRight, .bottomRight, .bottomLeft] : spots
        let leg = 1.5
        let index = Int(time / leg)
        let local = time - Double(index) * leg
        let from = index == 0 ? CGPoint(x: screen.midX, y: screen.midY) : edge(stops[(index - 1) % stops.count])
        let to = edge(stops[index % stops.count])
        let travel = min(local / 0.8, 1)
        let eased = 1 - pow(1 - travel, 3)
        let at = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
        if local > 0.8 {
            let bloom = min((local - 0.8) / 0.7, 1)
            let radius = 6 + bloom * screen.width * 0.16
            context.stroke(Path(ellipseIn: CGRect(x: to.x - radius, y: to.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(hue.opacity(0.8 * (1 - bloom))), lineWidth: 1.5)
        }
        var arrow = Path()
        arrow.move(to: at)
        arrow.addLine(to: CGPoint(x: at.x, y: at.y + 11))
        arrow.addLine(to: CGPoint(x: at.x + 3, y: at.y + 8))
        arrow.addLine(to: CGPoint(x: at.x + 7.5, y: at.y + 8))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(.white))
        context.stroke(arrow, with: .color(.black.opacity(0.6)), lineWidth: 0.75)
    }
}

// MARK: - Diagram

/// A screen you can click. Lit spots have an action; the selected one wears a ring. Flat
/// discs, not glass: the diagram scrolls with the panel.
struct CornersDiagram: View {
    @Binding var selected: HotSpot
    @ObservedObject private var corners = HotCorners.shared
    @State private var hovered: HotSpot?
    private let hue = DockHubHue.tint

    var body: some View {
        GeometryReader { geometry in
            let screen = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 7, dy: 7)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.04))
                MeshCanvas(hue: .aurora, hour: 21)
                    .overlay(Color.black.opacity(0.18))
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: screen.minX, y: screen.minY)
                Rectangle().fill(.black.opacity(0.28)).frame(width: screen.width, height: 9)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous))
                    .offset(x: screen.minX, y: screen.minY)
                Capsule().fill(.white.opacity(0.16)).frame(width: screen.width * 0.42, height: 12)
                    .offset(x: screen.midX - screen.width * 0.21, y: screen.maxY - 18)
                ForEach(HotSpot.allCases) { spot in
                    if corners.binding(spot).isActive && corners.enabled {
                        glow(spot, in: screen)
                    }
                }
                ZStack(alignment: .topLeading) {
                    ForEach(HotSpot.allCases) { spot in
                        button(spot, in: screen)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .modifier(LightWave(origin: UnitPoint(x: corners.fired?.spot.unit.x ?? 0.5, y: corners.fired?.spot.unit.y ?? 0.5),
                                trigger: corners.fired?.count ?? 0))
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(.rect(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
        .animation(DS.Motion.arrive, value: corners.bindings)
        .animation(DS.Motion.arrive, value: corners.enabled)
    }

    private func point(_ spot: HotSpot, in screen: CGRect, inset: Double) -> CGPoint {
        let unit = spot.unit
        return CGPoint(x: screen.minX + inset + unit.x * (screen.width - inset * 2),
                       y: screen.minY + inset + unit.y * (screen.height - inset * 2))
    }

    private func glow(_ spot: HotSpot, in screen: CGRect) -> some View {
        let center = point(spot, in: screen, inset: 0)
        let radius = screen.width * (spot.isCorner ? 0.2 : 0.14)
        return RadialGradient(colors: [hue.opacity(0.6), .clear], center: .center, startRadius: 0, endRadius: radius)
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func button(_ spot: HotSpot, in screen: CGRect) -> some View {
        let binding = corners.binding(spot)
        let active = binding.isActive
        let isSelected = spot == selected
        let hover = hovered == spot
        return Button { withAnimation(DS.Motion.settle) { selected = spot } } label: {
            ZStack {
                Circle().fill(active ? AnyShapeStyle(hue) : AnyShapeStyle(Color.black.opacity(hover ? 0.6 : 0.45)))
                Circle().strokeBorder(.white.opacity(active ? 0.3 : (hover ? 0.4 : 0.22)), lineWidth: 0.5)
                Image(systemName: active ? binding.action.symbol : "plus")
                    .font(.system(size: active ? 13 : 11, weight: .semibold))
                    .foregroundStyle(active ? Color.black.opacity(0.8) : .white.opacity(hover ? 0.95 : 0.75))
                if !binding.modifiers.isEmpty && active {
                    Text(binding.modifiers.symbols).font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(height: 13)
                        .background(.black.opacity(0.65), in: .capsule)
                        .offset(y: 20)
                }
            }
            .frame(width: 34, height: 34)
            .overlay { Circle().strokeBorder(.white, lineWidth: isSelected ? 2 : 0).padding(-3) }
            .contentShape(Circle().inset(by: -6))
            .animation(DS.Motion.hover, value: hover)
        }
        .buttonStyle(Pressable(scale: 0.9))
        .onHover { inside in hovered = inside ? spot : (hovered == spot ? nil : hovered) }
        .position(point(spot, in: screen, inset: 24))
        .accessibilityLabel(spot.title)
        .accessibilityValue(active ? binding.action.title : "Nothing")
        .help(active ? "\(spot.title): \(binding.action.title)" : spot.title)
    }
}

// MARK: - Editor

struct CornerEditor: View {
    let spot: HotSpot
    @ObservedObject private var corners = HotCorners.shared
    @State private var dwell = 0.15
    @State private var target = ""
    private let hue = DockHubHue.tint

    private var binding: CornerBinding { corners.binding(spot) }

    private func update(_ change: (inout CornerBinding) -> Void) {
        var next = binding
        change(&next)
        corners.set(next, for: spot)
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spot.title).font(DS.Typo.hero).tracking(-0.3)
                        Text(binding.isActive ? binding.action.title : "Choose an action").font(DS.caption)
                            .foregroundStyle(binding.isActive ? hue : DS.Ink.secondary)
                    }
                    Spacer()
                    if binding.isActive {
                        Chip("Try It") { corners.fire(spot, binding: binding, screen: NSScreen.main?.frame) }
                            .transition(.opacity)
                    }
                }
                ForEach(CornerAction.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.rawValue).font(DS.Typo.section).foregroundStyle(DS.Ink.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], spacing: 6) {
                            ForEach(CornerAction.allCases.filter { $0.group == group }) { action in
                                ActionTile(action: action, selected: binding.action == action) {
                                    withAnimation(DS.Motion.settle) { update { $0.action = action } }
                                }
                            }
                        }
                    }
                }
                parameters
                // Keys and wait belong to an action; with Nothing chosen there is nothing to hold them.
                Group {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(DS.Ink.hairline).frame(height: 0.5).padding(.bottom, DS.Space.s)
                    HStack(spacing: 8) {
                        Text("Hold").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).frame(width: 52, alignment: .leading)
                        ForEach([(HotModifiers.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command")],
                                id: \.1) { modifier, symbol, name in
                            let on = binding.modifiers.contains(modifier)
                            Button { update { $0.modifiers.formSymmetricDifference(modifier) } } label: {
                                Text(symbol).font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(on ? Color.black.opacity(0.85) : DS.Ink.secondary)
                                    .frame(width: 36, height: 30)
                                    .background(on ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fillStrong),
                                                in: .rect(cornerRadius: 9, style: .continuous))
                                    .contentShape(Rectangle())
                                    .animation(DS.Motion.settle, value: on)
                            }
                            .buttonStyle(Pressable(scale: 0.94))
                            .accessibilityLabel("Require \(name)")
                            .accessibilityValue(on ? "On" : "Off")
                        }
                        Spacer()
                        Text(binding.modifiers.isEmpty ? "No keys needed" : "Only with \(binding.modifiers.symbols)")
                            .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    }
                    .frame(minHeight: 36)
                    HStack(spacing: 8) {
                        Text("Wait").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).frame(width: 52, alignment: .leading)
                        LuxSlider(value: $dwell, range: 0...1.5, label: "Wait", tint: hue) { update { $0.dwell = (dwell * 20).rounded() / 20 } }
                        Text(dwell < 0.025 ? "Instant" : String(format: "%.2f s", dwell)).font(DS.Typo.value)
                            .foregroundStyle(DS.Ink.secondary).frame(minWidth: 52, alignment: .trailing)
                    }
                    .frame(minHeight: 36)
                }
                }
                .disabled(!binding.isActive)
                .opacity(binding.isActive ? 1 : 0.4)
                .help(binding.isActive ? "" : "Choose an action first.")
                if let note = binding.action.note {
                    Text(note).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = corners.lastError {
                    Text(error).font(DS.caption).foregroundStyle(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { dwell = binding.dwell; target = binding.target }
    }


    @ViewBuilder private var parameters: some View {
        switch binding.action {
        case .open:
            HStack(spacing: 8) {
                field("An app, file, folder or link", text: $target)
                Chip("Choose…") { choose() }
            }
        case .shortcut:
            HStack(spacing: 8) {
                field("Shortcut name, exactly as in Shortcuts", text: $target)
                Chip("Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            }
        case .layout:
            HStack(spacing: 8) {
                Text("Layout").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                Picker("Layout", selection: Binding(get: { binding.layout }, set: { value in update { $0.layout = value } })) {
                    ForEach(WindowGeometry.Layout.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 180)
            }
        default:
            EmptyView()
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain).font(DS.body)
            .padding(.horizontal, 12).frame(height: 32)
            .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            .onSubmit { update { $0.target = target } }
            .onChange(of: target) { _, value in update { $0.target = value } }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        target = url.path
        update { $0.target = url.path }
    }
}

private struct ActionTile: View {
    let action: CornerAction
    let selected: Bool
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 7) {
                Image(systemName: action.symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                    .foregroundStyle(selected ? DockHubHue.tint : DS.Ink.secondary)
                Text(action.title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? DS.Ink.primary : DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(minHeight: 32)
            .background(DS.Ink.fill.opacity(selected ? 0 : 1), in: .rect(cornerRadius: 9, style: .continuous))
            .modifier(DockHubPickFrame(selected: selected, hover: hover, radius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
        .onHover { hover = $0 }
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - macOS hot corners

/// Apple's own corners, kept as they were: they write com.apple.dock wvous-* through the model.
struct AppleCornersCard: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var corners = HotCorners.shared

    static let actions: [(Int, String)] = [
        (1, "Nothing"), (2, "Mission Control"), (3, "App Windows"), (4, "Desktop"), (5, "Screen Saver"),
        (10, "Sleep Display"), (12, "Notification Centre"), (13, "Lock Screen"), (14, "Quick Note"),
    ]

    var body: some View {
        RowGroup {
            ForEach([HotSpot.topLeft, .topRight, .bottomLeft, .bottomRight]) { spot in
                row(spot)
            }
        }
    }

    private func row(_ spot: HotSpot) -> some View {
        let key = spot.appleKey ?? "tl"
        let current = Int(model.dock.double("wvous-\(key)-corner", 1))
        let clash = current > 1 && corners.enabled && corners.binding(spot).isActive && corners.binding(spot).modifiers.isEmpty
        return SettingRow(title: spot.title, detail: clash ? "Atelier acts here too. Add a modifier to one of them." : nil,
                          density: .compact) {
            HStack(spacing: 6) {
                if clash {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.9))
                        .help("macOS and Atelier will both act on this corner. Add a modifier to one of them.")
                        .accessibilityLabel("Both fire here")
                }
                DockMenuPill(selection: Binding(get: { current }, set: { model.setCorner(key, to: $0) }), options: Self.actions)
            }
        }
        .dockHubRow()
    }
}

// MARK: - Stage replica

/// Live glass at rest; a plain disc while the stage camera flies.
private struct CornerBadgeGlass: ViewModifier {
    let flat: Bool
    func body(content: Content) -> some View {
        if flat {
            content.background(.black.opacity(0.35), in: .circle)
        } else {
            content.atelierGlass(.regular, in: .circle)
        }
    }
}

/// Draws the configured spots on the stage's replica screen. Atelier spots glow in the accent;
/// macOS corners glow white where Atelier has nothing.
struct CornersReplica: View {
    @ObservedObject var model: ManagerModel
    let size: CGSize
    @ObservedObject private var corners = HotCorners.shared

    var body: some View {
        ZStack {
            ForEach(HotSpot.allCases) { spot in
                let binding = corners.binding(spot)
                if corners.enabled && binding.isActive {
                    glow(spot, color: DockHubHue.tint)
                    badge(spot, symbol: binding.action.symbol)
                } else if let key = spot.appleKey, model.dock.double("wvous-\(key)-corner", 1) > 1 {
                    glow(spot, color: .white.opacity(0.7))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .animation(DS.Motion.arrive, value: corners.bindings)
    }

    /// Each glow covers only its own disc. Canvas-sized gradients, one per spot, made the GPU fill
    /// the whole replica several times a frame while the camera flew.
    private func glow(_ spot: HotSpot, color: Color) -> some View {
        let radius = size.width * (spot.isCorner ? 0.16 : 0.11)
        return Circle()
            .fill(RadialGradient(colors: [color.opacity(0.75), .clear], center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
            .position(x: spot.unit.x * size.width, y: spot.unit.y * size.height)
            .transition(.opacity)
    }

    private func badge(_ spot: HotSpot, symbol: String) -> some View {
        let inset = size.width * 0.03
        let x = inset + spot.unit.x * (size.width - inset * 2), y = inset * 1.4 + spot.unit.y * (size.height - inset * 2.8)
        return Image(systemName: symbol)
            .font(.system(size: max(size.width * 0.011, 9), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size.width * 0.026, height: size.width * 0.026)
            .modifier(CornerBadgeGlass(flat: model.cameraMoving))
            .position(x: x, y: y)
            .transition(.scale.combined(with: .opacity))
    }
}

