import AppKit
import Carbon.HIToolbox
import DockCore
import SwiftUI

// MARK: - Key combos

/// A global shortcut in Carbon terms, the only public way to own one without a key tap.
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier bits: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    var modifiers: UInt32

    /// Nil for keys that cannot stand alone as a global shortcut.
    init?(key: UInt16, flags raw: NSEvent.ModifierFlags) {
        let flags = raw.intersection(.deviceIndependentFlagsMask)
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= UInt32(cmdKey) }
        if flags.contains(.option) { bits |= UInt32(optionKey) }
        if flags.contains(.control) { bits |= UInt32(controlKey) }
        if flags.contains(.shift) { bits |= UInt32(shiftKey) }
        let code = UInt32(key)
        // A plain letter would steal typing everywhere. Function keys may stand alone.
        let strong = bits & UInt32(cmdKey | optionKey | controlKey) != 0
        guard strong || Self.functionKeys.contains(Int(code)) else { return nil }
        keyCode = code
        modifiers = bits
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
    }

    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                                 kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                                 kVK_F16, kVK_F17, kVK_F18, kVK_F19]

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + KeyNames.name(Int(keyCode))
    }
}

enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]

    /// US-layout names. Good enough for a label; the shortcut itself is the key code.
    static func name(_ code: Int) -> String { special[code] ?? "Key \(code)" }

    /// Keys that mean something on their own, worth showing even without a modifier.
    static let standalone: Set<Int> = [kVK_Return, kVK_Tab, kVK_Delete, kVK_ForwardDelete, kVK_Escape,
                                       kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                       kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
                                       kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                       kVK_F9, kVK_F10, kVK_F11, kVK_F12]
}

// MARK: - Tool actions

enum ToolAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case center, resizePercent, cycleWindows, nextZone, pinWindow, annotate, ruler, colourPicker, findCursor
    // Toolbox. Appended, because hot keys are registered by index.
    case textGrab, plainClipboard, quickLookClipboard, recordScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .center: "Centre Window"
        case .resizePercent: "Resize to Percent"
        case .cycleWindows: "Cycle App Windows"
        case .nextZone: "Next Custom Zone"
        case .pinWindow: "Pin Window"
        case .annotate: "Annotate Screen"
        case .ruler: "Ruler"
        case .colourPicker: "Colour Picker"
        case .findCursor: "Find Cursor"
        case .textGrab: "Text Grab"
        case .plainClipboard: "Plain-text Clipboard"
        case .quickLookClipboard: "Quick Look Clipboard"
        case .recordScreen: "Record Screen"
        }
    }

    var symbol: String {
        switch self {
        case .center: "rectangle.center.inset.filled"
        case .resizePercent: "arrow.up.left.and.arrow.down.right"
        case .cycleWindows: "rectangle.stack"
        case .nextZone: "rectangle.split.3x1"
        case .pinWindow: "pip"
        case .annotate: "pencil.tip.crop.circle"
        case .ruler: "ruler"
        case .colourPicker: "eyedropper"
        case .findCursor: "cursorarrow.rays"
        case .textGrab: "text.viewfinder"
        case .plainClipboard: "doc.plaintext"
        case .quickLookClipboard: "eye"
        case .recordScreen: "record.circle"
        }
    }

    /// Window actions move other apps' windows, so they need Accessibility.
    var needsAccessibility: Bool {
        switch self {
        case .center, .resizePercent, .cycleWindows, .nextZone: true
        default: false
        }
    }

    @MainActor func perform() {
        switch self {
        case .center: WindowEngine.shared.apply(.center)
        case .resizePercent: WindowEngine.shared.resizeFront(percent: Tools.shared.percent)
        case .cycleWindows: WindowEngine.shared.cycleFrontAppWindows()
        case .nextZone: WindowEngine.shared.nextCustomZone()
        case .pinWindow: WindowPin.shared.pinFrontWindow()
        case .annotate: DesktopPlus.shared.toggleAnnotate()
        case .ruler: DesktopPlus.shared.toggleRuler()
        case .colourPicker: DesktopPlus.shared.pickColour()
        case .findCursor: DesktopPlus.shared.findCursor()
        case .textGrab: TextGrab.shared.grab()
        case .plainClipboard: ClipboardTools.shared.run(.plain)
        case .quickLookClipboard: _ = QuickLookTool.previewClipboard()
        case .recordScreen: ScreenRecorder.shared.toggle()
        }
    }
}

/// 'ATol'. Window Engine uses 'WEng' and Command uses 'DSTK'.
private let toolsHotKeySignature = OSType(0x41546F6C)

/// Global shortcuts for the tools. Nothing is registered until the owner records one.
@MainActor
final class ToolsHotKeys: ObservableObject {
    static let shared = ToolsHotKeys()
    private let store = UserDefaults.standard

    @Published private(set) var combos: [ToolAction: KeyCombo] = [:]
    @Published private(set) var conflicts: Set<ToolAction> = []

    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var started = false

    private init() {
        if let data = store.data(forKey: "tools.hotKeys"),
           let saved = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (key, combo) in saved { if let action = ToolAction(rawValue: key) { combos[action] = combo } }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        // A later turn of the run loop puts this handler in front of the Command one, which claims every key.
        DispatchQueue.main.async { ToolsHotKeys.shared.register() }
    }

    func combo(for action: ToolAction) -> KeyCombo? { combos[action] }

    func set(_ combo: KeyCombo?, for action: ToolAction) {
        // One combo, one action.
        if let combo { for (other, existing) in combos where existing == combo && other != action { combos[other] = nil } }
        combos[action] = combo
        let raw = Dictionary(uniqueKeysWithValues: combos.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { store.set(data, forKey: "tools.hotKeys") }
        register()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == toolsHotKeySignature else { return OSStatus(eventNotHandledErr) }
            let index = Int(id.id)
            MainActor.assumeIsolated { ToolsHotKeys.shared.fire(index) }
            return noErr
        }, 1, &type, nil, &handler)
    }

    private func register() {
        guard started else { return }
        references.forEach { UnregisterEventHotKey($0) }
        references = []
        conflicts = []
        guard !combos.isEmpty else { return }
        installHandler()
        for (index, action) in ToolAction.allCases.enumerated() {
            guard let combo = combos[action] else { continue }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: toolsHotKeySignature, id: UInt32(index))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references.append(reference) } else { conflicts.insert(action) }
        }
    }

    private func fire(_ index: Int) {
        guard ToolAction.allCases.indices.contains(index) else { return }
        ToolAction.allCases[index].perform()
    }

    /// While recording, a registered combo must not fire its old action.
    func suspend(_ on: Bool) {
        if on { references.forEach { UnregisterEventHotKey($0) }; references = [] } else { register() }
    }
}

// MARK: - Shortcut recorder

@MainActor
final class RecorderModel: ObservableObject {
    @Published var recording = false
    @Published var rejected = false
    private var monitor: Any?

    func begin(_ done: @escaping @MainActor (KeyCombo?) -> Void) {
        end()
        recording = true
        rejected = false
        ToolsHotKeys.shared.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode, flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let model = Self.active else { return false }
                return model.handle(code: code, flags: flags)
            }
            return consumed ? nil : event
        }
        Self.active = self
        self.done = done
    }

    private static weak var active: RecorderModel?
    private var done: (@MainActor (KeyCombo?) -> Void)?

    private func handle(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let callback = done
        if code == UInt16(kVK_Escape) { end(); return true }
        if code == UInt16(kVK_Delete) && flags.intersection([.command, .option, .control]).isEmpty {
            end(); callback?(nil); return true
        }
        guard let combo = KeyCombo(key: code, flags: flags) else {
            withAnimation(DS.Motion.touch) { rejected = true }
            return true
        }
        end()
        callback?(combo)
        return true
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        done = nil
        if Self.active === self { Self.active = nil }
        if recording { ToolsHotKeys.shared.suspend(false) }
        recording = false
    }
}

/// Click, then press the shortcut. Escape cancels; Delete clears.
struct ShortcutRecorder: View {
    let action: ToolAction
    @ObservedObject private var keys = ToolsHotKeys.shared
    @StateObject private var model = RecorderModel()

    var body: some View {
        let combo = keys.combo(for: action)
        HStack(spacing: 4) {
            Button {
                if model.recording { model.end() } else { model.begin { keys.set($0, for: action) } }
            } label: {
                Text(model.recording ? (model.rejected ? "Add ⌘, ⌥ or ⌃" : "Type shortcut…") : combo?.display ?? "Set Shortcut")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(model.recording ? DS.Ink.primary : combo == nil ? DS.Ink.secondary : DS.Ink.primary)
                    .frame(minWidth: 86).frame(height: 28).padding(.horizontal, 8)
                    .background(model.recording ? AnyShapeStyle(DS.Ink.accent.opacity(0.55)) : AnyShapeStyle(DS.Ink.fillStrong),
                                in: .rect(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if keys.conflicts.contains(action) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.orange.opacity(0.8), lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(Pressable(scale: 0.96))
            .help(keys.conflicts.contains(action) ? "Another app already owns this shortcut." : "Click, then press the keys. Escape cancels.")
            if combo != nil && !model.recording {
                Button { keys.set(nil, for: action) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(Pressable())
                .accessibilityLabel("Clear \(action.title) shortcut")
            }
        }
        .animation(DS.Motion.settle, value: model.recording)
        .onDisappear { model.end() }
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(combo?.display ?? "None")
    }
}

// MARK: - Tools store

/// Custom layouts, per-app rules and the resize share. Window moves go through WindowEngine.
@MainActor
final class Tools: ObservableObject {
    static let shared = Tools()
    private let store = UserDefaults.standard

    @Published var layouts: [CustomLayout] { didSet { save(layouts, "tools.layouts") } }
    @Published var activeLayout: UUID? { didSet { store.set(activeLayout?.uuidString, forKey: "tools.activeLayout") } }
    @Published var shiftDragZones: Bool { didSet { store.set(shiftDragZones, forKey: "tools.shiftDrag"); WindowEngine.shared.toolsChanged() } }
    @Published var rules: [AppRule] { didSet { save(rules, "tools.rules") } }
    @Published var rulesEnabled: Bool { didSet { store.set(rulesEnabled, forKey: "tools.rulesOn"); applyRules() } }
    @Published var percent: Double { didSet { store.set(percent, forKey: "tools.percent") } }

    private var launchObserver: NSObjectProtocol?
    private var started = false

    private init() {
        layouts = Self.load("tools.layouts") ?? []
        activeLayout = store.string(forKey: "tools.activeLayout").flatMap(UUID.init(uuidString:))
        shiftDragZones = store.bool(forKey: "tools.shiftDrag")
        rules = Self.load("tools.rules") ?? []
        rulesEnabled = store.bool(forKey: "tools.rulesOn")
        percent = store.object(forKey: "tools.percent") as? Double ?? 0.8
    }

    func start() {
        guard !started else { return }
        started = true
        applyRules()
        ToolsHotKeys.shared.start()
    }

    var active: CustomLayout? { layouts.first { $0.id == activeLayout } ?? layouts.first }

    func layout(_ id: UUID) -> CustomLayout? { layouts.first { $0.id == id } }

    private func applyRules() {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        guard rulesEnabled else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier, bundle = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let pid, let bundle, let rule = ToolsGeometry.rule(for: bundle, in: Tools.shared.rules) else { return }
                Tools.shared.place(pid: pid, rule: rule, attempt: 0)
            }
        }
    }

    /// The first window can take a moment. Try a few times, then give up quietly.
    private func place(pid: pid_t, rule: AppRule, attempt: Int) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        if WindowEngine.shared.place(app: app, placement: rule.placement, display: rule.display) { return }
        guard attempt < 16 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Tools.shared.place(pid: pid, rule: rule, attempt: attempt + 1) }
    }

    func applyRuleNow(_ rule: AppRule) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: rule.bundleID).first else { return }
        _ = WindowEngine.shared.place(app: app, placement: rule.placement, display: rule.display)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { store.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
