import AppKit
import SwiftUI

/// The old Desktop Clock and Desktop Vitals effects now live on the board as widgets.
/// These let the old controls in Effects and Unique drive the widgets, and move an existing setup over once.
extension WidgetBoard {
    static let adoptedEffectsKey = "boardAdoptedEffects"

    /// Whether a Big Clock is on the board. Turning it on adds one where the old Desktop Clock sat, bottom left.
    var desktopClock: Bool {
        get { placements.contains { $0.kind == .bigClock } }
        set {
            if newValue {
                if !desktopClock { addDesktopClock(style: .thin) }
            } else {
                placements.filter { $0.kind == .bigClock }.forEach { remove($0.uid) }
            }
        }
    }

    /// The face of the first Big Clock, in the old four styles, for the old style picker.
    var desktopClockStyle: ClockStyle {
        get { placements.first { $0.kind == .bigClock }?.options.clock?.face.legacy ?? .thin }
        set {
            guard let clock = placements.first(where: { $0.kind == .bigClock }) else {
                addDesktopClock(style: newValue)
                return
            }
            update(clock.uid) {
                var options = $0.options.clock ?? ClockOptions()
                options.face = ClockFace(newValue)
                $0.options.clock = options
            }
        }
    }

    /// Whether a Vitals widget is on the board. Turning it on adds one where the old Desktop Vitals sat, bottom right.
    var desktopVitals: Bool {
        get { placements.contains { $0.kind == .vitals } }
        set {
            if newValue {
                if !desktopVitals { addDesktopVitals() }
            } else {
                placements.filter { $0.kind == .vitals }.forEach { remove($0.uid) }
            }
        }
    }

    /// A Big Clock in the old Desktop Clock's corner and style: no surface, white, a soft shadow, bottom left.
    @discardableResult
    func addDesktopClock(style: ClockStyle) -> String? {
        let span = style == .words ? WidgetSpan(columns: 7, rows: 3) : WidgetSpan(columns: 5, rows: 2)
        var options = WidgetOptions()
        options.clock = ClockOptions(legacy: style)
        var look = WidgetStyle.bare
        look.shadow = 0
        return addLegacy(.bigClock, span: span, options: options, style: look, corner: .bottomLeading)
    }

    /// A Vitals widget in the old Desktop Vitals' corner and look: white rings for memory, disk and battery.
    @discardableResult
    func addDesktopVitals() -> String? {
        var options = WidgetOptions()
        options.vitals = .legacy
        return addLegacy(.vitals, span: WidgetSpan(columns: 4, rows: 2), options: options, style: .bare, corner: .bottomTrailing)
    }

    private func addLegacy(_ kind: WidgetKind, span: WidgetSpan, options: WidgetOptions, style: WidgetStyle, corner: Alignment) -> String? {
        guard let screen = NSScreen.screens.first else { return nil }
        let key = Self.key(for: screen)
        let size = screen.visibleFrame.size
        let grid = Self.cells(in: size)
        let fitted = WidgetSpan(columns: min(span.columns, grid.columns), rows: min(span.rows, grid.rows))
        let column = corner == .bottomLeading ? 0 : max(grid.columns - fitted.columns, 0)
        let row = max(grid.rows - fitted.rows, 0)
        let place = slot(span: fitted.tuple, excluding: nil, column: column, row: row, screen: key, fallback: true, size: size)
        var placement = WidgetPlacement(kind: kind, column: place.column, row: place.row, screen: key, style: style, options: options)
        placement.custom = fitted
        if !enabled { enabled = true }
        placements.append(placement)
        return placement.uid
    }

    /// Once per Mac: a Desktop Clock or Desktop Vitals left on in Effects becomes a widget in the same spot and style,
    /// and the effect is turned off, so the two never draw at once. Call after `start()`.
    /// Once: a clock or vitals widget made while their defaults were the new faces goes back to
    /// the old Desktop Clock and Desktop Vitals look, which the owner preferred.
    func restoreClassicDesktopLooks() {
        let store = UserDefaults.standard
        guard !store.bool(forKey: "boardClassicLooks") else { return }
        store.set(true, forKey: "boardClassicLooks")
        for placement in placements {
            switch placement.kind {
            case .bigClock where placement.options.clock?.face == .thin:
                update(placement.uid) { $0.options.clock?.face = .desktop }
            case .vitals where placement.options.vitals?.display != .classic:
                update(placement.uid) {
                    $0.options.vitals?.display = .classic
                    $0.options.vitals?.metrics = [.memory, .disk, .battery]
                }
            default: break
            }
        }
    }

    func adoptDesktopEffects(from effects: Effects) {
        let store = UserDefaults.standard
        guard !store.bool(forKey: Self.adoptedEffectsKey) else { return }
        store.set(true, forKey: Self.adoptedEffectsKey)
        guard effects.clock || effects.widgets else { return }
        // The old clock and rings showed without the board. If the board was off, its widgets
        // were hidden on purpose: keep them as a layout and start the board with only these.
        if !enabled {
            if !placements.isEmpty {
                saveLayout(named: "Before Desktop Clock")
                placements.map(\.uid).forEach { remove($0) }
            }
            enabled = true
        }
        if effects.clock {
            if !desktopClock { addDesktopClock(style: effects.clockStyle) }
            effects.clock = false
        }
        if effects.widgets {
            if !desktopVitals { addDesktopVitals() }
            effects.widgets = false
        }
    }
}
