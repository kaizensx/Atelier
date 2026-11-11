import Combine
import DockCore
import SwiftUI

/// What Atelier is doing to the Mac right now, by place: light means on.
///
/// Each feature that bends macOS is listed once, with its family's hue and the place that holds
/// its controls. The sidebar lights a place's dot while any of its features is on; Home counts them.
/// Moving a feature to another place is one `chapter` edit here.
@MainActor
enum NavLit {
    struct Feature: Identifiable {
        let id: String
        let title: String
        let hue: Color
        let chapter: Chapter
        let isOn: @MainActor () -> Bool
    }

    static let input = Chapter(PersonalArea.input.rawValue)
    static let sounds = Chapter(PersonalArea.sounds.rawValue)
    static let everyApp = Chapter("appKit")

    /// Only the features a stock Mac cannot do. Reading these is a handful of stored Bools.
    static let features: [Feature] = [
        Feature(id: "xdr", title: "XDR Boost", hue: DS.Spectrum.light, chapter: .appearance) { LightEngine.shared.boostOn },
        Feature(id: "belowBlack", title: "Below Black", hue: DS.Spectrum.light, chapter: .appearance) { LightEngine.shared.dimOn },
        Feature(id: "candle", title: "Candlelight", hue: DS.Spectrum.light, chapter: .appearance) { LightEngine.shared.candleOn },
        Feature(id: "corners", title: "Rounded Corners", hue: DS.Spectrum.light, chapter: .appearance) { ScreenCorners.shared.enabled },
        Feature(id: "hud", title: "Atelier HUD", hue: DS.Spectrum.surfaces, chapter: .appearance) {
            let hud = AtelierHUD.shared
            return hud.volume || hud.brightness || hud.keyboard
        },
        Feature(id: "borders", title: "Window Borders", hue: DS.Spectrum.windows, chapter: .engine) { WindowBorders.shared.enabled },
        Feature(id: "dim", title: "Dim Inactive", hue: DS.Spectrum.windows, chapter: .engine) { InactiveDim.shared.enabled },
        Feature(id: "grab", title: "Move Anywhere", hue: DS.Spectrum.windows, chapter: .engine) { WindowGrab.shared.enabled },
        Feature(id: "ffm", title: "Focus Follows Mouse", hue: DS.Spectrum.windows, chapter: .engine) { FocusFollowsMouse.shared.enabled },
        Feature(id: "switcher", title: "Window Switcher", hue: DS.Spectrum.windows, chapter: .engine) { WindowSwitcher.shared.enabled },
        Feature(id: "thermals", title: "Thermals", hue: DS.Spectrum.sensors, chapter: .menubar) { ThermalsMenu.shared.enabled },
        Feature(id: "calendar", title: "Menu Calendar", hue: DS.Spectrum.surfaces, chapter: .menubar) { MenuCalendar.shared.enabled },
        Feature(id: "spaces", title: "Instant Spaces", hue: DS.Spectrum.surfaces, chapter: .menubar) {
            InstantSpaces.shared.instant || InstantSpaces.shared.hotkeys || SpacesIndicator.shared.enabled
        },
        Feature(id: "gestures", title: "Trackpad Gestures", hue: DS.Spectrum.input, chapter: input) { TrackpadGestures.shared.enabled },
        Feature(id: "haptics", title: "Haptics", hue: DS.Spectrum.sound, chapter: input) { Haptics.shared.enabled },
        Feature(id: "mouse", title: "Mouse Precision", hue: DS.Spectrum.input, chapter: input) { MousePrecision.shared.enabled },
        Feature(id: "wheel", title: "Wheel Direction", hue: DS.Spectrum.input, chapter: input) {
            let wheel = WheelDirection.shared
            return wheel.reverse || wheel.smooth
        },
        Feature(id: "hyper", title: "Hyper Key", hue: DS.Spectrum.input, chapter: input) { HyperKey.shared.enabled },
        Feature(id: "typing", title: "Typing Sounds", hue: DS.Spectrum.sound, chapter: sounds) { TypingSounds.shared.enabled },
        Feature(id: "quitGuard", title: "Hold ⌘Q", hue: DS.Spectrum.surfaces, chapter: everyApp) { QuitGuard.shared.enabled },
    ]

    /// Whether anything in this place is on now. Reads the last snapshot: no singleton is touched here.
    static func isLit(_ chapter: Chapter) -> Bool { NavLitState.shared.chapters.contains(chapter.rawValue) }

    /// Whether this feature is on now, from the last snapshot.
    static func isOn(_ id: String) -> Bool { NavLitState.shared.lit.contains(id) }
}

/// The snapshot views watch. Polled once a second and published only when something changed, so
/// a view that reads it redraws when a feature turns on or off and never otherwise. Polling beats
/// subscribing here: several of these objects publish counters many times a second.
@MainActor
final class NavLitState: ObservableObject {
    static let shared = NavLitState()

    /// Ids of the features that are on, in `NavLit.features` order.
    @Published private(set) var lit: [String] = []
    @Published private(set) var chapters: Set<String> = []
    private var timer: AnyCancellable?

    private init() {
        refresh()
        timer = Timer.publish(every: 1, tolerance: 0.3, on: .main, in: .common).autoconnect()
            .sink { _ in MainActor.assumeIsolated { NavLitState.shared.refresh() } }
    }

    /// Reads every feature now. Call after a change to show it without waiting for the tick.
    func refresh() {
        let on = NavLit.features.filter { $0.isOn() }
        let ids = on.map(\.id)
        guard ids != lit else { return }
        lit = ids
        chapters = Set(on.map(\.chapter.rawValue))
    }

    var litFeatures: [NavLit.Feature] {
        let set = Set(lit)
        return NavLit.features.filter { set.contains($0.id) }
    }
}
