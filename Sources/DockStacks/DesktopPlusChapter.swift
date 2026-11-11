import AppKit
import SwiftUI

// MARK: - Building blocks

/// A category heading: icon, name, one line of why.
struct DPSection: View {
    let title: String
    let symbol: String
    var detail: String?

    var body: some View { SectionHeader(title, symbol: symbol, detail: detail) }
}

/// Tracks the pointer like LuxSlider, but hands the value over only on release, so an
/// overlay is rebuilt once per drag instead of once per frame.
struct CommitSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var label: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    @State private var draft: Double?

    var body: some View {
        HStack(spacing: 12) {
            LuxSlider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), range: range) {
                if let draft { value = draft }
                draft = nil
            }
            Text(label(draft ?? value)).font(DS.caption).monospacedDigit()
                .foregroundStyle(DS.Ink.tertiary).frame(width: 46, alignment: .trailing)
        }
    }
}

struct DPToggleCard<Extra: View>: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    /// What the stage shows while the pointer rests on the card.
    var preview: StagePreviewSpec? = nil
    /// Whether this Mac can do it. A limit is shown under the switch; an unavailable feature keeps
    /// its switch, dimmed, so a setting carried over from another Mac can still be turned off.
    var availability: FeatureAvailability = .available
    @ViewBuilder var extra: Extra

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: title, detail: detail) {
                    LuxSwitch(isOn: $isOn, label: title)
                        .disabled(!availability.isUsable && !isOn)
                        .opacity(availability.isUsable ? 1 : 0.4)
                }
                AvailabilityNote(availability: availability)
                if isOn { extra.transition(.opacity) }
            }
        }
        .stagePreview(preview)
        .animation(DS.Motion.arrive, value: isOn)
    }
}

extension DPToggleCard where Extra == EmptyView {
    init(title: String, detail: String, isOn: Binding<Bool>, preview: StagePreviewSpec? = nil,
         availability: FeatureAvailability = .available) {
        self.init(title: title, detail: detail, isOn: isOn, preview: preview, availability: availability) { EmptyView() }
    }
}

/// A tool you invoke, with its own global shortcut.
struct DPToolCard: View {
    let action: ToolAction
    let detail: String
    let open: String
    var active = false

    var body: some View {
        Card {
            // Title and text get the full width; the controls sit on their own row below.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: action.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(DS.Ink.accent)
                        .frame(width: 34, height: 34)
                        .background(DS.Ink.fillStrong, in: .rect(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.title).font(DS.title)
                        Text(detail).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    ShortcutRecorder(action: action)
                    Chip(active ? "Close" : open) { action.perform() }
                }
            }
        }
    }
}

// MARK: - Effects chapter

/// The desktop's light. Focus Light, being light itself, glows amber.
private let effectsHue = DS.Spectrum.surfaces

/// The Effects chapter: three heroes macOS has no answer to, then everything else in quiet groups.
struct DesktopPlusEffectsChapter: View {
    @ObservedObject private var effects = Effects.shared
    @ObservedObject private var plus = DesktopPlus.shared
    /// The tint's live amount is published here, not on DesktopPlus: watched, the On/Waiting label keeps up.
    @ObservedObject private var look = DesktopPlus.shared.look

    var body: some View {
        Text("Things macOS does not do. Overlays are click-through, cost nothing while off, and go when you quit.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        heroes
        screen
        AmbientLightCards()
        designer
        presenting
        desktop
        power
        if let notice = plus.notice {
            Text(notice).font(DS.caption).foregroundStyle(.orange.opacity(0.9))
        }
    }

    // MARK: Heroes

    @ViewBuilder private var heroes: some View {
        HeroCard("Focus Light", pitch: "Everything behind the front window steps back into shade.",
                 isOn: $effects.focus, hue: DS.Spectrum.light,
                 readout: "\(Int((effects.focusDim * 100).rounded()))%", readoutCaption: "Shade",
                 preview: .overlay("focus", "Focus Light", isOn: effects.focus) { size in EffectPreviews.focus(effects.focusDim, size: size) }) {
            EffectsFocusPlate(dim: effects.focusDim)
        } controls: {
            HeroSlider(title: "Shade", value: $effects.focusDim, range: 0.2...0.92, hue: DS.Spectrum.light) { "\(Int(($0 * 100).rounded()))%" }
        }

        VStack(alignment: .leading, spacing: DS.Space.s) {
            HeroCard("Notch Shelf", pitch: "Drag files to the top of the screen and they wait there for you.",
                     isOn: $effects.shelf, hue: effectsHue) {
                EffectsShelfPlate()
            }
            AvailabilityNote(availability: DesktopAvailability.notchShelf)
        }

        VStack(alignment: .leading, spacing: DS.Space.s) {
            HeroCard("Menu Bar Hider", pitch: "A divider and an arrow tuck menu bar icons out of sight.",
                     isOn: hider, hue: effectsHue,
                     readout: plus.menuBarHider ? (plus.menuBarCollapsed ? "Tucked" : "Shown") : nil,
                     readoutCaption: plus.menuBarHider ? "Icons" : nil) {
                EffectsHiderPlate()
            } controls: {
                HStack(spacing: DS.Space.m) {
                    Chip(plus.menuBarCollapsed ? "Show Items" : "Tuck Away") { plus.setCollapsed(!plus.menuBarCollapsed) }
                    Text("Icons left of the divider tuck away. ⌘-drag one to its right to keep it showing.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        .help("Public API only. Some system items may not move, and space beside the notch is limited.")
                }
            }
            AvailabilityNote(availability: DesktopAvailability.menuBarHider)
        }
    }

    /// An unavailable hider keeps its switch only to turn a carried-over setting off.
    private var hider: Binding<Bool> {
        Binding(get: { plus.menuBarHider },
                set: { on in if !on || DesktopAvailability.menuBarHider.isUsable { plus.menuBarHider = on } })
    }

    // MARK: Groups

    @ViewBuilder private var screen: some View {
        DPSection(title: "Screen", symbol: "display", detail: "Light and texture over everything.")
        RowGroup {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                SettingRow(title: "Rounded Screen", detail: "Soft corners on every display.", symbol: "rectangle.roundedtop",
                           density: .compact) {
                    Text(effects.rounded < 0.5 ? "Off" : "\(Int(effects.rounded)) pt").font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
                }
                .stagePreview(.toggle("rounded", "Rounded Screen", isOn: effects.rounded > 0.5, region: StageRegion.whole) { snapshot in
                    snapshot.rounded = snapshot.rounded > 0.5 ? 0 : 18
                })
                CommitSlider(value: $effects.rounded, range: 0...32) { $0 < 0.5 ? "Off" : "\(Int($0)) pt" }
                    .padding(.leading, 28).padding(.bottom, DS.Space.s)
            }
            EffectsRow(title: "Vignette", detail: "A gentle darkening toward the edges, like a lens.", symbol: "camera.aperture",
                       isOn: $plus.vignette,
                       preview: .overlay("vignette", "Vignette", isOn: plus.vignette) { _ in EffectPreviews.vignette(plus.vignetteStrength) }) {
                CommitSlider(value: $plus.vignetteStrength, range: 0.1...1)
            }
            EffectsRow(title: "Film Grain", detail: "A still, fine grain over the whole screen.", symbol: "circle.dotted",
                       help: "Drawn once, never animated.", isOn: $plus.grain,
                       preview: .overlay("grain", "Film Grain", isOn: plus.grain) { _ in EffectPreviews.grain(plus.grainStrength) }) {
                CommitSlider(value: $plus.grainStrength, range: 0...1)
            }
            EffectsRow(title: "Night Tint", detail: "Warms the screen on a schedule, fading over 45 minutes.", symbol: "moon",
                       help: "Works beside Night Shift.", isOn: $plus.nightTint,
                       preview: .overlay("night", "Night Tint", isOn: plus.nightTint) { _ in EffectPreviews.nightTint(plus.nightWarmth) }) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("From").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        timePicker($plus.nightStart, label: "Start")
                        Text("to").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        timePicker($plus.nightEnd, label: "End")
                        Spacer()
                        Text(look.night > 0.01 ? "On now" : "Waiting").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    }
                    HStack(spacing: 10) {
                        Text("Warmth").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 52, alignment: .leading)
                        CommitSlider(value: $plus.nightWarmth, range: 0...1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var designer: some View {
        DPSection(title: "Designer Tools", symbol: "ruler", detail: "Open from here, a shortcut, or a hot corner. Escape leaves.")
        RowGroup {
            EffectsRow(title: "Pixel Grid", detail: "Hairlines on whole points, a stronger line every eight.", symbol: "grid",
                       isOn: $plus.grid) {
                Segments(selection: $plus.gridSpacing, options: [(4.0, "4 pt"), (8.0, "8 pt"), (10.0, "10 pt"), (16.0, "16 pt")])
            }
            EffectsToolRow(action: .ruler, detail: "Crosshair with coordinates. Drag to measure; ⌘C copies.",
                           open: "Open", active: plus.measuring)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                EffectsToolRow(action: .colourPicker, detail: "The system loupe. The hex value goes to the clipboard.", open: "Pick")
                if !plus.colours.isEmpty { swatches.padding(.leading, 28).padding(.bottom, DS.Space.s) }
            }
            EffectsToolRow(action: .annotate, detail: "Draw on the screen for a call or a recording.",
                           help: "⌘Z undoes, Escape clears and leaves.", open: "Draw", active: plus.annotating)
        }
    }

    private var swatches: some View {
        HStack(spacing: 6) {
            ForEach(plus.colours, id: \.self) { hex in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hex, forType: .string)
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(atelierHex: hex))
                        .frame(width: 26, height: 26)
                        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
                }
                .buttonStyle(Pressable(scale: 0.92))
                .help("Copy \(hex)")
                .accessibilityLabel("Copy \(hex)")
            }
        }
    }

    @ViewBuilder private var presenting: some View {
        DPSection(title: "Presenting", symbol: "play.rectangle", detail: "For demos, screen shares and recordings.")
        RowGroup {
            EffectsRow(title: "Show Keystrokes", detail: "Shortcuts appear at the bottom of the screen.", symbol: "keyboard",
                       help: "Password fields are never shown. Needs Accessibility.", isOn: $plus.keystrokes,
                       availability: DesktopAvailability.keystrokes) {
                SettingRow(title: "Every key", detail: "Off shows only shortcuts and special keys.", density: .compact) {
                    LuxSwitch(isOn: $plus.keystrokesAll, label: "Every key", tint: effectsHue)
                }
                .help("So ordinary typing stays private.")
            }
            EffectsRow(title: "Shake to Find Cursor", detail: "Shake the pointer and a ring of light closes in on it.",
                       symbol: "cursorarrow.rays", isOn: $plus.cursorHalo)
            EffectsToolRow(action: .findCursor, detail: "Call the ring without shaking.", open: "Show")
            EffectsRow(title: "Click Ripples", detail: "A ripple blooms wherever you click, anywhere.", symbol: "circle.circle",
                       isOn: $effects.ripples)
        }
    }

    @ViewBuilder private var desktop: some View {
        DPSection(title: "Desktop", symbol: "menubar.dock.rectangle")
        RowGroup {
            EffectsRow(title: "Clean Desktop", detail: MacPlatform.major >= 14
                           ? "Hides desktop icons until you show the desktop (F11 or the gesture)."
                           : "Hides desktop icons with Finder’s own setting.", symbol: "eye.slash",
                       apply: MacPlatform.major >= 14 ? nil : ApplyHint(kind: .restart, sentence: "Finder restarts once each way."),
                       isOn: $plus.cleanDesktop) {
                SettingRow(title: "Put icons back when Atelier quits", density: .compact) {
                    LuxSwitch(isOn: $plus.cleanRestoreOnQuit, label: "Put icons back when Atelier quits", tint: effectsHue)
                }
            }
        }
    }

    @ViewBuilder private var power: some View {
        DPSection(title: "Power", symbol: "cup.and.saucer")
        RowGroup {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                SettingRow(title: "Caffeinate", detail: caffeinateDetail, symbol: "cup.and.saucer", density: .compact) { EmptyView() }
                HStack(spacing: 8) {
                    Chip("15 min") { plus.caffeinate(minutes: 15) }
                    Chip("1 hour") { plus.caffeinate(minutes: 60) }
                    Chip("3 hours") { plus.caffeinate(minutes: 180) }
                    Chip("Until I stop") { plus.caffeinate(minutes: nil) }
                    if plus.caffeinateUntil != nil || plus.caffeinateForever { Chip("Stop") { plus.releaseCaffeinate() } }
                }
                .padding(.leading, 28).padding(.bottom, DS.Space.s)
            }
        }
    }

    private var caffeinateDetail: String {
        if plus.caffeinateForever { return "Keeping the display awake until you stop it, or quit." }
        if let until = plus.caffeinateUntil { return "Keeping the display awake until \(until.formatted(date: .omitted, time: .shortened))." }
        return "Keeps the display awake for a while, then lets it sleep."
    }

    private func timePicker(_ minutes: Binding<Double>, label: String) -> some View {
        let date = Binding<Date>(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(minutes.wrappedValue * 60) },
            set: { value in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                minutes.wrappedValue = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            })
        return DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden().datePickerStyle(.field).fixedSize()
    }
}

/// A plain effect as one compact row of a group. Its tuning opens beneath it while it is on.
private struct EffectsRow<Extra: View>: View {
    let title: String
    let detail: String
    var symbol: String?
    /// The long explanation, on hover.
    var help: String?
    var apply: ApplyHint?
    @Binding var isOn: Bool
    var preview: StagePreviewSpec?
    /// Whether this Mac can do it. An unavailable feature keeps its switch, dimmed, so a setting
    /// carried over from another Mac can still be turned off.
    var availability: FeatureAvailability = .available
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SettingRow(title: title, detail: detail, symbol: symbol, density: .compact) {
                HStack(spacing: DS.Space.xs) {
                    if let apply { apply }
                    LuxSwitch(isOn: $isOn, label: title, tint: effectsHue)
                        .disabled(!availability.isUsable && !isOn)
                        .opacity(availability.isUsable ? 1 : 0.4)
                }
            }
            .help(help ?? "")
            if availability.note != nil {
                AvailabilityNote(availability: availability).padding(.leading, symbol == nil ? 0 : 28).padding(.bottom, DS.Space.xs)
            }
            if isOn, Extra.self != EmptyView.self {
                extra
                    .padding(.leading, symbol == nil ? 0 : 28)
                    .padding(.bottom, DS.Space.s)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .stagePreview(preview)
        .animation(DS.Motion.reveal, value: isOn)
    }
}

extension EffectsRow where Extra == EmptyView {
    init(title: String, detail: String, symbol: String? = nil, help: String? = nil, apply: ApplyHint? = nil,
         isOn: Binding<Bool>, preview: StagePreviewSpec? = nil, availability: FeatureAvailability = .available) {
        self.init(title: title, detail: detail, symbol: symbol, help: help, apply: apply, isOn: isOn, preview: preview,
                  availability: availability) { EmptyView() }
    }
}

/// A tool you invoke, as a compact row: its shortcut and its button on the right.
private struct EffectsToolRow: View {
    let action: ToolAction
    let detail: String
    var help: String?
    let open: String
    var active = false

    var body: some View {
        SettingRow(title: action.title, detail: detail, symbol: action.symbol, density: .compact) {
            HStack(spacing: DS.Space.s) {
                ShortcutRecorder(action: action)
                Chip(active ? "Close" : open) { action.perform() }
            }
        }
        .help(help ?? "")
    }
}

// MARK: - Hero plates

/// Three windows; the front one stays in the light and the rest sink into shade. Under the
/// pointer the focus moves from window to window, as it does when you click about.
private struct EffectsFocusPlate: View {
    let dim: Double

    var body: some View {
        HeroLife { live in
            Group {
                if live {
                    TimelineView(.periodic(from: .now, by: 1.3)) { context in
                        scene(lit: Int(context.date.timeIntervalSinceReferenceDate / 1.3) % 3)
                    }
                } else {
                    scene(lit: 1)
                }
            }
        }
    }

    private func scene(lit: Int) -> some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            let frames = [CGRect(x: w * 0.26, y: 30, width: w * 0.26, height: h - 56),
                          CGRect(x: w * 0.42, y: 18, width: w * 0.28, height: h - 40),
                          CGRect(x: w * 0.62, y: 36, width: w * 0.24, height: h - 60)]
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.14, green: 0.16, blue: 0.24), Color(red: 0.2, green: 0.14, blue: 0.2)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.black.opacity(dim * 0.85)
                ForEach(0..<3, id: \.self) { index in
                    let frame = frames[index]
                    PlateWindow(tint: DS.Spectrum.light, focused: index == lit)
                        .overlay { Color.black.opacity(index == lit ? 0 : dim * 0.85).clipShape(.rect(cornerRadius: 7, style: .continuous)) }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(DS.Spectrum.light.opacity(index == lit ? 0.55 : 0), lineWidth: 1)
                        }
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .zIndex(index == lit ? 1 : 0)
                }
            }
            .animation(DS.Motion.arrive, value: lit)
        }
    }
}

/// The top of a screen with a notch. Under the pointer a file rises into the shelf beneath it
/// and settles beside the others; at rest the shelf simply holds two.
private struct EffectsShelfPlate: View {
    var body: some View {
        HeroLife { live in
            HeroClock(live: live, rest: 0) { t in
                GeometryReader { geometry in
                    let w = geometry.size.width, h = geometry.size.height
                    let loop = 2.6
                    let phase = live ? t.truncatingRemainder(dividingBy: loop) / loop : 0
                    // Rises for the first two thirds, eased out; then rests in the shelf.
                    let rise = min(phase / 0.66, 1)
                    let eased = 1 - pow(1 - rise, 3)
                    let start = CGPoint(x: w * 0.22, y: h - 22), end = CGPoint(x: w * 0.5 + 34, y: 52)
                    ZStack(alignment: .topLeading) {
                        LinearGradient(colors: [Color(red: 0.1, green: 0.16, blue: 0.26), Color(red: 0.07, green: 0.09, blue: 0.14)],
                                       startPoint: .top, endPoint: .bottom)
                        // Menu bar and notch.
                        Rectangle().fill(.white.opacity(0.08)).frame(width: w, height: 16)
                        UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                            .fill(.black).frame(width: 96, height: 20).offset(x: w / 2 - 48)
                        // The shelf.
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.black.opacity(0.6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(effectsHue.opacity(0.5), lineWidth: 0.75)
                            }
                            .frame(width: 168, height: 46)
                            .offset(x: w / 2 - 84, y: 28)
                        ForEach(0..<2, id: \.self) { index in
                            file(index == 0 ? "doc.richtext" : "photo")
                                .offset(x: w / 2 - 66 + Double(index) * 34, y: 36)
                        }
                        if live, phase > 0.66 {
                            file("doc.text").offset(x: end.x - 12, y: end.y - 16)
                        }
                        if live, phase <= 0.66 {
                            file("doc.text")
                                .offset(x: start.x + (end.x - start.x) * eased - 12, y: start.y + (end.y - start.y) * eased - 16)
                                .opacity(0.4 + 0.6 * eased)
                        }
                    }
                }
            }
        }
    }

    private func file(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .regular)).foregroundStyle(.white.opacity(0.9))
            .frame(width: 24, height: 30)
    }
}

/// A menu bar. Under the pointer the icons left of the divider tuck away and come back.
private struct EffectsHiderPlate: View {
    private let tucked = ["bolt.horizontal", "music.note", "cloud", "paperclip", "drop"]
    private let kept = ["wifi", "battery.75percent", "magnifyingglass"]

    var body: some View {
        HeroLife { live in
            Group {
                if live {
                    TimelineView(.periodic(from: .now, by: 1.4)) { context in
                        bar(collapsed: Int(context.date.timeIntervalSinceReferenceDate / 1.4) % 2 == 1)
                    }
                } else {
                    bar(collapsed: false)
                }
            }
        }
    }

    private func bar(collapsed: Bool) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.18, blue: 0.3), Color(red: 0.08, green: 0.1, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
            HStack(spacing: 12) {
                Image(systemName: "apple.logo").font(.system(size: 12, weight: .semibold))
                Text("Finder").font(.system(size: 11.5, weight: .bold))
                ForEach(["File", "Edit", "View"], id: \.self) { Text($0).font(.system(size: 11.5)) }
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    ForEach(tucked, id: \.self) { symbol in
                        Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                    }
                }
                .fixedSize()
                .frame(width: collapsed ? 0 : nil, alignment: .trailing)
                .opacity(collapsed ? 0 : 1)
                .clipped()
                Capsule().fill(effectsHue.opacity(0.85)).frame(width: 1.5, height: 14)
                Image(systemName: collapsed ? "chevron.left" : "chevron.right").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(effectsHue)
                    .contentTransition(.symbolEffect(.replace))
                ForEach(kept, id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                }
                Text("9:41").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(.white.opacity(0.1))
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5) }
            .padding(.top, 44)
            .animation(DS.Motion.arrive, value: collapsed)
        }
    }
}

// MARK: - Former Unique chapter, now spread across the app

/// Edge Glow and App Pulse. Shown in Effects, under Ambient.
struct AmbientLightCards: View {
    @ObservedObject private var effects = Effects.shared
    @ObservedObject private var plus = DesktopPlus.shared

    var body: some View {
        DPSection(title: "Ambient", symbol: "sun.haze", detail: "Light that answers what you do.")
        RowGroup {
            // stagePreview: a soft rim around the replica screen in the front app's colour.
            EffectsRow(title: "Edge Glow", detail: "A soft rim in the colour of the app you are in.", symbol: "rays",
                       help: "It changes only when you switch apps.", isOn: $plus.edgeGlow,
                       preview: .overlay("edgeglow", "Edge Glow", isOn: plus.edgeGlow) { _ in EffectPreviews.edgeGlow(DS.Ink.accent) }) {
                CommitSlider(value: $plus.edgeGlowWidth, range: 6...40) { "\(Int($0)) pt" }
            }
            // stagePreview: the replica screen edge flashing once in an app colour.
            EffectsRow(title: "App Pulse", detail: "The screen edge flashes in an app’s colour as you switch to it.",
                       symbol: "waveform.path.ecg", isOn: $effects.pulse)
        }
    }
}

/// For the Dock chapter.
struct DockGlowCard: View {
    @ObservedObject private var effects = Effects.shared
    var body: some View {
        // stagePreview: light pooling under the replica Dock.
        DPToggleCard(title: "Dock Glow", detail: "Light pools under your real Dock.", isOn: $effects.dockGlow,
                     availability: DesktopAvailability.dockGlow)
    }
}

/// For the Menu Bar chapter.
struct DayLineCard: View {
    @ObservedObject private var effects = Effects.shared
    var body: some View {
        // stagePreview: a hairline under the replica menu bar filling to the current time of day.
        DPToggleCard(title: "Day Line", detail: "A hairline under the menu bar fills as the day passes.", isOn: $effects.dayLine)
    }
}

/// For the Toolbox, beside timers and focus sessions.
struct FocusIslandCard: View {
    @ObservedObject private var effects = Effects.shared
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                // stagePreview: a countdown pill beside the replica notch.
                SettingRow(title: "Focus Island", detail: "A countdown beside the notch. The screen pulses when time is up.") { EmptyView() }
                AvailabilityNote(availability: DesktopAvailability.focusIsland)
                HStack(spacing: 8) {
                    Chip("15 min") { effects.startFocus(minutes: 15) }
                    Chip("25 min") { effects.startFocus(minutes: 25) }
                    Chip("50 min") { effects.startFocus(minutes: 50) }
                    if effects.focusEnd != nil { Chip("Stop") { effects.focusEnd = nil } }
                }
            }
        }
    }
}

/// Remove with `Chapter.unique` on merge. Until then it shows the moved pieces, so the
/// old chapter still works in this copy.

extension Color {
    /// "#RRGGBB" only. Anything else is clear.
    init(atelierHex hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = Int(digits, radix: 16) else { self = .clear; return }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Stage replica

/// The new desktop overlays, redrawn on the stage's replica screen at its scale.
struct DesktopPlusReplica: View {
    let size: CGSize
    @ObservedObject private var plus = DesktopPlus.shared
    @ObservedObject private var look = DesktopPlus.shared.look

    var body: some View {
        let scale = size.width / 1728
        ZStack {
            if plus.nightTint {
                // Shown at night strength even by day, so the warmth can be judged here.
                Color(red: 1, green: 0.52 - plus.nightWarmth * 0.12, blue: 0.12)
                    .opacity(max(look.night, 0.8) * (0.08 + plus.nightWarmth * 0.22))
                    .transition(.opacity)
            }
            if plus.vignette { VignetteView(strength: plus.vignetteStrength).transition(.opacity) }
            if plus.grain, let image = GrainTexture.image { GrainView(image: image, strength: plus.grainStrength).transition(.opacity) }
            if plus.grid { PixelGrid(spacing: max(plus.gridSpacing * scale * 2, 4), scale: 2).transition(.opacity) }
            if plus.edgeGlow { EdgeGlowRing(look: look, width: max(plus.edgeGlowWidth * scale * 1.4, 3)).transition(.opacity) }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .animation(DS.Motion.arrive, value: plus.nightTint)
        .animation(DS.Motion.arrive, value: plus.vignette)
        .animation(DS.Motion.arrive, value: plus.grain)
        .animation(DS.Motion.arrive, value: plus.grid)
        .animation(DS.Motion.arrive, value: plus.edgeGlow)
    }
}
