import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

/// The Toolbox chapter: one-shot tools for text, files, devices and time.
/// Two heroes lead (what a stock Mac cannot do in one keystroke), the rest are quiet tool cards.
struct ToolboxChapter: View {
    private let hue = DS.Spectrum.sensors

    var body: some View {
        Text("Tools that do one thing well. Each runs only when you ask, and most take a global shortcut.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
        SectionHeader("Off the screen", symbol: "sparkles",
                      detail: "Read text off any pixel, record the screen with every click shown.", hue: hue)
        TextGrabCard()
        RecorderCard()
        SectionHeader("Text & clipboard", symbol: "doc.on.clipboard", hue: hue)
        ClipboardCard()
        QuickLookCard()
        SectionHeader("Files", symbol: "doc.on.doc", hue: hue)
        RenameCard()
        ImageConvertCard()
        FinderScriptsCard()
        SectionHeader("Devices", symbol: "display.2",
                      detail: "Resolution and sound, switched in a click.", hue: hue)
        DisplayModesCard()
        AudioCard()
        Text("Brightness and the battery charge limit have no public API, so Atelier does not offer them. Battery health is in the Battery widget.")
            .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.xs)
        SectionHeader("Time & focus", symbol: "timer", hue: hue)
        TimersCard()
        FocusIslandCard()
        FocusSessionCard()
    }
}

// MARK: - Capture link

/// In Capture: where the Screen Recorder and Text Grab live, one click away.
struct ToolsCaptureLink: View {
    @State private var hover = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .studioChapter, object: Chapter.toolbox.rawValue)
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "record.circle").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Spectrum.sensors)
                    .frame(width: 32, height: 32)
                    .background(DS.Spectrum.sensors.opacity(0.13), in: .rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record the screen, grab text").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    Text("Screen Recorder and Text Grab live in Toolbox.").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Toolbox").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hover ? DS.Spectrum.sensors : DS.Ink.tertiary)
            }
            .padding(.horizontal, DS.Inset.card).padding(.vertical, DS.Space.m)
            .background { CardSurface(style: .standard) }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Spectrum.sensors.opacity(hover ? 0.45 : 0), lineWidth: 0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.99))
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .accessibilityLabel("Open Toolbox: Screen Recorder and Text Grab")
    }
}

// MARK: - Tool hero

/// A hero for a tool you run rather than switch: the plate runs it, a pill runs it, the
/// shortcut sits beside the pill. Lit in the family's hue while the tool is working.
private struct ToolsHero<Plate: View, Readout: View, Controls: View>: View {
    let title: String
    let pitch: String
    let action: ToolAction
    let actionTitle: String
    var active: Bool
    var hue: Color
    var availability: FeatureAvailability = .available
    var run: () -> Void
    @ViewBuilder var plate: (_ live: Bool) -> Plate
    @ViewBuilder var readout: Readout
    @ViewBuilder var controls: Controls
    @State private var hover = false
    @State private var sweeps = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: run) { plateView }
                .buttonStyle(Pressable(scale: 0.985))
                .disabled(!availability.isUsable)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                        Text(pitch).font(DS.body).foregroundStyle(DS.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ShortcutRecorder(action: action)
                    ToolsRunPill(title: actionTitle, hue: hue, active: active, action: run)
                        .disabled(!availability.isUsable)
                        .opacity(availability.isUsable ? 1 : 0.45)
                }
                controls
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, 14)
            .padding(.bottom, DS.Space.s)
        }
        .padding(DS.Inset.plate)
        .background { CardSurface(style: active ? .lit(hue) : .standard) }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(hover ? 0.1 : 0), lineWidth: 0.5)
        }
        .animation(DS.Motion.reveal, value: active)
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .onChange(of: active) { _, on in if on { sweeps += 1 } }
        .accessibilityElement(children: .contain)
    }

    private var plateView: some View {
        ZStack(alignment: .topLeading) {
            RadialGradient(colors: [hue.opacity(active ? 0.45 : 0.2), .clear],
                           center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: 260)
            HeroLife { live in plate(live) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HeroBadge(text: "Beyond macOS", hue: hue).padding(10)
            VStack(alignment: .trailing, spacing: 0) { readout }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(height: 148)
        .background(Color(red: 0.06, green: 0.065, blue: 0.08))
        .overlay { SweepLight(trigger: sweeps) }
        .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) { AvailabilityNote(availability: availability).padding(10) }
    }
}

/// The hero's own button: the family's light, filled while the tool is running.
private struct ToolsRunPill: View {
    let title: String
    let hue: Color
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.black.opacity(0.85) : DS.Ink.primary)
                .padding(.horizontal, 16).frame(minWidth: 76).frame(height: 30)
                .background(active ? AnyShapeStyle(hue) : AnyShapeStyle(hue.opacity(0.2)), in: .capsule)
                .overlay { Capsule().strokeBorder(hue.opacity(active ? 0 : 0.5), lineWidth: 0.75) }
                .contentShape(Capsule())
                .contentTransition(.opacity)
        }
        .buttonStyle(Pressable(scale: 0.95))
        .animation(DS.Motion.hover, value: active)
    }
}

/// The readout block every tool hero ends its plate with.
private struct ToolsReadout: View {
    let value: Text
    let caption: String

    var body: some View {
        value.font(DS.Typo.readout).foregroundStyle(.white).contentTransition(.numericText())
        Text(caption.uppercased()).font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
    }
}

/// A plain tool: a glyph tile in the family's light, a title, two lines at most, its control.
private struct ToolsKitCard<Trailing: View, Content: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var style: CardStyle = .standard
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        Card(style: style) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Spectrum.sensors)
                        .frame(width: 32, height: 32)
                        .background(DS.Spectrum.sensors.opacity(0.13), in: .rect(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(DS.title).foregroundStyle(DS.Ink.primary)
                        Text(detail).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
                content
            }
        }
    }
}

/// A one-line status under a tool, never truncated.
private struct ToolsNote: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text).font(DS.caption)
            .foregroundStyle(warning ? Color.orange.opacity(0.9) : DS.Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Text Grab

private struct TextGrabCard: View {
    @ObservedObject private var grab = TextGrab.shared

    private var words: Int { grab.lastText.split(whereSeparator: \.isWhitespace).count }

    var body: some View {
        ToolsHero(title: "Text Grab",
                  pitch: "Drag over any text on screen, even in a picture or a video. Read on this Mac with Vision, then copied.",
                  action: .textGrab, actionTitle: grab.working ? "Reading…" : "Grab",
                  active: grab.working, hue: DS.Spectrum.sensors, run: { ToolAction.textGrab.perform() }) { live in
            ToolsGrabPlate(live: live, working: grab.working)
        } readout: {
            if grab.lastText.isEmpty {
                ToolsReadout(value: Text("OCR"), caption: "On this Mac")
            } else {
                ToolsReadout(value: Text("\(words)"), caption: words == 1 ? "Word last grab" : "Words last grab")
            }
        } controls: {
            if let notice = grab.notice { ToolsNote(text: notice) }
        }
    }
}

/// A window of text in miniature with a selection marquee over two lines and the words
/// lifting into a clipboard chip. Still at rest; under the pointer the marquee sweeps.
private struct ToolsGrabPlate: View {
    let live: Bool
    let working: Bool
    private let hue = DS.Spectrum.sensors
    private let lines: [Double] = [0.92, 0.78, 0.86, 0.64, 0.82, 0.5]

    var body: some View {
        HeroClock(live: live, rest: 0.9) { t in
            GeometryReader { geometry in
                let size = geometry.size
                let window = CGRect(x: size.width * 0.18, y: 30, width: size.width * 0.44, height: size.height - 48)
                let lineHeight = 7.0, gap = 9.0
                let phase = live ? (sin(t * 1.6) + 1) / 2 : 1
                let marquee = CGRect(x: window.minX + 10, y: window.minY + 22 + (lineHeight + gap) * 1 - 5,
                                     width: (window.width - 20) * (0.35 + 0.65 * phase), height: (lineHeight + gap) * 2 + 1)
                ZStack(alignment: .topLeading) {
                    // The window.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                        .frame(width: window.width, height: window.height)
                        .offset(x: window.minX, y: window.minY)
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.22)).frame(width: 5, height: 5) }
                    }
                    .offset(x: window.minX + 8, y: window.minY + 7)
                    ForEach(lines.indices, id: \.self) { index in
                        Capsule().fill(.white.opacity(index == 1 || index == 2 ? 0.55 : 0.2))
                            .frame(width: (window.width - 20) * lines[index], height: lineHeight)
                            .offset(x: window.minX + 10, y: window.minY + 22 + (lineHeight + gap) * Double(index))
                    }
                    // The marquee.
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(hue.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(hue, style: StrokeStyle(lineWidth: 1, dash: [4, 3], dashPhase: live ? t * 14 : 0))
                        }
                        .frame(width: marquee.width, height: marquee.height)
                        .offset(x: marquee.minX, y: marquee.minY)
                    // The words, lifted out into a clipboard chip.
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(hue.opacity(0.9))
                        .offset(x: window.maxX + 12, y: size.height / 2 - 8)
                    HStack(spacing: 6) {
                        Image(systemName: working ? "text.viewfinder" : "doc.on.clipboard.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(hue)
                        Text("Aa").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(.black.opacity(0.4), in: .capsule)
                    .overlay { Capsule().strokeBorder(hue.opacity(0.55), lineWidth: 0.75) }
                    .opacity(live ? 0.55 + 0.45 * phase : 1)
                    .offset(x: window.maxX + 34, y: size.height / 2 - 14)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Clipboard

private struct ClipboardCard: View {
    @ObservedObject private var clipboard = ClipboardTools.shared
    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 6)]

    var body: some View {
        ToolsKitCard(symbol: "doc.plaintext", title: "Clipboard Actions", detail: "Rewrites the text you copied, as plain text.") {
            ShortcutRecorder(action: .plainClipboard)
        } content: {
            let preview = clipboard.preview
            Text(preview.isEmpty ? "The clipboard has no text." : preview)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DS.Ink.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(Color.black.opacity(0.22), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(TextTransform.allCases) { transform in
                    Chip(transform.title) { clipboard.run(transform) }
                }
            }
            if let notice = clipboard.notice { ToolsNote(text: notice) }
        }
    }
}

// MARK: - Quick Look

private struct QuickLookCard: View {
    @State private var targeted = false
    @State private var notice: String?

    var body: some View {
        ToolsKitCard(symbol: "eye", title: "Quick Look Anything", detail: "Drop files here, or preview the clipboard: files, an image or text.") {
            ShortcutRecorder(action: .quickLookClipboard)
        } content: {
            HStack(spacing: 8) {
                Chip("Clipboard") { notice = QuickLookTool.previewClipboard() ? nil : "Nothing to preview." }
                Chip("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    NSApp.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK { QuickLookTool.preview(panel.urls) }
                }
                DropTile(symbol: "eye", text: "Drop to preview", targeted: $targeted) { QuickLookTool.preview($0) }
            }
            if let notice { ToolsNote(text: notice) }
        }
    }
}

/// A dashed drop target that lights up while a file hovers over it. Tint only, nothing moves.
struct DropTile: View {
    let symbol: String
    let text: String
    @Binding var targeted: Bool
    var hue: Color = DS.Spectrum.sensors
    let onDrop: ([URL]) -> Void

    init(symbol: String, text: String, targeted: Binding<Bool>, hue: Color = DS.Spectrum.sensors, onDrop: @escaping ([URL]) -> Void) {
        self.symbol = symbol
        self.text = text
        self._targeted = targeted
        self.hue = hue
        self.onDrop = onDrop
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(targeted ? DS.Ink.primary : DS.Ink.secondary)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(targeted ? hue.opacity(0.16) : .clear, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(targeted ? hue : DS.Ink.edge, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .animation(DS.Motion.hover, value: targeted)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let decoded = URL(dataRepresentation: url, relativeTo: nil) { urls.append(decoded) }
                }
                await MainActor.run { onDrop(urls) }
            }
            return true
        }
        .accessibilityLabel(text)
    }
}

// MARK: - Recorder

private struct RecorderCard: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    /// ScreenCaptureKit writes files itself (SCRecordingOutput) only from macOS 15.
    private let availability = FeatureAvailability.needsMacOS(15)

    var body: some View {
        ToolsHero(title: "Screen Recorder",
                  pitch: "The main display to Movies at 60 fps, with clicks and keys shown. Atelier stays out of the picture.",
                  action: .recordScreen, actionTitle: recorder.recording ? "Stop" : "Record",
                  active: recorder.recording, hue: DS.Spectrum.sensors, availability: availability,
                  run: { recorder.toggle() }) { live in
            ToolsRecordPlate(live: live, recording: recorder.recording, clicks: recorder.showClicks, keys: recorder.showKeys)
        } readout: {
            if let start = recorder.startedAt {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(DS.Typo.readout).foregroundStyle(.white)
                Text("RECORDING").font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
            } else {
                ToolsReadout(value: Text("60"), caption: "fps · main display")
            }
        } controls: {
            if !recorder.recording, availability.isUsable {
                RowGroup {
                    SettingRow(title: "Clicks While Recording", detail: "A ring at each click, in the recording only.",
                               symbol: "cursorarrow.click", density: .compact) {
                        LuxSwitch(isOn: $recorder.showClicks, label: "Clicks While Recording", tint: DS.Spectrum.sensors)
                    }
                    SettingRow(title: "Keystrokes While Recording", detail: "Shows keystrokes only while recording. Needs Accessibility.",
                               symbol: "keyboard", density: .compact) {
                        LuxSwitch(isOn: $recorder.showKeys, label: "Keystrokes While Recording", tint: DS.Spectrum.sensors)
                    }
                    .help("Turns on Show Keystrokes (Effects) only while a recording runs.")
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
            if let notice = recorder.notice { ToolsNote(text: notice, warning: true) }
        }
        .animation(DS.Motion.reveal, value: recorder.recording)
    }
}

/// A screen in miniature: a menu bar with the record dot, a pointer, rings blooming at a click
/// and a keystroke pill. Still at rest; the rings bloom only under the pointer.
private struct ToolsRecordPlate: View {
    let live: Bool
    let recording: Bool
    let clicks: Bool
    let keys: Bool
    private let red = Color(red: 1, green: 0.27, blue: 0.23)

    var body: some View {
        HeroClock(live: live, rest: 0.45) { t in
            GeometryReader { geometry in
                let size = geometry.size
                let screen = CGRect(x: size.width * 0.2, y: 34, width: size.width * 0.6, height: size.height - 52)
                let click = CGPoint(x: screen.midX + 10, y: screen.midY + 2)
                let phase = live ? (t * 0.9).truncatingRemainder(dividingBy: 1) : 0.45
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.2), Color(red: 0.1, green: 0.09, blue: 0.12)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                        .frame(width: screen.width, height: screen.height)
                        .offset(x: screen.minX, y: screen.minY)
                    // Menu bar with the record dot.
                    Rectangle().fill(.white.opacity(0.09))
                        .frame(width: screen.width - 1, height: 10)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
                        .offset(x: screen.minX + 0.5, y: screen.minY + 0.5)
                    Circle().fill(recording || live ? red : red.opacity(0.55))
                        .frame(width: 6, height: 6)
                        .offset(x: screen.maxX - 14, y: screen.minY + 2.5)
                    // A window behind the pointer.
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.08))
                        .frame(width: screen.width * 0.5, height: screen.height * 0.5)
                        .offset(x: screen.minX + screen.width * 0.14, y: screen.minY + 20)
                    if clicks {
                        ForEach(0..<2, id: \.self) { ring in
                            let p = (phase + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                            Circle().strokeBorder(DS.Spectrum.sensors.opacity(0.9 * (1 - p)), lineWidth: 1.5)
                                .frame(width: 8 + 26 * p, height: 8 + 26 * p)
                                .offset(x: click.x - (4 + 13 * p), y: click.y - (4 + 13 * p))
                        }
                    }
                    Image(systemName: "cursorarrow").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .offset(x: click.x - 3, y: click.y - 2)
                    if keys {
                        Text("⌘ ⇧ 5").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .padding(.horizontal, 8).frame(height: 18)
                            .background(.black.opacity(0.55), in: .capsule)
                            .offset(x: screen.midX - 22, y: screen.maxY - 26)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Rename

private struct RenameCard: View {
    @ObservedObject private var renamer = BatchRenamer.shared
    @State private var targeted = false

    var body: some View {
        ToolsKitCard(symbol: "character.cursor.ibeam", title: "Batch Rename",
                     detail: "Tokens: {name} {n} {date} {ext}. Nothing changes until you press Rename.") {
            Chip("Choose…") { renamer.choose() }
        } content: {
            if renamer.files.isEmpty {
                DropTile(symbol: "character.cursor.ibeam", text: "Drop files to rename", targeted: $targeted) { renamer.files = $0 }
            } else {
                HStack(spacing: 8) {
                    field("Pattern", text: $renamer.plan.pattern)
                    field("Find", text: $renamer.plan.find)
                    field("Replace", text: $renamer.plan.replace)
                }
                HStack(spacing: 10) {
                    Stepper("Start at \(renamer.plan.start)", value: $renamer.plan.start, in: 0...9999).font(DS.caption)
                    Stepper("\(renamer.plan.padding) digits", value: $renamer.plan.padding, in: 1...6).font(DS.caption)
                }
                // The live list is the preview.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(zip(renamer.files, renamer.preview).prefix(8).enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 6) {
                            Text(pair.0.lastPathComponent).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(DS.Spectrum.sensors.opacity(0.8))
                            Text(pair.1).foregroundStyle(pair.0.lastPathComponent == pair.1 ? DS.Ink.secondary : DS.Ink.primary).lineLimit(1)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                    }
                    if renamer.files.count > 8 {
                        Text("and \(renamer.files.count - 8) more").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.22), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                HStack(spacing: 8) {
                    Chip("Rename \(renamer.files.count)") { renamer.apply() }
                    if !renamer.undo.isEmpty { Chip("Undo") { renamer.revert() } }
                    Chip("Clear") { renamer.files = [] }
                }
            }
            if let notice = renamer.notice { ToolsNote(text: notice) }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).frame(height: 30)
            .background(DS.Ink.fill, in: .rect(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
    }
}

// MARK: - Image converter

private struct ImageConvertCard: View {
    @State private var format = ImageConverter.Format.jpeg
    @State private var maxPixels = 2048
    @State private var targeted = false
    @State private var notice: String?

    var body: some View {
        ToolsKitCard(symbol: "photo.on.rectangle.angled", title: "Image Converter",
                     detail: "Drop images. Copies are saved beside them; the originals stay as they are.") {
            EmptyView()
        } content: {
            Segments(selection: $format, options: ImageConverter.Format.allCases.map { ($0, $0.rawValue.uppercased()) })
            Segments(selection: $maxPixels, options: [(0, "Original"), (4096, "4096"), (2048, "2048"), (1024, "1024"), (512, "512")])
            DropTile(symbol: "photo.on.rectangle.angled", text: "Drop images to convert", targeted: $targeted) { urls in
                notice = "Converting \(urls.count)…"
                Task {
                    let result = await ImageConverter.convert(urls, to: format, maxPixels: maxPixels, quality: 0.85)
                    notice = result.failed == 0 ? "Saved \(result.done) copies." : "Saved \(result.done). \(result.failed) were not images."
                }
            }
            if let notice { ToolsNote(text: notice) }
        }
    }
}

// MARK: - Finder scripts

private struct FinderScriptsCard: View {
    @State private var installed: Set<String> = Set(FinderScripts.all.filter(FinderScripts.isInstalled).map(\.name))
    @State private var notice: String?

    var body: some View {
        ToolsKitCard(symbol: "menubar.arrow.up.rectangle", title: "Finder Toolbar Buttons",
                     detail: "Add them here, then hold ⌘ and drag each into a Finder toolbar.") {
            Chip("Show Folder") {
                try? FileManager.default.createDirectory(at: FinderScripts.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(FinderScripts.folder)
            }
        } content: {
            RowGroup {
                ForEach(FinderScripts.all) { script in
                    SettingRow(title: script.name, symbol: script.symbol, density: .compact) {
                        if installed.contains(script.name) {
                            Chip("Remove") { FinderScripts.remove(script); installed.remove(script.name) }
                        } else {
                            Chip("Add") {
                                Task {
                                    notice = await FinderScripts.install(script)
                                    if notice == nil { installed.insert(script.name) }
                                }
                            }
                        }
                    }
                }
            }
            ToolsNote(text: "The first click asks to let the button control Finder.")
            if let notice { ToolsNote(text: notice, warning: true) }
        }
    }
}

// MARK: - Display modes

private struct DisplayModesCard: View {
    @ObservedObject private var modes = DisplayModes.shared

    var body: some View {
        RowGroup {
            ForEach(modes.screens) { screen in
                SettingRow(title: screen.name, detail: "Every mode it offers, including hidden ones.", symbol: "display", density: .compact) {
                    HStack(spacing: 6) {
                        if modes.canRestore(screen.id) { Chip("Restore") { modes.restore(screen.id) } }
                        Menu {
                            ForEach(screen.modes) { mode in
                                Button((mode.id == screen.current ? "✓ " : "") + mode.label) { modes.set(mode, on: screen.id) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(screen.modes.first { $0.id == screen.current }?.label ?? "Choose")
                                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
                            }
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(DS.Ink.fillStrong, in: .capsule)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                }
            }
        }
        .onAppear { modes.refresh() }
        if let notice = modes.notice { ToolsNote(text: notice, warning: true) }
    }
}

// MARK: - Audio

private struct AudioCard: View {
    @ObservedObject private var audio = AudioDevices.shared

    var body: some View {
        RowGroup {
            rows(output: true)
            rows(output: false)
            SettingRow(title: "Alerts Follow Output", detail: "Alert sounds move to the same device.", symbol: "bell", density: .compact) {
                LuxSwitch(isOn: $audio.alertsFollow, label: "Alerts Follow Output", tint: DS.Spectrum.sensors)
            }
        }
        .onAppear { audio.refresh() }
    }

    @ViewBuilder private func rows(output: Bool) -> some View {
        ForEach(audio.devices.filter { output ? $0.output : $0.input }) { device in
            let selected = (output ? audio.defaultOutput : audio.defaultInput) == device.id
            Button { audio.use(device, asOutput: output) } label: {
                SettingRow(title: device.name, detail: output ? "Output" : "Input",
                           symbol: output ? "speaker.wave.2" : "mic", density: .compact) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(selected ? DS.Spectrum.sensors : DS.Ink.glyph)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(device.name), \(output ? "output" : "input")")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

// MARK: - Timers

private struct TimersCard: View {
    @ObservedObject private var shelf = TimerShelf.shared
    @State private var alarm = Date().addingTimeInterval(3600)

    var body: some View {
        ToolsKitCard(symbol: "timer", title: "Timers & Alarms",
                     detail: "A sound and a small card at the top of the screen when time is up.",
                     style: shelf.items.isEmpty ? .standard : .lit(DS.Spectrum.sensors)) {
            EmptyView()
        } content: {
            HStack(spacing: 8) {
                ForEach([1.0, 5, 10, 25, 60], id: \.self) { minutes in
                    Chip(minutes < 60 ? "\(Int(minutes)) min" : "1 hour") { shelf.add(minutes: minutes) }
                }
            }
            HStack(spacing: 8) {
                DatePicker("Alarm", selection: $alarm, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field).fixedSize()
                Chip("Set Alarm") { shelf.addAlarm(at: alarm) }
            }
            if !shelf.items.isEmpty {
                RowGroup {
                    ForEach(shelf.items) { item in
                        SettingRow(title: item.label, symbol: item.isAlarm ? "alarm" : "timer", density: .compact) {
                            HStack(spacing: 10) {
                                Text(timerInterval: Date()...max(Date(), item.end), countsDown: true)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(DS.Spectrum.sensors)
                                Chip("Cancel") { shelf.remove(item) }
                            }
                        }
                    }
                }
            }
        }
        .animation(DS.Motion.reveal, value: shelf.items.count)
    }
}

// MARK: - Focus session

private struct FocusSessionCard: View {
    @ObservedObject private var focus = FocusSession.shared

    var body: some View {
        ToolsKitCard(symbol: "moon.circle", title: "Focus Session",
                     detail: "While it runs, the apps below are hidden as soon as they come forward.",
                     style: focus.running ? .lit(DS.Spectrum.sensors) : .standard) {
            EmptyView()
        } content: {
            if !focus.blocked.isEmpty {
                RowGroup {
                    ForEach(focus.blocked, id: \.self) { id in
                        HStack(spacing: 10) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
                            }
                            Text(FocusSession.name(of: id)).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                            Spacer()
                            if !focus.running { Chip("Remove") { focus.blocked.removeAll { $0 == id } } }
                        }
                        .frame(minHeight: 36)
                    }
                }
            }
            if !focus.running {
                Chip("Add Apps…") { focus.addApp() }
                RowGroup {
                    SettingRow(title: "Quit Instead of Hiding", detail: "Apps are asked to quit, so they can still ask to save.",
                               symbol: "xmark.app", density: .compact) {
                        LuxSwitch(isOn: $focus.quitInstead, label: "Quit Instead of Hiding", tint: DS.Spectrum.sensors)
                    }
                }
                HStack(spacing: 8) {
                    ForEach([25.0, 50, 90], id: \.self) { minutes in
                        Chip("\(Int(minutes)) min") { focus.start(minutes: minutes) }
                    }
                }
                .disabled(focus.blocked.isEmpty)
                .opacity(focus.blocked.isEmpty ? 0.5 : 1)
                .help("You can still open the apps; they just will not stay.")
            } else if let end = focus.endsAt {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(timerInterval: Date()...max(Date(), end), countsDown: true)
                        .font(DS.Typo.readout).monospacedDigit().foregroundStyle(DS.Ink.primary)
                    Text("\(focus.deflected) kept away").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    Spacer()
                    Chip("End Session") { focus.stop() }
                }
            }
        }
        .animation(DS.Motion.reveal, value: focus.running)
    }
}
