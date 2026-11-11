import AppKit
import SwiftUI

// MARK: - Shared pieces

/// A caption over a control, with an optional value on the right.
struct EditorRow<Content: View>: View {
    let title: String
    var value: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                Spacer()
                if let value { Text(value).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary) }
            }
            content
        }
    }
}

/// Picks one of many options as a wrapping grid of chips, for lists too long for Segments.
struct ChipPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var minimum = 82.0

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(options, id: \.0) { value, label in
                Button { withAnimation(DS.Motion.settle) { selection = value } } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == value ? DS.Ink.primary : DS.Ink.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(selection == value ? DS.Ink.fillStrong : DS.Ink.fill, in: .rect(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(selection == value ? DS.Spectrum.surfaces.opacity(0.7) : .clear, lineWidth: 1)
                        }
                        .contentShape(.rect(cornerRadius: 9))
                }
                .buttonStyle(Pressable(scale: 0.96))
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
    }
}

/// Swatches with a first chip that means "none".
struct OptionalSwatches: View {
    @Binding var selection: WidgetTint?
    let noneLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { withAnimation(DS.Motion.settle) { selection = nil } } label: {
                Text(noneLabel).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selection == nil ? DS.Ink.primary : DS.Ink.secondary)
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(selection == nil ? DS.Ink.fillStrong : DS.Ink.fill, in: .capsule)
                    .contentShape(Capsule())
            }
            .buttonStyle(Pressable(scale: 0.94))
            Swatches(selection: Binding(get: { selection ?? .graphite }, set: { selection = $0 }))
                .opacity(selection == nil ? 0.55 : 1)
        }
    }
}

// MARK: - Big Clock

struct ClockEditor: View {
    @ObservedObject var board: WidgetBoard
    let id: String

    private var options: Binding<ClockOptions> {
        Binding(get: { board.placement(id)?.options.clock ?? ClockOptions() },
                set: { new in board.update(id) { $0.options.clock = new } })
    }

    private var zones: [(String?, String)] {
        [(nil, "This Mac")] + WorldCity.catalog.map { ($0.zone, $0.name) }
    }

    var body: some View {
        let o = options
        VStack(alignment: .leading, spacing: 14) {
            EditorRow(title: "Face") {
                ChipPicker(selection: o.face, options: ClockFace.allCases.map { ($0, $0.title) })
            }
            if o.wrappedValue.face == .analog {
                EditorRow(title: "Dial") {
                    ChipPicker(selection: o.dial, options: DialStyle.allCases.map { ($0, $0.title) }, minimum: 70)
                }
                SettingRow(title: "Dial Disc", detail: "A soft disc behind the hands.") {
                    LuxSwitch(isOn: o.dialFill, label: "Dial Disc")
                }
            }
            HStack(spacing: 18) {
                SettingRow(title: "Seconds", detail: nil) { LuxSwitch(isOn: o.seconds, label: "Seconds") }
                if o.wrappedValue.face.digital || o.wrappedValue.face == .analog {
                    SettingRow(title: "24-Hour", detail: nil) {
                        LuxSwitch(isOn: Binding(get: { o.wrappedValue.uses24 }, set: { o.wrappedValue.hour24 = $0 }), label: "24-Hour")
                    }
                }
            }
            if o.wrappedValue.face == .analog && o.wrappedValue.seconds {
                EditorRow(title: "Seconds Hand") {
                    Segments(selection: o.sweep, options: [(false, "Tick"), (true, "Sweep")])
                }
            }
            EditorRow(title: "Date") {
                ChipPicker(selection: o.date, options: ClockDate.allCases.map { ($0, $0.title) }, minimum: 96)
            }
            HStack(spacing: 18) {
                SettingRow(title: "Weekday", detail: nil) { LuxSwitch(isOn: o.weekday, label: "Weekday") }
                SettingRow(title: "Date Above", detail: nil) { LuxSwitch(isOn: o.dateAbove, label: "Date above the time") }
            }
            EditorRow(title: "Time Zone") {
                Picker("Time Zone", selection: o.zone) {
                    ForEach(zones, id: \.0) { zone, name in Text(name).tag(zone) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)
            }
            Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
            EditorRow(title: "Colour") { OptionalSwatches(selection: o.color, noneLabel: "White") }
            EditorRow(title: "Gradient To") { OptionalSwatches(selection: o.gradient, noneLabel: "Solid") }
            EditorRow(title: "Glow", value: o.wrappedValue.glow < 0.01 ? "None" : Units.percent(o.wrappedValue.glow)) {
                LuxSlider(value: o.glow, range: 0...1)
            }
            EditorRow(title: "Shadow", value: o.wrappedValue.shadow < 0.01 ? "None" : Units.percent(o.wrappedValue.shadow)) {
                LuxSlider(value: o.shadow, range: 0...1)
            }
            if o.wrappedValue.face != .flip {
                EditorRow(title: "Weight", value: (o.wrappedValue.weight ?? o.wrappedValue.face.weight).title) {
                    LuxSlider(value: Binding(get: { Double((o.wrappedValue.weight ?? o.wrappedValue.face.weight).index) },
                                             set: { o.wrappedValue.weight = ClockWeight.allCases[min(max(Int($0.rounded()), 0), ClockWeight.allCases.count - 1)] }),
                              range: 0...Double(ClockWeight.allCases.count - 1))
                }
                EditorRow(title: "Width") {
                    Segments(selection: o.width, options: ClockWidth.allCases.map { ($0, $0.title) })
                }
            }
            EditorRow(title: "Alignment") {
                Segments(selection: o.align, options: ClockAlign.allCases.map { ($0, $0.title) })
            }
            SettingRow(title: "No Background", detail: "The time straight on the wallpaper, like the old Desktop Clock.") {
                LuxSwitch(isOn: Binding(get: { board.placement(id).map(board.style(for:))?.material == .bare },
                                        set: { on in
                                            withAnimation(DS.Motion.arrive) {
                                                board.update(id) {
                                                    var style = $0.style ?? board.style
                                                    style.material = on ? .bare : .glass
                                                    $0.style = style
                                                }
                                            }
                                        }), label: "No Background")
            }
        }
        .animation(DS.Motion.arrive, value: o.wrappedValue.face)
    }
}

// MARK: - Vitals

struct VitalsEditor: View {
    @ObservedObject var board: WidgetBoard
    let id: String

    private var options: Binding<VitalsOptions> {
        Binding(get: { board.placement(id)?.options.vitals ?? VitalsOptions() },
                set: { new in board.update(id) { $0.options.vitals = new } })
    }

    var body: some View {
        let o = options
        VStack(alignment: .leading, spacing: 14) {
            EditorRow(title: "Show") {
                VStack(spacing: 2) {
                    ForEach(VitalMetric.allCases) { metric in row(metric, o) }
                }
            }
            EditorRow(title: "Style") {
                Segments(selection: o.display, options: VitalsDisplay.allCases.map { ($0, $0.title) })
            }
            if o.wrappedValue.display != .numbers {
                EditorRow(title: "Thickness", value: "\(Int(o.wrappedValue.thickness.rounded())) pt") {
                    LuxSlider(value: o.thickness, range: VitalsOptions.thicknesses)
                }
            }
            HStack(spacing: 18) {
                SettingRow(title: "Labels", detail: nil) { LuxSwitch(isOn: o.labels, label: "Labels") }
                SettingRow(title: "Details", detail: nil) { LuxSwitch(isOn: o.large, label: "Details") }
            }
            SettingRow(title: "One Colour", detail: "Every metric in the widget's ink, like the old Desktop Vitals.") {
                LuxSwitch(isOn: o.mono, label: "One Colour")
            }
            SettingRow(title: "No Background", detail: "Rings straight on the wallpaper.") {
                LuxSwitch(isOn: Binding(get: { board.placement(id).map(board.style(for:))?.material == .bare },
                                        set: { on in
                                            withAnimation(DS.Motion.arrive) {
                                                board.update(id) {
                                                    var style = $0.style ?? board.style
                                                    style.material = on ? .bare : .glass
                                                    $0.style = style
                                                }
                                            }
                                        }), label: "No Background")
            }
        }
    }

    private func row(_ metric: VitalMetric, _ o: Binding<VitalsOptions>) -> some View {
        let on = o.wrappedValue.metrics.contains(metric)
        return HStack(spacing: 10) {
            Image(systemName: metric.symbol).font(.system(size: 12)).foregroundStyle(on ? o.wrappedValue.tint(metric).color : DS.Ink.tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.title).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.primary)
                Text(metric.detail).font(.system(size: 10.5)).foregroundStyle(DS.Ink.tertiary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if on && !o.wrappedValue.mono {
                Menu {
                    ForEach(WidgetTint.allCases) { tint in
                        Button(tint.title) { o.wrappedValue.tints[metric.rawValue] = tint }
                    }
                } label: {
                    Circle().fill(o.wrappedValue.tint(metric).color).frame(width: 16, height: 16)
                        .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1) }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Colour for \(metric.title)")
            }
            LuxSwitch(isOn: Binding(get: { on }, set: { wanted in
                withAnimation(DS.Motion.arrive) {
                    if wanted {
                        // Keep the order of the list, so the widget reads the same way Settings does.
                        let chosen = Set(o.wrappedValue.metrics + [metric])
                        o.wrappedValue.metrics = VitalMetric.allCases.filter(chosen.contains)
                    } else {
                        o.wrappedValue.metrics.removeAll { $0 == metric }
                    }
                }
            }), label: metric.title)
            .scaleEffect(0.85)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Span

/// Columns and rows, for kinds that take any span.
struct SpanEditor: View {
    @ObservedObject var board: WidgetBoard
    let id: String

    var body: some View {
        if let placement = board.placement(id), board.stack(containing: id) == nil {
            let span = placement.span
            HStack(spacing: 12) {
                stepper("Width", value: span.columns) { board.resize(id, span: WidgetSpan(columns: span.columns + $0, rows: span.rows)) }
                stepper("Height", value: span.rows) { board.resize(id, span: WidgetSpan(columns: span.columns, rows: span.rows + $0)) }
            }
        }
    }

    private func stepper(_ title: String, value: Int, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary)
            Spacer(minLength: 4)
            button("minus", "Narrower") { withAnimation(DS.Motion.arrive) { change(-1) } }
            Text("\(value)").font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(minWidth: 18)
                .contentTransition(.numericText())
            button("plus", "Wider") { withAnimation(DS.Motion.arrive) { change(1) } }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 34)
        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(value) cells")
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Ink.primary)
                .frame(width: 24, height: 24).background(DS.Ink.fillStrong, in: .circle).contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.9))
        .accessibilityLabel(label)
    }
}

// MARK: - Icon Harmony

struct HarmonyCard: View {
    @ObservedObject var board: WidgetBoard
    @ObservedObject private var icons = DesktopIcons.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SettingRow(title: "Icon Harmony", detail: board.harmony.detail, density: .compact) { EmptyView() }
            Segments(selection: $board.harmony, options: IconHarmony.allCases.map { ($0, $0.title) })
            if board.harmony != .off && !icons.readable {
                Label("Needs Accessibility, to see where Finder’s icons are.", systemImage: "hand.raised")
                    .font(DS.caption).foregroundStyle(DS.Spectrum.surfaces).fixedSize(horizontal: false, vertical: true)
                    .help("Allow Atelier in System Settings, Privacy & Security, Accessibility.")
            }
        }
    }
}
