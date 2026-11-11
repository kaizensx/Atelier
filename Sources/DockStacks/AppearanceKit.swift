import AppKit
import DockCore
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Light and Dark on your hours
//
// macOS's own Auto follows sunrise and sunset. This follows your hours instead: dark from the
// evening time you pick, light from the morning one. The switch is the same one System Settings
// flips (SkyLight's appearance theme). It acts only when an hour is crossed, so changing the
// mode by hand in between is respected until the next one.

enum Appearance {
    private typealias SetTheme = @convention(c) (Bool) -> Void
    private typealias GetTheme = @convention(c) () -> Bool
    private typealias SetAuto = @convention(c) (Bool) -> Void
    private typealias GetAuto = @convention(c) () -> Bool

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }

    static var isDark: Bool { symbol("SLSGetAppearanceThemeLegacy", GetTheme.self)?() ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) }
    static func set(dark: Bool) { symbol("SLSSetAppearanceThemeLegacy", SetTheme.self)?(dark) }
    static var macAuto: Bool { symbol("SLSGetAppearanceThemeSwitchesAutomatically", GetAuto.self)?() ?? false }
    static func set(macAuto on: Bool) { symbol("SLSSetAppearanceThemeSwitchesAutomatically", SetAuto.self)?(on) }

    /// SkyLight has had these since macOS 10.14 and still does on 27.3 (checked, arm64 and
    /// under Rosetta); a release without them turns the schedule off rather than pretending.
    static var canSwitch: Bool {
        symbol("SLSSetAppearanceThemeLegacy", SetTheme.self) != nil && symbol("SLSGetAppearanceThemeLegacy", GetTheme.self) != nil
    }
}

@MainActor
final class AppearanceSchedule: ObservableObject {
    static let shared = AppearanceSchedule()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "schedule.enabled"); apply() } }
    /// Minutes after midnight.
    @Published var darkAt: Int { didSet { store.set(darkAt, forKey: "schedule.dark"); if enabled { enforce() } } }
    @Published var lightAt: Int { didSet { store.set(lightAt, forKey: "schedule.light"); if enabled { enforce() } } }
    @Published private(set) var dark = Appearance.isDark

    private let store = UserDefaults.standard
    private var timer: Timer?
    private var lastWanted: Bool?

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "schedule.enabled")
        darkAt = d.object(forKey: "schedule.dark") as? Int ?? 19 * 60
        lightAt = d.object(forKey: "schedule.light") as? Int ?? 7 * 60 + 30
    }

    func resume() { if enabled { apply() } }

    /// Whether the hours say dark at this minute of the day.
    static func wantsDark(minute: Int, darkAt: Int, lightAt: Int) -> Bool {
        AppearanceHours.wantsDark(minute: minute, darkAt: darkAt, lightAt: lightAt)
    }

    private var minuteNow: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func apply() {
        timer?.invalidate()
        timer = nil
        guard enabled, Appearance.canSwitch else { lastWanted = nil; return }
        // Two schedules would fight: macOS's Auto steps aside while this one runs, and the
        // choice is remembered so turning this off gives it back.
        if Appearance.macAuto {
            store.set(true, forKey: "schedule.hadMacAuto")
            Appearance.set(macAuto: false)
        }
        enforce()
        let timer = Timer(timeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { AppearanceSchedule.shared.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func turnOffRestoringAuto() {
        enabled = false
        if store.bool(forKey: "schedule.hadMacAuto") {
            Appearance.set(macAuto: true)
            store.removeObject(forKey: "schedule.hadMacAuto")
        }
    }

    /// Sets the mode the hours ask for now.
    private func enforce() {
        let wanted = Self.wantsDark(minute: minuteNow, darkAt: darkAt, lightAt: lightAt)
        lastWanted = wanted
        if Appearance.isDark != wanted { Appearance.set(dark: wanted) }
        dark = wanted
    }

    /// Acts only when the hours change their answer.
    private func tick() {
        let wanted = Self.wantsDark(minute: minuteNow, darkAt: darkAt, lightAt: lightAt)
        dark = Appearance.isDark
        guard wanted != lastWanted else { return }
        enforce()
    }

    func flip() {
        Appearance.set(dark: !Appearance.isDark)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.dark = Appearance.isDark }
    }
}

struct AppearanceScheduleCard: View {
    @ObservedObject private var schedule = AppearanceSchedule.shared

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes.wrappedValue) * 60) },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                })
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(title: "Dark on Your Hours", detail: "Dark from the evening hour you choose, light from the morning one. macOS's Auto follows the sun; this follows you.") {
                    LuxSwitch(isOn: Binding(get: { schedule.enabled }, set: { $0 ? (schedule.enabled = true) : schedule.turnOffRestoringAuto() }),
                              label: "Dark on Your Hours")
                        .disabled(!Appearance.canSwitch && !schedule.enabled)
                }
                if !Appearance.canSwitch {
                    AvailabilityNote(availability: .unavailable("This macOS no longer lets apps switch Light and Dark"))
                }
                HStack(spacing: 14) {
                    Label("Dark", systemImage: "moon.fill").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    DatePicker("", selection: time($schedule.darkAt), displayedComponents: .hourAndMinute).labelsHidden()
                    Spacer()
                    Label("Light", systemImage: "sun.max.fill").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    DatePicker("", selection: time($schedule.lightAt), displayedComponents: .hourAndMinute).labelsHidden()
                }
                .disabled(!schedule.enabled)
                .opacity(schedule.enabled ? 1 : 0.5)
                HStack {
                    Text(schedule.dark ? "Dark now." : "Light now.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    Spacer()
                    Chip(schedule.dark ? "Switch to Light" : "Switch to Dark") { schedule.flip() }
                }
            }
        }
        .stagePreview(.demo("appearance.schedule", "Dark on Your Hours", isOn: schedule.enabled, region: StageRegion.whole, Demos.darkHours))
    }
}

// MARK: - Light apps in Dark Mode

/// Apps that stay light while the rest of the Mac is dark, the way Gray does it: the app's own
/// NSRequiresAquaSystemAppearance preference, which AppKit reads at launch. Sandboxed apps keep
/// their preferences in a container macOS guards, so they are shown but cannot be changed.
struct LightApp: Identifiable, Hashable {
    let id: String          // bundle identifier
    let name: String
    let url: URL
    let sandboxed: Bool
}

@MainActor
final class LightApps: ObservableObject {
    static let shared = LightApps()
    @Published private(set) var apps: [LightApp] = []
    @Published private(set) var revision = 0

    private static let key = "NSRequiresAquaSystemAppearance" as CFString

    private init() { apps = Self.scan() }

    /// Reads /Applications again: an app installed since is listed.
    func load() { apps = Self.scan() }

    private static func scan() -> [LightApp] {
        let containers = NSHomeDirectory() + "/Library/Containers/"
        return ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasSuffix(".app") }
            .compactMap { name in
                let url = URL(fileURLWithPath: "/Applications/" + name)
                guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return LightApp(id: id, name: String(name.dropLast(4)), url: url,
                                sandboxed: FileManager.default.fileExists(atPath: containers + id))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isLight(_ app: LightApp) -> Bool {
        _ = revision
        return (CFPreferencesCopyAppValue(Self.key, app.id as CFString) as? Bool) == true
    }

    func set(_ app: LightApp, light: Bool) {
        guard !app.sandboxed else { return }
        CFPreferencesSetAppValue(Self.key, light ? kCFBooleanTrue : nil, app.id as CFString)
        CFPreferencesAppSynchronize(app.id as CFString)
        revision += 1
    }

    func isRunning(_ app: LightApp) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty }

    /// Quits the app normally and opens it again, so it reads the setting. It can say no.
    func relaunch(_ app: LightApp) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id)
        running.forEach { $0.terminate() }
        Task {
            for _ in 0..<40 where running.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(150)) }
            guard running.allSatisfy(\.isTerminated) else { return }
            try? await NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
        }
    }
}

struct LightAppsCard: View {
    @ObservedObject private var store = LightApps.shared
    @State private var filter = ""

    private var shown: [LightApp] {
        let all = store.apps.filter { !$0.sandboxed }
        let light = all.filter(store.isLight)
        let matching = filter.isEmpty ? Array(all.prefix(8)) : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        return light + matching.filter { !light.contains($0) }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "Light Apps in Dark Mode", detail: "Keep chosen apps light while the rest of the Mac is dark. Each reads it when it opens.") { EmptyView() }
                TextField("Find an app", text: $filter)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(DS.Ink.fill, in: .rect(cornerRadius: 9, style: .continuous))
                ForEach(shown) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 22, height: 22)
                        Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Spacer()
                        if store.isLight(app), store.isRunning(app) {
                            Chip("Relaunch") { store.relaunch(app) }
                        }
                        LuxSwitch(isOn: Binding(get: { store.isLight(app) }, set: { store.set(app, light: $0) }), label: app.name + " stays light")
                    }
                }
                Text("Apps from the App Store keep their settings sealed, so they are not listed.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        }
        .onAppear { store.load() }
        .stagePreview(.demo("appearance.lightApps", "Light Apps in Dark Mode", isOn: false, region: StageRegion.whole, Demos.lightApp))
    }
}

// MARK: - Typing Sounds
//
// A soft key sound as you type, in the spirit of Klack. The sounds are made here, not
// recorded: a short noise burst through a resonant body, a different body for each pack, so
// nothing is borrowed. Key events come from the same global monitor Show Keystrokes uses;
// password fields never reach it, because macOS hides secure input from every app.

enum TypingPack: String, CaseIterable, Identifiable {
    case thock, click, typewriter, bubble
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thock: "Thock"
        case .click: "Click"
        case .typewriter: "Typewriter"
        case .bubble: "Bubble"
        }
    }
    /// Body pitch, decay and how much noise against tone.
    var voice: (pitch: Double, decay: Double, noise: Double, length: Double) {
        switch self {
        case .thock: (180, 38, 0.55, 0.07)
        case .click: (2600, 120, 0.8, 0.025)
        case .typewriter: (900, 55, 0.9, 0.06)
        case .bubble: (520, 30, 0.1, 0.08)
        }
    }
}

@MainActor
final class TypingSounds: ObservableObject {
    static let shared = TypingSounds()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "typing.enabled"); apply() } }
    @Published var pack: TypingPack { didSet { store.set(pack.rawValue, forKey: "typing.pack"); buffers = [:] } }
    @Published var volume: Double { didSet { store.set(volume, forKey: "typing.volume"); engine.mainMixerNode.outputVolume = Float(volume) } }
    /// Key presses heard since launch, for tests.
    private(set) var played = 0

    private let store = UserDefaults.standard
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var monitors: [Any] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "typing.enabled")
        pack = TypingPack(rawValue: d.string(forKey: "typing.pack") ?? "") ?? .thock
        volume = d.object(forKey: "typing.volume") as? Double ?? 0.5
    }

    func resume() { if enabled { apply() } }

    private func apply() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard enabled else { engine.stop(); return }
        if players.isEmpty {
            for _ in 0..<6 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                players.append(player)
            }
        }
        engine.mainMixerNode.outputVolume = Float(volume)
        try? engine.start()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            let code = Int(event.keyCode), repeated = event.isARepeat
            MainActor.assumeIsolated { TypingSounds.shared.key(code, repeated: repeated) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated { TypingSounds.shared.key(Int(event.keyCode), repeated: event.isARepeat) }
            return event
        }) { monitors.append(local) }
    }

    /// One key's sound: the space bar and return sit lower and longer, like a real board.
    func key(_ code: Int, repeated: Bool = false) {
        guard enabled, !repeated else { return }
        let size = code == 49 ? 2 : (code == 36 || code == 51) ? 1 : 0
        let variant = size == 0 ? code % 4 : 4 + size
        let buffer = buffers[variant] ?? make(variant: variant, size: size)
        buffers[variant] = buffer
        let player = players[next % players.count]
        next += 1
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        played += 1
    }

    private func make(variant: Int, size: Int) -> AVAudioPCMBuffer {
        var voice = pack.voice
        voice.pitch *= [1, 0.96, 1.04, 0.92, 1, 0.8, 0.62][min(variant, 6)]
        voice.length *= size == 0 ? 1 : 1.5
        let frames = AVAudioFrameCount(format.sampleRate * voice.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        var seed: UInt32 = UInt32(variant * 7919 + 17)
        var low = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 9) / Double(1 << 23) * 2 - 1
            low += (noise - low) * min(voice.pitch / 4000, 0.9)
            let tone = sin(2 * .pi * voice.pitch * t) * (pack == .bubble ? 1 - t / voice.length * 0.6 : 1)
            let envelope = exp(-t * voice.decay) * min(t * 4000, 1)
            out[i] = Float((tone * (1 - voice.noise) + low * voice.noise * 2.4) * envelope * 0.6)
        }
        return buffer
    }
}

struct TypingSoundsCard: View {
    @ObservedObject private var typing = TypingSounds.shared
    private let hue = DS.Spectrum.sound

    var body: some View {
        // Hearing keys typed in other apps takes a global monitor, which macOS only feeds to an
        // app with Accessibility; without it the sounds play in Atelier's own windows only.
        let availability: FeatureAvailability = AXIsProcessTrusted() ? .available
            : .limited("Needs Accessibility to hear typing in other apps")
        HeroCard("Typing Sounds", pitch: "A soft key sound as you type, made by Atelier, not recorded. Password fields stay silent.",
                 isOn: $typing.enabled, hue: hue,
                 readout: typing.pack.title, readoutCaption: "\(Int((typing.volume * 100).rounded()))% volume",
                 preview: .demo("sounds.typing", "Typing Sounds", isOn: typing.enabled, region: StageRegion.whole, Demos.typingSounds)) {
            TypingPlate(pack: typing.pack, hue: hue).displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: 12) {
                Segments(selection: $typing.pack, options: TypingPack.allCases.map { ($0, $0.title) })
                HStack(spacing: 12) {
                    Text("Volume").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    LuxSlider(value: $typing.volume, range: 0...1, label: "Typing volume", tint: hue)
                    Chip("Try") {
                        let was = typing.enabled
                        if !was { typing.enabled = true }
                        for (i, code) in [0, 1, 2, 49, 3, 36].enumerated() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.12) { typing.key(code) }
                        }
                        if !was { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { typing.enabled = false } }
                    }
                }
            }
        }
    }
}

/// The hero's plate: a row of keycaps and the sound coming off them. Still at rest; under the
/// pointer the keys go down in a typing rhythm and each one sends out a ring shaped by the pack:
/// a low round thock, a tight click, a wide typewriter strike, a soft bubble.
private struct TypingPlate: View {
    let pack: TypingPack
    let hue: Color
    private let keys = ["Q", "W", "E", "R", "T", "Y", "U"]

    var body: some View {
        PlateTimeline { elapsed in
            Canvas { context, size in
                let cap = 30.0, gap = 6.0
                let rowWidth = Double(keys.count) * cap + Double(keys.count - 1) * gap
                let x0 = (size.width - rowWidth) / 2, y0 = size.height * 0.56 - cap / 2
                // An uneven rhythm reads as typing; an even one reads as a metronome.
                let hits: [(at: Double, key: Int)] = [(0.0, 2), (0.16, 4), (0.27, 0), (0.48, 5), (0.6, 1), (0.85, 3), (0.97, 6)]
                let t = elapsed.map { $0.truncatingRemainder(dividingBy: 1.6) }
                let ring = pack.voice
                // Lower bodies ring wider and slower.
                let reach = 26 + 3000 / ring.pitch * 2.2, life = min(max(ring.length * 6, 0.22), 0.5)
                for (index, label) in keys.enumerated() {
                    let since = t.flatMap { now in hits.filter { $0.key == index && now >= $0.at }.map { now - $0.at }.min() }
                    let down = since.map { max(0, 1 - $0 / 0.09) } ?? 0
                    let x = x0 + Double(index) * (cap + gap)
                    let frame = CGRect(x: x, y: y0 + down * 2, width: cap, height: cap)
                    if let since, since < life {
                        let r = since / life
                        let radius = cap * 0.5 + reach * r
                        let circle = CGRect(x: frame.midX - radius, y: frame.midY - radius, width: radius * 2, height: radius * 2)
                        context.stroke(Path(ellipseIn: circle), with: .color(hue.opacity((1 - r) * 0.7)), lineWidth: 1.5)
                    }
                    // The skirt, then the top face, lit from above.
                    let skirt = Path(roundedRect: frame.offsetBy(dx: 0, dy: 3 - down * 2), cornerRadius: 6, style: .continuous)
                    context.fill(skirt, with: .color(.black.opacity(0.5)))
                    let face = Path(roundedRect: frame, cornerRadius: 6, style: .continuous)
                    context.fill(face, with: .linearGradient(Gradient(colors: [Color(white: 0.27 + down * 0.1), Color(white: 0.17)]),
                                                             startPoint: CGPoint(x: frame.midX, y: frame.minY),
                                                             endPoint: CGPoint(x: frame.midX, y: frame.maxY)))
                    context.stroke(face, with: .color(down > 0 ? hue.opacity(0.4 + 0.5 * down) : .white.opacity(0.14)), lineWidth: 0.75)
                    context.draw(Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75)),
                                 at: CGPoint(x: frame.midX, y: frame.midY))
                }
                // At rest, a quiet waveform of the pack's voice sits above the keys.
                if t == nil {
                    var wave = Path()
                    let width = rowWidth * 0.6, mid = y0 - 22, left = (size.width - width) / 2
                    for i in 0...80 {
                        let p = Double(i) / 80
                        let envelope = exp(-p * ring.decay / 12) * min(p * 40, 1)
                        let y = mid - sin(p * ring.pitch / 40) * 9 * envelope
                        if i == 0 { wave.move(to: CGPoint(x: left, y: y)) } else { wave.addLine(to: CGPoint(x: left + width * p, y: y)) }
                    }
                    context.stroke(wave, with: .color(hue.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - Your own alert sounds

/// Sounds in ~/Library/Sounds show up in macOS's alert list. Adding one copies it there; taking
/// one away moves it to the Trash, never deletes it.
@MainActor
final class UserSounds: ObservableObject {
    static let shared = UserSounds()
    @Published private(set) var files: [URL] = []
    @Published var notice: String?

    static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Sounds")

    func reload() {
        files = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["aiff", "aif", "caf", "wav"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.aiff, .wav, UTType("com.apple.coreaudio-format") ?? .audio]
        panel.message = "Choose a short sound (AIFF, WAV or CAF)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let target = Self.folder.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { notice = "A sound with that name is already there."; return }
            try FileManager.default.copyItem(at: url, to: target)
            notice = "Added. Choose it as the Alert Sound above."
        } catch { notice = error.localizedDescription }
        reload()
    }

    func remove(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { _, _ in
            DispatchQueue.main.async { UserSounds.shared.reload() }
        }
    }
}

struct UserSoundsCard: View {
    @ObservedObject private var sounds = UserSounds.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "Your Sounds", detail: sounds.notice ?? "Add your own short sounds to the alert list. Removing one moves it to the Trash.") {
                    Chip("Add a Sound…") { sounds.add() }
                }
                ForEach(sounds.files, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(DS.Ink.tertiary)
                        Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Chip("Play") { NSSound(contentsOf: url, byReference: true)?.play() }
                        Chip("Remove") { sounds.remove(url) }
                    }
                }
            }
        }
        .onAppear { sounds.reload() }
    }
}
