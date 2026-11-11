import AppKit
import DockCore
import SwiftUI

// MARK: - Screen shape cards
//
// Display & Appearance, after the stock display switches: Notch-Free as a hero with a miniature
// of the screen (the notch in the menu bar, or a black band above it), the Display Modes picker
// with every hidden mode and refresh, and HiDPI Anywhere with Virtual Screens. Every mode change
// made here shows the same "Keep this mode?" countdown and reverts by itself after 15 seconds.

struct DisplayModesCards: View {
    var body: some View {
        SectionHeader("Screen Shape", symbol: "rectangle.dashed",
                      detail: "Past System Settings: hide the notch, every hidden mode and refresh, HiDPI on any monitor.",
                      hue: DS.Spectrum.surfaces)
        NotchFreeCard()
        DisplayModesPickerCard()
        VirtualScreensCard()
    }
}

// MARK: - Keep this mode?

/// The probation banner: a ring running down 15 seconds, Keep and Revert.
struct KeepModeBanner: View {
    @ObservedObject private var engine = NotchFree.shared
    var hue: Color = DS.Spectrum.surfaces

    var body: some View {
        if case .pending(let previous, let applied, _) = engine.revert {
            // The buttons move under the sentence when the card is narrow, never squeezing it.
            AdaptiveRowLayout(spacing: DS.Space.m, hasSymbol: true, minText: 150) {
                ZStack {
                    Circle().stroke(DS.Ink.track, lineWidth: 3)
                    Circle().trim(from: 0, to: Double(engine.secondsLeft) / ModeRevertMachine.seconds)
                        .stroke(hue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: engine.secondsLeft)
                    Text("\(engine.secondsLeft)").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(DS.Ink.primary).contentTransition(.numericText())
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep this mode?").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    Text("\(applied.sizeText) at \(applied.refreshText). Back to \(previous.sizeText) in \(engine.secondsLeft) s.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Revert") { engine.revertNow() }
                    .buttonStyle(ModePillStyle(prominent: false, hue: hue))
                Button("Keep") { engine.keep() }
                    .buttonStyle(ModePillStyle(prominent: true, hue: hue))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.m)
            .background(hue.opacity(0.1), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(hue.opacity(0.45), lineWidth: 0.75)
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Keep this mode? Reverting in \(engine.secondsLeft) seconds")
        }
    }
}

/// A small capsule button: filled in the hue when prominent, a hairline otherwise.
private struct ModePillStyle: ButtonStyle {
    var prominent: Bool
    var hue: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(prominent ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fill), in: .capsule)
            .overlay { Capsule().strokeBorder(prominent ? Color.white.opacity(0.2) : DS.Ink.edge, lineWidth: 0.5) }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DS.Motion.touch, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: - Notch-Free

struct NotchFreeCard: View {
    @ObservedObject private var engine = NotchFree.shared
    private let hue = DS.Spectrum.surfaces

    var body: some View {
        let availability = engine.availability
        let pair = engine.pair
        let shown = engine.isNotchFreeNow ? pair?.free : pair?.notched
        HeroCard("Notch-Free",
                 pitch: "The screen becomes 16:10 below the notch: a true black band hides it and the menu bar moves under it. Same size, same sharpness.",
                 isOn: Binding(get: { engine.enabled }, set: { engine.setEnabled($0) }).displayCompatGated(availability),
                 hue: hue,
                 readout: shown.map { "\($0.width)×\($0.height)" },
                 readoutCaption: shown.map { "\($0.aspectName) · \($0.refreshText)" }) {
            NotchMiniature(on: engine.isNotchFreeNow, pair: pair, hue: hue)
                .displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                KeepModeBanner(hue: hue)
                if let pair {
                    Text("\(pair.notched.sizeText) with the notch, \(pair.free.sizeText) without. Changing the size in System Settings keeps it below the notch.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let error = engine.lastError {
                    AvailabilityNote(availability: .limited(error))
                }
            }
        }
        .animation(DS.Motion.reveal, value: engine.revert)
        .onAppear { engine.refresh() }
    }
}

/// A miniature of the built-in screen. Off: the menu bar runs either side of the notch. On: a
/// black band the notch disappears into, the menu bar under it.
private struct NotchMiniature: View {
    let on: Bool
    let pair: (notched: DisplayModeInfo, free: DisplayModeInfo)?
    let hue: Color

    var body: some View {
        // Proportions from the real modes; a 14" MacBook Pro's when the display cannot say.
        let notchedH = Double(pair?.notched.height ?? 1117)
        let band = pair.map { NotchFreeLogic.bandPoints(notched: $0.notched, notchFree: $0.free) } ?? 37
        let aspect = Double(pair?.notched.width ?? 1728) / notchedH
        GeometryReader { geometry in
            let height = geometry.size.height - 28
            let width = min(height * aspect, geometry.size.width - 40)
            let h = width / aspect
            let bandH = max(4, h * band / notchedH)
            let menuH = max(5, h * 0.028)
            let notchW = width * 0.108
            ZStack(alignment: .top) {
                // The picture: a wallpaper in the family's light.
                LinearGradient(colors: [hue.opacity(0.55), Color(red: 0.2, green: 0.16, blue: 0.42), Color(red: 0.06, green: 0.07, blue: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 0) {
                    // On: the band, true black, the notch inside it.
                    Color.black.frame(height: on ? bandH : 0)
                    // The menu bar: under the band, or on the top edge either side of the notch.
                    ZStack {
                        Rectangle().fill(.white.opacity(0.16))
                        HStack(spacing: 4) {
                            Image(systemName: "apple.logo").font(.system(size: menuH * 0.7))
                            ForEach(0..<3, id: \.self) { _ in Capsule().frame(width: width * 0.04, height: menuH * 0.32) }
                            Spacer(minLength: 0)
                            ForEach(0..<4, id: \.self) { _ in Circle().frame(width: menuH * 0.42, height: menuH * 0.42) }
                        }
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                    }
                    .frame(height: on ? menuH : bandH)
                    Spacer(minLength: 0)
                }
                // The notch itself, always the same physical size.
                UnevenRoundedRectangle(bottomLeadingRadius: bandH * 0.45, bottomTrailingRadius: bandH * 0.45, style: .continuous)
                    .fill(.black)
                    .frame(width: notchW, height: bandH)
                    .overlay {
                        // Where it is, once it is invisible: a faint outline in the band.
                        UnevenRoundedRectangle(bottomLeadingRadius: bandH * 0.45, bottomTrailingRadius: bandH * 0.45, style: .continuous)
                            .strokeBorder(.white.opacity(on ? 0.08 : 0), lineWidth: 0.5)
                    }
            }
            .frame(width: width, height: h)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 3, bottomTrailingRadius: 3,
                                              topTrailingRadius: 8, style: .continuous))
            .overlay {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 3, bottomTrailingRadius: 3,
                                       topTrailingRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1.5)
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 4)
            .animation(DS.Motion.gentle(DS.Motion.arrive), value: on)
        }
        .accessibilityElement()
        .accessibilityLabel(on ? "Screen below the notch, with a black band" : "Screen with the notch in the menu bar")
    }
}

// MARK: - Display Modes

struct DisplayModesPickerCard: View {
    @ObservedObject private var engine = NotchFree.shared
    @State private var expanded: Set<String> = []
    @Namespace private var chips
    private let hue = DS.Spectrum.surfaces

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    // The title and the current mode share a line; the sentence gets the card's width.
                    WrapStack(spacing: DS.Space.m, lineSpacing: 2) {
                        Text("Display Modes").font(DS.title).foregroundStyle(DS.Ink.primary)
                        if let current = engine.current {
                            Text("\(current.sizeText) · \(current.refreshText)").font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
                        }
                    }
                    Text("Every mode the display offers, hidden ones too, at every refresh rate.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if engine.displays.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(engine.displays) { display in
                                displayChip(display)
                            }
                        }
                    }
                }
                KeepModeBanner(hue: hue)
                SettingRow(title: "Show low-resolution duplicates",
                           detail: "The 1× twins of scaled sizes: the same pixels without HiDPI.", density: .compact) {
                    LuxSwitch(isOn: $engine.showDuplicates, label: "Show low-resolution duplicates", tint: hue)
                }
                let groups = engine.groups
                if groups.isEmpty {
                    Text("No modes to show.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
                ForEach(groups) { group in
                    section(group, open: isOpen(group, groups: groups))
                }
                if let error = engine.lastError {
                    AvailabilityNote(availability: .limited(error))
                }
            }
        }
        .animation(DS.Motion.reveal, value: engine.revert)
        .animation(DS.Motion.reveal, value: expanded)
        .onAppear { engine.refresh() }
    }

    /// The section holding the current mode starts open; the others open on a click.
    private func isOpen(_ group: DisplayAspectGroup, groups: [DisplayAspectGroup]) -> Bool {
        expanded.contains(group.id) != (group.id == groups.first?.id)
    }

    private func displayChip(_ display: NotchFree.Display) -> some View {
        let selected = display.id == engine.selectedDisplay
        return Button {
            withAnimation(DS.Motion.settle) { engine.select(display.id) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: display.builtIn ? "laptopcomputer" : "display")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(selected ? hue : DS.Ink.secondary)
                Text(display.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(selected ? DS.Ink.primary : DS.Ink.secondary)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(DS.Ink.fillStrong)
                        .matchedGeometryEffect(id: "display", in: chips)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? hue.opacity(0.55) : DS.Ink.hairline, lineWidth: selected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func section(_ group: DisplayAspectGroup, open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(DS.Ink.tertiary)
                    Eyebrow(text: group.name)
                    Text("\(group.resolutions.count)").font(DS.Typo.badge).foregroundStyle(DS.Ink.tertiary)
                    Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(group.resolutions.count) sizes")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                VStack(spacing: 2) {
                    ForEach(group.resolutions) { resolution in row(resolution) }
                }
                .transition(.opacity)
            }
        }
    }

    private func row(_ resolution: DisplayResolution) -> some View {
        let isCurrent = engine.current.map { $0.width == resolution.width && $0.height == resolution.height
            && $0.pixelWidth == resolution.pixelWidth } ?? false
        return AdaptiveRowLayout(spacing: 10, hasSymbol: false, minText: 150) {
            Button {
                if let mode = DisplayModeGrouping.pick(resolution, keeping: engine.current) { engine.choose(mode) }
            } label: {
                HStack(spacing: 6) {
                    // Verbatim: a size, never "2,056" with the locale's grouping.
                    Text(verbatim: "\(resolution.width) × \(resolution.height)").font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                        .monospacedDigit().foregroundStyle(isCurrent ? DS.Ink.primary : DS.Ink.secondary)
                    badge(resolution.isHiDPI ? "HiDPI" : "1×", lit: resolution.isHiDPI)
                    if resolution.isDefault { badge("Default", lit: false) }
                    if resolution.isNative { badge("Native", lit: false) }
                }
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.98))
            .accessibilityLabel("\(resolution.width) by \(resolution.height)\(resolution.isHiDPI ? ", HiDPI" : "")")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            WrapStack(spacing: 4, lineSpacing: 4) {
                ForEach(resolution.modes) { mode in refreshChip(mode) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isCurrent ? hue.opacity(0.1) : .clear, in: .rect(cornerRadius: 8, style: .continuous))
    }

    private func refreshChip(_ mode: DisplayModeInfo) -> some View {
        let selected = engine.current == mode
        let text = mode.refreshRate > 0 ? mode.refreshText.replacingOccurrences(of: " Hz", with: "") : "—"
        return Button { engine.choose(mode) } label: {
            Text(text).font(.system(size: 10.5, weight: selected ? .bold : .medium)).monospacedDigit()
                .lineLimit(1).fixedSize()
                .foregroundStyle(selected ? Color.black.opacity(0.85) : DS.Ink.secondary)
                .padding(.horizontal, 7).frame(height: 20)
                .background(selected ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fill), in: .capsule)
                .overlay { Capsule().strokeBorder(selected ? .clear : DS.Ink.hairline, lineWidth: 0.5) }
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.94))
        .help(mode.signature)
        .accessibilityLabel(mode.refreshText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func badge(_ text: String, lit: Bool) -> some View {
        Text(text.uppercased()).font(DS.Typo.badge).tracking(0.6)
            .foregroundStyle(lit ? hue : DS.Ink.tertiary)
            .padding(.horizontal, 5).frame(height: 15)
            .background((lit ? hue.opacity(0.12) : DS.Ink.fill), in: .rect(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - HiDPI Anywhere and Virtual Screens

struct VirtualScreensCard: View {
    @ObservedObject private var engine = VirtualDisplays.shared
    @State private var addSize = "1920x1080"
    @State private var addRefresh = 60.0
    @State private var addHiDPI = true
    private let hue = DS.Spectrum.surfaces

    private static let presets = ["1280x720", "1440x900", "1920x1080", "1920x1200", "2560x1440", "3840x2160", "1080x1920", "1170x2532"]
    private static let rates = [30.0, 60.0, 120.0]

    var body: some View {
        let availability = engine.availability
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    WrapStack(spacing: 8, lineSpacing: 4) {
                        Text("HiDPI Anywhere").font(DS.title).foregroundStyle(DS.Ink.primary)
                        HeroBadge(text: "Beyond macOS", hue: hue)
                    }
                    Text("Retina-sharp text and any scaled size on a monitor macOS calls low resolution, plus headless screens for sharing and recording.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                AvailabilityNote(availability: availability)
                monitorsSection
                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                screensSection
                if let error = engine.lastError {
                    AvailabilityNote(availability: .limited(error))
                }
            }
            .disabled(!availability.isUsable)
        }
        .onAppear { engine.refreshMonitors() }
    }

    // Monitors

    @ViewBuilder private var monitorsSection: some View {
        let externals = engine.monitors.filter { !$0.builtIn }
        Eyebrow(text: "Monitors")
        if externals.isEmpty {
            Text("Connect a monitor to give it HiDPI. The built-in display is already Retina.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(externals) { monitor in monitorRow(monitor) }
    }

    private func monitorRow(_ monitor: VirtualDisplays.Monitor) -> some View {
        let active = engine.hiDPISpec(for: monitor)
        return AdaptiveRowLayout(spacing: 10, hasSymbol: true, minText: 150) {
            Image(systemName: "display").font(.system(size: 15, weight: .medium))
                .foregroundStyle(active != nil ? hue : DS.Ink.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).fixedSize(horizontal: false, vertical: true)
                Text(monitorDetail(monitor, active: active)).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                ForEach(HiDPIMath.scaledSizes(native: (monitor.nativeWidth, monitor.nativeHeight)), id: \.width) { size in
                    Button(String("Looks like \(size.width) × \(size.height)")) {
                        engine.enableHiDPI(on: monitor, points: size)
                    }
                }
            } label: {
                Text(active.map { "\($0.width) × \($0.height)" } ?? "HiDPI…").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(monitor.nativeWidth == 0)
            if let active, engine.live[active.id] == nil {
                Button("Start") { engine.start(active.id) }
                    .buttonStyle(ModePillStyle(prominent: false, hue: hue))
            }
            if active != nil {
                Button("Off") { engine.disableHiDPI(on: monitor) }
                    .buttonStyle(ModePillStyle(prominent: false, hue: hue))
            }
        }
        .padding(.vertical, 4)
    }

    private func monitorDetail(_ monitor: VirtualDisplays.Monitor, active: VirtualDisplays.Spec?) -> String {
        var parts = ["\(monitor.nativeWidth) × \(monitor.nativeHeight)"]
        if let ppi = monitor.ppi { parts.append("\(Int(ppi.rounded())) ppi\(monitor.lowPPI ? ", low" : "")") }
        if let active { parts.append("HiDPI on, mirrors a \(active.width * 2) × \(active.height * 2) screen") }
        return parts.joined(separator: " · ")
    }

    // Virtual screens

    @ViewBuilder private var screensSection: some View {
        let screens = engine.specs.filter { $0.mirrorTarget == nil }
        HStack {
            Eyebrow(text: "Virtual Screens")
            Spacer(minLength: 0)
            if !screens.isEmpty {
                Button("Remove All") { for spec in screens { engine.remove(spec.id) } }
                    .buttonStyle(ModePillStyle(prominent: false, hue: hue))
            }
        }
        ForEach(screens) { spec in screenRow(spec) }
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(Self.presets, id: \.self) { preset in
                        Button(preset.replacingOccurrences(of: "x", with: " × ")) { addSize = preset }
                    }
                } label: {
                    Text(addSize.replacingOccurrences(of: "x", with: " × ")).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                .menuStyle(.borderlessButton).fixedSize()
                Segments(selection: $addRefresh, options: Self.rates.map { ($0, "\(Int($0)) Hz") })
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("HiDPI").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    LuxSwitch(isOn: $addHiDPI, label: "HiDPI", tint: hue)
                }
                Spacer(minLength: 0)
                Button("Add Screen") {
                    if let size = HiDPIMath.parseSize(addSize) {
                        engine.add(width: size.width, height: size.height, refreshRate: addRefresh, hiDPI: addHiDPI)
                    }
                }
                .buttonStyle(ModePillStyle(prominent: true, hue: hue))
            }
        }
        Text("A virtual screen lives while Atelier runs. Quitting removes it and puts every monitor back; the next launch brings it back.")
            .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    private func screenRow(_ spec: VirtualDisplays.Spec) -> some View {
        let up = engine.live[spec.id] != nil
        return AdaptiveRowLayout(spacing: 10, hasSymbol: true, minText: 150) {
            Image(systemName: "rectangle.dashed").font(.system(size: 15, weight: .medium))
                .foregroundStyle(up ? hue : DS.Ink.tertiary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "\(spec.width) × \(spec.height) · \(DisplayModeInfo.refreshText(spec.refreshRate))\(spec.hiDPI ? " · HiDPI" : "")\(up ? "" : " · not running")")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !up {
                Button("Start") { engine.start(spec.id) }
                    .buttonStyle(ModePillStyle(prominent: false, hue: hue))
            }
            Button { engine.remove(spec.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Ink.secondary)
                    .frame(width: 24, height: 24).background(DS.Ink.fill, in: .circle)
            }
            .buttonStyle(Pressable(scale: 0.92))
            .accessibilityLabel("Remove \(spec.name)")
        }
        .padding(.vertical, 2)
    }
}
