import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

private let english = Locale(identifier: "en_GB")

/// The desktop's light: widgets are a desktop surface.
private let widgetsHue = DS.Spectrum.surfaces

// MARK: - Chapter

struct WidgetsChapter: View {
    @ObservedObject private var board = WidgetBoard.shared
    @ObservedObject private var session = WidgetSession.shared

    var body: some View {
        Text("Ours, not Apple’s: they sit on your desktop under the icons and let every click through, until you arrange them.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HeroCard("Widget Board", pitch: "Positions, sizes and styles are saved, per display.",
                 isOn: $board.enabled, hue: widgetsHue,
                 readout: "\(board.placements.count)", readoutCaption: board.placements.count == 1 ? "Widget placed" : "Widgets placed",
                 preview: .toggle("widgets.on", "Widget Board", isOn: board.enabled, region: StageRegion.desktop) { $0.boardOn.toggle() }) {
            WidgetsBoardPlate()
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Button { board.editing.toggle() } label: {
                    Label(board.editing ? "Done Arranging" : "Arrange Widgets",
                          systemImage: board.editing ? "checkmark" : "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(board.editing ? .black : DS.Ink.primary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(board.editing ? AnyShapeStyle(widgetsHue) : AnyShapeStyle(DS.Ink.fillStrong),
                                    in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        .contentShape(.rect(cornerRadius: DS.Radius.control))
                        .animation(DS.Motion.touch, value: board.editing)
                }
                .buttonStyle(Pressable(scale: 0.98))
                SettingRow(title: "Interactive Widgets", detail: "Clicks reach checklists, timers, launchers and stacks.",
                           density: .compact) {
                    LuxSwitch(isOn: $board.interactive, label: "Interactive Widgets", tint: widgetsHue)
                }
                .help("Clicks reach checklists, habits, timers, launchers, reminders, the clipboard and stacks. Every other widget stays click-through.")
                .stagePreview(.demo("widgets.interactive", "Interactive Widgets", isOn: board.interactive, region: StageRegion.desktop, Demos.interactiveWidgets))
                HarmonyCard(board: board)
            }
        }
        SectionHeader("Library", symbol: "square.grid.2x2",
                      detail: "Click to add one, or drag it onto the stage where you want it.", hue: widgetsHue)
        WidgetGallery(board: board)
        if !board.placements.isEmpty {
            SectionHeader("On your desktop", symbol: "rectangle.dashed", detail: "Pick one to change what it shows and how it looks.",
                          hue: widgetsHue)
            WidgetList(board: board, session: session)
        }
        if let id = session.selection, let placement = board.placement(id) {
            WidgetInspector(board: board, session: session, placement: placement)
                .id(id)
                .transition(.opacity.combined(with: .offset(y: 8)))
        }
        SectionHeader("Board style", symbol: "paintbrush",
                      detail: "Every widget wears this unless you give it a style of its own.", hue: widgetsHue)
        Card {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                ThemePicker(board: board)
                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                WidgetStyleEditor(style: $board.style)
            }
        }
        SectionHeader("Layouts", symbol: "rectangle.3.group",
                      detail: "Save the board as it is now, and bring it back in one click.", hue: widgetsHue)
        LayoutsCard(board: board)
    }
}

/// A desktop corner with a few widgets on it. At rest a composed still; under the pointer the
/// clock's second hand sweeps, the rings fill and the weather glyph breathes. Shapes only.
private struct WidgetsBoardPlate: View {
    var body: some View {
        HeroLife { live in
            HeroClock(live: live, rest: 14) { t in
                GeometryReader { geometry in
                    let h = geometry.size.height
                    let unit = min((h - 40) / 2, 52.0)
                    ZStack(alignment: .topLeading) {
                        LinearGradient(colors: [Color(red: 0.08, green: 0.13, blue: 0.24), Color(red: 0.16, green: 0.12, blue: 0.22)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        HStack(alignment: .top, spacing: 8) {
                            tile(width: unit * 2 + 8, height: unit * 2 + 8) { clock(t: t, size: unit * 2 - 8) }
                            VStack(spacing: 8) {
                                tile(width: unit * 2 + 8, height: unit) { weather(t: t) }
                                HStack(spacing: 8) {
                                    tile(width: unit, height: unit) { rings(t: t, size: unit - 18) }
                                    tile(width: unit, height: unit) { day }
                                }
                            }
                            tile(width: unit * 1.5, height: unit * 2 + 8) { notes }
                        }
                        .padding(.leading, geometry.size.width * 0.26)
                        .padding(.top, 20)
                    }
                }
            }
        }
    }

    private func tile<Content: View>(width: Double, height: Double, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return content()
            .frame(width: width, height: height)
            .background(shape.fill(.white.opacity(0.09)))
            .overlay { shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.5) }
    }

    private func clock(t: Double, size: Double) -> some View {
        let seconds = t.truncatingRemainder(dividingBy: 60)
        return ZStack {
            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
            ForEach(0..<12, id: \.self) { tick in
                Capsule().fill(.white.opacity(tick % 3 == 0 ? 0.7 : 0.3)).frame(width: 1.5, height: tick % 3 == 0 ? 6 : 3)
                    .offset(y: -size / 2 + 6).rotationEffect(.degrees(Double(tick) * 30))
            }
            Capsule().fill(.white).frame(width: 3, height: size * 0.26).offset(y: -size * 0.13).rotationEffect(.degrees(305))
            Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: size * 0.38).offset(y: -size * 0.19).rotationEffect(.degrees(52))
            Capsule().fill(widgetsHue).frame(width: 1, height: size * 0.42).offset(y: -size * 0.21)
                .rotationEffect(.degrees(seconds * 6))
            Circle().fill(widgetsHue).frame(width: 5, height: 5)
        }
        .frame(width: size, height: size)
    }

    private func weather(t: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill").font(.system(size: 20)).foregroundStyle(DS.Spectrum.light)
                .rotationEffect(.degrees(t * 12))
            VStack(alignment: .leading, spacing: 0) {
                Text("21°").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text("Clear").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private func rings(t: Double, size: Double) -> some View {
        let wave = (sin(t * 0.9) + 1) / 2
        return ZStack {
            ForEach(0..<3, id: \.self) { ring in
                let inset = Double(ring) * 6
                let fill = [0.72, 0.55, 0.86][ring] * (0.75 + 0.25 * wave)
                Circle().stroke(.white.opacity(0.12), lineWidth: 4).padding(inset)
                Circle().trim(from: 0, to: fill)
                    .stroke([widgetsHue, DS.Spectrum.input, DS.Spectrum.light][ring], style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(inset)
            }
        }
        .frame(width: size, height: size)
    }

    private var day: some View {
        VStack(spacing: 0) {
            Text("TUE").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.Spectrum.sensors)
            Text("14").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(DS.Spectrum.light.opacity(0.85)).frame(width: 34, height: 4)
            ForEach([0.9, 0.7, 0.8, 0.5, 0.65], id: \.self) { width in
                Capsule().fill(.white.opacity(0.22)).frame(maxWidth: .infinity).frame(height: 3)
                    .scaleEffect(x: width, anchor: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}

// MARK: - Gallery

/// Every kind, grouped, one click to add.
struct WidgetGallery: View {
    @ObservedObject var board: WidgetBoard
    @State private var hovered: WidgetKind?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .center) {
                    Text(hovered?.blurb ?? "Point at a widget to read what it shows.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentTransition(.opacity)
                        .animation(DS.Motion.hover, value: hovered)
                    stackButton
                }
                ForEach(WidgetCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text(category.title).font(DS.Typo.section).foregroundStyle(DS.Ink.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: DS.Space.s)], spacing: DS.Space.s) {
                            ForEach(WidgetKind.allCases.filter { $0.category == category }) { kind in tile(kind) }
                        }
                    }
                }
            }
        }
    }

    private func add(_ kind: WidgetKind) {
        if !board.enabled { board.enabled = true }
        withAnimation(DS.Motion.arrive) { _ = board.add(kind) }
    }

    private var stackButton: some View {
        Button { add(.stack) } label: {
            Label("New Smart Stack", systemImage: "square.stack")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(hovered == .stack ? DS.Ink.fillStrong : DS.Ink.fill, in: .capsule)
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(Pressable(scale: 0.96))
        .onHover { inside in hovered = inside ? .stack : (hovered == .stack ? nil : hovered) }
        .accessibilityHint(WidgetKind.stack.blurb)
    }

    private func tile(_ kind: WidgetKind) -> some View {
        let placed = board.isOn(kind) && !kind.allowsMultiple
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        return Button { add(kind) } label: {
            VStack(spacing: DS.Space.s) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(placed ? widgetsHue : DS.Ink.primary)
                    .frame(width: 40, height: 40)
                    .background(placed ? widgetsHue.opacity(0.16) : DS.Ink.fillStrong,
                                in: .rect(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if placed {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12)).foregroundStyle(widgetsHue)
                                .background(Circle().fill(.black).padding(1))
                                .offset(x: 5, y: -5)
                        }
                    }
                Text(kind.title).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(placed ? DS.Ink.primary : DS.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, DS.Space.m).padding(.horizontal, DS.Space.xs)
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(shape.fill(hovered == kind ? DS.Ink.fill : .clear))
            .overlay { shape.strokeBorder(placed ? widgetsHue.opacity(0.45) : DS.Ink.hairline, lineWidth: placed ? 1 : 0.5) }
            .animation(DS.Motion.hover, value: hovered)
            .contentShape(shape)
        }
        .buttonStyle(Pressable(scale: 0.96))
        .draggable(StageDrop.widget(kind)) {
            Image(systemName: kind.symbol).font(.system(size: 22)).padding(10).atelierGlass(.regular, in: .circle)
        }
        // Tiles sliding under a still pointer while the panel scrolls would re-render the
        // description's transition every frame: only a resting pointer changes it.
        .onHover { inside in
            if inside, ScrollActivity.scrolling { return }
            hovered = inside ? kind : (hovered == kind ? nil : hovered)
        }
        .accessibilityLabel(placed ? "\(kind.title), on the desktop" : "Add \(kind.title)")
        .accessibilityHint(kind.blurb)
    }
}

// MARK: - List

/// What is on the desktop now. Pick one to style it.
struct WidgetList: View {
    @ObservedObject var board: WidgetBoard
    @ObservedObject var session: WidgetSession

    private func subtitle(_ placement: WidgetPlacement) -> String {
        var parts = [placement.sizeTitle]
        if placement.style == nil { parts.append("Board style") } else { parts.append(board.style(for: placement).material.title) }
        if placement.layer == .floating { parts.append("Above windows") }
        let detail: String? = switch placement.kind {
        case .countdown, .photo, .checklist: placement.options.title
        case .sticker: placement.options.text?.split(separator: "\n").first.map(String.init)
        case .weather: placement.options.place?.name
        case .stack: placement.options.stack.map { $0.map(\.kind.title).joined(separator: ", ") }
        case .slideshow: placement.options.folder.map { URL(fileURLWithPath: $0).lastPathComponent }
        default: nil
        }
        if let detail, !detail.isEmpty { parts.insert(detail, at: 0) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card(padding: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                ForEach(board.placements) { placement in
                    let selected = session.selection == placement.uid || board.stack(containing: session.selection ?? "")?.uid == placement.uid
                    HStack(spacing: 12) {
                        Image(systemName: placement.kind.symbol).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? widgetsHue : DS.Ink.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(placement.kind.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                                if placement.locked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(DS.Ink.tertiary) }
                            }
                            Text(subtitle(placement)).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button {
                            withAnimation(DS.Motion.arrive) { board.remove(placement.uid) }
                        } label: {
                            Image(systemName: "minus").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(DS.Ink.secondary).frame(width: 24, height: 24)
                                .background(DS.Ink.fill, in: .circle).contentShape(Circle())
                        }
                        .buttonStyle(Pressable(scale: 0.9))
                        .accessibilityLabel("Remove \(placement.kind.title)")
                    }
                    .padding(.horizontal, 8).padding(.vertical, DS.Space.xs).frame(minHeight: 44)
                    .background(selected ? widgetsHue.opacity(0.12) : .clear, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(selected ? widgetsHue.opacity(0.5) : .clear, lineWidth: 0.75)
                    }
                    .contentShape(.rect(cornerRadius: DS.Radius.control))
                    .onTapGesture {
                        withAnimation(DS.Motion.arrive) { session.selection = session.selection == placement.uid ? nil : placement.uid }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }
}

// MARK: - Inspector

/// The selected widget: a live preview, its size and layer, what it shows and how it looks.
struct WidgetInspector: View {
    @ObservedObject var board: WidgetBoard
    @ObservedObject var session: WidgetSession
    let placement: WidgetPlacement
    @ObservedObject private var pomodoro = WidgetBoard.shared.pomodoro

    private var id: String { placement.uid }
    private var kind: WidgetKind { placement.kind }
    private var live: WidgetPlacement { board.placement(id) ?? placement }
    private var parent: WidgetPlacement? { board.stack(containing: id) }

    private var custom: Binding<Bool> {
        Binding(get: { board.placement(id)?.style != nil }, set: { on in
            withAnimation(DS.Motion.arrive) { board.update(id) { $0.style = on ? board.style : nil } }
        })
    }

    private var style: Binding<WidgetStyle> {
        Binding(get: { board.placement(id).map(board.style(for:)) ?? board.style },
                set: { new in board.update(id) { $0.style = new } })
    }

    private func option<Value>(_ path: WritableKeyPath<WidgetOptions, Value?>, _ fallback: Value) -> Binding<Value> {
        Binding(get: { board.placement(id)?.options[keyPath: path] ?? fallback },
                set: { new in board.update(id) { $0.options[keyPath: path] = new } })
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if let parent {
                        Button { withAnimation(DS.Motion.arrive) { session.selection = parent.uid } } label: {
                            Label("Stack", systemImage: "chevron.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(widgetsHue)
                        }
                        .buttonStyle(.plain)
                    }
                    Image(systemName: kind.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(widgetsHue)
                    Text(kind.title).font(DS.title).foregroundStyle(DS.Ink.primary)
                    Spacer()
                    Button { withAnimation(DS.Motion.arrive) { session.selection = nil } } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.secondary)
                            .frame(width: 22, height: 22).background(DS.Ink.fill, in: .circle).contentShape(Circle())
                    }
                    .buttonStyle(Pressable(scale: 0.9))
                    .accessibilityLabel("Close inspector")
                }
                preview
                if parent == nil {
                    placementSettings
                }
                contentSettings
                if let cadence = kind.cadence {
                    Text(cadence).font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if kind == .battery {
                    // A desktop Mac has no battery: the widget still shows the power adapter, so say what it will show.
                    AvailabilityNote(availability: BatteryMeter.hasInternalBattery ? .available
                                     : .limited("This Mac has no battery, so the widget shows only that it runs on power."))
                }
                if kind.needsClicks && !board.interactive && parent == nil {
                    Text("Turn on Interactive Widgets above to use its controls on the desktop.")
                        .font(DS.caption).foregroundStyle(widgetsHue).fixedSize(horizontal: false, vertical: true)
                }
                if parent == nil {
                    Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                    SettingRow(title: "Own Style", detail: "Off follows the board style below.", density: .compact) {
                        LuxSwitch(isOn: custom, label: "Own Style", tint: widgetsHue)
                    }
                    if live.style != nil {
                        WidgetStyleEditor(style: style)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
            }
        }
    }

    private var preview: some View {
        let shown = parent ?? live
        let tile = WidgetBoard.tileSize(shown)
        let k = min(1, 300 / tile.width, 240 / tile.height)
        return Group {
            if parent != nil {
                // A page of a stack previews on its own, in the stack's frame.
                WidgetFace(kind: kind, board: board, size: tile, placement: live)
            } else {
                WidgetFace(kind: kind, board: board, size: tile, placement: live)
            }
        }
        .scaleEffect(k, anchor: .topLeading)
        .frame(width: tile.width * k, height: tile.height * k, alignment: .topLeading)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.32), Color(red: 0.3, green: 0.22, blue: 0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .animation(DS.Motion.arrive, value: shown.size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var placementSettings: some View {
        if kind.sizes.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.freeSpan ? "Size, or any span below, or drag its corner while arranging" : "Size")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                Segments(selection: Binding(get: { board.placement(id)?.size ?? kind.defaultSize },
                                            set: { size in
                                                withAnimation(DS.Motion.arrive) {
                                                    board.resize(id, to: size)
                                                    if kind == .stack { board.update(id) { $0.options.stack = $0.options.stack?.map { var p = $0; p.size = size; return p } } }
                                                }
                                            }),
                         options: kind.sizes.map { ($0, $0.title) })
                    .opacity(live.custom != nil ? 0.6 : 1)
                if kind.freeSpan { SpanEditor(board: board, id: id) }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Layer").font(DS.caption).foregroundStyle(DS.Ink.secondary)
            Segments(selection: Binding(get: { board.placement(id)?.layer ?? .desktop },
                                        set: { layer in board.update(id) { $0.layer = layer } }),
                     options: WidgetLayer.allCases.map { ($0, $0.title) })
        }
        HStack(spacing: 8) {
            pill(live.locked ? "Unlock" : "Lock Position", symbol: live.locked ? "lock.open" : "lock") {
                withAnimation(DS.Motion.settle) { board.update(id) { $0.locked.toggle() } }
            }
            if kind.allowsMultiple {
                pill("Duplicate", symbol: "plus.square.on.square") {
                    withAnimation(DS.Motion.arrive) { if let copy = board.duplicate(id) { session.selection = copy } }
                }
            }
        }
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(DS.Ink.fillStrong, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(.rect(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(Pressable(scale: 0.97))
    }

    @ViewBuilder private var contentSettings: some View {
        switch kind {
        case .notes:
            field("Note") {
                TextEditor(text: $board.note).font(DS.body).scrollContentBackground(.hidden).frame(height: 76)
                    .accessibilityLabel("Note")
            }
        case .clocks:
            CityList(board: board)
        case .pomodoro:
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "Pomodoro", detail: "\(pomodoro.phase.title), round \(pomodoro.finished % 4 + 1) of 4. A long break follows the fourth.") {
                    HStack(spacing: 6) {
                        PomodoroButton(symbol: pomodoro.running ? "pause.fill" : "play.fill", label: pomodoro.running ? "Pause" : "Start", action: pomodoro.toggle)
                        PomodoroButton(symbol: "arrow.counterclockwise", label: "Reset", action: pomodoro.reset)
                    }
                }
                .stagePreview(.demo("widgets.pomodoro", "Pomodoro", isOn: false, region: StageRegion.desktop, Demos.pomodoro))
                HStack(spacing: 12) {
                    LuxSlider(value: $pomodoro.focusMinutes, range: 10...60)
                    Text("\(Int(pomodoro.focusMinutes)) min").font(DS.caption).monospacedDigit()
                        .foregroundStyle(DS.Ink.secondary).frame(width: 44, alignment: .trailing)
                }
            }
        case .countdown:
            field("Title") {
                TextField("", text: option(\.title, ""), prompt: Text("What are you counting down to?"))
                    .textFieldStyle(.plain).font(DS.body)
            }
            HStack {
                Text("Date").font(DS.title).foregroundStyle(DS.Ink.primary)
                Spacer()
                DatePicker("Date", selection: Binding(
                    get: { board.placement(id)?.options.date ?? Calendar.current.startOfDay(for: Date().addingTimeInterval(7 * 86_400)) },
                    set: { new in board.update(id) { $0.options.date = new; if $0.options.start == nil { $0.options.start = Date() } } }),
                    displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .environment(\.locale, english)
            }
            Button {
                board.update(id) { $0.options.start = Date() }
            } label: {
                Text("Restart Progress Bar From Today").font(.system(size: 12, weight: .medium)).foregroundStyle(widgetsHue)
            }
            .buttonStyle(.plain)
        case .sticker:
            field("Text") {
                TextEditor(text: option(\.text, "")).font(DS.body).scrollContentBackground(.hidden).frame(height: 76)
                    .accessibilityLabel("Sticker text")
            }
            field("Attribution") {
                TextField("", text: option(\.title, ""), prompt: Text("Optional, shown under the text"))
                    .textFieldStyle(.plain).font(DS.body)
            }
        case .photo:
            wideButton(live.options.photo == nil ? "Choose Photo…" : "Replace Photo…") { choosePhoto() }
            Text("A copy is kept in Atelier’s own folder, so moving or deleting the original changes nothing.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            field("Caption") {
                TextField("", text: option(\.title, ""), prompt: Text("Optional"))
                    .textFieldStyle(.plain).font(DS.body)
            }
        case .moon:
            SettingRow(title: "Southern Hemisphere", detail: "Mirrors the moon as it looks south of the equator.", density: .compact) {
                LuxSwitch(isOn: option(\.southern, false), label: "Southern Hemisphere", tint: widgetsHue)
            }
            .stagePreview(.demo("widgets.south", "Southern Hemisphere", isOn: option(\.southern, false).wrappedValue, region: StageRegion.desktop, Demos.southern))
        case .weather:
            WeatherPlacePicker(board: board, id: id)
            SettingRow(title: "Fahrenheit", detail: nil, density: .compact) {
                LuxSwitch(isOn: option(\.fahrenheit, Locale.current.measurementSystem == .us), label: "Fahrenheit", tint: widgetsHue)
            }
            .stagePreview(.demo("widgets.f", "Fahrenheit", isOn: option(\.fahrenheit, Locale.current.measurementSystem == .us).wrappedValue, region: StageRegion.desktop, Demos.fahrenheit))
            Text("Weather data by Open-Meteo.com, under CC BY 4.0.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
        case .events:
            AgendaAccess(kind: .event)
        case .reminders:
            AgendaAccess(kind: .reminder)
        case .checklist:
            field("Title") {
                TextField("", text: option(\.title, ""), prompt: Text("Checklist")).textFieldStyle(.plain).font(DS.body)
            }
            ChecklistEditor(board: board, id: id)
        case .habits:
            HabitEditor(board: board, id: id)
        case .launcher:
            LauncherEditor(board: board, id: id)
        case .stopwatch:
            ChronoSettings(board: board, id: id)
        case .slideshow:
            wideButton(live.options.folder == nil ? "Choose Folder…" : "Change Folder…") { chooseFolder() }
            if let folder = live.options.folder {
                Text(folder).font(DS.caption).foregroundStyle(DS.Ink.tertiary).lineLimit(2).truncationMode(.middle)
            }
            labeledSlider("Next Picture Every", value: Binding(get: { board.placement(id)?.options.minutes ?? 5 },
                                                              set: { new in board.update(id) { $0.options.minutes = (new * 2).rounded() / 2 } }),
                          range: 0.5...60, text: { "\($0 < 1 ? "30 s" : "\(Int($0)) min")" })
        case .stack:
            StackEditor(board: board, session: session, id: id)
        case .bigClock:
            ClockEditor(board: board, id: id)
        case .vitals:
            VitalsEditor(board: board, id: id)
        default:
            EmptyView()
        }
    }

    private func wideButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(DS.Ink.fillStrong, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(.rect(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(Pressable(scale: 0.98))
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                Spacer()
                Text(text(value.wrappedValue)).font(DS.caption).monospacedDigit().foregroundStyle(DS.Ink.tertiary)
            }
            LuxSlider(value: value, range: range)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        InspectorField(title: title, content: content)
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Photo"
        guard panel.runModal() == .OK, let url = panel.url, let name = WidgetPhotos.importImage(from: url) else { return }
        let old = board.placement(id)?.options.photo
        board.update(id) { $0.options.photo = name }
        board.release(picture: old)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        board.update(id) { $0.options.folder = url.path }
    }
}

struct InspectorField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary)
            content
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        }
    }
}

/// A small round button for list rows in the inspector.
private struct RowButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .foregroundStyle(DS.Ink.secondary).frame(width: 24, height: 24).contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// A text field with an Add button, for growing lists.
private struct AddField: View {
    let prompt: String
    let add: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain).font(DS.body)
                .onSubmit(commit)
            Button(action: commit) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Ink.primary)
                    .frame(width: 26, height: 26).background(DS.Ink.fillStrong, in: .circle).contentShape(Circle())
            }
            .buttonStyle(Pressable(scale: 0.9))
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Add")
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        add(value)
        text = ""
    }
}

// MARK: - Content editors

struct CityList: View {
    @ObservedObject var board: WidgetBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cities").font(DS.title).foregroundStyle(DS.Ink.primary)
            ForEach(board.cities) { city in
                HStack {
                    Text(city.name).font(DS.body).foregroundStyle(DS.Ink.secondary)
                    Spacer()
                    if board.cities.count > 1 {
                        RowButton(symbol: "minus", label: "Remove \(city.name)") {
                            withAnimation(DS.Motion.arrive) { board.cities.removeAll { $0 == city } }
                        }
                    }
                }
            }
            if board.cities.count < 4 {
                Menu {
                    ForEach(WorldCity.catalog.filter { !board.cities.contains($0) }) { city in
                        Button(city.name) { withAnimation(DS.Motion.arrive) { board.cities.append(city) } }
                    }
                } label: {
                    Text("Add City").font(.system(size: 12, weight: .medium)).foregroundStyle(widgetsHue)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            Text("The small size shows the first city.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
        }
    }
}

/// Finds a city through Open-Meteo's geocoder. No location permission: the owner types where.
struct WeatherPlacePicker: View {
    @ObservedObject var board: WidgetBoard
    let id: String
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var searching = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let place = board.placement(id)?.options.place {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name).font(DS.title).foregroundStyle(DS.Ink.primary)
                        if let region = place.region { Text(region).font(DS.caption).foregroundStyle(DS.Ink.tertiary) }
                    }
                    Spacer()
                    Button("Refresh") { WeatherService.feed(for: place).refresh(force: true) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(widgetsHue)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DS.Ink.tertiary)
                TextField("", text: $query, prompt: Text("Search for a city"))
                    .textFieldStyle(.plain).font(DS.body)
                    .onSubmit { search() }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            if failed { Text("Couldn’t reach Open-Meteo. Check the connection and try again.").font(DS.caption).foregroundStyle(DS.Ink.secondary) }
            ForEach(results, id: \.self) { place in
                Button {
                    withAnimation(DS.Motion.arrive) {
                        board.update(id) { $0.options.place = place }
                        results = []
                        query = ""
                    }
                } label: {
                    HStack {
                        Text(place.name).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.primary)
                        Text(place.region ?? "").font(DS.caption).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(DS.Ink.fill, in: .rect(cornerRadius: 9, style: .continuous))
                    .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(Pressable(scale: 0.98))
            }
        }
    }

    private func search() {
        let text = query
        searching = true
        failed = false
        Task {
            do {
                let found = try await WeatherAPI.search(text)
                withAnimation(DS.Motion.arrive) { results = found }
            } catch {
                failed = true
            }
            searching = false
        }
    }
}

/// Calendar and Reminders are asked for only when the owner presses the button.
struct AgendaAccess: View {
    let kind: EKEntityType
    @ObservedObject private var agenda = Agenda.shared

    private var status: EKAuthorizationStatus { kind == .event ? agenda.eventStatus : agenda.reminderStatus }
    private var name: String { kind == .event ? "Calendar" : "Reminders" }

    var body: some View {
        switch status {
        case .fullAccess:
            Label("\(name) access is on.", systemImage: "checkmark.circle.fill").font(DS.caption).foregroundStyle(DS.Ink.secondary)
        case .notDetermined:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if kind == .event { agenda.requestEvents() } else { agenda.requestReminders() }
                } label: {
                    Text("Allow \(name) Access…").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(DS.Ink.fillStrong, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        .contentShape(.rect(cornerRadius: DS.Radius.control))
                }
                .buttonStyle(Pressable(scale: 0.98))
                Text(kind == .event ? "Read only: events are shown, never changed." : "Ticking a reminder on the desktop completes it in Reminders.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                // macOS 14 split Calendar access: "Add Only" lets an app create events but not read them.
                Text(status == .writeOnly
                     ? "Atelier can only add events. Choose Full Access for it in System Settings, Privacy & Security, \(name)."
                     : "\(name) access is off. Turn it on for Atelier in System Settings, Privacy & Security, \(name).")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") {
                    let pane = kind == .event ? "Privacy_Calendars" : "Privacy_Reminders"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(widgetsHue)
            }
        }
    }
}

struct ChecklistEditor: View {
    @ObservedObject var board: WidgetBoard
    let id: String

    private var items: [CheckItem] { board.placement(id)?.options.items ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Items").font(DS.caption).foregroundStyle(DS.Ink.secondary)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Button {
                        withAnimation(DS.Motion.settle) { mutate { list in if let i = list.firstIndex(where: { $0.id == item.id }) { list[i].done.toggle() } } }
                    } label: {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14)).foregroundStyle(item.done ? widgetsHue : DS.Ink.tertiary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    TextField("", text: Binding(get: { item.text }, set: { new in mutate { list in if let i = list.firstIndex(where: { $0.id == item.id }) { list[i].text = new } } }))
                        .textFieldStyle(.plain).font(DS.body).foregroundStyle(item.done ? DS.Ink.tertiary : DS.Ink.primary)
                    RowButton(symbol: "arrow.up", label: "Move up") { move(item.id, -1) }
                        .opacity(items.first?.id == item.id ? 0.3 : 1)
                    RowButton(symbol: "minus", label: "Remove \(item.text)") {
                        withAnimation(DS.Motion.arrive) { mutate { $0.removeAll { $0.id == item.id } } }
                    }
                }
            }
            AddField(prompt: "Add an item") { text in withAnimation(DS.Motion.arrive) { mutate { $0.append(CheckItem(text: text)) } } }
            if items.contains(where: \.done) {
                Button("Clear Completed") { withAnimation(DS.Motion.arrive) { mutate { $0.removeAll(where: \.done) } } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(widgetsHue)
            }
        }
    }

    private func mutate(_ change: (inout [CheckItem]) -> Void) {
        board.update(id) { placement in
            var list = placement.options.items ?? []
            change(&list)
            placement.options.items = list
        }
    }

    private func move(_ item: String, _ offset: Int) {
        withAnimation(DS.Motion.settle) {
            mutate { list in
                guard let i = list.firstIndex(where: { $0.id == item }), list.indices.contains(i + offset) else { return }
                list.swapAt(i, i + offset)
            }
        }
    }
}

struct HabitEditor: View {
    @ObservedObject var board: WidgetBoard
    let id: String
    static let symbols = ["checkmark", "drop.fill", "figure.walk", "book.fill", "dumbbell.fill", "leaf.fill", "moon.zzz.fill", "pencil", "music.note", "heart.fill"]

    private var habits: [Habit] { board.placement(id)?.options.habits ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Habits").font(DS.caption).foregroundStyle(DS.Ink.secondary)
            ForEach(habits) { habit in
                HStack(spacing: 8) {
                    Menu {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button { mutate { list in if let i = list.firstIndex(where: { $0.id == habit.id }) { list[i].symbol = symbol } } } label: {
                                Label(symbol, systemImage: symbol)
                            }
                        }
                    } label: {
                        Image(systemName: habit.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(widgetsHue)
                            .frame(width: 26, height: 26).background(DS.Ink.fill, in: .circle)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    TextField("", text: Binding(get: { habit.name }, set: { new in mutate { list in if let i = list.firstIndex(where: { $0.id == habit.id }) { list[i].name = new } } }))
                        .textFieldStyle(.plain).font(DS.body)
                    Text("\(HabitDay.streak(habit.marks, today: Date())) d").font(DS.caption).monospacedDigit().foregroundStyle(DS.Ink.tertiary)
                    RowButton(symbol: "minus", label: "Remove \(habit.name)") {
                        withAnimation(DS.Motion.arrive) { mutate { $0.removeAll { $0.id == habit.id } } }
                    }
                }
            }
            if habits.count < 3 {
                AddField(prompt: "Add a habit") { text in withAnimation(DS.Motion.arrive) { mutate { $0.append(Habit(name: text)) } } }
            }
            Text("Up to three. Tap the circle on the desktop to mark today, with Interactive Widgets on.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mutate(_ change: (inout [Habit]) -> Void) {
        board.update(id) { placement in
            var list = placement.options.habits ?? []
            change(&list)
            placement.options.habits = list
        }
    }
}

struct LauncherEditor: View {
    @ObservedObject var board: WidgetBoard
    @ObservedObject private var icons = AtelierIcons.shared
    let id: String

    private var links: [LaunchLink] { board.placement(id)?.options.links ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Items. Click an icon to change it.").font(DS.caption).foregroundStyle(DS.Ink.secondary)
            ForEach(links) { link in
                HStack(spacing: 8) {
                    // Click the icon to change it: a picture, or one from macOSicons.
                    IconChooserMenu(query: link.name, canReset: icons.has(link.target),
                                    onPick: { icons.set($0, for: link.target) },
                                    onReset: { icons.reset(link.target) }) {
                        Group {
                            if let icon = LaunchIcons.icon(for: link) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "globe").foregroundStyle(widgetsHue)
                            }
                        }
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .background(DS.Ink.fill, in: .rect(cornerRadius: 7, style: .continuous))
                        .contentShape(.rect)
                    }
                    .help("Change icon")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(link.name).font(DS.body).foregroundStyle(DS.Ink.primary).lineLimit(1)
                        Text(link.target).font(DS.caption).foregroundStyle(DS.Ink.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    RowButton(symbol: "arrow.up", label: "Move up") { move(link.id, -1) }
                        .opacity(links.first?.id == link.id ? 0.3 : 1)
                    RowButton(symbol: "minus", label: "Remove \(link.name)") {
                        withAnimation(DS.Motion.arrive) { mutate { $0.removeAll { $0.id == link.id } } }
                    }
                }
            }
            if links.count < 16 {
                HStack(spacing: 8) {
                    small("Add App…") { pick(apps: true) }
                    small("Add Folder…") { pick(apps: false) }
                }
                AddField(prompt: "Add a link, like apple.com") { text in
                    guard let url = LaunchLink.url(from: text) else { NSSound.beep(); return }
                    withAnimation(DS.Motion.arrive) {
                        mutate { $0.append(LaunchLink(kind: .url, name: url.host?.replacingOccurrences(of: "www.", with: "") ?? text, target: url.absoluteString)) }
                    }
                }
            }
        }
    }

    private func small(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(DS.Ink.fillStrong, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .contentShape(.rect(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(Pressable(scale: 0.97))
    }

    private func pick(apps: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if apps {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.prompt = "Add"
        } else {
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Add"
        }
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map { url in
            LaunchLink(kind: apps ? .app : .folder,
                       name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                       target: url.path)
        }
        withAnimation(DS.Motion.arrive) { mutate { $0 = Array(($0 + added).prefix(16)) } }
    }

    private func mutate(_ change: (inout [LaunchLink]) -> Void) {
        board.update(id) { placement in
            var list = placement.options.links ?? []
            change(&list)
            placement.options.links = list
        }
    }

    private func move(_ item: String, _ offset: Int) {
        withAnimation(DS.Motion.settle) {
            mutate { list in
                guard let i = list.firstIndex(where: { $0.id == item }), list.indices.contains(i + offset) else { return }
                list.swapAt(i, i + offset)
            }
        }
    }
}

struct ChronoSettings: View {
    @ObservedObject var board: WidgetBoard
    let id: String

    var body: some View {
        let timer = board.placement(id)?.options.timer == true
        let model = Chrono.model(id)
        VStack(alignment: .leading, spacing: 12) {
            Segments(selection: Binding(get: { board.placement(id)?.options.timer == true },
                                        set: { on in model.reset(); board.update(id) { $0.options.timer = on } }),
                     options: [(false, "Stopwatch"), (true, "Timer")])
            if timer {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Length").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        Spacer()
                        Text("\(Int(board.placement(id)?.options.minutes ?? 5)) min").font(DS.caption).monospacedDigit().foregroundStyle(DS.Ink.tertiary)
                    }
                    LuxSlider(value: Binding(get: { board.placement(id)?.options.minutes ?? 5 },
                                             set: { new in board.update(id) { $0.options.minutes = max(new.rounded(), 1) } }),
                              range: 1...120)
                }
            }
            ChronoButtons(model: model, timer: timer ? (board.placement(id)?.options.minutes ?? 5) * 60 : nil)
        }
    }
}

private struct ChronoButtons: View {
    @ObservedObject var model: ChronoModel
    let timer: TimeInterval?

    var body: some View {
        HStack(spacing: 6) {
            PomodoroButton(symbol: model.running ? "pause.fill" : "play.fill", label: model.running ? "Pause" : "Start") { model.toggle(timer: timer) }
            PomodoroButton(symbol: "arrow.counterclockwise", label: "Reset", action: model.reset)
            if timer == nil { PomodoroButton(symbol: "flag.fill", label: "Lap", action: model.lap) }
        }
    }
}

struct StackEditor: View {
    @ObservedObject var board: WidgetBoard
    @ObservedObject var session: WidgetSession
    let id: String

    var body: some View {
        let stack = board.placement(id)
        let items = stack?.options.stack ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text("In This Stack").font(DS.caption).foregroundStyle(DS.Ink.secondary)
            ForEach(items) { inner in
                HStack(spacing: 10) {
                    Image(systemName: inner.kind.symbol).font(.system(size: 12)).foregroundStyle(DS.Ink.secondary).frame(width: 20)
                    Text(inner.kind.title).font(DS.body).foregroundStyle(DS.Ink.primary)
                    Spacer()
                    Button("Edit") { withAnimation(DS.Motion.arrive) { session.selection = inner.uid } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(widgetsHue)
                    RowButton(symbol: "arrow.up", label: "Move up") { withAnimation(DS.Motion.settle) { board.moveInStack(inner.uid, by: -1) } }
                        .opacity(items.first?.uid == inner.uid ? 0.3 : 1)
                    RowButton(symbol: "minus", label: "Remove \(inner.kind.title)") { withAnimation(DS.Motion.arrive) { board.remove(inner.uid) } }
                }
            }
            if items.count < 8 {
                Menu {
                    ForEach(WidgetBoard.stackable(for: stack?.size ?? .small)) { kind in
                        Button { withAnimation(DS.Motion.arrive) { board.addToStack(id, kind: kind) } } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    Text("Add Widget to Stack").font(.system(size: 12, weight: .medium)).foregroundStyle(widgetsHue)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            SettingRow(title: "Rotate", detail: "Turns to the next widget every 10 seconds, pausing under the pointer.") {
                LuxSwitch(isOn: Binding(get: { board.placement(id)?.options.rotate == true },
                                        set: { on in board.update(id) { $0.options.rotate = on } }), label: "Rotate")
            }
            .stagePreview(.demo("widgets.rotate", "Rotate", isOn: board.placement(id)?.options.rotate == true, region: StageRegion.desktop, Demos.rotate))
            Text("With Interactive Widgets on, scroll or swipe on the stack to page through it.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Themes and layouts

struct ThemePicker: View {
    @ObservedObject var board: WidgetBoard
    @State private var everywhere = false
    @State private var hovered: BoardTheme?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Themes").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: DS.Space.s)], spacing: DS.Space.m) {
                ForEach(BoardTheme.allCases) { theme in
                    let chosen = board.style == theme.style
                    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                    Button {
                        withAnimation(DS.Motion.arrive) { board.apply(theme: theme, everywhere: everywhere) }
                    } label: {
                        VStack(spacing: 6) {
                            shape
                                .fill(LinearGradient(colors: theme.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay {
                                    // A widget's shape on the swatch, so a theme reads as a material, not a colour.
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(.white.opacity(0.16))
                                        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
                                        .padding(10)
                                }
                                .overlay { Color.white.opacity(hovered == theme && !chosen ? 0.08 : 0).clipShape(shape) }
                                .frame(height: 50)
                                .overlay {
                                    shape.strokeBorder(chosen ? widgetsHue : .white.opacity(hovered == theme ? 0.3 : 0.12),
                                                       lineWidth: chosen ? 2 : 0.5)
                                }
                            Text(theme.title).font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(chosen ? DS.Ink.primary : DS.Ink.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .animation(DS.Motion.hover, value: hovered)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(Pressable(scale: 0.96))
                    .onHover { inside in if inside { hovered = theme } else if hovered == theme { hovered = nil } }
                    .accessibilityLabel("\(theme.title) theme")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            SettingRow(title: "Apply to Every Widget", detail: "Also clears widgets’ own styles when you pick a theme.",
                       density: .compact) {
                LuxSwitch(isOn: $everywhere, label: "Apply to Every Widget", tint: widgetsHue)
            }
        }
    }
}

struct LayoutsCard: View {
    @ObservedObject var board: WidgetBoard
    @State private var name = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(board.layouts) { layout in
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.3.group").font(.system(size: 12)).foregroundStyle(DS.Ink.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(layout.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                            Text("\(layout.placements.count) widgets · \(layout.saved.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(english)))")
                                .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        }
                        Spacer()
                        Button("Apply") { withAnimation(DS.Motion.arrive) { board.restore(layout) } }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(widgetsHue)
                            .accessibilityLabel("Apply \(layout.name)")
                        RowButton(symbol: "minus", label: "Delete \(layout.name)") { withAnimation(DS.Motion.arrive) { board.deleteLayout(layout.id) } }
                    }
                    .frame(minHeight: 36)
                }
                AddField(prompt: board.layouts.isEmpty ? "Name this layout, like Work" : "Save current as…") { text in
                    withAnimation(DS.Motion.arrive) { board.saveLayout(named: text) }
                }
            }
        }
    }
}
