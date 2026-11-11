import Combine
import SwiftUI

// The Dock chapter's camera leans into the bottom of the stage, where a dock usually is. A dock
// on the left, right or top edge sits where that zoom pushes the stage past the viewport, under
// the sidebar or the chapter panel. With a dock on any of those edges the camera stays at rest
// instead, so the whole screen, and the dock on it, is in view.

@MainActor
final class StageDockSide: ObservableObject {
    static let shared = StageDockSide()

    /// The dock the stage shows is on the left, right or top edge.
    @Published private(set) var side = false

    /// The macOS Dock's edge as the Studio last read it. The Atelier Dock's comes from `OwnDock`.
    var systemEdge = "bottom" {
        didSet { if systemEdge != oldValue { update() } }
    }

    private var watch: AnyCancellable?

    private init() {
        // OwnDock publishes on settings changes only, never per frame.
        watch = OwnDock.shared.objectWillChange.sink { _ in
            DispatchQueue.main.async { StageDockSide.shared.update() }
        }
        side = Self.isSide(ownOn: OwnDock.shared.enabled, ownEdge: OwnDock.shared.edge, systemEdge: systemEdge)
    }

    private func update() {
        let next = Self.isSide(ownOn: OwnDock.shared.enabled, ownEdge: OwnDock.shared.edge, systemEdge: systemEdge)
        guard next != side else { return }
        withAnimation(DS.Motion.camera) { side = next }
    }

    nonisolated static func isSide(ownOn: Bool, ownEdge: OwnDockEdge, systemEdge: String) -> Bool {
        ownOn ? ownEdge != .bottom : systemEdge != "bottom"
    }
}
