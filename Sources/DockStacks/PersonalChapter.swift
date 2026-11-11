import AppKit
import DockCore
import SwiftUI

// MARK: - Model

/// Applies and reverts PersonalCatalog settings. Every change stores the original first,
/// so Revert puts back exactly what was there, including "nothing".
@MainActor
final class PersonalModel: ObservableObject {
    static let shared = PersonalModel()

    /// Bumped after every write so rows read their value again.
    @Published private(set) var revision = 0
    @Published var notice: String?
    @Published private(set) var restarting: String?

    let engine = PersonalEngine()

    /// Processes that relaunch themselves when killed. Anything else is the user's app and
    /// gets a Relaunch button instead of being quit from under them.
    private static let selfRelaunching: Set<String> = ["Finder", "Dock", "SystemUIServer", "ControlCenter", "WindowManager", "Spotlight"]

    func value(_ setting: PersonalSetting) -> PersonalValue? {
        _ = revision
        return engine.prefs.read(setting)
    }

    func isChanged(_ setting: PersonalSetting) -> Bool {
        _ = revision
        return engine.ledger.isTracked(setting.id)
    }

    /// "Was: Off" for a changed setting, or nil.
    func originalLabel(_ setting: PersonalSetting) -> String? {
        guard let original = engine.ledger.original(setting.id) else { return nil }
        if let original { return label(original, for: setting) }
        return "macOS default"
    }

    func label(_ value: PersonalValue?, for setting: PersonalSetting) -> String {
        guard let value else {
            return setting.fallback.map { label($0, for: setting) + " (macOS default)" } ?? "macOS default"
        }
        switch setting.control {
        // A switch reads On or Off, whatever number or word it is stored as.
        case let .toggle(on, _): return value == on ? "On" : "Off"
        case let .choice(options): return options.first { $0.value == value }?.label ?? value.label
        case .sound, .folder:
            if case let .string(path) = value { return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
            return value.label
        case let .number(_, _, unit): return value.label + (unit.isEmpty ? "" : " " + unit)
        default: return value.label
        }
    }

    func set(_ value: PersonalValue, for setting: PersonalSetting) {
        // A key this macOS does not read is never written: an older or newer release could
        // misread it, and the change would show nothing. The rows already hide such settings.
        guard setting.isAvailable() else {
            notice = "\(setting.title) is not read by macOS \(PersonalAvailability.runningMajor). "
                + setting.availability.requirement(onMajor: PersonalAvailability.runningMajor) + "."
            revision += 1
            return
        }
        // Back to what it was before Atelier touched it: put the original back exactly, absent
        // key included, instead of writing an explicit value macOS never had.
        if let original = engine.ledger.original(setting.id) {
            let home: Bool
            if case let .toggle(on, _) = setting.control { home = ((original ?? setting.fallback) == on) == (value == on) }
            else { home = original == value || (original == nil && value == setting.fallback) }
            if home { revert(setting); return }
        }
        do { try engine.apply(value, to: setting) }
        catch { notice = error.localizedDescription; revision += 1; return }
        finish(setting)
    }

    func revert(_ setting: PersonalSetting) {
        do { try engine.revert(setting) }
        catch { notice = error.localizedDescription; revision += 1; return }
        finish(setting)
    }

    private func finish(_ setting: PersonalSetting) {
        notice = nil
        revision += 1
        if let name = PersonalCatalog.changeNotification(for: setting) {
            DistributedNotificationCenter.default().postNotificationName(.init(name), object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
        }
        if case let .restart(process) = setting.effect, Self.selfRelaunching.contains(process) { restart(process) }
    }

    func restart(_ process: String) {
        guard restarting == nil else { return }
        restarting = process
        Task.detached {
            Prefs.restart(process)
            await MainActor.run { PersonalModel.shared.restarting = nil }
        }
    }

    /// Quits a user app politely and opens it again. The app may ask to save first.
    func relaunch(appNamed name: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }),
              let url = app.bundleURL else { return }
        app.terminate()
        Task {
            for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(150)) }
            guard app.isTerminated else { notice = "\(name) is still open. Quit it yourself to finish."; return }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func isRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
    }
}

// MARK: - Chapter

/// One area of the PersonalCatalog, grouped into sections, plus that area's bespoke cards.
struct PersonalChapter: View {
    let area: PersonalArea
    var model: ManagerModel?
    /// Only these catalogue sections, for a place that holds part of an area (one app of Apps).
    var sections: [String]?
    @ObservedObject private var personal = PersonalModel.shared

    private static let intros: [PersonalArea: String] = [
        .finder: "Finder's own preferences, found in its binary. Finder restarts once after a change.",
        .folders: "Give folders and your own apps an icon of your choice. Revert puts the original back.",
        .input: "Pointer, keyboard, trackpad and typing. Many of these are read at login, and say so.",
        .sounds: "The alert sound and the little noises your Mac makes. The startup chime lives in NVRAM and is left alone.",
        .animations: "The motion macOS adds to apps, the Dock and Finder.",
        .apps: "What opens at login, and settings every app shares. Each app with settings of its own has a place under Apps.",
        .controlCenter: "Which items sit in the menu bar, and how the clock and battery read. ControlCenter restarts after a change.",
        .spotlight: "Spotlight's own interface switches, most of them internal. Spotlight restarts after a change.",
        .missionControl: "Mission Control, Spaces, Stage Manager, tiling and the app switcher, including hidden Dock switches.",
        .lockScreen: "The screen saver, the lock screen clock and what logging out remembers.",
        .accessibility: "Visual accessibility. macOS guards this domain, so a change can be refused and applies after logging out.",
        .appKit: "Behaviour every app shares: the caret, text, scrolling, windows and fonts. Apps pick it up when reopened.",
        .quickLook: "The preview panel, which runs inside each app. Reopen the app to see a change.",
    ]

    /// One app of the Apps area: its settings only, said plainly.
    private var singleApp: String? {
        guard area == .apps, let sections, sections.count == 1, sections[0] != "All Apps" else { return nil }
        return sections[0]
    }

    var body: some View {
        if let app = singleApp {
            Text("Settings \(app) keeps but does not show. Each row says when \(app) picks it up.")
                .font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let intro = Self.intros[area] {
            Text(intro).font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
        switch area {
        case .finder: DesktopIconsCard()
        case .folders: FolderIconStudio(); AppIconStudio()
        case .input: KeyRemapCard()
        case .animations:
            if let model {
                TweakList(model: model, tweaks: TweakCatalog.tweaks(personal: .animations))
                SettingsCompatHiddenGroup(items: TweakCatalog.unsupported(personal: .animations).map(\.compatHiddenItem))
            }
        case .apps:
            if let app = singleApp { PersonalAppHeader(name: app) } else { LoginItemsCard() }
        default: EmptyView()
        }
        PersonalRows(area: area, sections: sections)
        if let notice = personal.notice {
            Text(notice).font(DS.caption).foregroundStyle(.orange.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The catalogue rows for an area, by section. Embeddable in existing chapters
/// (Finder, Capture, Windows, Corners) so their settings live in one place.
struct PersonalRows: View {
    let area: PersonalArea
    /// Only these sections; all of the area when nil.
    var sections: [String]?

    var body: some View {
        // Only what this macOS reads gets a control; the rest collapse into one group below.
        let split = PersonalAvailability.partition(PersonalCatalog.settings(in: area).filter { sections?.contains($0.section) ?? true })
        let all = split.supported
        let shown = PersonalCatalog.sections(in: area).filter { section in
            (sections?.contains(section) ?? true) && all.contains { $0.section == section }
        }
        // Lazy: a chapter with dozens of rows builds only the ones on screen, so opening it
        // never stalls the camera move.
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(shown, id: \.self) { section in
                // A place that is one section already says its name in the title.
                if shown.count > 1 || sections == nil { SectionHeader(section, symbol: Self.symbol(section)) }
                // One surface per section, compact rows with hairlines. A section builds eagerly,
                // the sections themselves stay lazy.
                RowGroup {
                    ForEach(all.filter { $0.section == section }) { setting in
                        PersonalRow(setting: setting, grouped: true)
                    }
                }
            }
            SettingsCompatHiddenGroup(items: split.unsupported.map(\.compatHiddenItem))
        }
    }

    static func symbol(_ section: String) -> String {
        switch section {
        case "New Windows": "macwindow.badge.plus"
        case "Window Chrome": "sidebar.left"
        case "Files": "doc"
        case "Trash": "trash"
        case "Desktop": "menubar.dock.rectangle"
        case "Pointer": "cursorarrow"
        case "Keyboard": "keyboard"
        case "Trackpad": "rectangle.and.hand.point.up.left"
        case "Text": "textformat"
        case "Alerts": "bell"
        case "Feedback": "speaker.wave.2"
        case "Dock": "dock.rectangle"
        case "Screenshots": "camera.viewfinder"
        case "Recordings": "record.circle"
        case "Mission Control": "rectangle.3.group"
        case "Hot Corners": "rectangle.inset.topleft.filled"
        case "Hidden Extras": "eye.slash"
        case "All Apps": "square.grid.2x2"
        case "Menu Bar Items": "menubar.rectangle"
        case "Stage Manager": "square.stack.3d.forward.dottedline"
        case "Tiling": "rectangle.split.2x1"
        case "Haptics": "hand.tap"
        default: "slider.horizontal.3"
        }
    }
}

struct PersonalRow: View {
    let setting: PersonalSetting
    /// Inside a RowGroup: a compact row, no card of its own.
    var grouped = false
    @ObservedObject private var personal = PersonalModel.shared
    @State private var draftNumber: Double?
    @State private var draftText = ""

    var body: some View {
        let current = personal.value(setting)
        Group {
            if grouped { rowContent(current).padding(.vertical, DS.Space.s) } else { Card { rowContent(current) } }
        }
        .help(helpText)
        // stagePreview: setting.preview — the catalogue carries one sentence per setting.
        .stagePreview(.demo("personal." + setting.id, setting.title, isOn: Self.isOn(setting, current),
                            Demos.personal(area: setting.area.rawValue, section: setting.section,
                                           title: setting.title, preview: setting.preview)))
        .accessibilityElement(children: .contain)
        .navTarget(Self.target(setting))
    }

    private var isBeta: Bool { setting.experimental || setting.isExperimental }

    /// The caution, said in full on hover. Plist keys and evidence only in debug builds.
    private var helpText: String {
        var parts: [String] = []
        if let caution = setting.caution { parts.append(caution) }
        else if isBeta { parts.append("A hidden switch with no setting in System Settings.") }
        if let note = setting.availability.verificationNote(onMajor: PersonalAvailability.runningMajor) { parts.append(note) }
        if let debug = setting.debugHelp { parts.append(debug) }
        return parts.joined(separator: "\n\n")
    }

    @ViewBuilder private func rowContent(_ current: PersonalValue?) -> some View {
        VStack(alignment: .leading, spacing: grouped ? DS.Space.s : 10) {
            SettingRow(title: setting.title, detail: setting.detail, density: grouped ? .compact : .regular) {
                HStack(spacing: 6) {
                    if isBeta { BetaBadge() }
                    ApplyHint(effect: setting.effect, restarting: personal.restarting)
                    if personal.isChanged(setting), let was = personal.originalLabel(setting) {
                        RevertGlyph(was: was) { personal.revert(setting) }
                    }
                    trailing(current)
                }
            }
            wide(current)
            if let app = setting.effect.relaunchTarget, personal.isChanged(setting), personal.isRunning(app) {
                Chip("Relaunch \(app)") { personal.relaunch(appNamed: app) }
            }
        }
    }

    /// Whether the row reads as On: a toggle at its on value, anything else away from the default.
    static func isOn(_ setting: PersonalSetting, _ current: PersonalValue?) -> Bool {
        if case let .toggle(on, _) = setting.control { return (current ?? setting.fallback) == on }
        guard let current else { return false }
        return current != setting.fallback
    }

    /// The id search uses to point at this setting's row.
    nonisolated static func target(_ setting: PersonalSetting) -> String { "personal." + setting.id }

    private var isOnBinding: Binding<Bool> {
        guard case let .toggle(on, off) = setting.control else { return .constant(false) }
        return Binding(get: { (personal.value(setting) ?? setting.fallback) == on },
                       set: { personal.set($0 ? on : off, for: setting) })
    }

    @ViewBuilder private func trailing(_ current: PersonalValue?) -> some View {
        switch setting.control {
        case .toggle: LuxSwitch(isOn: isOnBinding, label: setting.title)
        case let .choice(options) where options.count > 4:
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option.label) { personal.set(option.value, for: setting) }
                }
            } label: {
                Text(personal.label(current ?? setting.fallback, for: setting).replacingOccurrences(of: " (macOS default)", with: ""))
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                    .background(DS.Ink.fillStrong, in: .capsule)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
        case .folder:
            Chip("Choose…") { chooseFolder() }
        case .sound:
            AlertSoundMenu(label: personal.label(current ?? setting.fallback, for: setting).replacingOccurrences(of: " (macOS default)", with: "")) { path in
                NSSound(contentsOfFile: path, byReference: true)?.play()
                personal.set(.string(path), for: setting)
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private func wide(_ current: PersonalValue?) -> some View {
        switch setting.control {
        case let .choice(options) where options.count <= 4:
            Segments(selection: Binding(get: { current ?? setting.fallback ?? options[0].value },
                                        set: { personal.set($0, for: setting) }),
                     options: options.map { ($0.value, $0.label) })
        case let .number(range, step, unit):
            CommitSlider(value: Binding(get: { current?.number ?? setting.fallback?.number ?? range.lowerBound },
                                        set: { value in
                                            let snapped = (value / step).rounded() * step
                                            personal.set(setting.kind == .int ? .int(Int(snapped)) : .float(snapped), for: setting)
                                        }),
                         range: range) { value in
                let snapped = (value / step).rounded() * step
                return (snapped == snapped.rounded() ? String(Int(snapped)) : String(format: "%.2f", snapped)) + (unit.isEmpty ? "" : " " + unit)
            }
        case let .text(placeholder):
            TextField(placeholder, text: $draftText)
                .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).frame(height: 34)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .onAppear { if case let .string(text) = current { draftText = text } }
                .onSubmit {
                    let text = draftText.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { personal.set(.string(text), for: setting) }
                }
        default: EmptyView()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        personal.set(.string(url.path), for: setting)
    }

    /// macOS's own sounds never change, so they are read once.
    static let systemSounds: [String] = {
        let folder = "/System/Library/Sounds"
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { ["aiff", "aif", "wav", "caf"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted().map { folder + "/" + $0 }
    }()

    /// The system's sounds, then yours from ~/Library/Sounds as Your Sounds lists them now.
    @MainActor static var sounds: [String] { systemSounds + UserSounds.shared.files.map(\.path) }
}

/// The Alert Sound menu. It watches Your Sounds, so a sound added there is offered at once.
private struct AlertSoundMenu: View {
    let label: String
    let choose: (String) -> Void
    @ObservedObject private var user = UserSounds.shared

    var body: some View {
        Menu {
            ForEach(PersonalRow.sounds, id: \.self) { path in
                Button(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) { choose(path) }
            }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                .background(DS.Ink.fillStrong, in: .capsule)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .onAppear { user.reload() }
    }
}

// MARK: - Desktop icons

/// Finder's desktop icon size, grid and labels, from the nested DesktopViewSettings dictionary.
struct DesktopIconsCard: View {
    @ObservedObject private var personal = PersonalModel.shared
    @State private var options = DesktopIconOptions(desktopViewSettings: DesktopIconsCard.stored())
    @State private var changed = UserDefaults.standard.object(forKey: DesktopIconsCard.memory) != nil

    private static let memory = "personal.original.DesktopViewSettings"
    private static let absent = "absent"

    nonisolated static func stored() -> [String: Any]? {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        return CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
    }

    var body: some View {
        SectionHeader("Desktop Icons", symbol: "square.grid.3x3", detail: "Size, spacing and labels for icons on the desktop.")
        Card {
            VStack(alignment: .leading, spacing: 12) {
                // stagePreview: desktop icons on the replica wallpaper resizing and re-spacing live.
                row("Icon Size") { CommitSlider(value: bind(\.iconSize), range: 16...128) { "\(Int($0)) pt" } }
                row("Grid Spacing") { CommitSlider(value: bind(\.gridSpacing), range: 1...100) { "\(Int($0))" } }
                row("Label Size") { CommitSlider(value: bind(\.textSize), range: 10...16) { "\(Int($0)) pt" } }
                // stagePreview: labels jumping between under and beside the icons.
                SettingRow(title: "Labels Below Icons", detail: nil) { LuxSwitch(isOn: bind(\.labelOnBottom), label: "Labels Below Icons") }
                // stagePreview: a grey line of item info (size, pixel dimensions) under each icon.
                SettingRow(title: "Show Item Info", detail: "Sizes, counts and dimensions under each icon.") {
                    LuxSwitch(isOn: bind(\.showItemInfo), label: "Show Item Info")
                }
                // stagePreview: generic document icons turning into thumbnails.
                SettingRow(title: "Icon Previews", detail: "Thumbnails instead of generic icons.") {
                    LuxSwitch(isOn: bind(\.showIconPreview), label: "Icon Previews")
                }
                // stagePreview: desktop icons re-sorting into the chosen order.
                Menu {
                    ForEach(DesktopIconOptions.arrangements, id: \.0) { value, label in
                        Button(label) { options.arrangeBy = value; apply() }
                    }
                } label: {
                    Text("Sort By: " + (DesktopIconOptions.arrangements.first { $0.0 == options.arrangeBy }?.1 ?? options.arrangeBy))
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                        .background(DS.Ink.fillStrong, in: .capsule)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                HStack(spacing: 6) {
                    Spacer()
                    ApplyHint(kind: .restart, sentence: "Restarts Finder once after a change. Folders you arranged by hand keep their own layout.")
                    if changed { RevertGlyph(was: "your previous desktop layout") { revert() } }
                }
            }
        }
        #if DEBUG
        .help("com.apple.finder · DesktopViewSettings › IconViewSettings. Keys found by REA in the Finder binary.")
        #endif
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary)
            content()
        }
    }

    private func bind<Value>(_ path: WritableKeyPath<DesktopIconOptions, Value>) -> Binding<Value> {
        Binding(get: { options[keyPath: path] }, set: { options[keyPath: path] = $0; apply() })
    }

    private func apply() {
        let store = UserDefaults.standard
        let current = Self.stored()
        if store.object(forKey: Self.memory) == nil {
            if let current, let data = try? PropertyListSerialization.data(fromPropertyList: current, format: .binary, options: 0) {
                store.set(data, forKey: Self.memory)
            } else {
                store.set(Self.absent, forKey: Self.memory)
            }
        }
        write(options.merged(into: current) as CFPropertyList)
        changed = true
    }

    private func revert() {
        let store = UserDefaults.standard
        let saved = store.object(forKey: Self.memory)
        if let data = saved as? Data,
           let original = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            write(original as CFPropertyList)
        } else if saved as? String == Self.absent {
            write(nil)
        }
        store.removeObject(forKey: Self.memory)
        changed = false
        options = DesktopIconOptions(desktopViewSettings: Self.stored())
    }

    private func write(_ value: CFPropertyList?) {
        do {
            try PersonalPrefs().set(value, key: "DesktopViewSettings", domain: "com.apple.finder")
            personal.restart("Finder")
        } catch { personal.notice = error.localizedDescription }
    }
}

// MARK: - Keyboard remapping

/// Remaps keys with Apple's own hidutil and its UserKeyMapping property (TN2450).
/// It lasts until restart; Atelier can apply it again each time it opens.
@MainActor
final class KeyRemapper: ObservableObject {
    static let shared = KeyRemapper()

    @Published var active: Set<KeyRemap> {
        didSet { UserDefaults.standard.set(active.map(\.rawValue), forKey: "keyRemap.active") }
    }
    @Published var reapplyAtLaunch: Bool { didSet { UserDefaults.standard.set(reapplyAtLaunch, forKey: "keyRemap.relaunch") } }
    @Published var notice: String?

    private init() {
        active = Set((UserDefaults.standard.stringArray(forKey: "keyRemap.active") ?? []).compactMap(KeyRemap.init(rawValue:)))
        reapplyAtLaunch = UserDefaults.standard.bool(forKey: "keyRemap.relaunch")
    }

    /// Call once at launch.
    func start() { if reapplyAtLaunch, !active.isEmpty { apply() } }

    func toggle(_ remap: KeyRemap) {
        if active.contains(remap) { active.remove(remap) }
        else {
            if remap == .capsToEscape { active.remove(.capsToControl) }
            if remap == .capsToControl { active.remove(.capsToEscape) }
            active.insert(remap)
        }
        apply()
    }

    /// Clears every mapping, including ones another tool set.
    func clear() { active = []; apply() }

    /// Through the writer Hyper Key shares, so Caps Lock → F18 stays in the list when Hyper is on.
    private func apply() {
        KeyMapping.write { ok in KeyRemapper.shared.notice = ok ? nil : "hidutil refused the mapping." }
    }
}

struct KeyRemapCard: View {
    @ObservedObject private var remapper = KeyRemapper.shared

    var body: some View {
        SectionHeader("Remap Keys", symbol: "keyboard.badge.ellipsis",
                      detail: "Apple's hidutil, no driver or extension. It resets when the Mac restarts.")
        RowGroup {
            ForEach(KeyRemap.allCases) { remap in
                // stagePreview: the replica keyboard with the source key lighting up as the destination key.
                SettingRow(title: remap.title, density: .compact) {
                    LuxSwitch(isOn: Binding(get: { remapper.active.contains(remap) }, set: { _ in remapper.toggle(remap) }),
                              label: remap.title)
                }
                .padding(.vertical, DS.Space.s)
            }
            SettingRow(title: "Apply Again When Atelier Opens", detail: "Restores your remaps after a restart, once Atelier runs.",
                       density: .compact) {
                HStack(spacing: 6) {
                    if !remapper.active.isEmpty {
                        Button { remapper.clear() } label: {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 10.5, weight: .semibold))
                                .frame(width: 22, height: 22).contentShape(.rect)
                        }
                        .buttonStyle(Pressable(scale: 0.9)).foregroundStyle(DS.Ink.secondary)
                        .help("Clear all remaps").accessibilityLabel("Clear all remaps")
                    }
                    LuxSwitch(isOn: $remapper.reapplyAtLaunch, label: "Apply Again When Atelier Opens")
                }
            }
            .padding(.vertical, DS.Space.s)
        }
        if let notice = remapper.notice {
            Text(notice).font(DS.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Login items

/// What starts with your Mac. Read-only: background items are managed by macOS, and the
/// public API only covers an app's own items.
struct LoginItemsCard: View {
    @State private var agents: [Agent] = []

    struct Agent: Identifiable, Hashable {
        let url: URL
        let label: String
        let program: String
        let scope: String
        /// The app this agent belongs to, when one can be found on disk.
        let app: URL?
        /// What a person would call it: the app's name, else the program's file name.
        let name: String
        var id: URL { url }
    }

    var body: some View {
        SectionHeader("Starts With Your Mac", symbol: "power", detail: "Launch agents and daemons on disk. Read only.")
        RowGroup {
            if agents.isEmpty {
                Text("Nothing found in the launch agent folders.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .frame(minHeight: 36)
            }
            ForEach(agents) { agent in
                // stagePreview: none, a list.
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: (agent.app ?? URL(fileURLWithPath: agent.program)).path))
                        .resizable().interpolation(.high).frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(agent.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(agent.scope).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([agent.url]) } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(Pressable(scale: 0.9)).foregroundStyle(DS.Ink.secondary)
                    .help("Show in Finder").accessibilityLabel("Show \(agent.name) in Finder")
                }
                .frame(minHeight: 36)
                .padding(.vertical, DS.Space.xxs)
                #if DEBUG
                .help("\(agent.label)\n\(agent.program)")
                #endif
                .accessibilityElement(children: .combine)
            }
            HStack {
                Text("To turn items off, use Login Items in System Settings.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                Chip("Open Login Items") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.vertical, DS.Space.s)
        }
        .task { agents = await Self.scan() }
    }

    nonisolated static func scan() async -> [Agent] {
        let folders: [(String, String)] = [
            (NSHomeDirectory() + "/Library/LaunchAgents", "You"),
            ("/Library/LaunchAgents", "All Users"),
            ("/Library/LaunchDaemons", "System"),
        ]
        var found: [Agent] = []
        for (folder, scope) in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
                let plist = NSDictionary(contentsOf: url)
                let label = plist?["Label"] as? String ?? String(name.dropLast(6))
                let program = plist?["Program"] as? String ?? (plist?["ProgramArguments"] as? [String])?.first ?? ""
                let app = owningApp(program: program, label: label)
                found.append(Agent(url: url, label: label, program: program, scope: scope, app: app,
                                   name: displayName(app: app, program: program, label: label)))
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The .app around the program, else an installed app whose bundle id the label starts with.
    nonisolated static func owningApp(program: String, label: String) -> URL? {
        if let range = program.range(of: ".app/", options: .backwards) {
            return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
        }
        if program.hasSuffix(".app") { return URL(fileURLWithPath: program) }
        var parts = label.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) { return url }
            parts.removeLast()
        }
        return nil
    }

    /// Never a raw bundle id: the app's own name, else the program's file name, else the label's
    /// last readable word.
    nonisolated static func displayName(app: URL?, program: String, label: String) -> String {
        if let app {
            let bundle = Bundle(url: app)
            if let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty { return name }
            return app.deletingPathExtension().lastPathComponent
        }
        let file = URL(fileURLWithPath: program).lastPathComponent
        if !file.isEmpty { return file }
        let generic: Set<String> = ["agent", "daemon", "helper", "plist", "launcher", "service", "update", "updater"]
        let words = label.split(separator: ".").map(String.init)
        return words.last { !generic.contains($0.lowercased()) && $0.count > 2 }?.capitalized ?? label
    }
}
