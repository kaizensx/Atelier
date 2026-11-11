import AppKit
import Carbon.HIToolbox
import SwiftUI

// A shortcut you choose by pressing it, and the Carbon hot keys behind every Dock shortcut.
// `DockShortcutRecorder` is meant for reuse: give it a binding and it records, shows and clears.

// MARK: - DockKeyCombo

/// A key and its modifiers, saved as a Carbon key code and Carbon modifier flags, the form
/// `RegisterEventHotKey` takes.
public struct DockKeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Carbon flags from AppKit ones.
    public static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    /// AppKit flags from Carbon ones.
    public static func cocoa(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// The glyphs in the order macOS menus use: ⌃⌥⇧⌘.
    public static func glyphs(_ carbon: UInt32) -> String {
        var text = ""
        if carbon & UInt32(controlKey) != 0 { text += "⌃" }
        if carbon & UInt32(optionKey) != 0 { text += "⌥" }
        if carbon & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbon & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    public var glyphs: String { Self.glyphs(modifiers) }

    /// Function keys and the like stand alone; anything else needs ⌃, ⌥ or ⌘, or it would
    /// take a key away from typing.
    public var valid: Bool {
        let strong = modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
        return strong || Self.functionKeys.contains(Int(keyCode))
    }

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
}

@MainActor
extension DockKeyCombo {
    /// "⌃⌥ D", as menus show it.
    public var label: String { glyphs + " " + DockKeyNames.name(Int(keyCode)) }
}

/// Key names for display, from the current keyboard layout, so ⌃⌥ Z reads right on AZERTY.
@MainActor
enum DockKeyNames {
    private static var cache: [Int: String] = [:]

    static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "Help",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func name(_ code: Int) -> String {
        if let known = special[code] { return known }
        if let known = cache[code] { return known }
        let found = translate(code) ?? "Key \(code)"
        cache[code] = found
        return found
    }

    /// The layout changed: names are read again.
    static func forget() { cache = [:] }

    private static func translate(_ code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).uppercased()
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

// MARK: - Conflicts

/// Who else in Atelier, or macOS itself, already answers to a shortcut.
@MainActor
enum ShortcutConflicts {
    /// Window Engine's keys, all under ⌃⌥ while its shortcuts are on.
    private static let engineKeys: [(Int, String)] = [
        (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"), (kVK_ANSI_D, "D"),
        (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_E, "E"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"), (kVK_ANSI_I, "I"),
        (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_C, "C"), (kVK_Return, "↩"), (kVK_ANSI_S, "S"),
    ]

    /// A sentence naming the clash, or nil. `except` is the Dock action being edited.
    static func message(for combo: DockKeyCombo, except: DockHubAction? = nil) -> String? {
        if !combo.valid { return "Add ⌃, ⌥ or ⌘, so the shortcut does not take a key away from typing." }
        for action in DockHubAction.allCases where action != except {
            if OwnDock.shared.hub.shortcut(action) == combo { return "Already used for \(action.title)." }
        }
        if combo == DockKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) {
            return "Atelier's command bar uses ⌥ Space."
        }
        if let orbit = Orbit.shared.activeShortcut, orbit.key == combo.keyCode, orbit.modifiers == combo.modifiers,
           except != .showOrbit {
            return "Orbit already uses \(orbit.label)."
        }
        if WindowEngine.shared.hotKeysEnabled, combo.modifiers == UInt32(controlKey | optionKey),
           let key = engineKeys.first(where: { UInt32($0.0) == combo.keyCode }) {
            return "Window Engine uses ⌃⌥ \(key.1) while its shortcuts are on."
        }
        if systemTakes(combo) { return "macOS already uses this shortcut, in Keyboard Shortcuts settings." }
        return nil
    }

    /// The shortcuts macOS has reserved and switched on: Spotlight, input sources, Mission Control.
    static func systemTakes(_ combo: DockKeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let cocoa = UInt32(DockKeyCombo.cocoa(combo.modifiers).rawValue)
        return list.contains { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == combo.keyCode,
                  let flags = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return false }
            let relevant = flags & 0x1F_0000
            return flags == combo.modifiers || relevant == cocoa
        }
    }
}

// MARK: - Recorder

/// Click, press the keys, done. Shows ⌃⌥⇧⌘ glyphs, has a clear button, and warns about a
/// clash with Atelier's own shortcuts or macOS's. Esc cancels; Delete clears.
public struct DockShortcutRecorder: View {
    @Binding var shortcut: DockKeyCombo?
    private let conflict: @MainActor (DockKeyCombo) -> String?
    /// Told when recording starts and stops, so hot keys can step aside while keys are read.
    private let recordingChanged: @MainActor (Bool) -> Void

    @State private var recording = false
    @State private var held: NSEvent.ModifierFlags = []
    @State private var monitor: MonitorBox?
    @State private var rejected: String?

    public init(shortcut: Binding<DockKeyCombo?>) {
        _shortcut = shortcut
        conflict = { ShortcutConflicts.message(for: $0) }
        recordingChanged = { DockHubHotKeys.shared.suspended = $0 }
    }

    init(shortcut: Binding<DockKeyCombo?>, conflict: @escaping @MainActor (DockKeyCombo) -> String?,
         recordingChanged: @escaping @MainActor (Bool) -> Void = { DockHubHotKeys.shared.suspended = $0 }) {
        _shortcut = shortcut
        self.conflict = conflict
        self.recordingChanged = recordingChanged
    }

    private var title: String {
        if recording {
            let glyphs = DockKeyCombo.glyphs(DockKeyCombo.carbon(held))
            return glyphs.isEmpty ? "Type shortcut" : glyphs + " …"
        }
        return shortcut?.label ?? "Record Shortcut"
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        if recording {
                            Circle().fill(Color(red: 1, green: 0.36, blue: 0.32)).frame(width: 6, height: 6)
                        }
                        Text(title)
                            .font(.system(size: 12.5, weight: shortcut == nil && !recording ? .medium : .semibold,
                                          design: shortcut == nil || recording ? .default : .rounded))
                            .monospacedDigit()
                            .foregroundStyle(shortcut == nil && !recording ? DS.Ink.secondary : DS.Ink.primary)
                            .contentTransition(.opacity)
                    }
                    .padding(.horizontal, 12)
                    .frame(minWidth: 108, minHeight: 28)
                    .background(recording ? AnyShapeStyle(DS.Ink.accent.opacity(0.22)) : AnyShapeStyle(DS.Ink.fillStrong),
                                in: .capsule)
                    .overlay { Capsule().strokeBorder(recording ? DS.Ink.accent : .clear, lineWidth: 1) }
                    .contentShape(.capsule)
                    .animation(DS.Motion.touch, value: recording)
                }
                .buttonStyle(Pressable())
                .accessibilityLabel(recording ? "Recording a shortcut. Press the keys, or Escape to cancel."
                                    : shortcut.map { "Shortcut \($0.label). Click to change." } ?? "Record a shortcut")
                if shortcut != nil, !recording {
                    Button {
                        shortcut = nil
                        rejected = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(DS.Ink.tertiary)
                            .frame(width: 22, height: 22).contentShape(.circle)
                    }
                    .buttonStyle(Pressable(scale: 0.9))
                    .accessibilityLabel("Clear shortcut")
                }
            }
            if let warning = rejected ?? shortcut.flatMap(conflict) {
                Text(warning)
                    .font(DS.caption).foregroundStyle(Color(red: 1, green: 0.66, blue: 0.4))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        rejected = nil
        held = []
        recording = true
        recordingChanged(true)
        let box = MonitorBox()
        box.token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            let type = event.type, code = Int(event.keyCode)
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            let used = MainActor.assumeIsolated { handle(type: type, code: code, flags: flags) }
            return used ? nil : event
        }
        monitor = box
    }

    private func stop() {
        if let token = monitor?.token { NSEvent.removeMonitor(token) }
        monitor = nil
        guard recording else { return }
        recording = false
        held = []
        recordingChanged(false)
    }

    /// True for the events it uses up.
    private func handle(type: NSEvent.EventType, code: Int, flags: NSEvent.ModifierFlags) -> Bool {
        switch type {
        case .leftMouseDown:
            stop()
            return false
        case .flagsChanged:
            held = flags
            return true
        case .keyDown:
            if flags.isEmpty, code == kVK_Escape { stop(); return true }
            if flags.isEmpty, code == kVK_Delete || code == kVK_ForwardDelete {
                shortcut = nil
                stop()
                return true
            }
            let combo = DockKeyCombo(keyCode: UInt32(code), modifiers: DockKeyCombo.carbon(flags))
            guard combo.valid else {
                rejected = "Add ⌃, ⌥ or ⌘, so the shortcut does not take a key away from typing."
                NSSound.beep()
                return true
            }
            rejected = nil
            shortcut = combo
            stop()
            return true
        default:
            return false
        }
    }
}

/// Holds the event monitor token for the recorder's state.
private final class MonitorBox {
    var token: Any?
}

// MARK: - Hot keys

/// Every Dock shortcut, as Carbon hot keys. One handler on the dispatcher target, like
/// Orbit's: it takes only its own presses and passes everything else on.
@MainActor
final class DockHubHotKeys: ObservableObject {
    static let shared = DockHubHotKeys()

    /// Shortcuts that could not be registered: another app holds them.
    @Published private(set) var failed: Set<DockHubAction> = []
    /// While a recorder reads keys, the hot keys step aside so the keys reach it.
    var suspended = false { didSet { if suspended != oldValue { register() } } }

    nonisolated private static let signature = OSType(0x4144_4842) // 'ADHB'
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    private var wanted: [DockHubAction: DockKeyCombo] = [:]
    private var dockOn = false

    /// The shortcuts to hold. Toggle Dock is held even while the dock is off, so it can come back.
    func apply(_ shortcuts: [String: DockKeyCombo], dockOn: Bool) {
        var map: [DockHubAction: DockKeyCombo] = [:]
        for (key, combo) in shortcuts {
            if let action = DockHubAction(rawValue: key) { map[action] = combo }
        }
        guard map != wanted || dockOn != self.dockOn || references.isEmpty != map.isEmpty else { return }
        wanted = map
        self.dockOn = dockOn
        register()
    }

    func label(_ action: DockHubAction) -> String? {
        guard !failed.contains(action) else { return nil }
        return wanted[action]?.label
    }

    private func install() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == DockHubHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let index = Int(id.id)
            MainActor.assumeIsolated {
                guard DockHubAction.allCases.indices.contains(index) else { return }
                OwnDock.shared.perform(DockHubAction.allCases[index])
            }
            return noErr
        }, 1, &type, nil, &handler)
    }

    private func register() {
        references.forEach { UnregisterEventHotKey($0) }
        references = []
        var failures: Set<DockHubAction> = []
        defer { if failures != failed { failed = failures } }
        guard !suspended, !wanted.isEmpty else { return }
        install()
        for (index, action) in DockHubAction.allCases.enumerated() {
            guard let combo = wanted[action], combo.valid, dockOn || action == .toggleDock else { continue }
            var made: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            if RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetEventDispatcherTarget(), 0, &made) == noErr, let made {
                references.append(made)
            } else {
                failures.insert(action)
            }
        }
    }
}

// MARK: - Rows

/// One recorder per Dock action, with what each does and whether another app holds it.
/// One grouped surface, a compact row per action; the chapter's section header says where
/// they work.
struct DockHubShortcutRows: View {
    @ObservedObject private var dock = OwnDock.shared
    @ObservedObject private var keys = DockHubHotKeys.shared

    var body: some View {
        RowGroup {
            ForEach(DockHubAction.allCases) { action in
                VStack(alignment: .trailing, spacing: 3) {
                    SettingRow(title: action.title, detail: action.detail, density: .compact) {
                        DockShortcutRecorder(shortcut: Binding(get: { dock.hub.shortcut(action) },
                                                           set: { dock.setShortcut($0, for: action) }),
                                         conflict: { ShortcutConflicts.message(for: $0, except: action) })
                    }
                    if keys.failed.contains(action) {
                        Text("Another app holds this shortcut, so it does nothing here. Pick another one.")
                            .font(DS.caption).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .dockHubRow()
            }
        }
    }
}
