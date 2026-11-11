import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DockCore
import QuartzCore
import SwiftUI

// MARK: - Edge Stash
//
// Hold the stash key (⌘ by default) while dragging a window and let go against the left or right
// edge of the screen, or fling it that way, or press ⌃⌥⌘← / ⌃⌥⌘→: the window slides out until
// only a two-point sliver is left, and a small glass tab with the app's icon marks it on the
// edge. Resting the pointer on the tab (or on the sliver) slides the window back in over
// everything; moving away slides it out again. Clicking the tab, ⌃⌥⌘↓, turning the feature off,
// quitting Atelier or a crash puts every window back exactly where it was.
//
// The window really leaves the screen: Accessibility moves it, as Move & Resize Anywhere does.
// macOS keeps at least one point of a window on some display and pulls a window that would be
// fully off back to 40 points (measured on 27.3, see EdgeStashLogic), so the stash keeps a
// sliver and reads its frame back after the move. Only outer edges qualify: a window pushed
// out towards a neighbouring display would land on it.
//
// Nothing can be lost off screen. Each stash is saved (`edgeStash.records`) with the frame the
// window had before. On quit and on turning off, every window goes back synchronously. After a
// crash, the next launch finds the windows at their stashed frames and moves them back. When an
// app quits with a window stashed, the record is kept as an orphan; the next time that app opens
// a window at the stashed frame (apps reopen windows where they saved them), it is moved back.
//
// Placement follows the order that works for every app tried: origin, size, origin, then read
// back and retry, because some apps clamp a size against the old position and others refuse a
// move made while their size is still changing.
//
// Motion: a display link on the window's screen (120 Hz on ProMotion) writes the origin once per
// frame from a closed-form spring (WindowGeometry.Spring), so a new target mid-slide keeps the
// velocity. Idle, the engine polls the pointer 30 times a second and touches no window.

enum EdgeStashKey: String, CaseIterable, Sendable {
    case option, control, command

    var symbol: String {
        switch self {
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .control: .control
        case .command: .command
        }
    }

    /// Exactly this key among ⌃⌥⇧⌘: with more held, the person means some other shortcut.
    func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.control, .option, .shift, .command]) == self.flags
    }
}

/// A thin layer over the Accessibility calls the stash needs. Reads and writes fail quietly:
/// a window can close at any moment and an app can stop answering.
enum StashAX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success ? raw : nil
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p = value(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              let s = value(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func set(_ window: AXUIElement, origin: CGPoint) -> Bool {
        var point = origin
        guard let v = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) == .success
    }

    static func set(_ window: AXUIElement, size: CGSize) {
        var dimensions = size
        guard let v = AXValueCreate(.cgSize, &dimensions) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard let raw = value(app(pid), kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.25)
        return window
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        guard let list = value(app(pid), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.filter { (value($0, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole }
    }

    /// A standard window that can be moved and is not full screen.
    static func isStashable(_ window: AXUIElement) -> Bool {
        guard (value(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
              (value(window, "AXFullScreen") as? Bool) != true,
              (value(window, kAXMinimizedAttribute) as? Bool) != true else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
    }

    nonisolated(unsafe) private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }()

    /// The window under a point, and its app, unless it is Atelier's own.
    static func window(at point: CGPoint) -> (AXUIElement, pid_t)? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid() else { return nil }
        if let window = value(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            element = window as! AXUIElement
        } else {
            for _ in 0..<32 {
                if (value(element, kAXRoleAttribute) as? String) == kAXWindowRole { break }
                guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
                element = parent as! AXUIElement
            }
        }
        guard (value(element, kAXRoleAttribute) as? String) == kAXWindowRole else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        return (element, pid)
    }

    static func title(_ window: AXUIElement) -> String { (value(window, kAXTitleAttribute) as? String) ?? "" }

    static func raise(_ window: AXUIElement) { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }

    /// Brings an app forward through Accessibility, which works from a background app where
    /// `NSRunningApplication.activate` may be refused by cooperative activation.
    static func bringForward(_ pid: pid_t) {
        AXUIElementSetAttributeValue(app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    /// Origin, size, origin: the order every app tried accepts. Returns the frame read back.
    @discardableResult
    static func place(_ window: AXUIElement, _ target: CGRect) -> CGRect? {
        set(window, origin: target.origin)
        set(window, size: target.size)
        set(window, origin: target.origin)
        return frame(window)
    }

    /// Places and verifies, retrying a few times with a short pause. Synchronous, for quit.
    @discardableResult
    static func placeVerified(_ window: AXUIElement, _ target: CGRect, tries: Int = 4) -> Bool {
        for attempt in 0..<tries {
            if let actual = place(window, target), EdgeStashLogic.matches(actual, target) { return true }
            if attempt < tries - 1 { usleep(40_000) }
        }
        return false
    }

    static func windowNumber(pid: pid_t, frame: CGRect) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let raw = info[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary),
                  EdgeStashLogic.matches(bounds, frame, tolerance: 2) else { continue }
            return info[kCGWindowNumber as String] as? Int
        }
        return nil
    }
}

private let stashHotKeySignature = OSType(0x4553_7448) // "EStH"

@MainActor
final class EdgeStash: ObservableObject {
    static let shared = EdgeStash()

    enum Phase: String { case stashing, stashed, peeking, peeked, hiding, restoring }

    /// One window in the stash.
    @MainActor
    final class Item: @MainActor Identifiable {
        var record: EdgeStashRecord
        let window: AXUIElement
        let display: EdgeStashLogic.Display
        var phase: Phase = .stashing
        var x: WindowGeometry.Spring
        var y: WindowGeometry.Spring
        var target: CGPoint
        var peek: CGRect = .zero
        var tab = CGRect.zero
        let panel: EdgeStashTabPanel
        /// The app that was in front before a peek brought this one forward.
        var previousFront: pid_t?
        var broughtForward = false
        /// Peeked by a key or the test hook: stays out until the pointer has been over it once.
        var pinned = false
        var pointerVisited = false
        /// Off until the pointer has left the tab once, so a drop at the edge does not peek at once.
        var armed = false
        var leftAt: Double?
        var lastStep = 0.0
        var onArrive: (() -> Void)?
        var id: UUID { record.id }

        init(record: EdgeStashRecord, window: AXUIElement, display: EdgeStashLogic.Display, from: CGPoint) {
            self.record = record
            self.window = window
            self.display = display
            x = .init(value: from.x)
            y = .init(value: from.y)
            target = from
            panel = EdgeStashTabPanel(edge: record.edge)
        }
    }

    // MARK: Settings ("edgeStash.")

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "edgeStash.enabled"); apply() } }
    @Published var key: EdgeStashKey { didSet { store.set(key.rawValue, forKey: "edgeStash.key") } }
    @Published var fling: Bool { didSet { store.set(fling, forKey: "edgeStash.fling") } }
    @Published var hotKeysEnabled: Bool { didSet { store.set(hotKeysEnabled, forKey: "edgeStash.hotKeys"); registerHotKeys() } }
    /// Seconds the pointer may be away from a peeked window before it slides out again.
    @Published var returnDelay: Double { didSet { store.set(returnDelay, forKey: "edgeStash.returnDelay") } }
    @Published var bringForward: Bool { didSet { store.set(bringForward, forKey: "edgeStash.bringForward") } }

    @Published private(set) var items: [Item] = []
    @Published private(set) var status: String?
    @Published private(set) var hotKeyConflicts: [String] = []
    var trusted: Bool { AXIsProcessTrusted() }

    private let store = UserDefaults.standard
    private var started = false
    private var timer: Timer?
    private var link: CADisplayLink?
    private let ticker = EdgeStashTicker()
    private var observers: [NSObjectProtocol] = []
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var lastExternal: pid_t?
    private var orphans: [EdgeStashRecord] = []

    // The drag being watched.
    private var wasDown = false
    private var samples: [EdgeStashLogic.Sample] = []
    private var drag: (window: AXUIElement, pid: pid_t, start: CGRect, moved: Bool)?
    private var keySeenAt = -1.0
    private var lookedUp = false
    private var grabOffset = CGSize.zero

    /// True while the stash key is held with the feature on: Snap Zones stand aside then, so
    /// one drop is never both a snap and a stash.
    var claimsDrag: Bool { enabled && key.isHeld(NSEvent.modifierFlags) }
    private var lastValidate = 0.0

    // Diagnostics.
    private(set) var stashes = 0
    private(set) var peeks = 0
    private(set) var restores = 0
    private(set) var framesWritten = 0
    private var slideTicks = 0
    private var slideStart = 0.0
    private(set) var lastSlideFPS = 0.0
    private(set) var lastRestoreCheck = "-"

    private init() {
        enabled = store.bool(forKey: "edgeStash.enabled")
        // ⌘ by default: ⌥ is macOS's own tiling accelerator, ⌃ turns a click into a right-click.
        key = store.string(forKey: "edgeStash.key").flatMap(EdgeStashKey.init) ?? .command
        fling = store.object(forKey: "edgeStash.fling") as? Bool ?? true
        hotKeysEnabled = store.object(forKey: "edgeStash.hotKeys") as? Bool ?? true
        returnDelay = store.object(forKey: "edgeStash.returnDelay") as? Double ?? 0.45
        bringForward = store.object(forKey: "edgeStash.bringForward") as? Bool ?? true
        orphans = EdgeStashRecord.decode(store.data(forKey: "edgeStash.orphans"))
            .filter { Date().timeIntervalSince($0.date) < EdgeStashRecord.orphanLifetime }
    }

    // MARK: Life cycle

    /// At launch. Puts back anything a crash left stashed, then starts if the owner turned it on.
    func resume() {
        recoverAfterCrash()
        watchApps()
        if enabled { apply() }
    }

    /// For applicationWillTerminate: every window back where it was, before the process ends.
    func restoreOnQuit() {
        for item in items {
            let target = EdgeStashLogic.restoreFrame(item.record.original, displays: displays())
            StashAX.placeVerified(item.window, target)
            item.panel.close()
        }
        items = []
        persist()
        stopLink()
    }

    private func apply() {
        if enabled {
            guard !started else { return }
            started = true
            let next = Timer(timeInterval: 1 / 30, repeats: true) { _ in MainActor.assumeIsolated { EdgeStash.shared.tick() } }
            next.tolerance = 0.005
            RunLoop.main.add(next, forMode: .common)
            timer = next
            registerHotKeys()
        } else {
            guard started else { return }
            started = false
            timer?.invalidate()
            timer = nil
            unregisterHotKeys()
            unstashAll(animated: false)
            drag = nil
            samples = []
        }
        objectWillChange.send()
    }

    private func watchApps() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid, pid != getpid() { EdgeStash.shared.lastExternal = pid }
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { EdgeStash.shared.appQuit(pid) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { EdgeStash.shared.appLaunched(app) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            // A display came or went: the edges moved. Everything comes back rather than risk it.
            MainActor.assumeIsolated { EdgeStash.shared.unstashAll(animated: false) }
        })
    }

    // MARK: Geometry

    private var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    private func displays() -> [EdgeStashLogic.Display] {
        let height = primaryHeight
        return NSScreen.screens.map {
            .init(frame: WindowGeometry.flipped($0.frame, primaryHeight: height),
                  visible: WindowGeometry.flipped($0.visibleFrame, primaryHeight: height))
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// macOS 15+ edge tiling, read live; we never write it.
    private var appleTilingOn: Bool {
        let domain = "com.apple.WindowManager" as CFString
        func flag(_ key: String) -> Bool? { CFPreferencesCopyAppValue(key as CFString, domain) as? Bool }
        return MacPlatform.major >= 15 && (flag(WindowsCompatTiling.edgeDragKey) ?? true)
    }

    // MARK: Stashing

    /// The app the keys and the test hook act on: the front one, or the last one in front
    /// before Atelier.
    private func targetPID(bundleID: String? = nil) -> pid_t? {
        if let bundleID { return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { return front.processIdentifier }
        return lastExternal
    }

    func item(for window: AXUIElement) -> Item? { items.first { CFEqual($0.window, window) } }

    /// Stashes a window on an edge. `original` is the frame to come back to; by default the
    /// frame it has now. Returns a reason when it refuses.
    @discardableResult
    func stash(_ window: AXUIElement, pid: pid_t, edge: EdgeStashLogic.Edge, original: CGRect? = nil, drop: CGRect? = nil) -> String? {
        guard trusted else { return "accessibility" }
        guard pid != getpid() else { return "atelier" }
        guard item(for: window) == nil else { return "already-stashed" }
        guard StashAX.isStashable(window), var frame = StashAX.frame(window) else { return "not-stashable" }
        if let drop {
            // Back to the size it had in the hand, in case something resized it on the drop.
            if !EdgeStashLogic.matches(CGRect(origin: frame.origin, size: drop.size), frame) {
                StashAX.set(window, size: drop.size)
                frame = StashAX.frame(window) ?? frame
            }
            frame = CGRect(x: frame.minX, y: drop.minY, width: frame.width, height: frame.height)
        }
        let all = displays()
        let back = original ?? frame
        guard let index = EdgeStashLogic.displayIndex(for: back, in: all) else { return "no-display" }
        let span = Double(frame.minY)...Double(frame.maxY)
        guard EdgeStashLogic.isOuterEdge(edge, of: index, span: span, in: all) else {
            status = "Another display is beyond that edge."
            return "inner-edge"
        }
        let display = all[index]
        let stashed = EdgeStashLogic.stashedFrame(for: frame, edge: edge, display: display)
        let app = NSRunningApplication(processIdentifier: pid)
        let record = EdgeStashRecord(pid: pid, bundleID: app?.bundleIdentifier, appName: app?.localizedName ?? "App",
                                     title: StashAX.title(window), edge: edge, original: back, stashed: stashed,
                                     windowNumber: StashAX.windowNumber(pid: pid, frame: frame))
        let item = Item(record: record, window: window, display: display, from: frame.origin)
        item.panel.setIcon(app?.icon)
        items.append(item)
        persist() // Saved before the window moves, so a crash mid-slide still has it.
        stashes += 1
        status = nil
        layoutTabs()
        slide(item, to: stashed.origin, phase: .stashing) { [weak self, weak item] in
            guard let self, let item else { return }
            // Something may have resized it on the way (macOS tiling answering the same drop).
            if let actual = StashAX.frame(item.window), !EdgeStashLogic.matches(actual, stashed) {
                StashAX.place(item.window, stashed)
            }
            // What macOS really left on screen is what the stash remembers.
            if let actual = StashAX.frame(item.window) { item.record.stashed = actual }
            item.phase = .stashed
            self.persist()
            self.layoutTabs()
        }
        return nil
    }

    /// The front app's focused window: stash it, or if it is already stashed, show or hide it.
    func stashFront(edge: EdgeStashLogic.Edge, bundleID: String? = nil) -> String {
        guard trusted else { return "error=accessibility" }
        if let pid = targetPID(bundleID: bundleID), let window = StashAX.focusedWindow(pid: pid) {
            if let existing = item(for: window) {
                togglePeek(existing, pinned: true)
                return "toggled=\(existing.record.appName)"
            }
            if let reason = stash(window, pid: pid, edge: edge) {
                // Nothing to stash: the newest stash on that edge peeks instead.
                if let newest = items.last(where: { $0.record.edge == edge }) {
                    togglePeek(newest, pinned: true)
                    return "toggled=\(newest.record.appName) (\(reason))"
                }
                return "error=\(reason)"
            }
            return "stashed"
        }
        if let newest = items.last(where: { $0.record.edge == edge }) {
            togglePeek(newest, pinned: true)
            return "toggled=\(newest.record.appName)"
        }
        return "error=no-front-window"
    }

    // MARK: Peeking

    func togglePeek(_ item: Item, pinned: Bool) {
        if item.phase == .peeked || item.phase == .peeking { hide(item) } else { peek(item, pinned: pinned) }
    }

    func peek(_ item: Item, pinned: Bool = false) {
        guard item.phase == .stashed || item.phase == .hiding else { return }
        item.peek = EdgeStashLogic.peekFrame(for: item.record.stashed, edge: item.record.edge, display: item.display)
        item.pinned = pinned
        item.pointerVisited = false
        item.leftAt = nil
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if item.phase == .stashed {
            item.previousFront = front != item.record.pid ? front : nil
            item.broughtForward = false
        }
        StashAX.raise(item.window)
        if bringForward, front != item.record.pid {
            StashAX.bringForward(item.record.pid)
            item.broughtForward = true
        }
        peeks += 1
        item.panel.model.peeking = true
        slide(item, to: item.peek.origin, phase: .peeking) { [weak item] in item?.phase = .peeked }
    }

    func hide(_ item: Item) {
        guard item.phase == .peeked || item.phase == .peeking else { return }
        item.armed = false
        item.panel.model.peeking = false
        let previous = item.broughtForward ? item.previousFront : nil
        let pid = item.record.pid
        slide(item, to: item.record.stashed.origin, phase: .hiding) { [weak item] in
            item?.phase = .stashed
            // Hand the keyboard back to the app that had it, unless the person moved on.
            if let previous, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               NSRunningApplication(processIdentifier: previous) != nil {
                StashAX.bringForward(previous)
            }
        }
    }

    // MARK: Restoring

    /// Puts one window back where it was before its stash and forgets it.
    func unstash(_ item: Item, animated: Bool = true) {
        guard items.contains(where: { $0 === item }), item.phase != .restoring else { return }
        let target = EdgeStashLogic.restoreFrame(item.record.original, displays: displays())
        item.panel.model.leaving = true
        restores += 1
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.placeWithRetry(item.window, target, tries: 5)
            item.panel.close()
            self.items.removeAll { $0 === item }
            self.persist()
            self.layoutTabs()
        }
        if animated && !reduceMotion {
            slide(item, to: target.origin, phase: .restoring, then: finish)
        } else {
            item.phase = .restoring
            finish()
        }
    }

    func unstashAll(animated: Bool = true) {
        for item in items { unstash(item, animated: animated) }
    }

    /// Origin, size, origin; then read back after a beat and again if the app had not caught up.
    private func placeWithRetry(_ window: AXUIElement, _ target: CGRect, tries: Int) {
        let actual = StashAX.place(window, target)
        framesWritten += 1
        if let actual, EdgeStashLogic.matches(actual, target) {
            lastRestoreCheck = "ok \(Self.describe(actual))"
            return
        }
        guard tries > 1 else {
            lastRestoreCheck = "mismatch \(actual.map(Self.describe) ?? "gone") wanted \(Self.describe(target))"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { EdgeStash.shared.placeWithRetry(window, target, tries: tries - 1) }
        }
    }

    // MARK: Recovery

    /// Records still on disk at launch mean Atelier ended without putting them back.
    private func recoverAfterCrash() {
        let left = EdgeStashRecord.decode(store.data(forKey: "edgeStash.records"))
        guard !left.isEmpty, trusted else {
            if !left.isEmpty {
                // Without access the windows cannot be found now; keep them as orphans.
                orphans += left.map { var r = $0; r.orphaned = true; return r }
                store.removeObject(forKey: "edgeStash.records")
                persistOrphans()
            }
            return
        }
        for record in left {
            if !recover(record) {
                var orphan = record
                orphan.orphaned = true
                orphans.append(orphan)
            }
        }
        store.removeObject(forKey: "edgeStash.records")
        persistOrphans()
        // Apps that are running now may hold orphans from earlier sessions too.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            recoverOrphans(of: app)
        }
    }

    /// Finds the window a record left at its stashed frame and moves it back. Matches by
    /// app (pid if still alive, else bundle id) and the stashed frame.
    @discardableResult
    private func recover(_ record: EdgeStashRecord) -> Bool {
        var pids: [pid_t] = []
        if NSRunningApplication(processIdentifier: record.pid)?.bundleIdentifier == record.bundleID { pids.append(record.pid) }
        if let bundleID = record.bundleID {
            pids += NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier).filter { !pids.contains($0) }
        }
        for pid in pids {
            let candidates = StashAX.windows(pid: pid).filter { window in
                StashAX.frame(window).map { EdgeStashLogic.looksStashed($0, stashed: record.stashed) } ?? false
            }
            // Prefer the one with the same title when several sit at the same spot.
            guard let window = candidates.first(where: { StashAX.title($0) == record.title }) ?? candidates.first else { continue }
            let target = EdgeStashLogic.restoreFrame(record.original, displays: displays())
            let ok = StashAX.placeVerified(window, target)
            lastRestoreCheck = "recovered \(record.appName) ok=\(ok)"
            restores += 1
            return true
        }
        return false
    }

    private func recoverOrphans(of app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, orphans.contains(where: { $0.bundleID == bundleID }), trusted else { return }
        var kept: [EdgeStashRecord] = []
        for orphan in orphans {
            if orphan.bundleID == bundleID, recover(orphan) { continue }
            kept.append(orphan)
        }
        if kept.count != orphans.count {
            orphans = kept
            persistOrphans()
        }
    }

    private func appQuit(_ pid: pid_t) {
        let gone = items.filter { $0.record.pid == pid }
        guard !gone.isEmpty else { return }
        for item in gone {
            var orphan = item.record
            orphan.orphaned = true
            orphan.date = Date()
            orphans.append(orphan)
            item.panel.close()
        }
        items.removeAll { $0.record.pid == pid }
        persist()
        persistOrphans()
        layoutTabs()
    }

    /// An app reopens its windows a moment after it launches, so look a few times.
    private func appLaunched(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier, orphans.contains(where: { $0.bundleID == bundleID }) else { return }
        for delay in [0.8, 2.0, 4.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { EdgeStash.shared.recoverOrphans(of: app) }
            }
        }
    }

    private func persist() {
        let records = items.map(\.record)
        if records.isEmpty { store.removeObject(forKey: "edgeStash.records") }
        else if let data = EdgeStashRecord.encode(records) { store.set(data, forKey: "edgeStash.records") }
        objectWillChange.send()
    }

    private func persistOrphans() {
        if orphans.isEmpty { store.removeObject(forKey: "edgeStash.orphans") }
        else if let data = EdgeStashRecord.encode(orphans) { store.set(data, forKey: "edgeStash.orphans") }
    }

    // MARK: The loop

    /// 30 times a second: the pointer and the keys, no Accessibility unless a drag with the
    /// stash key is under way or a window is out.
    private func tick() {
        let now = CACurrentMediaTime()
        let cursor = cursorPoint()
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let held = key.isHeld(NSEvent.modifierFlags)
        if held { keySeenAt = now }
        trackDrag(now: now, cursor: cursor, down: down, held: held)
        wasDown = down
        trackHover(now: now, cursor: cursor, down: down)
        if now - lastValidate > 1 {
            lastValidate = now
            validate()
        }
    }

    private func cursorPoint() -> CGPoint {
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private func trackDrag(now: Double, cursor: CGPoint, down: Bool, held: Bool) {
        if down && !wasDown {
            samples = []
            drag = nil
            lookedUp = false
        }
        if down {
            samples.append(.init(time: now, point: cursor))
            if samples.count > 24 { samples.removeFirst(samples.count - 24) }
            // The window under the press is looked up once, the first tick the stash key is
            // held: by hit-testing, because a ⌘-drag moves a window without bringing it forward.
            if drag == nil, held, !lookedUp, let first = samples.first {
                lookedUp = true
                if let (window, pid) = StashAX.window(at: first.point), item(for: window) == nil, StashAX.isStashable(window),
                   let frame = StashAX.frame(window) {
                    // If the pointer has already carried it, take that back off.
                    let carried = hypot(cursor.x - first.point.x, cursor.y - first.point.y) > 5
                    let start = carried ? frame.offsetBy(dx: first.point.x - cursor.x, dy: first.point.y - cursor.y) : frame
                    drag = (window, pid, start, false)
                    grabOffset = CGSize(width: first.point.x - start.minX, height: first.point.y - start.minY)
                }
            }
            if var current = drag, !current.moved, let frame = StashAX.frame(current.window),
               hypot(frame.minX - current.start.minX, frame.minY - current.start.minY) > 3 {
                current.moved = true
                drag = current
            }
            return
        }
        guard wasDown, let current = drag else { return }
        drag = nil
        // The key may come up a moment before the button: allow a short grace.
        guard current.moved, held || now - keySeenAt < 0.15 else { return }
        let all = displays()
        guard let frame = StashAX.frame(current.window),
              let index = EdgeStashLogic.displayIndex(for: CGRect(origin: cursor, size: CGSize(width: 1, height: 1)), in: all) else { return }
        let span = Double(frame.minY)...Double(frame.maxY)
        let edge = EdgeStashLogic.releaseEdge(cursor: cursor, velocityX: EdgeStashLogic.velocityX(samples), display: all[index], fling: fling,
                                              leftOuter: EdgeStashLogic.isOuterEdge(.left, of: index, span: span, in: all),
                                              rightOuter: EdgeStashLogic.isOuterEdge(.right, of: index, span: span, in: all))
        guard let edge else { return }
        // The original is where the window sat before the drag, on screen. The drop frame is
        // where the hand left it, at the size it had: macOS tiling may be resizing it right now.
        let original = EdgeStashLogic.restoreFrame(current.start, displays: all)
        let drop = CGRect(x: cursor.x - grabOffset.width, y: cursor.y - grabOffset.height,
                          width: current.start.width, height: current.start.height)
        let window = current.window, pid = current.pid
        // With macOS's own edge tiling on, a drop at the edge also tiles; let its animation end
        // first, then put the size back and slide out.
        let delay = appleTilingOn && (cursor.x <= all[index].frame.minX + EdgeStashLogic.edgeZone
                                      || cursor.x >= all[index].frame.maxX - EdgeStashLogic.edgeZone - 1) ? 0.4 : 0
        if delay == 0 {
            stash(window, pid: pid, edge: edge, original: original, drop: drop)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { _ = EdgeStash.shared.stash(window, pid: pid, edge: edge, original: original, drop: drop) }
            }
        }
    }

    private func trackHover(now: Double, cursor: CGPoint, down: Bool) {
        for item in items {
            switch item.phase {
            case .stashed:
                // Not while a button is held: a drag passing the edge is not a request.
                guard !down else { continue }
                let zones = EdgeStashLogic.hotZones(tab: item.tab, stashed: item.record.stashed, edge: item.record.edge, display: item.display)
                let hot = EdgeStashLogic.isHot(cursor, zones: zones)
                if !item.armed { item.armed = !hot; continue }
                if hot { peek(item) }
            case .peeked, .peeking:
                let keep = EdgeStashLogic.keepZone(peek: item.peek, tab: item.tab)
                if keep.contains(cursor) {
                    item.pointerVisited = true
                    item.leftAt = nil
                    continue
                }
                if item.pinned && !item.pointerVisited { continue }
                if down { item.leftAt = nil; continue }
                // Moved by hand: it is the person's window again, where they put it.
                if item.phase == .peeked, let actual = StashAX.frame(item.window), EdgeStashLogic.movedByHand(actual, peek: item.peek) {
                    release(item)
                    continue
                }
                if item.leftAt == nil { item.leftAt = now }
                if let left = item.leftAt, now - left >= returnDelay { hide(item) }
            default:
                continue
            }
        }
    }

    /// Lets go of a stash without moving the window: the person dragged it out themselves.
    private func release(_ item: Item) {
        item.panel.model.leaving = true
        item.panel.close()
        items.removeAll { $0 === item }
        persist()
        layoutTabs()
    }

    /// Once a second: windows that closed lose their tab.
    private func validate() {
        for item in items where (item.phase == .stashed || item.phase == .peeked) && StashAX.frame(item.window) == nil {
            item.panel.close()
            items.removeAll { $0 === item }
            persist()
            layoutTabs()
        }
    }

    // MARK: Tabs

    private func layoutTabs() {
        for edge in EdgeStashLogic.Edge.allCases {
            let group = items.filter { $0.record.edge == edge }
            guard let display = group.first?.display else { continue }
            let range = Double(display.visible.minY)...Double(display.visible.maxY)
            let centers = EdgeStashLogic.tabCenters(desired: group.map { Double($0.record.stashed.midY) }, range: range)
            for (item, center) in zip(group, centers) {
                item.tab = EdgeStashLogic.tabFrame(edge: edge, center: center, display: item.display)
                item.panel.show(at: item.tab, primaryHeight: primaryHeight)
            }
        }
    }

    // MARK: Motion

    private func slide(_ item: Item, to origin: CGPoint, phase: Phase, then: (() -> Void)? = nil) {
        item.phase = phase
        item.target = origin
        item.onArrive = then
        if reduceMotion {
            arrive(item)
            return
        }
        // A window at rest starts from where it really is; a running slide keeps its velocity.
        if item.lastStep == 0, let current = StashAX.frame(item.window)?.origin {
            item.x = .init(value: current.x)
            item.y = .init(value: current.y)
        }
        item.lastStep = CACurrentMediaTime()
        startLink()
    }

    private func arrive(_ item: Item) {
        StashAX.set(item.window, origin: item.target)
        framesWritten += 1
        item.x = .init(value: item.target.x)
        item.y = .init(value: item.target.y)
        item.lastStep = 0
        let done = item.onArrive
        item.onArrive = nil
        done?()
    }

    private func startLink() {
        if let link { link.isPaused = false; return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let next = screen?.displayLink(target: ticker, selector: #selector(EdgeStashTicker.tick(_:))) else {
            for item in items where item.lastStep > 0 { arrive(item) }
            return
        }
        next.add(to: .main, forMode: .common)
        link = next
        slideTicks = 0
        slideStart = CACurrentMediaTime()
    }

    private func stopLink() {
        if slideTicks > 4 {
            let elapsed = CACurrentMediaTime() - slideStart
            if elapsed > 0 { lastSlideFPS = Double(slideTicks) / elapsed }
        }
        link?.invalidate()
        link = nil
    }

    /// One display frame: every sliding window steps its spring and writes its origin.
    fileprivate func step() {
        let now = CACurrentMediaTime()
        slideTicks += 1
        var anyMoving = false
        let (response, damping) = (0.3, 0.86)
        for item in items where item.lastStep > 0 {
            let dt = min(now - item.lastStep, 1 / 30)
            item.lastStep = now
            // Out to the edge without a bounce, in with a little life.
            let critical = item.phase == .stashing || item.phase == .hiding
            item.x.step(to: item.target.x, dt: dt, response: critical ? 0.26 : response, damping: critical ? 1 : damping)
            item.y.step(to: item.target.y, dt: dt, response: critical ? 0.26 : response, damping: critical ? 1 : damping)
            if item.x.isSettled(at: item.target.x) && item.y.isSettled(at: item.target.y) {
                arrive(item)
                continue
            }
            anyMoving = true
            if !StashAX.set(item.window, origin: CGPoint(x: item.x.value.rounded(), y: item.y.value.rounded())) {
                // The window went away mid-slide.
                item.lastStep = 0
                item.onArrive = nil
                continue
            }
            framesWritten += 1
        }
        if !anyMoving { stopLink() }
    }

    // MARK: Hot keys

    private struct HotKey { let key: Int; let label: String; let action: () -> Void }

    private var hotKeys: [HotKey] {
        [.init(key: kVK_LeftArrow, label: "⌃⌥⌘←") { _ = EdgeStash.shared.stashFront(edge: .left) },
         .init(key: kVK_RightArrow, label: "⌃⌥⌘→") { _ = EdgeStash.shared.stashFront(edge: .right) },
         .init(key: kVK_DownArrow, label: "⌃⌥⌘↓") { EdgeStash.shared.unstashAll() }]
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        guard started, hotKeysEnabled else { return }
        if hotKeyHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // Command.swift claims every press on the application target; the dispatcher sits
            // above it and passes on what is not ours, as Orbit does.
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == stashHotKeySignature else { return OSStatus(eventNotHandledErr) }
                let index = Int(id.id)
                MainActor.assumeIsolated { EdgeStash.shared.fireHotKey(index) }
                return noErr
            }, 1, &type, nil, &hotKeyHandler)
        }
        var conflicts: [String] = []
        for (index, hotKey) in hotKeys.enumerated() {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: stashHotKeySignature, id: UInt32(index))
            if RegisterEventHotKey(UInt32(hotKey.key), UInt32(controlKey | optionKey | cmdKey), id, GetEventDispatcherTarget(), 0, &reference) == noErr,
               let reference {
                hotKeyRefs.append(reference)
            } else {
                conflicts.append(hotKey.label)
            }
        }
        hotKeyConflicts = conflicts
    }

    private func unregisterHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
    }

    private func fireHotKey(_ index: Int) {
        let keys = hotKeys
        guard keys.indices.contains(index) else { return }
        keys[index].action()
    }

    // MARK: Diagnostics and the test hook

    static func describe(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height))" }

    var diagnostics: String {
        "stashOn=\(enabled) stashItems=\(items.count) stashOrphans=\(orphans.count) stashes=\(stashes) stashPeeks=\(peeks) "
            + "stashRestores=\(restores) stashFrames=\(framesWritten) stashFPS=\(Int(lastSlideFPS.rounded())) "
            + "stashHotKeys=\(hotKeyRefs.count) stashRestore=\(lastRestoreCheck.replacingOccurrences(of: " ", with: "_"))"
    }

    private func reportLines() -> [String] {
        var lines = ["enabled=\(enabled) trusted=\(trusted) key=\(key.rawValue) fling=\(fling) returnDelay=\(returnDelay)"]
        for (index, item) in items.enumerated() {
            let actual = StashAX.frame(item.window).map(Self.describe) ?? "gone"
            lines.append("item=\(index + 1) app=\(item.record.appName) title=\(item.record.title) edge=\(item.record.edge.rawValue) "
                + "phase=\(item.phase.rawValue) original=\(Self.describe(item.record.original)) stashed=\(Self.describe(item.record.stashed)) "
                + "peek=\(Self.describe(item.peek)) actual=\(actual) tab=\(Self.describe(item.tab)) panel=\(item.panel.isVisible)")
        }
        for orphan in orphans {
            lines.append("orphan app=\(orphan.appName) stashed=\(Self.describe(orphan.stashed)) original=\(Self.describe(orphan.original))")
        }
        lines.append(diagnostics)
        return lines
    }

    private func writeReport(_ extra: [String]) {
        let text = (extra + reportLines()).joined(separator: "\n")
        try? text.write(toFile: NSTemporaryDirectory() + "atelier-stash.txt", atomically: true, encoding: .utf8)
    }

    /// `atelier://stash?…` — `on=0|1`; `stash=front&edge=left|right` (optional `app=<bundle id>`);
    /// `peek=<n>|last` shows a stash pinned, `peek=0` hides every peek; `unstash=all|<n>`;
    /// `report=1`. Every call writes `$TMPDIR/atelier-stash.txt` at once and again 1.2 s later,
    /// when the slides have settled (that one starts with `settled=1`).
    func handleTest(_ items: [URLQueryItem]) {
        var lines: [String] = []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let on = value("on") { enabled = on == "1" }
        if value("stash") == "front" {
            let edge = EdgeStashLogic.Edge(rawValue: value("edge") ?? "left") ?? .left
            if !enabled { lines.append("error=off") }
            else { lines.append("stash=" + stashFront(edge: edge, bundleID: value("app"))) }
        }
        if let which = value("peek") {
            if which == "0" {
                for item in self.items { hide(item) }
                lines.append("peek=hidden")
            } else if let item = which == "last" ? self.items.last : Int(which).flatMap({ self.items.indices.contains($0 - 1) ? self.items[$0 - 1] : nil }) {
                peek(item, pinned: true)
                lines.append("peek=\(item.record.appName)")
            } else {
                lines.append("error=no-such-stash(\(which))")
            }
        }
        if let which = value("unstash") {
            if which == "all" { unstashAll() }
            else if let n = Int(which), self.items.indices.contains(n - 1) { unstash(self.items[n - 1]) }
            else { lines.append("error=no-such-stash(\(which))") }
            lines.append("unstash=\(which)")
        }
        writeReport(lines)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated { EdgeStash.shared.writeReport(["settled=1"] + lines) }
        }
    }
}

/// The display link's target; it runs on the main run loop.
private final class EdgeStashTicker: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { EdgeStash.shared.step() }
    }
}

// MARK: - The tab

@MainActor
final class EdgeStashTabModel: ObservableObject {
    @Published var icon: NSImage?
    @Published var peeking = false
    @Published var hover = false
    @Published var leaving = false
    @Published var shown = false
}

/// A small borderless panel on the screen edge that holds the tab. It never takes focus; a
/// click on it brings the window back for good.
@MainActor
final class EdgeStashTabPanel {
    let model = EdgeStashTabModel()
    private let panel: NSPanel
    private let edge: EdgeStashLogic.Edge

    init(edge: EdgeStashLogic.Edge) {
        self.edge = edge
        let size = EdgeStashLogic.tabSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        let view = EdgeStashTabView(model: model, edge: edge) { [weak self] in self?.clicked() }
        panel.contentView = NSHostingView(rootView: view)
    }

    static let bleed = 8.0
    var isVisible: Bool { panel.isVisible }

    func setIcon(_ image: NSImage?) { model.icon = image }

    /// `frame` in Accessibility coordinates.
    func show(at frame: CGRect, primaryHeight: Double) {
        // Room around the tab for its glow; the edge side stays flush with the bezel.
        let bleed = Self.bleed
        let rect = NSRect(x: edge == .left ? frame.minX : frame.minX - bleed, y: primaryHeight - frame.maxY - bleed,
                          width: frame.width + bleed, height: frame.height + bleed * 2)
        panel.setFrame(rect, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [model] in model.shown = true }
        }
    }

    func close() {
        model.shown = false
        let panel = self.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { panel.orderOut(nil) }
    }

    private func clicked() {
        guard let item = EdgeStash.shared.items.first(where: { $0.panel === self }) else { return }
        EdgeStash.shared.unstash(item)
    }
}

/// Glass with a lit rim in the windows hue, the app's icon in the middle. Rounded on the side
/// facing the screen, square against the edge, as if the window's corner were folded over it.
struct EdgeStashTabView: View {
    @ObservedObject var model: EdgeStashTabModel
    let edge: EdgeStashLogic.Edge
    let onClick: () -> Void
    @State private var hover = false
    private let hue = DS.Spectrum.windows

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: edge == .left
            ? .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 11, topTrailing: 11)
            : .init(topLeading: 11, bottomLeading: 11, bottomTrailing: 0, topTrailing: 0), style: .continuous)
        let lit = hover || model.peeking
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(LinearGradient(colors: [hue.opacity(lit ? 0.5 : 0.28), hue.opacity(lit ? 0.22 : 0.1)],
                                      startPoint: .top, endPoint: .bottom))
            // The rim that faces the screen glows; the edge side fades into the bezel.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(lit ? 0.7 : 0.42), hue.opacity(0.5), .white.opacity(0.1)],
                                              startPoint: edge == .left ? .trailing : .leading,
                                              endPoint: edge == .left ? .leading : .trailing), lineWidth: 0.75)
            if let icon = model.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: edge == .left ? 1.5 : -1.5)
            } else {
                Capsule().fill(.white.opacity(0.8)).frame(width: 3, height: 18)
            }
        }
        .compositingGroup()
        .shadow(color: hue.opacity(lit ? 0.8 : 0.45), radius: lit ? 6 : 3)
        .scaleEffect(x: model.shown && !model.leaving ? 1 : 0.2, y: model.shown && !model.leaving ? 1 : 0.6,
                     anchor: edge == .left ? .leading : .trailing)
        .opacity(model.shown && !model.leaving ? 1 : 0)
        .padding(.vertical, 3 + EdgeStashTabPanel.bleed)
        .padding(edge == .left ? .trailing : .leading, EdgeStashTabPanel.bleed)
        .animation(DS.Motion.gentle(DS.Motion.settle), value: model.shown)
        .animation(DS.Motion.gentle(DS.Motion.settle), value: model.leaving)
        .animation(DS.Motion.hover, value: lit)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onClick)
        .accessibilityLabel("Stashed window. Click to bring it back.")
    }
}
