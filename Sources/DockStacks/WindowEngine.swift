import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DockCore
import SwiftUI

// MARK: - Pure geometry

/// Everything in this enum is free of AppKit state, so it runs without Accessibility.
/// All rectangles use Accessibility coordinates: the origin is the top left of the primary
/// display and y grows downward.
///
/// Metrics measured in macOS 27.3 `WindowManager.framework` (defaults in
/// `WindowManagerPreferencesController`): `tiledWindowSpacing` 8, `tilingHotzoneDelay` 0,
/// `tilingSoftHotzoneDelay` 0.2, `tilingSoftHotzoneSize` 20, `tilingTouchHotzonePadding` 44.
/// `effectiveTiledWindowSpacing` is the spacing with margins on and 0 with them off.
enum WindowGeometry {
    static let appleGap = 8.0
    static let softZone = 20.0
    static let softDelay = 0.2
    /// WindowManager compares a squared drag distance with 25 before it counts as moving.
    static let dragThreshold = 5.0

    struct Display: Equatable {
        var frame: CGRect
        var visible: CGRect
    }

    enum Layout: String, CaseIterable, Codable, Identifiable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
        case topLeft, topRight, bottomLeft, bottomRight
        case center, maximize

        var id: String { rawValue }

        var title: String {
            switch self {
            case .leftHalf: "Left Half"
            case .rightHalf: "Right Half"
            case .topHalf: "Top Half"
            case .bottomHalf: "Bottom Half"
            case .leftThird: "Left Third"
            case .centerThird: "Center Third"
            case .rightThird: "Right Third"
            case .leftTwoThirds: "Left Two Thirds"
            case .rightTwoThirds: "Right Two Thirds"
            case .topLeft: "Top Left"
            case .topRight: "Top Right"
            case .bottomLeft: "Bottom Left"
            case .bottomRight: "Bottom Right"
            case .center: "Center"
            case .maximize: "Maximize"
            }
        }

        /// (first column, column span, columns, first row, row span, rows)
        private var cell: (Int, Int, Int, Int, Int, Int)? {
            switch self {
            case .leftHalf: (0, 1, 2, 0, 1, 1)
            case .rightHalf: (1, 1, 2, 0, 1, 1)
            case .topHalf: (0, 1, 1, 0, 1, 2)
            case .bottomHalf: (0, 1, 1, 1, 1, 2)
            case .leftThird: (0, 1, 3, 0, 1, 1)
            case .centerThird: (1, 1, 3, 0, 1, 1)
            case .rightThird: (2, 1, 3, 0, 1, 1)
            case .leftTwoThirds: (0, 2, 3, 0, 1, 1)
            case .rightTwoThirds: (1, 2, 3, 0, 1, 1)
            case .topLeft: (0, 1, 2, 0, 1, 2)
            case .topRight: (1, 1, 2, 0, 1, 2)
            case .bottomLeft: (0, 1, 2, 1, 1, 2)
            case .bottomRight: (1, 1, 2, 1, 1, 2)
            case .maximize: (0, 1, 1, 0, 1, 1)
            case .center: nil
            }
        }

        func frame(in visible: CGRect, gap: Double, current: CGSize? = nil) -> CGRect {
            guard let (column, columnSpan, columns, row, rowSpan, rows) = cell else {
                let room = visible.insetBy(dx: gap, dy: gap)
                let size = current ?? CGSize(width: visible.width * 0.6, height: visible.height * 0.7)
                let width = min(size.width, room.width), height = min(size.height, room.height)
                return CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(),
                              width: width, height: height)
            }
            let (left, right) = WindowGeometry.span(from: column, count: columnSpan, of: columns,
                                                    start: visible.minX, length: visible.width, gap: gap)
            let (top, bottom) = WindowGeometry.span(from: row, count: rowSpan, of: rows,
                                                    start: visible.minY, length: visible.height, gap: gap)
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    /// Whole-point edges of a run of equal tracks, with `gap` around and between them.
    private static func span(from first: Int, count: Int, of total: Int,
                             start: Double, length: Double, gap: Double) -> (Double, Double) {
        let track = (length - gap * Double(total + 1)) / Double(total)
        let low = start + gap + Double(first) * (track + gap)
        let high = start + gap + Double(first + count) * (track + gap) - gap
        return (low.rounded(), high.rounded())
    }

    static func flipped(_ rect: CGRect, primaryHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func displayIndex(at point: CGPoint, in displays: [Display]) -> Int? {
        if displays.isEmpty { return nil }
        if let index = displays.firstIndex(where: { $0.frame.contains(point) }) { return index }
        func distance(_ frame: CGRect) -> Double {
            hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
        }
        return displays.indices.min { distance(displays[$0].frame) < distance(displays[$1].frame) }
    }

    /// Which zone the pointer is in while a window is dragged. Edges follow the visible
    /// frame, so a Dock or menu bar never pushes a zone out of reach.
    static func zone(cursor: CGPoint, display: Display, soft: Double = softZone) -> Layout? {
        let visible = display.visible
        let left = cursor.x <= visible.minX + soft, right = cursor.x >= visible.maxX - soft
        let top = cursor.y <= visible.minY + soft, bottom = cursor.y >= visible.maxY - soft
        let cornerX = max(120, visible.width * 0.14), cornerY = max(96, visible.height * 0.16)
        if left || right {
            if cursor.y <= visible.minY + cornerY { return left ? .topLeft : .topRight }
            if cursor.y >= visible.maxY - cornerY { return left ? .bottomLeft : .bottomRight }
            return left ? .leftHalf : .rightHalf
        }
        if top {
            if cursor.x <= visible.minX + cornerX { return .topLeft }
            if cursor.x >= visible.maxX - cornerX { return .topRight }
            return .maximize
        }
        if bottom {
            let position = (cursor.x - visible.minX) / visible.width
            return position < 1.0 / 3 ? .leftThird : position < 2.0 / 3 ? .centerThird : .rightThird
        }
        return nil
    }

    /// A rows-and-columns grid for `count` windows. Short rows stretch to fill the width.
    static func gridCells(count: Int, in visible: CGRect, gap: Double) -> [CGRect] {
        guard count > 0 else { return [] }
        let major = Int(Double(count).squareRoot().rounded(.up))
        let minor = Int((Double(count) / Double(major)).rounded(.up))
        let wide = visible.width >= visible.height
        let lines = wide ? minor : major, perLine = wide ? major : minor
        var cells: [CGRect] = []
        var remaining = count
        for line in 0..<lines {
            let items = min(perLine, remaining)
            remaining -= items
            for item in 0..<items {
                let (top, bottom) = span(from: line, count: 1, of: lines, start: wide ? visible.minY : visible.minX,
                                         length: wide ? visible.height : visible.width, gap: gap)
                let (left, right) = span(from: item, count: 1, of: items, start: wide ? visible.minX : visible.minY,
                                         length: wide ? visible.width : visible.height, gap: gap)
                cells.append(wide ? CGRect(x: left, y: top, width: right - left, height: bottom - top)
                                  : CGRect(x: top, y: left, width: bottom - top, height: right - left))
            }
        }
        return cells
    }

    /// One cell index per window, sending each window to a near cell so paths stay short.
    /// `rotation` walks the result round the grid, so repeated shuffles keep rearranging.
    static func assign(windows: [CGRect], cells: [CGRect], rotation: Int = 0) -> [Int] {
        guard windows.count == cells.count, !windows.isEmpty else { return [] }
        var pairs: [(distance: Double, window: Int, cell: Int)] = []
        for (w, window) in windows.enumerated() {
            for (c, cell) in cells.enumerated() {
                pairs.append((hypot(window.midX - cell.midX, window.midY - cell.midY), w, c))
            }
        }
        pairs.sort { ($0.distance, $0.window, $0.cell) < ($1.distance, $1.window, $1.cell) }
        var result = [Int](repeating: -1, count: windows.count)
        var taken = Set<Int>()
        for pair in pairs where result[pair.window] < 0 && !taken.contains(pair.cell) {
            result[pair.window] = pair.cell
            taken.insert(pair.cell)
        }
        return result.map { ($0 + rotation) % cells.count }
    }

    /// Pairs saved windows with live ones: same app and title first, then same app in order.
    static func match(saved: [(app: String, title: String)], live: [(app: String, title: String)]) -> [(saved: Int, live: Int)] {
        var pairs: [(saved: Int, live: Int)] = []
        var usedSaved = Set<Int>(), usedLive = Set<Int>()
        for (s, window) in saved.enumerated() {
            if let l = live.indices.first(where: {
                !usedLive.contains($0) && live[$0].app == window.app && live[$0].title == window.title
            }) {
                pairs.append((s, l))
                usedSaved.insert(s)
                usedLive.insert(l)
            }
        }
        for (s, window) in saved.enumerated() where !usedSaved.contains(s) {
            if let l = live.indices.first(where: { !usedLive.contains($0) && live[$0].app == window.app }) {
                pairs.append((s, l))
                usedLive.insert(l)
            }
        }
        return pairs.sorted { $0.saved < $1.saved }
    }

    /// Brings a saved frame onto a display that exists now, for example after a monitor left.
    static func rehome(_ frame: CGRect, displays: [Display]) -> CGRect {
        guard let first = displays.first else { return frame }
        let area = { (rect: CGRect) in rect.isNull ? 0 : rect.width * rect.height }
        let best = displays.max { area($0.visible.intersection(frame)) < area($1.visible.intersection(frame)) } ?? first
        let visible = best.visible
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }

    /// Size to hold during a glide: shrink first, grow on arrival, so a window never
    /// sweeps across the screen at its larger size.
    static func interimSize(from current: CGSize, to target: CGSize) -> CGSize {
        CGSize(width: min(current.width, target.width), height: min(current.height, target.height))
    }

    /// Where a window goes when its app refused the requested size.
    static func settledOrigin(actual: CGSize, target: CGRect, bounds: CGRect) -> CGPoint {
        CGPoint(x: max(min(target.minX, bounds.maxX - actual.width), bounds.minX),
                y: max(min(target.minY, bounds.maxY - actual.height), bounds.minY))
    }

    struct ListedWindow: Equatable {
        var id: Int
        var pid: Int32
        var layer: Int
        var bounds: CGRect
    }

    /// Finds the window-server id that goes with an Accessibility frame.
    static func windowID(pid: Int32, frame: CGRect, in list: [ListedWindow]) -> Int? {
        list.first {
            $0.pid == pid && $0.layer == 0
                && abs($0.bounds.minX - frame.minX) <= 2 && abs($0.bounds.minY - frame.minY) <= 2
                && abs($0.bounds.width - frame.width) <= 2 && abs($0.bounds.height - frame.height) <= 2
        }?.id
    }

    /// A damped spring solved in closed form, so an uneven tick rate cannot destabilise it.
    /// A new target keeps the current velocity, which is what makes a glide interruptible.
    struct Spring: Equatable {
        var value: Double
        var velocity = 0.0

        mutating func step(to target: Double, dt: Double, response: Double, damping: Double) {
            let omega = 2 * .pi / response
            let offset = value - target
            let decay = exp(-damping * omega * dt)
            if damping >= 1 {
                let b = velocity + omega * offset
                value = target + (offset + b * dt) * decay
                velocity = (b - omega * (offset + b * dt)) * decay
            } else {
                let omegaD = omega * (1 - damping * damping).squareRoot()
                let b = (velocity + damping * omega * offset) / omegaD
                let cosine = cos(omegaD * dt), sine = sin(omegaD * dt)
                value = target + decay * (offset * cosine + b * sine)
                velocity = decay * ((b * omegaD - damping * omega * offset) * cosine
                    - (offset * omegaD + damping * omega * b) * sine)
            }
        }

        func isSettled(at target: Double) -> Bool { abs(value - target) < 0.5 && abs(velocity) < 12 }
    }

    /// Decides from polled samples when a window is being dragged into a zone. There is no
    /// event tap; the caller feeds it mouse state and the focused window's frame.
    struct SnapTracker {
        enum Event: Equatable {
            case none
            case preview(Layout, display: Int)
            case clear
            case commit(Layout, display: Int)
        }

        struct Sample {
            var time: Double
            var mouseDown: Bool
            var cursor: CGPoint
            var window: Int?
            var frame: CGRect?
            var cancel = false
        }

        private enum Phase {
            case idle
            case armed(window: Int, frame: CGRect, cursor: CGPoint)
            case ignored
            case dragging
            case hovering(Layout, display: Int, since: Double)
            case previewing(Layout, display: Int)
        }

        private var phase = Phase.idle

        mutating func update(_ sample: Sample, displays: [Display]) -> Event {
            guard sample.mouseDown else {
                defer { phase = .idle }
                if case let .previewing(zone, display) = phase { return sample.cancel ? .clear : .commit(zone, display: display) }
                return .none
            }
            switch phase {
            case .ignored:
                return .none
            case .idle:
                if let window = sample.window, let frame = sample.frame {
                    phase = .armed(window: window, frame: frame, cursor: sample.cursor)
                }
                return .none
            case let .armed(window, frame, cursor):
                guard let current = sample.window, let now = sample.frame else { return .none }
                if current != window {
                    phase = .armed(window: current, frame: now, cursor: sample.cursor)
                    return .none
                }
                if abs(now.width - frame.width) > 1 || abs(now.height - frame.height) > 1 {
                    phase = .ignored // A size change means a resize, which never snaps.
                    return .none
                }
                let moved = hypot(now.minX - frame.minX, now.minY - frame.minY)
                let followed = hypot(sample.cursor.x - cursor.x, sample.cursor.y - cursor.y)
                guard moved >= WindowGeometry.dragThreshold, followed >= WindowGeometry.dragThreshold else { return .none }
                phase = .dragging
                return hover(sample, displays: displays)
            case .dragging, .hovering, .previewing:
                return hover(sample, displays: displays)
            }
        }

        private mutating func hover(_ sample: Sample, displays: [Display]) -> Event {
            var showing = false
            if case .previewing = phase { showing = true }
            if sample.cancel {
                phase = .ignored
                return showing ? .clear : .none
            }
            guard let index = WindowGeometry.displayIndex(at: sample.cursor, in: displays),
                  let zone = WindowGeometry.zone(cursor: sample.cursor, display: displays[index]) else {
                phase = .dragging
                return showing ? .clear : .none
            }
            switch phase {
            case let .previewing(current, display) where current == zone && display == index:
                return .none
            case .previewing:
                phase = .previewing(zone, display: index) // Once shown, it follows with no delay.
                return .preview(zone, display: index)
            case let .hovering(current, display, since) where current == zone && display == index:
                guard sample.time - since >= WindowGeometry.softDelay else { return .none }
                phase = .previewing(zone, display: index)
                return .preview(zone, display: index)
            default:
                phase = .hovering(zone, display: index, since: sample.time)
                return .none
            }
        }
    }
}

// MARK: - Stored arrangements

struct WindowSnapshot: Codable, Equatable {
    var app: String
    var appName: String
    var title: String
    var frame: CGRect
}

struct WindowWorkspace: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var windows: [WindowSnapshot]
}

// MARK: - Accessibility

/// A thin layer over AXUIElement. Reads and writes fail quietly, because a window can close
/// at any moment and an app can stop answering.
struct AXWindow {
    let element: AXUIElement
    let app: NSRunningApplication

    private func value(_ attribute: String) -> AXValue? {
        guard let raw = AXDesk.value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }

    var frame: CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let position = value(kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let extent = value(kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var title: String { (AXDesk.value(element, kAXTitleAttribute) as? String) ?? "" }

    var isFullScreen: Bool { (AXDesk.value(element, "AXFullScreen") as? Bool) ?? false }

    var isMovable: Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    @discardableResult
    func set(origin: CGPoint) -> Bool {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    func set(size: CGSize) {
        var dimensions = size
        guard let value = AXValueCreate(.cgSize, &dimensions) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    func raise() { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
}

enum AXDesk {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success ? raw : nil
    }

    /// Accessibility calls are synchronous, and the default timeout would freeze our main
    /// thread for six seconds on an app that has stopped responding.
    private static func element(for app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    static func focusedWindow(of app: NSRunningApplication) -> AXWindow? {
        guard let raw = value(element(for: app), kAXFocusedWindowAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: raw as! AXUIElement, app: app)
    }

    /// Standard, on-screen windows of every regular app except Atelier, front to back within each app.
    static func allWindows() -> [AXWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != own }
            .flatMap { app -> [AXWindow] in
                guard let elements = value(element(for: app), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
                return elements.compactMap { element in
                    guard (value(element, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                          (value(element, kAXMinimizedAttribute) as? Bool) != true else { return nil }
                    let window = AXWindow(element: element, app: app)
                    return window.isFullScreen ? nil : window
                }
            }
    }

    static func listedWindows() -> [WindowGeometry.ListedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let raw = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { return nil }
            return WindowGeometry.ListedWindow(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }
}

/// One window in flight. Position is sprung; size changes at the two ends of the glide.
private final class Glide {
    static let response = 0.34, damping = 0.88, limit = 0.9

    let window: AXWindow
    var target: CGRect
    var x: WindowGeometry.Spring
    var y: WindowGeometry.Spring
    var startTime: Double
    var lastStep: Double
    var preparedSize = false
    var shown = false

    init(window: AXWindow, from: CGRect, target: CGRect, startTime: Double) {
        self.window = window
        self.target = target
        x = .init(value: from.minX)
        y = .init(value: from.minY)
        self.startTime = startTime
        lastStep = startTime
    }

    var isSettled: Bool { x.isSettled(at: target.minX) && y.isSettled(at: target.minY) }

    func advance(now: Double) {
        let dt = now - lastStep
        lastStep = now
        x.step(to: target.minX, dt: dt, response: Self.response, damping: Self.damping)
        y.step(to: target.minY, dt: dt, response: Self.response, damping: Self.damping)
    }
}

// MARK: - Engine

/// Our own window manager, built on the public Accessibility API. Nothing here runs or asks
/// for anything until the owner turns a feature on and presses Grant Access.
@MainActor
final class WindowEngine: ObservableObject {
    static let shared = WindowEngine()
    private let store = UserDefaults.standard

    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var awaitingGrant = false
    @Published var snapEnabled: Bool { didSet { store.set(snapEnabled, forKey: "windowEngine.snap"); reconfigure() } }
    @Published var hotKeysEnabled: Bool { didSet { store.set(hotKeysEnabled, forKey: "windowEngine.hotKeys"); applyHotKeys() } }
    @Published var glowEnabled: Bool { didSet { store.set(glowEnabled, forKey: "windowEngine.glow"); reconfigure() } }
    @Published var gap: Double { didSet { store.set(gap, forKey: "windowEngine.gap") } }
    @Published var glowIntensity: Double {
        didSet { store.set(glowIntensity, forKey: "windowEngine.glowIntensity"); glow.model.intensity = glowIntensity }
    }
    @Published private(set) var workspaces: [WindowWorkspace] = []
    @Published private(set) var status: String?
    @Published private(set) var canUndo = false
    @Published private(set) var hotKeyConflicts: [String] = []
    @Published private(set) var appleTilingOn = false
    @Published private(set) var stageManagerOn = false
    /// While the chapter is open, a grant made in System Settings shows up within a second.
    var chapterVisible = false { didSet { retime() } }

    private var started = false
    private var timer: Timer?
    private var rate = 0.0
    private var lastTrustCheck = 0.0
    private var wasDown = false
    private var lastExternal: pid_t?
    private var activationObserver: NSObjectProtocol?

    private var glides: [Glide] = []
    private var glideCursor = 0
    private var undoFrames: [(window: AXWindow, frame: CGRect)] = []
    private var shuffleKey: Set<Int> = []
    private var shuffleRotation = 0

    private var tracker = WindowGeometry.SnapTracker()
    private var dragged: AXWindow?
    private let preview = SnapPreview()

    private let glow = StageGlow()
    private var glowWindow: AXWindow?
    private var glowMoving = false

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?

    // Tools: Shift-drag into custom zones, and the zone each window last took.
    private var customDrag: (window: AXWindow, start: CGRect)?
    private var customTarget: CGRect?
    private var zoneCursor: [Int: Int] = [:]

    private init() {
        snapEnabled = store.bool(forKey: "windowEngine.snap")
        hotKeysEnabled = store.bool(forKey: "windowEngine.hotKeys")
        glowEnabled = store.bool(forKey: "windowEngine.glow")
        gap = store.object(forKey: "windowEngine.gap") as? Double ?? WindowGeometry.appleGap
        glowIntensity = store.object(forKey: "windowEngine.glowIntensity") as? Double ?? 0.7
        if let data = store.data(forKey: "windowEngine.workspaces"),
           let saved = try? JSONDecoder().decode([WindowWorkspace].self, from: data) {
            workspaces = saved
        }
        glow.model.intensity = glowIntensity
    }

    /// Safe to call at launch: it never prompts, and with no feature on it starts no timer.
    func start() {
        guard !started else { return }
        started = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { WindowEngine.shared.noteActivation(pid) }
        }
        refreshTiling()
        reconfigure()
        Tools.shared.start()
        // Carbon runs the newest handler first, and the handler in Command.swift claims every
        // hot key. A later turn of the run loop puts ours in front of it.
        DispatchQueue.main.async { WindowEngine.shared.applyHotKeys() }
    }

    private func noteActivation(_ pid: pid_t?) {
        if let pid, pid != ProcessInfo.processInfo.processIdentifier { lastExternal = pid }
    }

    // MARK: Permission

    /// The only place that shows the system prompt.
    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        awaitingGrant = !trusted
        reconfigure()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshTrust() {
        lastTrustCheck = CACurrentMediaTime()
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        if now { awaitingGrant = false }
        reconfigure()
        applyHotKeys()
    }

    /// Reads Apple's own edge tiling (macOS 15 and later) so the chapter can warn about two
    /// previews at once, and Stage Manager, which changes which windows Shuffle may touch.
    /// They stay as the owner set them in System Settings; we never write these keys.
    func refreshTiling() {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        func flag(_ key: String) -> Bool? { CFPreferencesCopyAppValue(key as CFString, domain) as? Bool }
        appleTilingOn = WindowsCompatTiling.appleTilingReacts(major: MacPlatform.major,
                                                              edgeDrag: flag(WindowsCompatTiling.edgeDragKey),
                                                              topEdgeDrag: flag(WindowsCompatTiling.topEdgeDragKey))
        stageManagerOn = WindowsCompatTiling.stageManagerOn(flag(WindowsCompatTiling.stageManagerKey))
    }

    /// Snap Zones as this Mac has them: on macOS 15 and later, Apple's tiling may answer the
    /// same drag.
    var snapAvailability: FeatureAvailability {
        appleTilingOn ? .limited("macOS tiling also answers edge drags. Turn it off in Desktop & Dock › Windows")
            : .available
    }

    // MARK: The loop

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func reconfigure() {
        if !(trusted && snapEnabled) {
            preview.hide()
            tracker = WindowGeometry.SnapTracker()
        }
        if !(trusted && glowEnabled) {
            glow.hide()
            glowWindow = nil
            glowMoving = false
        }
        retime()
    }

    /// Fast only while something moves. Idle polling reads mouse state, which costs nothing;
    /// Accessibility is only touched while the button is down or the glow is on.
    private func retime() {
        let customDrag = Tools.shared.shiftDragZones
        let held = wasDown && (snapEnabled || glowEnabled || customDrag)
        let wanted: Double
        if !trusted { wanted = awaitingGrant || chapterVisible ? 1 : 0 }
        else if !glides.isEmpty || held || glowMoving { wanted = 60 }
        else if snapEnabled || customDrag { wanted = 20 }
        else if glowEnabled { wanted = 12 }
        else { wanted = 0 }
        guard wanted != rate else { return }
        rate = wanted
        timer?.invalidate()
        timer = nil
        guard wanted > 0 else { return }
        let next = Timer(timeInterval: 1 / wanted, repeats: true) { _ in
            MainActor.assumeIsolated { WindowEngine.shared.tick() }
        }
        next.tolerance = 0.1 / wanted
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if now - lastTrustCheck >= 1 { refreshTrust() }
        guard trusted else { return }
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down && !wasDown { interruptGlides() }
        wasDown = down
        advanceGlides(now: now)
        let custom = Tools.shared.shiftDragZones && trackCustomDrag(down: down)
        if snapEnabled && !custom { trackSnap(now: now, down: down) }
        if glowEnabled { trackGlow(now: now, down: down) }
        retime()
    }

    // MARK: Moving windows

    /// The first screen always holds the menu bar and is the origin of both coordinate systems.
    private var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    private func displays() -> [WindowGeometry.Display] {
        let height = primaryHeight
        return NSScreen.screens.map {
            .init(frame: WindowGeometry.flipped($0.frame, primaryHeight: height),
                  visible: WindowGeometry.flipped($0.visibleFrame, primaryHeight: height))
        }
    }

    private func move(_ window: AXWindow, to target: CGRect, delay: Double = 0) {
        guard let frame = window.frame else { return }
        if reduceMotion {
            finish(window, at: target)
            return
        }
        let start = CACurrentMediaTime() + delay
        if let running = glides.first(where: { CFEqual($0.window.element, window.element) }) {
            running.target = target // Keeps its velocity, so a change of mind curves instead of stopping.
            running.startTime = start
            running.preparedSize = false
        } else {
            glides.append(Glide(window: window, from: frame, target: target, startTime: start))
        }
        retime()
    }

    private func finish(_ window: AXWindow, at target: CGRect) {
        window.set(size: target.size)
        window.set(origin: target.origin)
        window.set(size: target.size) // Some apps clamp size against the old position.
        guard let actual = window.frame?.size,
              actual.width > target.width + 2 || actual.height > target.height + 2,
              let index = WindowGeometry.displayIndex(at: CGPoint(x: target.midX, y: target.midY), in: displays()) else { return }
        window.set(origin: WindowGeometry.settledOrigin(actual: actual, target: target, bounds: displays()[index].visible))
    }

    private func advanceGlides(now: Double) {
        guard !glides.isEmpty else { return }
        // A slow app blocks the main thread on every set, so each tick has a budget and the
        // windows take turns. Each glide keeps its own clock, so a skipped tick only means
        // a longer step, not a slower one.
        let budget = CACurrentMediaTime() + 0.009
        var finished: [ObjectIdentifier] = []
        for offset in glides.indices {
            guard CACurrentMediaTime() < budget else { break }
            let glide = glides[(glideCursor + offset) % glides.count]
            guard now >= glide.startTime else { continue }
            if !glide.shown {
                glide.shown = true
                glide.lastStep = now
            }
            if !glide.preparedSize, let current = glide.window.frame?.size {
                glide.preparedSize = true
                glide.window.set(size: WindowGeometry.interimSize(from: current, to: glide.target.size))
            }
            glide.advance(now: now)
            let arrived = glide.isSettled || now - glide.startTime > Glide.limit
            if arrived {
                finish(glide.window, at: glide.target)
                finished.append(ObjectIdentifier(glide))
            } else if !glide.window.set(origin: CGPoint(x: glide.x.value.rounded(), y: glide.y.value.rounded())) {
                finished.append(ObjectIdentifier(glide))
            }
        }
        glideCursor += 1
        glides.removeAll { finished.contains(ObjectIdentifier($0)) }
    }

    /// The hand always wins: pressing the mouse leaves windows where they are.
    private func interruptGlides() {
        for glide in glides { glide.window.set(size: glide.target.size) }
        glides.removeAll()
    }

    private var targetApp: NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own { return front }
        return lastExternal.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    private func remember(_ windows: [AXWindow]) {
        undoFrames = windows.compactMap { window in window.frame.map { (window, $0) } }
        canUndo = !undoFrames.isEmpty
    }

    // MARK: Layouts

    func apply(_ layout: WindowGeometry.Layout) {
        guard trusted else { return }
        guard let app = targetApp, let window = AXDesk.focusedWindow(of: app), let frame = window.frame else {
            status = "There is no window to move."
            return
        }
        guard window.isMovable, !window.isFullScreen else {
            status = "\(app.localizedName ?? "This app") does not allow this window to move."
            return
        }
        let all = displays()
        guard let index = WindowGeometry.displayIndex(at: CGPoint(x: frame.midX, y: frame.midY), in: all) else { return }
        remember([window])
        move(window, to: layout.frame(in: all[index].visible, gap: gap, current: frame.size))
        status = nil
    }

    // MARK: Shuffle

    func shuffle() {
        guard trusted else { return }
        let all = displays()
        let cursor = cursorPoint()
        guard let index = WindowGeometry.displayIndex(at: cursor, in: all) else { return }
        refreshTiling()
        // With Stage Manager on, the apps waiting in the strip still report their windows to
        // Accessibility; only what the window server shows on screen belongs to this stage.
        let onScreen = stageManagerOn ? AXDesk.listedWindows() : nil
        let onDisplay = AXDesk.allWindows().compactMap { window -> (AXWindow, CGRect)? in
            guard window.isMovable, let frame = window.frame,
                  WindowGeometry.displayIndex(at: CGPoint(x: frame.midX, y: frame.midY), in: all) == index else { return nil }
            if let onScreen, WindowGeometry.windowID(pid: window.app.processIdentifier, frame: frame, in: onScreen) == nil { return nil }
            return (window, frame)
        }
        guard !onDisplay.isEmpty else {
            status = "There are no windows to shuffle on this display."
            return
        }
        let key = Set(onDisplay.map { Int(CFHash($0.0.element)) })
        shuffleRotation = key == shuffleKey ? shuffleRotation + 1 : 0
        shuffleKey = key
        remember(onDisplay.map(\.0))
        let cells = WindowGeometry.gridCells(count: onDisplay.count, in: all[index].visible, gap: gap)
        let assignment = WindowGeometry.assign(windows: onDisplay.map(\.1), cells: cells, rotation: shuffleRotation)
        for (order, entry) in onDisplay.enumerated() {
            move(entry.0, to: cells[assignment[order]], delay: Double(order) * 0.028)
        }
        status = nil
    }

    func undo() {
        let frames = undoFrames
        undoFrames = []
        canUndo = false
        for (order, entry) in frames.enumerated() { move(entry.window, to: entry.frame, delay: Double(order) * 0.02) }
    }

    // MARK: Workspaces

    func saveWorkspace(named name: String) {
        guard trusted else { return }
        let windows = AXDesk.allWindows().compactMap { window -> WindowSnapshot? in
            guard let frame = window.frame, let id = window.app.bundleIdentifier else { return nil }
            return WindowSnapshot(app: id, appName: window.app.localizedName ?? id, title: window.title, frame: frame)
        }
        guard !windows.isEmpty else {
            status = "There are no windows to save."
            return
        }
        workspaces.insert(WindowWorkspace(name: name, windows: windows), at: 0)
        persistWorkspaces()
        status = nil
    }

    func restore(_ workspace: WindowWorkspace) {
        guard trusted else { return }
        let live = AXDesk.allWindows().filter(\.isMovable)
        let pairs = WindowGeometry.match(saved: workspace.windows.map { ($0.app, $0.title) },
                                         live: live.map { ($0.app.bundleIdentifier ?? "", $0.title) })
        let all = displays()
        remember(pairs.map { live[$0.live] })
        for (order, pair) in pairs.enumerated() {
            let frame = WindowGeometry.rehome(workspace.windows[pair.saved].frame, displays: all)
            live[pair.live].raise()
            move(live[pair.live], to: frame, delay: Double(order) * 0.024)
        }
        let placed = Set(pairs.map(\.saved))
        let missing = workspace.windows.indices.filter { !placed.contains($0) }.map { workspace.windows[$0].appName }
        status = missing.isEmpty ? nil
            : "Restored \(pairs.count) of \(workspace.windows.count) windows. Not open: \(Array(Set(missing)).sorted().joined(separator: ", "))."
    }

    /// Display Memory's way in: the same glide as a workspace, without raising (the stacking
    /// order stays as it is) and undoable. Without motion the frames are set at once.
    func place(_ moves: [(window: AXWindow, frame: CGRect)], animated: Bool) {
        if !trusted { refreshTrust() }
        guard trusted, !moves.isEmpty else { return }
        remember(moves.map(\.window))
        for (order, item) in moves.enumerated() {
            if animated { move(item.window, to: item.frame, delay: Double(order) * 0.024) } else { finish(item.window, at: item.frame) }
        }
    }

    func delete(_ workspace: WindowWorkspace) {
        workspaces.removeAll { $0.id == workspace.id }
        persistWorkspaces()
    }

    private func persistWorkspaces() {
        if let data = try? JSONEncoder().encode(workspaces) { store.set(data, forKey: "windowEngine.workspaces") }
    }

    // MARK: Snap Zones

    private func cursorPoint() -> CGPoint {
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private func trackSnap(now: Double, down: Bool) {
        var sample = WindowGeometry.SnapTracker.Sample(time: now, mouseDown: down, cursor: cursorPoint())
        if down {
            sample.cancel = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) || EdgeStash.shared.claimsDrag
            let own = ProcessInfo.processInfo.processIdentifier
            if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own,
               let window = AXDesk.focusedWindow(of: app), let frame = window.frame, !window.isFullScreen {
                dragged = window
                sample.window = Int(CFHash(window.element))
                sample.frame = frame
            }
        }
        let event = tracker.update(sample, displays: displays())
        switch event {
        case .none:
            break
        case .clear:
            preview.hide()
        case let .preview(layout, index):
            let all = displays()
            guard all.indices.contains(index) else { return }
            preview.show(layout: layout,
                         frame: layout.frame(in: all[index].visible, gap: gap, current: dragged?.frame?.size),
                         display: all[index], primaryHeight: primaryHeight,
                         below: dragged.flatMap(windowNumber))
        case let .commit(layout, index):
            preview.hide()
            let all = displays()
            guard let dragged, all.indices.contains(index), let frame = dragged.frame else { return }
            remember([dragged])
            move(dragged, to: layout.frame(in: all[index].visible, gap: gap, current: frame.size))
        }
    }

    private func windowNumber(_ window: AXWindow) -> Int? {
        guard let frame = window.frame else { return nil }
        return WindowGeometry.windowID(pid: window.app.processIdentifier, frame: frame, in: AXDesk.listedWindows())
    }

    // MARK: Stage Glow

    private func trackGlow(now: Double, down: Bool) {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own,
              let window = AXDesk.focusedWindow(of: app), let frame = window.frame, !window.isFullScreen else {
            glow.hide()
            glowWindow = nil
            glowMoving = false
            return
        }
        let changed = glowWindow.map { !CFEqual($0.element, window.element) } ?? true
        if changed {
            glowWindow = window
            glow.tint(from: app)
        }
        let number = changed || glow.needsReorder(now: now) ? windowNumber(window) : nil
        glowMoving = glow.follow(frame: frame, track: down, reduceMotion: reduceMotion, now: now,
                                 primaryHeight: primaryHeight, below: number)
    }

    // MARK: Hot keys

    fileprivate struct Binding {
        let key: Int
        let label: String
        let action: Action
        enum Action {
            case layout(WindowGeometry.Layout)
            case shuffle
        }
    }

    fileprivate static let bindings: [Binding] = [
        .init(key: kVK_LeftArrow, label: "Left", action: .layout(.leftHalf)),
        .init(key: kVK_RightArrow, label: "Right", action: .layout(.rightHalf)),
        .init(key: kVK_UpArrow, label: "Up", action: .layout(.topHalf)),
        .init(key: kVK_DownArrow, label: "Down", action: .layout(.bottomHalf)),
        .init(key: kVK_ANSI_D, label: "D", action: .layout(.leftThird)),
        .init(key: kVK_ANSI_F, label: "F", action: .layout(.centerThird)),
        .init(key: kVK_ANSI_G, label: "G", action: .layout(.rightThird)),
        .init(key: kVK_ANSI_E, label: "E", action: .layout(.leftTwoThirds)),
        .init(key: kVK_ANSI_T, label: "T", action: .layout(.rightTwoThirds)),
        .init(key: kVK_ANSI_U, label: "U", action: .layout(.topLeft)),
        .init(key: kVK_ANSI_I, label: "I", action: .layout(.topRight)),
        .init(key: kVK_ANSI_J, label: "J", action: .layout(.bottomLeft)),
        .init(key: kVK_ANSI_K, label: "K", action: .layout(.bottomRight)),
        .init(key: kVK_ANSI_C, label: "C", action: .layout(.center)),
        .init(key: kVK_Return, label: "Return", action: .layout(.maximize)),
        .init(key: kVK_ANSI_S, label: "S", action: .shuffle),
    ]

    /// Separate from registration so its place in the Carbon handler chain can be tested.
    func installHotKeyHandler() {
        guard hotKeyHandler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Anything that is not ours passes on, or the Command hot key would stop working.
            guard status == noErr, id.signature == engineHotKeySignature else { return OSStatus(eventNotHandledErr) }
            let index = Int(id.id)
            MainActor.assumeIsolated { WindowEngine.shared.fire(index) }
            return noErr
        }, 1, &type, nil, &hotKeyHandler)
    }

    private func applyHotKeys() {
        guard started else { return }
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        hotKeyConflicts = []
        guard hotKeysEnabled, trusted else { return }
        installHotKeyHandler()
        for (index, binding) in Self.bindings.enumerated() {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: engineHotKeySignature, id: UInt32(index))
            let status = RegisterEventHotKey(UInt32(binding.key), UInt32(controlKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                hotKeyRefs.append(reference)
            } else {
                hotKeyConflicts.append(binding.label)
            }
        }
    }

    private func fire(_ index: Int) {
        guard Self.bindings.indices.contains(index) else { return }
        switch Self.bindings[index].action {
        case let .layout(layout): apply(layout)
        case .shuffle: shuffle()
        }
    }
}

// MARK: - Tools

extension WindowEngine {
    func toolsChanged() {
        if !Tools.shared.shiftDragZones { customDrag = nil; customTarget = nil }
        retime()
    }

    /// The app the tools act on: the front one, or the last one before Atelier came forward.
    var toolsTargetApp: NSRunningApplication? { targetApp }

    /// Whether the front app's focused window is in full screen. False without Accessibility.
    func frontIsFullScreen() -> Bool {
        guard trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = AXDesk.focusedWindow(of: app) else { return false }
        return window.isFullScreen
    }

    private func focusedMovable() -> (AXWindow, CGRect, Int)? {
        guard trusted else { status = "Window tools need Accessibility access."; return nil }
        guard let app = targetApp, let window = AXDesk.focusedWindow(of: app), let frame = window.frame else {
            status = "There is no window to move."
            return nil
        }
        guard window.isMovable, !window.isFullScreen else {
            status = "\(app.localizedName ?? "This app") does not allow this window to move."
            return nil
        }
        let all = displays()
        guard let index = WindowGeometry.displayIndex(at: CGPoint(x: frame.midX, y: frame.midY), in: all) else { return nil }
        return (window, frame, index)
    }

    func resizeFront(percent: Double) {
        guard let (window, _, index) = focusedMovable() else { return }
        remember([window])
        move(window, to: ToolsGeometry.percentFrame(percent, in: displays()[index].visible))
        status = nil
    }

    /// Puts the front window in a zone of the active custom layout, one zone further each time.
    func nextCustomZone() {
        guard let layout = Tools.shared.active, !layout.zones.isEmpty else {
            status = "Draw a custom layout first."
            return
        }
        guard let (window, _, index) = focusedMovable() else { return }
        let key = Int(CFHash(window.element))
        let next = ToolsGeometry.nextIndex(after: zoneCursor[key], count: layout.zones.count) ?? 0
        zoneCursor[key] = next
        remember([window])
        move(window, to: ToolsGeometry.frame(of: layout.zones[next], in: displays()[index].visible, gap: gap))
        status = nil
    }

    func moveFront(to zone: ZoneRect) {
        guard let (window, _, index) = focusedMovable() else { return }
        remember([window])
        move(window, to: ToolsGeometry.frame(of: zone, in: displays()[index].visible, gap: gap))
        status = nil
    }

    /// Brings the next window of the front app forward, like Command-` but across its windows on this Space.
    func cycleFrontAppWindows() {
        guard trusted else { status = "Window tools need Accessibility access."; return }
        guard let app = targetApp else { return }
        let windows = AXDesk.allWindows().filter { $0.app.processIdentifier == app.processIdentifier }
        guard windows.count > 1 else {
            status = windows.isEmpty ? "There is no window to cycle." : "\(app.localizedName ?? "This app") has one window."
            return
        }
        // The AX list runs front to back, so the back-most window is the next one up.
        let next = windows[windows.count - 1]
        AXUIElementSetAttributeValue(next.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        next.raise()
        app.activate()
        status = nil
    }

    /// For per-app rules. False until the app has a window to place.
    func place(app: NSRunningApplication, placement: RulePlacement, display: Int?) -> Bool {
        guard trusted, let window = AXDesk.focusedWindow(of: app) ?? AXDesk.allWindows().first(where: {
            $0.app.processIdentifier == app.processIdentifier
        }), let frame = window.frame, window.isMovable, !window.isFullScreen else { return false }
        let all = displays()
        let current = WindowGeometry.displayIndex(at: CGPoint(x: frame.midX, y: frame.midY), in: all) ?? 0
        let index = ToolsGeometry.displayIndex(preferred: display, count: all.count, fallback: current)
        guard all.indices.contains(index) else { return false }
        let visible = all[index].visible
        let target: CGRect
        switch placement {
        case let .layout(raw):
            target = (WindowGeometry.Layout(rawValue: raw) ?? .maximize).frame(in: visible, gap: gap, current: frame.size)
        case let .zone(id, zone):
            guard let layout = Tools.shared.layout(id), layout.zones.indices.contains(zone) else { return true }
            target = ToolsGeometry.frame(of: layout.zones[zone], in: visible, gap: gap)
        case let .percent(share):
            target = ToolsGeometry.percentFrame(share, in: visible)
        }
        move(window, to: target)
        return true
    }

    /// Holding Shift while dragging a window offers the active custom layout's zones.
    /// Returns true while it owns the drag, so the built-in Snap Zones stay quiet.
    fileprivate func trackCustomDrag(down: Bool) -> Bool {
        guard let layout = Tools.shared.active, !layout.zones.isEmpty else { return false }
        guard down else {
            defer { customDrag = nil; customTarget = nil }
            guard let drag = customDrag, let target = customTarget else { return false }
            preview.hide()
            tracker = WindowGeometry.SnapTracker()
            remember([drag.window])
            move(drag.window, to: target)
            return true
        }
        if customDrag == nil {
            let own = ProcessInfo.processInfo.processIdentifier
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own,
                  let window = AXDesk.focusedWindow(of: app), let frame = window.frame, !window.isFullScreen else { return false }
            customDrag = (window, frame)
        }
        guard let drag = customDrag, NSEvent.modifierFlags.contains(.shift), let frame = drag.window.frame,
              hypot(frame.minX - drag.start.minX, frame.minY - drag.start.minY) > WindowGeometry.dragThreshold else {
            if customTarget != nil { preview.hide(); customTarget = nil }
            return false
        }
        let all = displays(), cursor = cursorPoint()
        guard let index = WindowGeometry.displayIndex(at: cursor, in: all) else { return false }
        let visible = all[index].visible
        let unit = CGPoint(x: (cursor.x - visible.minX) / max(visible.width, 1), y: (cursor.y - visible.minY) / max(visible.height, 1))
        guard let zone = ToolsGeometry.zoneIndex(containing: unit, in: layout.zones) else {
            if customTarget != nil { preview.hide(); customTarget = nil }
            return true
        }
        let target = ToolsGeometry.frame(of: layout.zones[zone], in: visible, gap: gap)
        if target != customTarget {
            customTarget = target
            preview.show(title: "\(layout.name) · \(zone + 1)", frame: target, display: all[index],
                         primaryHeight: primaryHeight, below: windowNumber(drag.window))
        }
        return true
    }
}

// MARK: - Radial Menu

extension WindowEngine {
    /// Where a radial pick would put the focused window, on the display under `point`.
    struct RadialTarget {
        var frame: CGRect
        var display: WindowGeometry.Display
        var primaryHeight: Double
        var windowNumber: Int?
        var appName: String
        var current: CGRect
    }

    /// `point` is in Accessibility coordinates. Nil without access or a movable window.
    func radialTarget(_ layout: WindowGeometry.Layout, at point: CGPoint, windowNumber wanted: Bool) -> RadialTarget? {
        guard trusted, let app = targetApp, let window = AXDesk.focusedWindow(of: app), let frame = window.frame,
              window.isMovable, !window.isFullScreen else { return nil }
        let all = displays()
        guard let index = WindowGeometry.displayIndex(at: point, in: all) else { return nil }
        return RadialTarget(frame: layout.frame(in: all[index].visible, gap: gap, current: frame.size), display: all[index],
                            primaryHeight: primaryHeight, windowNumber: wanted ? windowNumber(window) : nil,
                            appName: app.localizedName ?? "", current: frame)
    }

    /// Glides the focused window into `layout` on the display under `point`, with Undo.
    @discardableResult
    func radialApply(_ layout: WindowGeometry.Layout, at point: CGPoint) -> RadialTarget? {
        guard let target = radialTarget(layout, at: point, windowNumber: false),
              let app = targetApp, let window = AXDesk.focusedWindow(of: app) else { return nil }
        remember([window])
        move(window, to: target.frame)
        status = nil
        return target
    }

    /// For tests: puts the focused window exactly at `frame`, no glide.
    func radialPlaceFront(_ frame: CGRect) -> Bool {
        guard trusted, let app = targetApp, let window = AXDesk.focusedWindow(of: app) else { return false }
        finish(window, at: frame)
        return true
    }
}

/// 'WEng'. The Command hot key in Command.swift uses 'DSTK'.
private let engineHotKeySignature = OSType(0x57456E67)

// MARK: - Overlay panels

@MainActor
private func overlayPanel(_ frame: NSRect) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    panel.level = .normal
    return panel
}

@MainActor
final class SnapPreviewModel: ObservableObject {
    @Published var rect = CGRect.zero
    @Published var title = ""
    @Published var visible = false
}

/// The glass slab that shows where a window will land. It sits just below the dragged
/// window, the same place WindowManager puts its tiling overlay by default.
struct SnapPreviewView: View {
    @ObservedObject var model: SnapPreviewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            Color.clear
                .atelierGlass(.regular.tint(DS.Ink.accent.opacity(0.16)), in: shape)
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.14)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .overlay {
                    Text(model.title)
                        .font(DS.title)
                        .foregroundStyle(DS.Ink.primary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .atelierGlass(.regular, in: .capsule)
                        .contentTransition(.opacity)
                }
                .frame(width: model.rect.width, height: model.rect.height)
                .scaleEffect(model.visible || reduceMotion ? 1 : 0.95)
                .opacity(model.visible ? 1 : 0)
                .animation(DS.Motion.touch, value: model.visible)
                .offset(x: model.rect.minX, y: model.rect.minY)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84), value: model.rect)
        }
    }
}

@MainActor
private final class SnapPreview {
    private let model = SnapPreviewModel()
    private var panel: NSPanel?
    private var generation = 0

    func show(layout: WindowGeometry.Layout, frame: CGRect, display: WindowGeometry.Display,
              primaryHeight: Double, below number: Int?) {
        show(title: layout.title, frame: frame, display: display, primaryHeight: primaryHeight, below: number)
    }

    func show(title: String, frame: CGRect, display: WindowGeometry.Display,
              primaryHeight: Double, below number: Int?) {
        generation += 1
        let area = WindowGeometry.flipped(display.frame, primaryHeight: primaryHeight)
        let panel = panel ?? overlayPanel(area)
        if self.panel == nil {
            panel.contentView = NSHostingView(rootView: SnapPreviewView(model: model))
            self.panel = panel
        }
        let local = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        model.title = title
        if !model.visible || panel.frame != area {
            panel.setFrame(area, display: false)
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { model.rect = local }
        } else {
            model.rect = local
        }
        if let number {
            panel.order(.below, relativeTo: number)
        } else {
            panel.level = .floating
            panel.orderFrontRegardless()
        }
        model.visible = true
    }

    func hide() {
        guard model.visible else { return }
        model.visible = false
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
            self.panel?.level = .normal
        }
    }
}

@MainActor
final class StageGlowModel: ObservableObject {
    @Published var color = DS.Ink.accent
    @Published var intensity = 0.7
    @Published var visible = false
}

/// Light that seems to come from behind a window. The window itself hides the middle.
struct StageGlowView: View {
    @ObservedObject var model: StageGlowModel
    let bleed: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(model.color.opacity(0.75 * model.intensity))
                .padding(bleed * 0.62)
                .blur(radius: bleed * 0.42)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(model.color.atelierMix(with: .white, by: 0.18).opacity(0.8 * model.intensity))
                .padding(bleed * 0.9)
                .blur(radius: bleed * 0.12)
        }
        .opacity(model.visible ? 1 : 0)
        .animation(DS.Motion.arrive, value: model.visible)
        .animation(DS.Motion.arrive, value: model.color)
        .animation(DS.Motion.touch, value: model.intensity)
    }
}

/// The light drifts between windows on focus change and tracks a drag exactly.
@MainActor
private final class StageGlow {
    static let bleed = 110.0
    let model = StageGlowModel()
    private var panel: NSPanel?
    private var springs: [WindowGeometry.Spring] = []
    private var lastStep = 0.0
    private var lastOrder = 0.0
    private var generation = 0
    private var tints: [pid_t: Color] = [:]

    func tint(from app: NSRunningApplication) {
        let pid = app.processIdentifier
        let color = tints[pid] ?? app.icon.flatMap(iconTint) ?? DS.Ink.accent
        tints[pid] = color
        model.color = color
    }

    func needsReorder(now: Double) -> Bool { now - lastOrder > 1 }

    /// Returns true while the light is still travelling.
    func follow(frame: CGRect, track: Bool, reduceMotion: Bool, now: Double, primaryHeight: Double, below number: Int?) -> Bool {
        generation += 1
        let target = frame.insetBy(dx: -Self.bleed, dy: -Self.bleed)
        let goals = [target.minX, target.minY, target.width, target.height]
        if springs.isEmpty || track || reduceMotion {
            springs = goals.map { .init(value: $0) }
        } else {
            let dt = now - lastStep
            for index in springs.indices {
                springs[index].step(to: goals[index], dt: dt, response: 0.42, damping: 1)
            }
        }
        lastStep = now
        let current = CGRect(x: springs[0].value, y: springs[1].value, width: springs[2].value, height: springs[3].value)
        let area = WindowGeometry.flipped(current, primaryHeight: primaryHeight)
        let panel = panel ?? overlayPanel(area)
        if self.panel == nil {
            panel.contentView = NSHostingView(rootView: StageGlowView(model: model, bleed: Self.bleed))
            self.panel = panel
        }
        if panel.frame != area { panel.setFrame(area, display: true) }
        if let number {
            panel.order(.below, relativeTo: number)
            lastOrder = now
            model.visible = true
        } else if !model.visible {
            lastOrder = 0 // No window id yet: stay dark rather than draw over the window.
        }
        return zip(springs, goals).contains { !$0.isSettled(at: $1) }
    }

    func hide() {
        springs = []
        guard model.visible else { return }
        model.visible = false
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// The most saturated colour in an icon, lifted so it reads as light.
    private func iconTint(_ image: NSImage) -> Color? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
        NSGraphicsContext.restoreGraphicsState()
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for x in 0..<24 {
            for y in 0..<24 {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let weight = color.saturationComponent * color.saturationComponent * color.alphaComponent
                red += color.redComponent * weight
                green += color.greenComponent * weight
                blue += color.blueComponent * weight
                total += weight
            }
        }
        guard total > 0.5 else { return nil }
        let mean = NSColor(deviceRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        return Color(hue: mean.hueComponent, saturation: max(mean.saturationComponent, 0.6), brightness: max(mean.brightnessComponent, 0.9))
    }
}

// MARK: - Chapter

struct WindowEngineChapter: View {
    @ObservedObject private var engine = WindowEngine.shared
    /// Set only by offline renders, which cannot hold the permission.
    var previewTrusted: Bool?
    @State private var newName = ""
    /// The layout under the pointer, else the last one applied: named once, under the grid.
    @State private var hoveredLayout: WindowGeometry.Layout?
    @State private var lastLayout: WindowGeometry.Layout?

    private var trusted: Bool { previewTrusted ?? engine.trusted }
    private let hue = DS.Spectrum.windows

    var body: some View {
        Text("Windows that glide into place, on keys and edges you own.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary)
            .onAppear {
                engine.start()
                engine.refreshTrust()
                engine.refreshTiling()
                engine.chapterVisible = true
            }
            .onDisappear { engine.chapterVisible = false }
        if !trusted { accessCard }

        SectionHeader("Window superpowers", symbol: "sparkles.rectangle.stack", hue: hue)
        BordersCard(trusted: trusted)
        WindowGrabCard(trusted: trusted)
        WindowSwitcherCard()
        EdgeStashCard(trusted: trusted)

        SectionHeader("Snap and layouts", symbol: "rectangle.split.2x2", hue: hue)
        EngineStage(gap: engine.gap)
        snapCard
        layoutsCard
        RadialMenuCard(trusted: trusted)

        SectionHeader("Focus", symbol: "scope", hue: hue)
        InactiveDimCard(trusted: trusted)
        FocusFollowsMouseCard()

        SectionHeader("Display Memory", symbol: "display.2", hue: hue)
        DisplayMemoryCard(trusted: trusted)

        SectionHeader("Keys and tools", symbol: "command", hue: hue)
        hotKeysCard
        shuffleCard
        workspacesCard
        glowCard
        ToolsCards(trusted: trusted)
        if let status = engine.status {
            Text(status).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                .transition(.opacity)
        }
    }

    private var accessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                DisplayTitle(text: "One permission", size: 22)
                Text("Moving another app's windows needs Accessibility access. Until then, the controls below stay off and the rest of Atelier works as usual.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { engine.requestAccess() } label: {
                        Text(engine.awaitingGrant ? "Ask Again" : "Grant Access")
                            .font(DS.title).foregroundStyle(.white)
                            .frame(minWidth: 132, minHeight: 36)
                            .background(DS.Ink.accent.opacity(0.85), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                    }
                    .buttonStyle(Pressable())
                    if engine.awaitingGrant {
                        Button { engine.openAccessibilitySettings() } label: {
                            Text("Open Settings")
                                .font(DS.title).foregroundStyle(DS.Ink.primary)
                                .frame(minHeight: 36).padding(.horizontal, 14)
                                .background(DS.Ink.fillStrong, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        }
                        .buttonStyle(Pressable())
                        Text("Waiting for your approval.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    }
                }
            }
        }
    }

    private var layoutsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Layouts")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(LayoutTile.order) { layout in
                        LayoutTile(layout: layout, gap: engine.gap, hue: hue, selected: layout == lastLayout) { inside in
                            if inside { hoveredLayout = layout } else if hoveredLayout == layout { hoveredLayout = nil }
                        } action: {
                            lastLayout = layout
                            engine.apply(layout)
                        }
                    }
                }
                layoutCaption
            }
        }
        .disabled(!trusted)
        .opacity(trusted ? 1 : 0.5)
    }

    /// One line under the grid names the layout once, with its hot key. Instant, no animation:
    /// the pointer crosses these tiles many times a minute.
    private var layoutCaption: some View {
        let shown = hoveredLayout ?? lastLayout
        return HStack(spacing: 8) {
            Text(shown?.title ?? "Point at a layout to see its name")
                .font(shown == nil ? DS.caption : DS.Typo.rowTitle)
                .foregroundStyle(shown == nil ? DS.Ink.tertiary : DS.Ink.primary)
            Spacer(minLength: 8)
            if let shown, let keys = Self.hotKey(for: shown) {
                Text(keys)
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(engine.hotKeysEnabled ? DS.Ink.secondary : DS.Ink.tertiary)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(DS.Ink.fill, in: .rect(cornerRadius: 6, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
                    .accessibilityLabel("Hot key \(keys)")
            }
        }
        .frame(height: 22)
    }

    /// The hot key for a layout, as macOS writes it: ⌃⌥ and the key.
    static func hotKey(for layout: WindowGeometry.Layout) -> String? {
        guard let binding = WindowEngine.bindings.first(where: {
            if case .layout(let bound) = $0.action { bound == layout } else { false }
        }) else { return nil }
        let glyphs = ["Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Return": "↩"]
        return "⌃⌥" + (glyphs[binding.label] ?? binding.label)
    }

    private var snapCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "Snap Zones", detail: "Drag a window to an edge or corner. Glass shows where it will land. Press Escape to cancel.") {
                    LuxSwitch(isOn: $engine.snapEnabled, label: "Snap Zones", tint: hue)
                }
                .stagePreview(.demo("engine.snap", "Snap Zones", isOn: engine.snapEnabled, region: StageRegion.window, Demos.snapZones))
                if engine.snapEnabled { AvailabilityNote(availability: engine.snapAvailability) }
                HStack(spacing: 12) {
                    Text("Gap").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    LuxSlider(value: $engine.gap, range: 0...24, label: "Gap", tint: hue)
                    Text("\(Int(engine.gap.rounded())) pt").font(DS.caption).monospacedDigit()
                        .foregroundStyle(DS.Ink.tertiary).frame(width: 34, alignment: .trailing)
                }
            }
        }
        .disabled(!trusted)
        .opacity(trusted ? 1 : 0.5)
    }

    private var hotKeysCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "Hot Keys", detail: "Hold Control and Option, then press a key.") {
                    LuxSwitch(isOn: $engine.hotKeysEnabled, label: "Hot Keys", tint: hue)
                }
                .stagePreview(.demo("engine.keys", "Hot Keys", isOn: engine.hotKeysEnabled, region: StageRegion.window, Demos.hotKeys))
                VStack(alignment: .leading, spacing: 5) {
                    KeyHint(keys: "Arrows", action: "Halves")
                    KeyHint(keys: "D  F  G", action: "Thirds")
                    KeyHint(keys: "E  T", action: "Two thirds")
                    KeyHint(keys: "U  I  J  K", action: "Quarters")
                    KeyHint(keys: "Return", action: "Maximize")
                    KeyHint(keys: "C", action: "Center")
                    KeyHint(keys: "S", action: "Shuffle")
                }
                if !engine.hotKeyConflicts.isEmpty {
                    Text("Another app already uses: \(engine.hotKeyConflicts.joined(separator: ", ")).")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
            }
        }
        .disabled(!trusted)
        .opacity(trusted ? 1 : 0.5)
    }

    private var shuffleCard: some View {
        Card {
            SettingRow(title: "Window Shuffle", detail: "Every window on this display flows into a grid. Press again to rotate them.") {
                HStack(spacing: 8) {
                    if engine.canUndo {
                        EngineButton(title: "Undo", prominent: false) { engine.undo() }
                            .transition(.opacity)
                    }
                    EngineButton(title: "Shuffle", prominent: true) { engine.shuffle() }
                }
                .animation(DS.Motion.settle, value: engine.canUndo)
            }
            .stagePreview(.demo("engine.shuffle", "Window Shuffle", isOn: false, region: StageRegion.window, Demos.shuffle))
        }
        .disabled(!trusted)
        .opacity(trusted ? 1 : 0.5)
    }

    private var workspacesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Workspaces")
                HStack(spacing: 8) {
                    TextField("Name this arrangement", text: $newName)
                        .textFieldStyle(.plain)
                        .font(DS.body)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        .onSubmit(saveWorkspace)
                    EngineButton(title: "Save", prominent: true, action: saveWorkspace)
                        .disabled(trimmedName.isEmpty)
                }
                if engine.workspaces.isEmpty {
                    Text("Saved arrangements appear here. Restoring moves windows of open apps; it never launches anything.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(engine.workspaces) { workspace in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workspace.name).font(DS.title).foregroundStyle(DS.Ink.primary)
                            Text(workspace.windows.count == 1 ? "1 window" : "\(workspace.windows.count) windows")
                                .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        }
                        Spacer(minLength: 8)
                        EngineButton(title: "Restore", prominent: false) { engine.restore(workspace) }
                        Button { engine.delete(workspace) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DS.Ink.tertiary)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(Pressable())
                        .accessibilityLabel("Delete \(workspace.name)")
                    }
                }
            }
        }
        .disabled(!trusted)
        .opacity(trusted ? 1 : 0.5)
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveWorkspace() {
        guard !trimmedName.isEmpty else { return }
        engine.saveWorkspace(named: trimmedName)
        newName = ""
    }

    private var glowCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: "Stage Glow", detail: "A light behind the focused window, tinted by its app's icon. It drifts as focus moves.") {
                    LuxSwitch(isOn: $engine.glowEnabled, label: "Stage Glow", tint: hue)
                }
                .stagePreview(.demo("engine.glow", "Stage Glow", isOn: engine.glowEnabled, region: StageRegion.window, Demos.stageGlow))
                if engine.glowEnabled {
                    LuxSlider(value: $engine.glowIntensity, range: 0.2...1, label: "Glow", tint: hue)
                }
            }
        }
        .disabled(!trusted)
        .opacity(trusted ? 1 : 0.5)
    }
}

private struct EngineButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.Ink.primary)
                .frame(height: 34)
                .padding(.horizontal, 14)
                .background(prominent ? AnyShapeStyle(DS.Ink.accent.opacity(enabled ? 0.8 : 0.3)) : AnyShapeStyle(DS.Ink.fillStrong),
                            in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(Pressable())
    }
}

private struct KeyHint: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 10) {
            Text(keys).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.primary)
                .frame(width: 84, alignment: .leading)
            Text(action).font(DS.caption).foregroundStyle(DS.Ink.secondary)
        }
    }
}

/// A small screen with the layout lit up. It uses the same geometry as the real thing.
private struct LayoutTile: View {
    static let order: [WindowGeometry.Layout] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize,
        .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
        .topLeft, .topRight, .bottomLeft, .bottomRight, .center,
    ]

    let layout: WindowGeometry.Layout
    let gap: Double
    var hue: Color = DS.Spectrum.windows
    var selected = false
    var hover: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 3, dy: 3)
                let tile = layout.frame(in: bounds, gap: 2 + gap / 8, current: CGSize(width: bounds.width * 0.5, height: bounds.height * 0.6))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(hovering || selected ? hue : DS.Ink.primary.opacity(0.62))
                    .frame(width: tile.width, height: tile.height)
                    .offset(x: tile.minX, y: tile.minY)
            }
            .aspectRatio(1.6, contentMode: .fit)
            .background(selected ? hue.opacity(0.12) : DS.Ink.fill, in: .rect(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? hue.opacity(0.6) : (hovering ? DS.Ink.edge : DS.Ink.hairline), lineWidth: selected ? 0.75 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.95))
        // Tint and stroke only on hover; nothing moves.
        .animation(DS.Motion.hover, value: hovering)
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
        .accessibilityLabel(layout.title)
        .accessibilityValue(Self.hotKeyValue(layout))
    }

    private static func hotKeyValue(_ layout: WindowGeometry.Layout) -> String {
        WindowEngineChapter.hotKey(for: layout) ?? ""
    }
}

/// A live miniature of the desktop. Three windows glide through real layouts while the
/// glow follows the focused one. It needs no permission, since it only moves its own views.
private struct EngineStage: View {
    let gap: Double
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tints: [Color] = [DS.Ink.accent, Color(red: 0.98, green: 0.62, blue: 0.4), Color(red: 0.5, green: 0.9, blue: 0.72)]

    private func frames(in screen: CGRect) -> [CGRect] {
        let gap = 2 + self.gap / 3
        func tiles(_ layouts: [WindowGeometry.Layout]) -> [CGRect] { layouts.map { $0.frame(in: screen, gap: gap) } }
        switch step % 4 {
        case 0: return tiles([.leftHalf, .topRight, .bottomRight])
        case 1: return tiles([.leftThird, .centerThird, .rightThird])
        case 2: return WindowGeometry.gridCells(count: 3, in: screen, gap: gap)
        default:
            let full = WindowGeometry.Layout.maximize.frame(in: screen, gap: gap)
            return [full.insetBy(dx: 10, dy: 8), full, full.insetBy(dx: 18, dy: 14)]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let screen = CGRect(x: 0, y: 12, width: geometry.size.width, height: geometry.size.height - 12)
            let rects = frames(in: screen)
            let focus = step % 3
            ZStack(alignment: .topLeading) {
                MeshCanvas(hue: .ocean, hour: 20)
                Rectangle().fill(.black.opacity(0.25)).frame(height: 12)
                // A gradient, not a blur: the glow costs nothing while the panel fades in.
                EllipticalGradient(colors: [tints[focus].opacity(0.7), tints[focus].opacity(0)], center: .center,
                                   startRadiusFraction: 0.25, endRadiusFraction: 0.62)
                    .frame(width: rects[focus].width + 44, height: rects[focus].height + 44)
                    .offset(x: rects[focus].minX - 22, y: rects[focus].minY - 22)
                ForEach(0..<3, id: \.self) { index in
                    MiniWindow(tint: tints[index], focused: index == focus)
                        .frame(width: rects[index].width, height: rects[index].height)
                        .offset(x: rects[index].minX, y: rects[index].minY)
                        .zIndex(index == focus ? 2 : 1)
                }
            }
        }
        .frame(height: 184)
        // One flattened layer: the panel's fade then moves a picture, not a tree of shapes.
        .drawingGroup()
        .clipShape(.rect(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                if Task.isCancelled { return }
                withAnimation(.spring(response: Glide.response * 2, dampingFraction: Glide.damping)) { step += 1 }
            }
        }
    }
}

private struct MiniWindow: View {
    let tint: Color
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.white.opacity(focused ? 0.75 : 0.35)).frame(width: 4, height: 4)
                }
            }
            .padding(6)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(tint.opacity(0.8)).frame(maxWidth: 46).frame(height: 4)
                Capsule().fill(.white.opacity(0.2)).frame(maxWidth: 72).frame(height: 3)
                Capsule().fill(.white.opacity(0.14)).frame(maxWidth: 58).frame(height: 3)
            }
            .padding(.horizontal, 7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: focused ? 0.16 : 0.11).opacity(0.94), in: .rect(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(focused ? 0.28 : 0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}


/// The ring around the window you are in: on or off, its colours, width, glow and corners.
struct BordersCard: View {
    let trusted: Bool
    @ObservedObject private var borders = WindowBorders.shared

    private var preview: StagePreviewSpec {
        .overlay("engine.borders", "Window Borders", isOn: borders.enabled) { size in BorderPreview(size: size) }
    }

    var body: some View {
        HeroCard("Window Borders", pitch: "A ring of light follows the window you are working in.",
                 isOn: $borders.enabled, hue: DS.Spectrum.windows,
                 readout: "\(Int(borders.width.rounded())) pt", readoutCaption: "Width", preview: preview) {
            LivePlate { size, since in BorderPreview(size: size, plate: true, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                swatches
                HeroSlider(title: "Width", value: $borders.width, range: 1...12, hue: DS.Spectrum.windows) { "\(Int($0.rounded())) pt" }
                HeroSlider(title: "Glow", value: $borders.glow, range: 0...1, hue: DS.Spectrum.windows) { "\(Int(($0 * 100).rounded()))%" }
                HeroSlider(title: "Corners", value: $borders.radius, range: 0...30, hue: DS.Spectrum.windows) { "\(Int($0.rounded())) pt" }
                Text(trusted ? "Steps aside in full screen, and around Atelier's own window."
                             : "Needs Accessibility, to know where your window is.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        }
    }

    /// One canvas paints every swatch; the buttons over it are clear. Seven gradient rings as
    /// separate views cost the chapter frames while it opens.
    private var swatches: some View {
        let styles = BorderStyle.allCases
        return Canvas { context, size in
            let step = size.width / Double(styles.count)
            for (index, style) in styles.enumerated() {
                let center = CGPoint(x: step * (Double(index) + 0.5), y: 17)
                let ring = Path(ellipseIn: CGRect(x: center.x - 12.5, y: center.y - 12.5, width: 25, height: 25))
                context.stroke(ring, with: .conicGradient(Gradient(colors: style.colors(wallpaper: borders.wallpaperColor)), center: center),
                               lineWidth: 5)
                if style == borders.style {
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 19, y: center.y - 19, width: 38, height: 38)),
                                   with: .color(.white), lineWidth: 2)
                }
                context.draw(Text(style.title).font(.system(size: 11, weight: .medium))
                                .foregroundStyle(style == borders.style ? DS.Ink.primary : DS.Ink.secondary),
                             at: CGPoint(x: center.x, y: 48))
            }
        }
        .frame(height: 58)
        .overlay {
            HStack(spacing: 0) {
                ForEach(styles) { style in
                    Button { borders.style = style } label: { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(style.title + " border")
                        .accessibilityValue(borders.style == style ? "Selected" : "")
                }
            }
        }
    }
}

// MARK: - Hero plates

extension FocusTracker {
    /// True when the focused window is one of Atelier's own. Borders and Dim step aside then:
    /// a ring or a shade around the panel fights its chrome.
    static func isAtelier(_ focus: Focus) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { return true }
        guard let id = focus.windowID else { return false }
        return NSApp.windows.contains { $0.windowNumber == Int(id) }
    }
}

/// Hosts a hero's miniature and tells it when the pointer arrived. At rest (`since == nil`) the
/// miniature is a still picture; it plays only while hovered, and never under Reduce Motion.
struct LivePlate<Content: View>: View {
    private let content: (CGSize, Date?) -> Content
    @State private var since: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(@ViewBuilder content: @escaping (CGSize, Date?) -> Content) { self.content = content }

    var body: some View {
        GeometryReader { geometry in content(geometry.size, since) }
            .contentShape(Rectangle())
            .onHover { inside in since = inside && !reduceMotion ? .now : nil }
    }
}

/// A plate's clock: seconds since the pointer arrived, starting from the plate's rest pose
/// `rest`. Paused (no frames at all) while `since` is nil; leaving eases back to the rest pose.
struct PlateClock<Content: View>: View {
    let since: Date?
    var rest: Double = 0
    var fps: Double = 60
    @ViewBuilder var content: (Double) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps, paused: since == nil)) { context in
            content(rest + (since.map { max(context.date.timeIntervalSince($0), 0) } ?? 0))
        }
        .animation(DS.Motion.arrive, value: since == nil)
    }
}

/// A window drawn for a plate: traffic lights, a tinted title line and a few lines of text.
/// Gradients and a hairline only: no shadow, so it can move without re-rendering one.
struct PlateWindow: View {
    var tint: Color = DS.Spectrum.windows
    var focused = true
    var corner: Double = 7

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3.5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { light in
                    Circle().fill(focused ? light.opacity(0.85) : .white.opacity(0.22)).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 7).padding(.top, 7).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(tint.opacity(focused ? 0.9 : 0.45)).frame(width: 38, height: 4)
                Capsule().fill(.white.opacity(0.2)).frame(maxWidth: 76).frame(height: 3)
                Capsule().fill(.white.opacity(0.14)).frame(maxWidth: 60).frame(height: 3)
                Capsule().fill(.white.opacity(0.1)).frame(maxWidth: 68).frame(height: 3)
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            shape.fill(LinearGradient(colors: [Color(white: focused ? 0.21 : 0.15), Color(white: focused ? 0.13 : 0.1)],
                                      startPoint: .top, endPoint: .bottom))
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(focused ? 0.26 : 0.12), .white.opacity(0.04)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
        }
    }
}

/// A hero's tuning slider: name, slider in the hero's light, value in tabular figures.
struct HeroSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var hue: Color = DS.Spectrum.windows
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 60, alignment: .leading)
            LuxSlider(value: $value, range: range, label: title, tint: hue)
            Text(format(value)).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
