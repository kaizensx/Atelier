import CoreGraphics
import Foundation

// MARK: - Display Memory, the pure half
//
// macOS moves windows whenever the set of displays changes: a monitor plugged or unplugged, a
// wake from sleep, a resolution change. Display Memory remembers the arrangement for each
// display *configuration* and puts every window back when that configuration returns.
//
// Everything here is free of AppKit and Accessibility so it can be tested:
// - the configuration fingerprint (which displays, where, at which size),
// - snapshot diffing and merging (so a Space switch does not forget windows),
// - matching remembered windows to live ones (window id, title, similar title, app order),
// - where a window goes when its display is missing (rehome),
// - the settle gate that waits out a burst of reconfiguration events,
// - the journal that only trusts a snapshot once no reconfiguration followed it.
//
// Rectangles are in global Accessibility coordinates: origin at the top left of the primary
// display, y growing downward.

/// One display as Display Memory sees it.
public struct DisplayFacts: Codable, Equatable, Sendable {
    /// CoreGraphics' display UUID (ColorSync derives it from vendor, model, serial and port).
    public var uuid: String
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var name: String
    public var builtIn: Bool
    public var frame: CGRect
    public var visible: CGRect
    public var scale: Double
    public var rotation: Double

    public init(uuid: String, vendor: UInt32, model: UInt32, serial: UInt32, name: String, builtIn: Bool,
                frame: CGRect, visible: CGRect, scale: Double = 2, rotation: Double = 0) {
        self.uuid = uuid
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.name = name
        self.builtIn = builtIn
        self.frame = frame
        self.visible = visible
        self.scale = scale
        self.rotation = rotation
    }

    /// Stable across reconnects, ports and reboots when the display reports a serial number.
    /// Without one, the UUID (which then also depends on the port) is the best there is.
    public var baseIdentity: String {
        serial != 0 ? String(format: "%x-%x-%x", vendor, model, serial) : uuid.lowercased()
    }

    /// The display holding the menu bar: the origin of the global space.
    public var isPrimary: Bool { frame.minX == 0 && frame.minY == 0 }
}

/// A set of connected displays and their arrangement, with a fingerprint that names it.
public struct DisplayConfiguration: Codable, Equatable, Sendable {
    /// Sorted by identity, so the same setup always reads the same.
    public private(set) var displays: [DisplayFacts]
    /// Identities, parallel to `displays`. Two identical monitors without serials get `#2`.
    public private(set) var identities: [String]
    /// `dm-` and 16 hex digits.
    public private(set) var key: String

    public init(_ input: [DisplayFacts]) {
        // Twins (same base identity) are told apart by position, left to right, top to bottom.
        let ordered = input.sorted {
            ($0.baseIdentity, $0.frame.minX, $0.frame.minY) < ($1.baseIdentity, $1.frame.minX, $1.frame.minY)
        }
        var seen: [String: Int] = [:]
        var ids: [String] = []
        for display in ordered {
            let n = (seen[display.baseIdentity] ?? 0) + 1
            seen[display.baseIdentity] = n
            ids.append(n == 1 ? display.baseIdentity : "\(display.baseIdentity)#\(n)")
        }
        displays = ordered
        identities = ids
        key = Self.fingerprint(ordered, identities: ids)
    }

    /// The canonical text a fingerprint hashes: identity, origin, size in points, scale, rotation.
    public static func canonical(_ displays: [DisplayFacts], identities: [String]) -> String {
        zip(displays, identities).map { display, id in
            let f = display.frame
            return "\(id)@\(Int(f.minX.rounded())),\(Int(f.minY.rounded())),\(Int(f.width.rounded()))x\(Int(f.height.rounded()))"
                + "*\(Int((display.scale * 100).rounded()))r\(Int(display.rotation.rounded()))"
        }.joined(separator: "|")
    }

    static func fingerprint(_ displays: [DisplayFacts], identities: [String]) -> String {
        "dm-" + String(format: "%016llx", DisplayMemoryLogic.fnv1a(canonical(displays, identities: identities)))
    }

    public var isEmpty: Bool { displays.isEmpty }

    public func display(identity: String) -> DisplayFacts? {
        identities.firstIndex(of: identity).map { displays[$0] }
    }

    /// The display a rectangle belongs to: the one it overlaps most, else the nearest.
    public func identity(for rect: CGRect) -> String? {
        guard !displays.isEmpty else { return nil }
        func overlap(_ d: DisplayFacts) -> Double {
            let i = d.frame.intersection(rect)
            return i.isNull ? 0 : i.width * i.height
        }
        func distance(_ d: DisplayFacts) -> Double {
            let dx = max(d.frame.minX - rect.midX, 0, rect.midX - d.frame.maxX)
            let dy = max(d.frame.minY - rect.midY, 0, rect.midY - d.frame.maxY)
            return dx * dx + dy * dy
        }
        let best = displays.indices.max { overlap(displays[$0]) < overlap(displays[$1]) }!
        if overlap(displays[best]) > 0 { return identities[best] }
        return identities[displays.indices.min { distance(displays[$0]) < distance(displays[$1]) }!]
    }

    /// Short, human: "Built-in Display + DELL U2720Q".
    public var summary: String {
        let builtInFirst = displays.sorted { ($0.builtIn ? 0 : 1, $0.frame.minX) < ($1.builtIn ? 0 : 1, $1.frame.minX) }
        return builtInFirst.map(\.name).joined(separator: " + ")
    }

    /// The bounding box of every display, for a mini-map.
    public var bounds: CGRect { displays.reduce(CGRect.null) { $0.union($1.frame) } }
}

/// A window as remembered for one configuration.
public struct RememberedWindow: Codable, Equatable, Sendable {
    public var app: String
    public var appName: String
    public var title: String
    public var windowID: Int?
    public var pid: Int32?
    public var frame: CGRect
    /// Identity of the display holding it, in its configuration.
    public var display: String?
    /// Front to back across all windows, 0 is frontmost.
    public var order: Int

    public init(app: String, appName: String, title: String, windowID: Int?, pid: Int32?, frame: CGRect,
                display: String?, order: Int) {
        self.app = app
        self.appName = appName
        self.title = title
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
        self.display = display
        self.order = order
    }
}

/// Everything remembered about one configuration.
public struct DisplaySetup: Codable, Equatable, Identifiable, Sendable {
    public var id: String { configuration.key }
    public var configuration: DisplayConfiguration
    public var windows: [RememberedWindow]
    public var updated: Date
    public var restored: Date?
    /// How many times this configuration came back and was restored.
    public var restores: Int

    public init(configuration: DisplayConfiguration, windows: [RememberedWindow], updated: Date,
                restored: Date? = nil, restores: Int = 0) {
        self.configuration = configuration
        self.windows = windows
        self.updated = updated
        self.restored = restored
        self.restores = restores
    }
}

/// A window that exists now, as the matcher needs it.
public struct LiveWindow: Equatable, Sendable {
    public var app: String
    public var title: String
    public var windowID: Int?
    public var pid: Int32?
    public var frame: CGRect

    public init(app: String, title: String, windowID: Int?, pid: Int32?, frame: CGRect) {
        self.app = app
        self.title = title
        self.windowID = windowID
        self.pid = pid
        self.frame = frame
    }
}

public enum DisplayMemoryLogic {
    /// 64-bit FNV-1a: stable across launches and machines, unlike `Hasher`.
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: Cheap change detection

    /// A signature of the window server's list (id and bounds of every normal window): polled
    /// every couple of seconds, and only a change pays for an Accessibility snapshot.
    public static func listSignature(_ windows: [(id: Int, bounds: CGRect)]) -> UInt64 {
        let text = windows.sorted { $0.id < $1.id }.map { w in
            "\(w.id):\(Int(w.bounds.minX.rounded())),\(Int(w.bounds.minY.rounded())),\(Int(w.bounds.width.rounded())),\(Int(w.bounds.height.rounded()))"
        }.joined(separator: ";")
        return fnv1a(text)
    }

    // MARK: Snapshot diffing

    public static func close(_ a: CGRect, _ b: CGRect, tolerance: Double = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// True when two snapshots differ in which windows exist or where any of them is.
    public static func differs(_ a: [RememberedWindow], _ b: [RememberedWindow], tolerance: Double = 2) -> Bool {
        guard a.count == b.count else { return true }
        func key(_ w: RememberedWindow) -> String { "\(w.app)|\(w.windowID.map(String.init) ?? "t:" + w.title)" }
        var pool = Dictionary(grouping: b, by: key)
        for window in a {
            guard var candidates = pool[key(window)],
                  let index = candidates.firstIndex(where: { close($0.frame, window.frame, tolerance: tolerance) }) else { return true }
            candidates.remove(at: index)
            pool[key(window)] = candidates
        }
        return false
    }

    /// A fresh snapshot keeps the windows Accessibility could not see this time (another Space,
    /// an app that did not answer in time) as long as the window server says they still exist.
    public static func merge(previous: [RememberedWindow], fresh: [RememberedWindow], alive: Set<Int>) -> [RememberedWindow] {
        let freshIDs = Set(fresh.compactMap(\.windowID))
        let kept = previous.filter { old in
            guard let id = old.windowID else { return false }
            return alive.contains(id) && !freshIDs.contains(id)
        }
        return (fresh + kept.map { var w = $0; w.order += fresh.count; return w })
            .enumerated().map { var w = $0.element; w.order = $0.offset; return w }
    }

    // MARK: Matching

    public enum MatchReason: String, Sendable, CaseIterable {
        case windowID, title, similarTitle, appOrder
    }

    public struct Match: Equatable, Sendable {
        public var saved: Int
        public var live: Int
        public var reason: MatchReason
    }

    /// "Report.txt — Edited" and "report.txt" are the same document.
    public static func normalized(_ title: String) -> String {
        var t = title.lowercased()
        for suffix in [" — edited", " - edited", " — locked", " (edited)"] where t.hasSuffix(suffix) {
            t.removeLast(suffix.count)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 0…1: the better of word overlap and shared ends. Tabs and documents change their titles
    /// a little ("Inbox (3)" → "Inbox (5)"); a different document scores low.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalized(a), y = normalized(b)
        if x == y { return 1 }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        let separators = CharacterSet.alphanumerics.inverted
        let wx = Set(x.components(separatedBy: separators).filter { !$0.isEmpty })
        let wy = Set(y.components(separatedBy: separators).filter { !$0.isEmpty })
        let jaccard = wx.isEmpty || wy.isEmpty ? 0 : Double(wx.intersection(wy).count) / Double(wx.union(wy).count)
        // What the two share at both ends: "Inbox (3) — Mail" and "Inbox (5) — Mail" differ by one character.
        let prefix = zip(x, y).prefix { $0 == $1 }.count
        let suffix = zip(x.reversed(), y.reversed()).prefix { $0 == $1 }.count
        let ends = min(prefix + suffix, min(x.count, y.count))
        return max(jaccard, Double(ends) / Double(max(x.count, y.count)))
    }

    public static let similarityThreshold = 0.6

    /// Pairs remembered windows with live ones, strongest evidence first:
    /// 1. the same window-server id in the same process (the app never quit),
    /// 2. the same app and title,
    /// 3. the same app and a similar title, best pair first,
    /// 4. the same app, in front-to-back order.
    public static func match(saved: [RememberedWindow], live: [LiveWindow]) -> [Match] {
        var result: [Match] = []
        var usedSaved = Set<Int>(), usedLive = Set<Int>()
        func take(_ s: Int, _ l: Int, _ reason: MatchReason) {
            result.append(Match(saved: s, live: l, reason: reason))
            usedSaved.insert(s)
            usedLive.insert(l)
        }
        for (s, window) in saved.enumerated() {
            guard let id = window.windowID else { continue }
            if let l = live.indices.first(where: {
                !usedLive.contains($0) && live[$0].windowID == id && live[$0].app == window.app
                    && (window.pid == nil || live[$0].pid == nil || live[$0].pid == window.pid)
            }) { take(s, l, .windowID) }
        }
        for (s, window) in saved.enumerated() where !usedSaved.contains(s) {
            if let l = live.indices.first(where: {
                !usedLive.contains($0) && live[$0].app == window.app && normalized(live[$0].title) == normalized(window.title)
            }) { take(s, l, .title) }
        }
        var scored: [(s: Int, l: Int, score: Double)] = []
        for (s, window) in saved.enumerated() where !usedSaved.contains(s) {
            for l in live.indices where !usedLive.contains(l) && live[l].app == window.app {
                let score = similarity(window.title, live[l].title)
                if score >= similarityThreshold { scored.append((s, l, score)) }
            }
        }
        for pair in scored.sorted(by: { ($1.score, $0.s) < ($0.score, $1.s) })
        where !usedSaved.contains(pair.s) && !usedLive.contains(pair.l) {
            take(pair.s, pair.l, .similarTitle)
        }
        let byOrder = saved.indices.filter { !usedSaved.contains($0) }.sorted { saved[$0].order < saved[$1].order }
        for s in byOrder {
            if let l = live.indices.first(where: { !usedLive.contains($0) && live[$0].app == saved[s].app }) {
                take(s, l, .appOrder)
            }
        }
        return result.sorted { $0.saved < $1.saved }
    }

    // MARK: Placement

    /// Fits a rectangle inside `bounds`: shrinks it if it is larger, then slides it in.
    public static func fit(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width), height = min(rect.height, bounds.height)
        return CGRect(x: min(max(rect.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(rect.minY, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    /// Maps a rectangle from one display to another of a different size, keeping its relative
    /// position and size within the visible area.
    public static func proportional(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return fit(rect, in: target) }
        let sx = target.width / source.width, sy = target.height / source.height
        return CGRect(x: target.minX + (rect.minX - source.minX) * sx, y: target.minY + (rect.minY - source.minY) * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    public enum Placement: String, Sendable {
        /// Its display is there at the same size: the exact frame.
        case exact
        /// Its display is there at another size or position: moved and scaled with it.
        case followed
        /// Its display is gone: scaled onto the primary display.
        case rehomed
    }

    /// Where a remembered window goes in the configuration that exists now.
    public static func target(for window: RememberedWindow, saved: DisplayConfiguration,
                              current: DisplayConfiguration) -> (frame: CGRect, placement: Placement) {
        let identity = window.display ?? saved.identity(for: window.frame)
        let from = identity.flatMap(saved.display(identity:))
        if let identity, let from, let to = current.display(identity: identity) {
            if close(from.frame, to.frame, tolerance: 0.5), close(from.visible, to.visible, tolerance: 0.5) {
                return (window.frame, .exact)
            }
            let sameSize = abs(from.visible.width - to.visible.width) < 0.5 && abs(from.visible.height - to.visible.height) < 0.5
            let moved = sameSize
                ? window.frame.offsetBy(dx: to.visible.minX - from.visible.minX, dy: to.visible.minY - from.visible.minY)
                : proportional(window.frame, from: from.visible, to: to.visible)
            return (fit(moved, in: to.visible), .followed)
        }
        guard let home = current.displays.first(where: \.isPrimary) ?? current.displays.first else {
            return (window.frame, .exact)
        }
        let source = from?.visible ?? saved.bounds
        // The relative position carries over; the window keeps its own size, shrunk only to fit.
        let mapped = source.isNull ? window.frame : proportional(window.frame, from: source, to: home.visible)
        return (fit(CGRect(origin: mapped.origin, size: window.frame.size), in: home.visible), .rehomed)
    }

    /// Whether a window needs moving to reach `target`.
    public static func needsMove(_ current: CGRect, to target: CGRect, tolerance: Double = 3) -> Bool {
        !close(current, target, tolerance: tolerance)
    }
}

// MARK: - Settling

/// Waits out a burst of reconfiguration events. macOS sends several for one plug (each display
/// begins and ends, the mode settles, the arrangement is written), and on wake the list of
/// displays can flicker for a second or two. The gate says "settled" once: when nothing has
/// changed for `quiet` seconds and the same configuration has been seen for `stable` seconds,
/// or after `maxWait` whatever happens, so a display that keeps flapping cannot hold it forever.
public struct DisplaySettleGate: Equatable, Sendable {
    public var quiet: Double
    public var stable: Double
    public var maxWait: Double
    public private(set) var settling = false
    private var firstChange = 0.0
    private var lastChange = 0.0
    private var key: String?
    private var keySince = 0.0

    public init(quiet: Double = 1.2, stable: Double = 1.0, maxWait: Double = 15) {
        self.quiet = quiet
        self.stable = stable
        self.maxWait = maxWait
    }

    public mutating func noteChange(now: Double) {
        if !settling { firstChange = now }
        settling = true
        lastChange = now
    }

    /// Feed the configuration seen now (nil: no display, as with the lid closed and nothing
    /// attached). Returns the key once, when it has settled.
    public mutating func observe(key current: String?, now: Double) -> String? {
        guard settling else { return nil }
        if current != key {
            key = current
            keySince = now
        }
        guard let current else { return nil }
        let calm = now - lastChange >= quiet && now - keySince >= stable
        guard calm || now - firstChange >= maxWait else { return nil }
        settling = false
        return current
    }
}

/// A snapshot is only trusted once `confirmDelay` seconds pass with no reconfiguration: macOS
/// starts moving windows at the same moment it tells us the displays are changing, so the
/// snapshot taken just before could already be the scrambled one.
public struct SnapshotJournal<Payload: Sendable>: Sendable {
    public var confirmDelay: Double
    public private(set) var pending: (key: String, payload: Payload, time: Double)?

    public init(confirmDelay: Double = 1.5) { self.confirmDelay = confirmDelay }

    public mutating func propose(key: String, payload: Payload, now: Double) {
        pending = (key, payload, now)
    }

    /// A reconfiguration began: whatever was waiting is suspect.
    public mutating func invalidate() { pending = nil }

    /// The pending snapshot, once old enough, for the configuration that is still current.
    public mutating func due(now: Double, currentKey: String?) -> (key: String, payload: Payload)? {
        guard let pending, now - pending.time >= confirmDelay else { return nil }
        self.pending = nil
        guard pending.key == currentKey else { return nil }
        return (pending.key, pending.payload)
    }
}
