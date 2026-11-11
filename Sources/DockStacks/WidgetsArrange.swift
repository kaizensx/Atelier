import AppKit
import SwiftUI

// MARK: - Arrange bar

/// The small bar shown while arranging. It finds a spot no widget covers, can be dragged anywhere,
/// and folds its hint away after a few seconds, leaving only Add and Done.
struct ArrangeBar: View {
    @ObservedObject var board: WidgetBoard
    /// Every widget's tile on this canvas, to keep clear of.
    let tiles: [CGRect]
    let canvas: CGSize
    @State private var expanded = true
    @State private var hovering = false
    /// Where the owner dragged the bar, from its chosen spot.
    @State private var moved = CGSize.zero
    @State private var dragging = CGSize.zero
    @State private var pinned = false
    @State private var spot: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 380, height: 38)

    /// The first spot, from a short list of good ones and then a scan, where the bar covers no widget.
    static func freeSpot(avoiding tiles: [CGRect], in canvas: CGSize, size: CGSize = ArrangeBar.size) -> CGPoint {
        let margin = 12.0
        let maxX = max(canvas.width - size.width - margin, margin), maxY = max(canvas.height - size.height - margin, margin)
        let centre = (canvas.width - size.width) / 2
        var candidates = [CGPoint(x: centre, y: margin), CGPoint(x: centre, y: maxY),
                          CGPoint(x: margin, y: margin), CGPoint(x: maxX, y: margin),
                          CGPoint(x: margin, y: maxY), CGPoint(x: maxX, y: maxY)]
        for y in stride(from: margin, through: maxY, by: 26) {
            candidates.append(CGPoint(x: centre, y: y))
            for x in stride(from: margin, through: maxX, by: 52) { candidates.append(CGPoint(x: x, y: y)) }
        }
        let padded = tiles.map { $0.insetBy(dx: -10, dy: -10) }
        for point in candidates {
            let rect = CGRect(origin: point, size: size)
            if !padded.contains(where: { $0.intersects(rect) }) { return point }
        }
        // A full screen: the spot that covers the least.
        return candidates.min { a, b in
            func covered(_ p: CGPoint) -> Double {
                let rect = CGRect(origin: p, size: size)
                return padded.reduce(0) { total, tile in
                    let overlap = tile.intersection(rect)
                    return total + (overlap.isNull ? 0 : overlap.width * overlap.height)
                }
            }
            return covered(a) < covered(b)
        } ?? CGPoint(x: centre, y: margin)
    }

    private func clamped(_ offset: CGSize, from origin: CGPoint) -> CGSize {
        CGSize(width: min(max(offset.width, -origin.x + 4), canvas.width - Self.size.width - origin.x - 4),
               height: min(max(offset.height, -origin.y + 4), canvas.height - Self.size.height - origin.y - 4))
    }

    var body: some View {
        let base = spot ?? Self.freeSpot(avoiding: tiles, in: canvas)
        let open = expanded || hovering
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
                .frame(width: 18, height: 26)
                .contentShape(Rectangle())
                .atelierPointer(.grabIdle)
                .accessibilityHidden(true)
            if open {
                Text("Drag widgets anywhere. Drag a corner to resize.")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            }
            AddWidgetMenu(board: board)
            Button { board.editing = false } label: {
                Text("Done").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 13).frame(height: 26)
                    .background(.white, in: .capsule)
                    .contentShape(Capsule())
            }
            .buttonStyle(Pressable(scale: 0.95))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Ends arranging. Esc does the same.")
        }
        .padding(.leading, 8).padding(.trailing, 6).frame(height: Self.size.height)
        .atelierGlass(.regular, in: .capsule)
        .fixedSize()
        .contentShape(Capsule())
        .onHover { inside in withAnimation(reduceMotion ? nil : DS.Motion.settle) { hovering = inside } }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { dragging = $0.translation }
                .onEnded { gesture in
                    pinned = true
                    moved = clamped(CGSize(width: moved.width + gesture.translation.width, height: moved.height + gesture.translation.height), from: base)
                    dragging = .zero
                }
        )
        .animation(reduceMotion ? nil : DS.Motion.settle, value: open)
        .frame(width: Self.size.width, height: Self.size.height)
        .offset(x: base.x + moved.width + dragging.width, y: base.y + moved.height + dragging.height)
        .animation(reduceMotion || dragging != .zero ? nil : DS.Motion.arrive, value: base)
        .onAppear { spot = Self.freeSpot(avoiding: tiles, in: canvas) }
        // A widget dropped where the bar sits sends it somewhere free, unless the owner put it there.
        .onChange(of: tiles) { _, new in
            guard !pinned else { return }
            let next = Self.freeSpot(avoiding: new, in: canvas)
            if next != spot { spot = next }
        }
        .task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(reduceMotion ? nil : DS.Motion.arrive) { expanded = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arranging widgets")
    }
}

/// Every kind, by category, one click to add while arranging.
struct AddWidgetMenu: View {
    @ObservedObject var board: WidgetBoard

    var body: some View {
        Menu {
            ForEach(WidgetCategory.allCases) { category in
                Section(category.title) {
                    ForEach(WidgetKind.allCases.filter { $0.category == category }) { kind in
                        Button { add(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                            .disabled(!kind.allowsMultiple && board.isOn(kind))
                    }
                }
            }
            Divider()
            Button { add(.stack) } label: { Label(WidgetKind.stack.title, systemImage: WidgetKind.stack.symbol) }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.Ink.primary)
                .frame(width: 26, height: 26)
                .background(DS.Ink.fillStrong, in: .circle)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Add a widget")
    }

    private func add(_ kind: WidgetKind) {
        withAnimation(DS.Motion.arrive) { _ = board.add(kind) }
    }
}

// MARK: - Tile chrome

/// The controls every widget shows while arranging, iOS style: remove at the top left, a menu of sizes and looks
/// at the top right, and a corner to drag to resize.
struct TileChrome: View {
    @ObservedObject var board: WidgetBoard
    let placement: WidgetPlacement
    let canvas: CGSize
    let radius: Double
    let lifted: Bool
    @State private var resizing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: WidgetKind { placement.kind }
    private var session: WidgetSession { board.session }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                badge.offset(x: -9, y: -9)
            }
            .overlay(alignment: .topTrailing) {
                if !placement.locked { TileMenu(board: board, placement: placement).offset(x: 9, y: -9) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !placement.locked && (kind.freeSpan || kind.sizes.count > 1) { handle }
            }
            .opacity(lifted ? 0 : 1)
            .animation(DS.Motion.touch, value: lifted)
    }

    @ViewBuilder private var badge: some View {
        if placement.locked {
            ChromeButton(symbol: "lock.fill", label: "Unlock \(kind.title)") {
                withAnimation(DS.Motion.settle) { board.update(placement.uid) { $0.locked = false } }
            }
        } else {
            ChromeButton(symbol: "minus", label: "Remove \(kind.title)", weight: .heavy) {
                withAnimation(reduceMotion ? nil : DS.Motion.arrive) { board.remove(placement.uid) }
            }
        }
    }

    /// The corner: drag for any span on kinds that take one, a click to step through the sizes on the rest.
    private var handle: some View {
        CornerArc(radius: min(radius, 22))
            .stroke(.white.opacity(resizing ? 1 : 0.85), style: StrokeStyle(lineWidth: resizing ? 4.5 : 3.5, lineCap: .round))
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .frame(width: 26, height: 26)
            .padding(6)
            .contentShape(Rectangle())
            .offset(x: 9, y: 9)
            .atelierPointer(.frameResize(position: .bottomTrailing))
            .gesture(kind.freeSpan ? resizeGesture : nil)
            .simultaneousGesture(TapGesture().onEnded {
                guard !kind.freeSpan else { return }
                withAnimation(reduceMotion ? nil : DS.Motion.arrive) { board.cycleSize(placement.uid) }
            })
            .help(kind.freeSpan ? "Drag to resize" : "Click for the next size")
            .accessibilityLabel(kind.freeSpan ? "Resize \(kind.title)" : "Change size of \(kind.title)")
            .accessibilityAction(named: "Larger") { step(1) }
            .accessibilityAction(named: "Smaller") { step(-1) }
            .overlay(alignment: .bottomTrailing) {
                if resizing, let ghost = session.ghost, ghost.uid == placement.uid {
                    Text(WidgetSpan(columns: ghost.span.columns, rows: ghost.span.rows).title)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 8).frame(height: 22)
                        .atelierGlass(.regular, in: .capsule)
                        .fixedSize()
                        .offset(x: 30, y: 32)
                        .allowsHitTesting(false)
                }
            }
    }

    private func span(for translation: CGSize) -> WidgetSpan {
        let now = placement.span
        let wanted = WidgetSpan(columns: now.columns + Int((translation.width / WidgetBoard.pitch).rounded()),
                                rows: now.rows + Int((translation.height / WidgetBoard.pitch).rounded()))
        var span = board.clampedSpan(wanted, for: placement)
        // Never past the screen's right or bottom edge from where the widget sits.
        let grid = WidgetBoard.cells(in: canvas)
        span.columns = max(min(span.columns, grid.columns - placement.column), kind.minimumSpan.columns)
        span.rows = max(min(span.rows, grid.rows - placement.row), kind.minimumSpan.rows)
        return span
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { gesture in
                if !resizing { withAnimation(DS.Motion.touch) { resizing = true } }
                let next = span(for: gesture.translation)
                // A new span is news, a pixel is not: the ghost changes a few times per drag.
                guard session.ghost?.uid != placement.uid || session.ghost?.custom != next else { return }
                var ghost = placement
                ghost.custom = next
                session.ghost = ghost
                session.guides = board.guides(for: ghost, fallback: true)
            }
            .onEnded { gesture in
                let next = span(for: gesture.translation)
                session.ghost = nil
                session.guides = AlignmentGuides()
                session.selection = placement.uid
                withAnimation(reduceMotion ? nil : DS.Motion.arrive) {
                    board.resize(placement.uid, span: next)
                    resizing = false
                }
            }
    }

    private func step(_ direction: Int) {
        if kind.freeSpan {
            let now = placement.span
            board.resize(placement.uid, span: WidgetSpan(columns: now.columns + direction, rows: now.rows + direction))
        } else {
            board.cycleSize(placement.uid)
        }
    }
}

/// A quarter circle that hugs a tile's bottom-right corner, like the resize handle on an iPhone widget.
struct CornerArc: Shape {
    let radius: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        return path
    }
}

private struct ChromeButton: View {
    let symbol: String
    let label: String
    var weight = Font.Weight.bold
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: weight)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(white: 0.2).opacity(0.85), in: .circle)
                .atelierGlass(.regular, in: .circle)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(Pressable(scale: 0.86))
        .accessibilityLabel(label)
    }
}

/// Sizes, spans, looks and the rest, for one widget, without leaving the desktop.
private struct TileMenu: View {
    @ObservedObject var board: WidgetBoard
    let placement: WidgetPlacement

    private var kind: WidgetKind { placement.kind }

    /// Spans worth one click on kinds that take any span.
    private static let spans: [(String, WidgetSpan)] = [
        ("Strip", WidgetSpan(columns: 4, rows: 1)), ("Wide", WidgetSpan(columns: 6, rows: 2)),
        ("Banner", WidgetSpan(columns: 8, rows: 2)), ("Big", WidgetSpan(columns: 6, rows: 3)),
        ("Huge", WidgetSpan(columns: 8, rows: 4)),
    ]

    private func setMaterial(_ material: WidgetMaterial) {
        withAnimation(DS.Motion.arrive) {
            board.update(placement.uid) {
                var style = $0.style ?? board.style
                style.material = material
                $0.style = style
            }
        }
    }

    var body: some View {
        Menu {
            if kind.sizes.count > 1 || kind.freeSpan {
                Section("Size") {
                    ForEach(kind.sizes) { size in
                        Toggle(size.title, isOn: Binding(get: { placement.custom == nil && placement.size == size },
                                                         set: { _ in withAnimation(DS.Motion.arrive) { board.resize(placement.uid, to: size) } }))
                    }
                    if kind.freeSpan {
                        ForEach(Self.spans, id: \.0) { name, span in
                            Toggle("\(name), \(span.title)", isOn: Binding(get: { placement.custom == span },
                                                                           set: { _ in withAnimation(DS.Motion.arrive) { board.resize(placement.uid, span: span) } }))
                        }
                    }
                }
            }
            if !kind.edgeToEdge {
                Section("Background") {
                    ForEach(WidgetMaterial.allCases) { material in
                        Toggle(material.title, isOn: Binding(get: { board.style(for: placement).material == material },
                                                             set: { _ in setMaterial(material) }))
                    }
                    if placement.style != nil {
                        Button("Follow Board Style") { withAnimation(DS.Motion.arrive) { board.update(placement.uid) { $0.style = nil } } }
                    }
                }
            }
            Section {
                Toggle("Keep Above Windows", isOn: Binding(get: { placement.layer == .floating },
                                                          set: { on in board.update(placement.uid) { $0.layer = on ? .floating : .desktop } }))
                Button("Lock Position") { withAnimation(DS.Motion.settle) { board.update(placement.uid) { $0.locked = true } } }
                if kind.allowsMultiple {
                    Button("Duplicate") {
                        withAnimation(DS.Motion.arrive) { if let copy = board.duplicate(placement.uid) { board.selection = copy } }
                    }
                }
                if board.screenCount > 1 {
                    Button("Move to Next Display") { withAnimation(DS.Motion.arrive) { board.sendToNextScreen(placement.uid) } }
                }
            }
            Section {
                Button("Customise in Settings…") {
                    board.selection = placement.uid
                    ManagerWindow.shared.show(chapter: Chapter.widgets.rawValue)
                }
                Button("Remove \(kind.title)", role: .destructive) { withAnimation(DS.Motion.arrive) { board.remove(placement.uid) } }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(white: 0.2).opacity(0.85), in: .circle)
                .atelierGlass(.regular, in: .circle)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .contentShape(Circle().inset(by: -4))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Options for \(kind.title)")
    }
}

// MARK: - Wiggle

/// One small, damped wiggle as arranging begins, staggered across tiles. Then the tiles keep still,
/// so arranging costs nothing per frame while nobody is touching anything.
struct Wiggle: ViewModifier {
    let order: Int
    let active: Bool
    @State private var angle = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onChange(of: active) { _, on in
                guard on, !reduceMotion, Date().timeIntervalSince(WidgetSession.shared.arrangeStarted) < 1 else { return }
                let delay = min(Double(order), 12) * 0.025
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    var start = Transaction()
                    start.disablesAnimations = true
                    withTransaction(start) { angle = order.isMultiple(of: 2) ? 1.6 : -1.6 }
                    withAnimation(.interpolatingSpring(stiffness: 340, damping: 7)) { angle = 0 }
                }
            }
    }
}
