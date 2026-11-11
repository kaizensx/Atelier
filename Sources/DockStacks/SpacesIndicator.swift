import AppKit
import SwiftUI
import DockCore

// MARK: - Spaces in the menu bar
//
// Which desktop you are on, at a glance, in the spirit of Spaceman: dots, numbers or your own
// names in the menu bar, the current one lit. The list comes from the window server's managed
// spaces (read only). Moving to another one goes through Instant Spaces (InstantSpaces.swift):
// no slide when Switch Instantly is on and works here, else Control-Arrow, macOS's own
// shortcut, as many times as it takes. The menu can also send the front window to a desktop.

struct DesktopSpace: Identifiable, Equatable {
    let id: String      // the space's uuid, stable across launches
    let number: Int     // 1-based, in Mission Control's order
    let current: Bool
    /// The window server's ManagedSpaceID, what switching and sending address.
    var sid: Int = 0
}

enum SpacesLook: String, CaseIterable, Identifiable {
    case dots, numbers, names
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dots: "Dots"
        case .numbers: "Numbers"
        case .names: "Names"
        }
    }
}

@MainActor
final class SpacesIndicator: NSObject, ObservableObject {
    static let shared = SpacesIndicator()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "spaces.enabled"); apply() } }
    @Published var look: SpacesLook { didSet { store.set(look.rawValue, forKey: "spaces.look"); render() } }
    @Published private(set) var spaces: [DesktopSpace] = []
    @Published private(set) var names: [String: String]

    private let store = UserDefaults.standard
    private var item: NSStatusItem?
    private var observer: NSObjectProtocol?
    /// Adding or removing a desktop posts no notification, so the list is re-read now and then
    /// while the item shows. Reading it is one cheap window-server call.
    private var poll: Timer?

    private override init() {
        enabled = UserDefaults.standard.bool(forKey: "spaces.enabled")
        look = SpacesLook(rawValue: UserDefaults.standard.string(forKey: "spaces.look") ?? "") ?? .dots
        names = UserDefaults.standard.dictionary(forKey: "spaces.names") as? [String: String] ?? [:]
        super.init()
        refresh()
    }

    func resume() {
        InstantSpaces.shared.resume()
        if enabled { apply() }
    }

    func name(_ space: DesktopSpace) -> String { names[space.id].flatMap { $0.isEmpty ? nil : $0 } ?? "Desktop \(space.number)" }

    func rename(_ space: DesktopSpace, to name: String) {
        names[space.id] = name.trimmingCharacters(in: .whitespaces)
        store.set(names, forKey: "spaces.names")
        render()
    }

    // MARK: Reading the window server

    /// The main display's desktops, in order. Full-screen apps are left out: they are not places you name.
    /// Returns true when the list changed.
    @discardableResult
    func refresh() -> Bool {
        guard let display = SpacesEngine.mainDisplay() else { return false }
        let list = Self.desktops(of: display)
        guard list != spaces else { return false }
        spaces = list
        return true
    }

    static func desktops(of display: ManagedDisplay) -> [DesktopSpace] {
        display.desktops.enumerated().map { index, space in
            DesktopSpace(id: space.uuid, number: index + 1, current: space.id == display.current, sid: space.id)
        }
    }

    // MARK: Menu bar item

    private func apply() {
        if enabled {
            if item == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.target = self
                item.button?.action = #selector(clicked)
                item.button?.setAccessibilityLabel("Spaces")
                self.item = item
            }
            if observer == nil {
                observer = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        SpacesIndicator.shared.refresh(); SpacesIndicator.shared.render()
                        if SpacesCardPresence.visible { InstantSpaces.shared.refreshWindows() }
                    }
                }
            }
            if poll == nil {
                let timer = Timer(timeInterval: 2, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if SpacesIndicator.shared.refresh() { SpacesIndicator.shared.render() }
                    }
                }
                timer.tolerance = 0.5
                RunLoop.main.add(timer, forMode: .common)
                poll = timer
            }
            refresh()
            render()
        } else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            poll?.invalidate()
            poll = nil
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
        }
    }

    private func render() {
        guard let button = item?.button else { return }
        let renderer = ImageRenderer(content: SpacesBadge(spaces: spaces, look: look, name: name))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let image = renderer.nsImage {
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = spaces.first(where: \.current).map(name)
    }

    @objc private func clicked() {
        if refresh() { render() }
        // With separate Spaces per display, switching and sending act on the display under the
        // pointer, which is the one whose menu bar was clicked: list that display's desktops,
        // so every entry is reachable. With one shared list this is the main display's.
        let displays = SpacesEngine.displays()
        let shown = SpaceWalk.displayForShortcuts(displays, cursorDisplay: SpacesEngine.cursorDisplayIdentifier())
            .map(Self.desktops(of:)) ?? spaces
        let menu = NSMenu()
        for space in shown {
            let entry = NSMenuItem(title: name(space), action: #selector(choose(_:)), keyEquivalent: space.number <= 9 ? "\(space.number)" : "")
            entry.keyEquivalentModifierMask = []
            entry.target = self
            entry.tag = space.sid
            entry.state = space.current ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        // Send the front app's window: status items do not take focus, so it is still the user's.
        let send = NSMenuItem(title: "Send Window to", action: nil, keyEquivalent: "")
        let targets = NSMenu()
        for space in shown where !space.current {
            let entry = NSMenuItem(title: name(space), action: #selector(sendTo(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = space.sid
            targets.addItem(entry)
        }
        send.submenu = targets
        send.isEnabled = InstantSpaces.shared.canSend && !targets.items.isEmpty
        if !InstantSpaces.shared.canSend { send.toolTip = "Not available on this version of macOS." }
        menu.addItem(send)
        menu.addItem(.separator())
        let names = NSMenuItem(title: "Name Your Desktops…", action: #selector(openSettings), keyEquivalent: "")
        names.target = self
        menu.addItem(names)
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    // The menu lists the clicked display's desktops, so its items carry ManagedSpaceIDs rather
    // than numbers: with separate Spaces per display, "Desktop 2" of another display differs.
    @objc private func choose(_ sender: NSMenuItem) { InstantSpaces.shared.go(toSpace: sender.tag) }
    @objc private func sendTo(_ sender: NSMenuItem) { InstantSpaces.shared.sendFocused(toSpace: sender.tag) }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "atelier://studio?chapter=menubar")!)
    }

    /// Moves to desktop N: instantly when that is on, else with Control-Arrow (InstantSpaces).
    func go(to number: Int) {
        InstantSpaces.shared.go(toDesktop: number)
    }
}

/// What the menu bar shows: one mark per desktop, the current one filled.
struct SpacesBadge: View {
    let spaces: [DesktopSpace]
    let look: SpacesLook
    let name: (DesktopSpace) -> String

    var body: some View {
        HStack(spacing: look == .dots ? 4 : 5) {
            ForEach(spaces) { space in
                switch look {
                case .dots:
                    Circle().fill(.black.opacity(space.current ? 1 : 0.35))
                        .frame(width: space.current ? 8 : 6, height: space.current ? 8 : 6)
                case .numbers:
                    // A template image keeps only alpha, so a white digit on the black tile would
                    // vanish. The current digit is cut out of its tile instead.
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(space.current ? 1 : 0))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.black.opacity(0.5), lineWidth: space.current ? 0 : 1)
                        Text("\(space.number)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.black)
                            .blendMode(space.current ? .destinationOut : .normal)
                    }
                    .frame(width: 16, height: 15)
                    .compositingGroup()
                case .names:
                    if space.current {
                        Text(name(space)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    } else {
                        Circle().fill(.black.opacity(0.35)).frame(width: 5, height: 5)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 18)
    }
}

