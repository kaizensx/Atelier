import AppKit
import SwiftUI

// The stage is not only a picture: what is on it can be picked up and changed, and the change is real.
// Every handle here writes through the same public API the panels use, so Before and After, the
// change card and the real desktop all follow.
//
// Gestures run in the canvas's coordinate space ("dock"): stage points before the camera's scale, so a
// drag reads the same at every zoom. Each handle keeps its drag in its own state, so a moving pointer
// redraws a handle, never the whole replica.

// MARK: - Widgets

/// Drag a widget to move it on the real desktop, click it to open its inspector.
struct StageWidgetHandles: View {
    let places: [WidgetPlacement]
    /// The display's visible frame, in canvas points.
    let area: CGRect
    /// Screen points to canvas points.
    let scale: Double
    @Binding var lifted: String?
    let open: (WidgetPlacement) -> Void

    var body: some View {
        let screen = NSScreen.screens.first?.visibleFrame.size ?? CGSize(width: 1728, height: 1080)
        ZStack(alignment: .topLeading) {
            ForEach(places) { place in
                StageWidgetHandle(place: place, area: area, scale: scale, screen: screen, lifted: $lifted) { open(place) }
            }
        }
    }
}

private struct StageWidgetHandle: View {
    let place: WidgetPlacement
    let area: CGRect
    let scale: Double
    let screen: CGSize
    @Binding var lifted: String?
    let open: () -> Void
    @State private var hovering = false
    /// The drag so far, or where the copy flies to land.
    @State private var drag: CGSize?

    private func frame(column: Int, row: Int) -> CGRect {
        let origin = WidgetBoard.origin(column: column, row: row), size = WidgetBoard.tileSize(place)
        return CGRect(x: area.minX + origin.x * scale, y: area.minY + origin.y * scale,
                      width: size.width * scale, height: size.height * scale)
    }

    /// The free cell nearest to where the widget is being dragged, as the board itself would choose.
    private func target(_ moved: CGSize) -> (column: Int, row: Int) {
        let column = place.column + Int((moved.width / scale / WidgetBoard.pitch).rounded())
        let row = place.row + Int((moved.height / scale / WidgetBoard.pitch).rounded())
        return WidgetBoard.shared.slot(span: place.span, excluding: place.uid, column: column, row: row,
                                       screen: place.screen, fallback: true, size: screen)
    }

    var body: some View {
        let home = frame(column: place.column, row: place.row)
        let radius = min(WidgetFace.radius * scale, min(home.width, home.height) * 0.3)
        let moved = drag ?? .zero
        ZStack(alignment: .topLeading) {
            if let drag {
                let slot = target(drag)
                let landing = frame(column: slot.column, row: slot.row)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DS.Ink.accent.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(DS.Ink.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    }
                    .frame(width: home.width, height: home.height)
                    .offset(x: landing.minX - home.minX, y: landing.minY - home.minY)
                    .animation(DS.Motion.touch, value: slot.column)
                    .animation(DS.Motion.touch, value: slot.row)
                LiftedWidget(place: place, scale: scale).equatable()
                    .scaleEffect(1.03)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                    .offset(moved)
            }
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(hovering && drag == nil ? 0.05 : 0.001))
                .overlay {
                    if hovering || drag != nil {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hovering && drag == nil { tag.offset(y: -30).transition(.opacity) }
                }
                .frame(width: home.width, height: home.height)
                .offset(moved)
                .contentShape(.rect(cornerRadius: radius))
                .onHover { over in withAnimation(DS.Motion.touch) { hovering = over } }
                .atelierPointer(place.locked ? .default : drag == nil ? .grabIdle : .grabActive)
                .onTapGesture(perform: open)
                .gesture(move, including: place.locked ? .subviews : .all)
                .accessibilityElement()
                .accessibilityLabel(place.kind.title)
                .accessibilityHint("Drag to move it on the desktop. Click to edit it.")
                .accessibilityAddTraits(.isButton)
        }
        .frame(width: home.width, height: home.height, alignment: .topLeading)
        .offset(x: home.minX, y: home.minY)
    }

    private var tag: some View {
        HStack(spacing: 5) {
            Text(place.kind.title).font(.system(size: 11, weight: .semibold))
            Text(place.locked ? "Locked · click to edit" : "Drag to move · click to edit")
                .font(.system(size: 11)).foregroundStyle(DS.Ink.secondary)
        }
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 10).frame(height: 24)
        .atelierGlass(.regular.tint(.black.opacity(0.25)), in: .capsule)
        .allowsHitTesting(false)
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("dock"))
            .onChanged { value in
                if drag == nil { lifted = place.uid }
                drag = value.translation
            }
            .onEnded { value in
                let slot = target(value.translation)
                let home = frame(column: place.column, row: place.row)
                let landing = frame(column: slot.column, row: slot.row)
                let uid = place.uid
                withAnimation(DS.Motion.arrive, completionCriteria: .logicallyComplete) {
                    drag = CGSize(width: landing.minX - home.minX, height: landing.minY - home.minY)
                } completion: {
                    // The real widget takes the copy's place in the same frame, so nothing jumps.
                    var quiet = Transaction()
                    quiet.disablesAnimations = true
                    withTransaction(quiet) {
                        WidgetBoard.shared.update(uid) {
                            $0.column = slot.column
                            $0.row = slot.row
                        }
                        drag = nil
                        if lifted == uid { lifted = nil }
                    }
                }
            }
    }
}

/// A still copy of a widget for the pointer to carry. Equatable, so a drag frame does not rebuild its face.
private struct LiftedWidget: View, Equatable {
    let place: WidgetPlacement
    let scale: Double

    nonisolated static func == (a: LiftedWidget, b: LiftedWidget) -> Bool { a.place == b.place && a.scale == b.scale }

    var body: some View {
        let size = WidgetBoard.tileSize(place)
        WidgetFace(kind: place.kind, board: WidgetBoard.shared, size: size, placement: place)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

// MARK: - Atelier Dock

/// The Atelier Dock's tiles on the stage: click one to open its inspector, drag along the bar to
/// reorder, drag away from the edge to move the whole dock to another edge.
struct StageOwnDockHandles: View {
    let dock: OwnDock
    let edge: OwnDockEdge
    /// Where the miniature's frame sits on the canvas.
    let area: CGRect
    let scale: Double
    let canvas: CGSize
    let open: (String) -> Void
    @State private var scene = DockScene()
    @State private var hovered: String?
    @State private var dragID: String?
    @State private var translation = CGSize.zero
    @State private var pointer = CGPoint.zero
    /// The drag left the bar: it moves the dock, not a tile.
    @State private var moving = false

    private var horizontal: Bool { edge.horizontal }
    private func along(_ point: CGPoint) -> Double { horizontal ? point.x : point.y }
    private func along(_ size: CGSize) -> Double { horizontal ? size.width : size.height }
    private func across(_ size: CGSize) -> Double { horizontal ? size.height : size.width }

    var body: some View {
        let movable = Set(dock.items.map(\.id))
        ZStack(alignment: .topLeading) {
            if moving {
                StageEdgeTargets(canvas: canvas, edges: OwnDockEdge.allCases.map(\.rawValue),
                                 hot: StageEdgeTargets.nearest(pointer, canvas: canvas, edges: OwnDockEdge.allCases.map(\.rawValue)))
            }
            ForEach(scene.tiles) { tile in
                if tile.slot.kind != .divider, tile.slot.kind != .section {
                    handle(tile, movable: movable.contains(tile.id))
                }
            }
            if let dragID, !moving, let tile = scene.tiles.first(where: { $0.id == dragID }) {
                caret(for: tile)
                ghost(tile)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .onAppear(perform: layout)
        .onChange(of: edge) { layout() }
        .onChange(of: area) { layout() }
        // OwnDock announces a change before it lands; lay out on the next turn, with the new values.
        .onReceive(dock.objectWillChange) { _ in DispatchQueue.main.async { layout() } }
    }

    /// The same layout engine and inputs the miniature uses, so every handle sits on its tile.
    private func layout() {
        var field = DockField()
        field.motion = false
        var metrics = DockMetrics(edge: edge, tile: dock.tile * scale, large: dock.large * scale, magnify: dock.magnify, panel: area.size)
        metrics.apply(dock.appearance, scale: scale)
        field.sync(dock.slots(), instant: true)
        scene = field.scene(metrics)
    }

    private func centre(_ tile: DockTile) -> CGPoint {
        CGPoint(x: area.minX + tile.center.x, y: area.minY + tile.center.y)
    }

    @ViewBuilder private func handle(_ tile: DockTile, movable: Bool) -> some View {
        let side = max(tile.icon, scene.tile * 0.8)
        let point = centre(tile)
        let lit = hovered == tile.id && dragID == nil
        RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
            .fill(Color.white.opacity(lit ? 0.12 : 0.001))
            .overlay {
                if lit {
                    RoundedRectangle(cornerRadius: side * 0.26, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 1)
                }
            }
            .frame(width: side, height: side)
            .opacity(dragID == tile.id && !moving ? 0.3 : 1)
            .contentShape(.rect(cornerRadius: side * 0.26))
            .onHover { over in
                withAnimation(DS.Motion.touch) { hovered = over ? tile.id : (hovered == tile.id ? nil : hovered) }
            }
            .atelierPointer(dragID == nil ? .grabIdle : .grabActive)
            .onTapGesture { open(tile.id) }
            .gesture(drag(tile, movable: movable))
            .offset(x: point.x - side / 2, y: point.y - side / 2)
            .accessibilityElement()
            .accessibilityLabel(tile.slot.title.isEmpty ? "Dock tile" : tile.slot.title)
            .accessibilityHint(movable ? "Click to edit. Drag along the dock to move it." : "Click to edit.")
            .accessibilityAddTraits(.isButton)
    }

    private func drag(_ tile: DockTile, movable: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("dock"))
            .onChanged { value in
                if dragID == nil { dragID = tile.id }
                translation = value.translation
                pointer = value.location
                // Pulling away from the edge picks up the whole dock. Sticky, so it does not flicker back.
                if !moving, abs(across(value.translation)) > max(scene.tile * 0.9, abs(along(value.translation)) * 1.2) {
                    withAnimation(DS.Motion.touch) { moving = true }
                }
            }
            .onEnded { value in
                if moving {
                    let names = OwnDockEdge.allCases.map(\.rawValue)
                    if let next = OwnDockEdge(rawValue: StageEdgeTargets.nearest(value.location, canvas: canvas, edges: names)), next != edge {
                        withAnimation(DS.Motion.camera) { place(next) }
                    }
                } else if movable, let item = dock.items.first(where: { $0.id == tile.id }) {
                    let before = insertion(for: tile)?.before
                    let section = before.flatMap { id in dock.items.first { $0.id == id } }?.section ?? item.section
                    withAnimation(DS.Motion.arrive) { dock.move(tile.id, before: before, section: section) }
                }
                withAnimation(DS.Motion.arrive) {
                    dragID = nil
                    moving = false
                    translation = .zero
                }
            }
    }

    /// The edge for the display the stage shows: its own edge when it has one, else the dock's.
    private func place(_ next: OwnDockEdge) {
        if let name = NSScreen.screens.first?.localizedName, dock.edgeOverrides[name] != nil {
            dock.edgeOverrides[name] = next
        } else {
            dock.edge = next
        }
    }

    /// Where a dragged tile would land: before which item, and the point between the two neighbours.
    private func insertion(for tile: DockTile) -> (before: String?, at: Double)? {
        let ids = Set(dock.items.map(\.id))
        let order = scene.tiles.filter { ids.contains($0.id) && $0.id != tile.id }
        guard !order.isEmpty else { return nil }
        let position = along(tile.center) + along(translation)
        if let index = order.firstIndex(where: { along($0.center) > position }) {
            let next = order[index]
            let previous = index > 0 ? along(order[index - 1].center) : along(next.center) - scene.unit
            return (next.id, (previous + along(next.center)) / 2)
        }
        return (nil, along(order[order.count - 1].center) + scene.unit / 2)
    }

    @ViewBuilder private func caret(for tile: DockTile) -> some View {
        if let spot = insertion(for: tile) {
            let base = centre(tile)
            let length = scene.tile * 0.9
            Capsule().fill(DS.Ink.accent)
                .frame(width: horizontal ? 3 : length, height: horizontal ? length : 3)
                .shadow(color: DS.Ink.accent.opacity(0.8), radius: 6)
                .offset(x: horizontal ? area.minX + spot.at - 1.5 : base.x - length / 2,
                        y: horizontal ? base.y - length / 2 : area.minY + spot.at - 1.5)
                .animation(DS.Motion.touch, value: spot.at)
                .allowsHitTesting(false)
        }
    }

    private func ghost(_ tile: DockTile) -> some View {
        let side = max(tile.icon, scene.tile * 0.8)
        let point = centre(tile)
        let shift = horizontal ? CGSize(width: translation.width, height: 0) : CGSize(width: 0, height: translation.height)
        return Group {
            if !tile.slot.path.isEmpty {
                Image(nsImage: DockIcons.image(tile.slot.path)).resizable().interpolation(.high)
            } else {
                Image(systemName: "square.grid.2x2.fill").resizable().scaledToFit().padding(side * 0.2).foregroundStyle(.white)
                    .background(.white.opacity(0.15), in: .rect(cornerRadius: side * 0.24))
            }
        }
        .frame(width: side, height: side)
        .scaleEffect(1.12)
        .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
        .offset(x: point.x - side / 2 + shift.width, y: point.y - side / 2 + shift.height - (horizontal ? side * 0.2 : 0))
        .allowsHitTesting(false)
    }
}

// MARK: - macOS Dock

/// Drags the replica of the macOS Dock to another edge, and opens the Dock chapter on a click.
struct StageDockMover<Content: View>: View {
    let canvas: CGSize
    let alignment: Alignment
    let edges: [String]
    let enabled: Bool
    let tap: () -> Void
    let move: (String) -> Void
    @ViewBuilder var content: Content
    @State private var pointer: CGPoint?
    @State private var offset = CGSize.zero

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear.allowsHitTesting(false)
            if let pointer {
                StageEdgeTargets(canvas: canvas, edges: edges, hot: StageEdgeTargets.nearest(pointer, canvas: canvas, edges: edges))
            }
            content
                .contentShape(.rect)
                .offset(offset)
                .atelierPointer(enabled ? (pointer == nil ? .grabIdle : .grabActive) : .default)
                .onTapGesture { if enabled { tap() } }
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("dock"))
                    .onChanged { value in
                        if pointer == nil { withAnimation(DS.Motion.touch) { pointer = value.location } } else { pointer = value.location }
                        // It follows the pointer on a short leash: it is going to an edge, not anywhere.
                        offset = CGSize(width: value.translation.width * 0.35, height: value.translation.height * 0.35)
                    }
                    .onEnded { value in
                        let next = StageEdgeTargets.nearest(value.location, canvas: canvas, edges: edges)
                        withAnimation(DS.Motion.arrive) {
                            pointer = nil
                            offset = .zero
                        }
                        move(next)
                    }, including: enabled ? .all : .subviews)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

/// The edges a dock can go to, lit while one is carried. The nearest one glows.
struct StageEdgeTargets: View {
    let canvas: CGSize
    let edges: [String]
    let hot: String

    static func nearest(_ point: CGPoint, canvas: CGSize, edges: [String]) -> String {
        let distances: [String: Double] = [
            "left": point.x, "right": canvas.width - point.x,
            "top": point.y - canvas.height * 0.04, "bottom": canvas.height - point.y,
        ]
        return edges.min { (distances[$0] ?? .infinity) < (distances[$1] ?? .infinity) } ?? edges.first ?? "bottom"
    }

    var body: some View {
        ZStack {
            ForEach(edges, id: \.self) { edge in
                let lit = edge == hot
                RoundedRectangle(cornerRadius: canvas.width * 0.01, style: .continuous)
                    .fill(DS.Ink.accent.opacity(lit ? 0.32 : 0.1))
                    .overlay {
                        RoundedRectangle(cornerRadius: canvas.width * 0.01, style: .continuous)
                            .strokeBorder(DS.Ink.accent.opacity(lit ? 0.95 : 0.35), lineWidth: lit ? 1.5 : 1)
                    }
                    .frame(width: edge == "left" || edge == "right" ? canvas.width * 0.05 : canvas.width * 0.56,
                           height: edge == "left" || edge == "right" ? canvas.height * 0.56 : canvas.height * 0.07)
                    .padding(.top, edge == "top" ? canvas.height * 0.05 : 0)
                    .padding(canvas.width * 0.008)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.alignment(edge))
                    .animation(DS.Motion.touch, value: lit)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    static func alignment(_ edge: String) -> Alignment {
        switch edge {
        case "left": .leading
        case "right": .trailing
        case "top": .top
        default: .bottom
        }
    }
}
