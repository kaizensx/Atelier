import CoreGraphics
import Foundation

// The pure part of the Window Switcher: which shortcut opens it, what order the windows come
// in, and how the selection moves. Kept apart from AppKit so it can be tested without windows.

/// The chord that opens the Window Switcher. ⌘Tab is deliberately absent: it stays macOS's.
public enum SwitcherShortcut: String, CaseIterable, Codable, Sendable {
    case optionTab
    case controlTab
    case commandGrave

    /// Virtual key codes: Tab is 48 and the grave accent key, left of 1, is 50.
    public var keyCode: Int64 {
        switch self {
        case .optionTab, .controlTab: 48
        case .commandGrave: 50
        }
    }

    /// The modifier that has to be held, as a raw CGEventFlags mask.
    public var modifier: UInt64 {
        switch self {
        case .optionTab: CGEventFlags.maskAlternate.rawValue
        case .controlTab: CGEventFlags.maskControl.rawValue
        case .commandGrave: CGEventFlags.maskCommand.rawValue
        }
    }

    public var label: String {
        switch self {
        case .optionTab: "⌥Tab"
        case .controlTab: "⌃Tab"
        case .commandGrave: "⌘`"
        }
    }

    /// ⌘` is macOS's own "next window of this app", so in that mode the switcher keeps to the
    /// front app's windows and simply shows them.
    public var frontAppOnly: Bool { self == .commandGrave }

    /// Whether a key press with these flags is this chord. Shift may be added, for going
    /// backwards; any other modifier makes it a different shortcut that belongs to someone else.
    public func matches(keyCode: Int64, flags: UInt64) -> Bool {
        guard keyCode == self.keyCode, flags & modifier != 0 else { return false }
        let others = (CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue
                      | CGEventFlags.maskCommand.rawValue) & ~modifier
        return flags & others == 0
    }
}

public enum SwitcherOrder {
    /// Orders windows the way the switcher lists them: windows on screen first, front to back
    /// as the window server stacks them (which is the order they were last used in), then
    /// windows the window server does not show on screen, then minimised ones. Ties keep the
    /// order they came in, so an app's own front-to-back order survives.
    public static func ordered<T>(_ items: [T], zIndex: (T) -> Int?, minimized: (T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            let ka = key(zIndex(a.element), minimized(a.element)), kb = key(zIndex(b.element), minimized(b.element))
            if ka.group != kb.group { return ka.group < kb.group }
            if ka.z != kb.z { return ka.z < kb.z }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func key(_ z: Int?, _ minimized: Bool) -> (group: Int, z: Int) {
        if minimized { return (2, 0) }
        guard let z else { return (1, 0) }
        return (0, z)
    }

    /// A window-server list, front to back, turned into a lookup of each window's place in it.
    public static func zIndex(of frontToBack: [UInt32]) -> [UInt32: Int] {
        var map: [UInt32: Int] = [:]
        for (index, id) in frontToBack.enumerated() where map[id] == nil { map[id] = index }
        return map
    }
}

/// Where the highlight sits in a grid of cards, and how keys move it. Everything wraps, the way
/// ⌘Tab does.
public struct SwitcherSelection: Equatable, Sendable {
    public private(set) var index: Int
    public let count: Int
    public let columns: Int

    /// The first press lands on the second window, like ⌘Tab, because the first is the one
    /// already in front. Going backwards lands on the last.
    public init(count: Int, columns: Int, backward: Bool = false) {
        self.count = max(count, 0)
        self.columns = max(columns, 1)
        if count <= 1 {
            index = 0
        } else {
            index = backward ? count - 1 : 1
        }
    }

    /// Tab and ⇧Tab, and the left and right arrows.
    public mutating func step(_ delta: Int) {
        guard count > 0 else { return }
        index = ((index + delta) % count + count) % count
    }

    /// The up and down arrows: one row, in the same column, wrapping round the top and bottom.
    /// The last row may be short; landing past its end picks its last card.
    public mutating func row(_ delta: Int) {
        guard count > 0 else { return }
        let rows = (count + columns - 1) / columns
        guard rows > 1 else { return }
        let row = ((index / columns + delta) % rows + rows) % rows
        index = min(row * columns + index % columns, count - 1)
    }

    public mutating func select(_ newIndex: Int) {
        guard newIndex >= 0, newIndex < count else { return }
        index = newIndex
    }
}

public enum SwitcherLayout {
    /// How many cards go in a row: all of them up to the limit, then even rows, so a second
    /// row is never left with one lonely card.
    public static func columns(count: Int, maxColumns: Int) -> Int {
        guard count > 0, maxColumns > 0 else { return 1 }
        guard count > maxColumns else { return count }
        let rows = (count + maxColumns - 1) / maxColumns
        return (count + rows - 1) / rows
    }

    /// A small schematic of a window's shape, fitted inside a box, never thinner than a sliver.
    public static func schematic(for size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: max(size.width * scale, box.width * 0.2), height: max(size.height * scale, box.height * 0.2))
    }
}
