import AppKit
import DockCore
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    convenience init(frame: NSRect) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
    }
}

enum DockEdge {
    case bottom, left, right

    static var current: DockEdge {
        let value = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        switch value {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }
}

// MARK: - Model

@MainActor
final class BubbleModel: ObservableObject {
    @Published var open = false
    @Published var title = ""
    @Published var style = StackStyle()
    @Published var path: [StackItem] = []
    @Published var query = ""
    @Published var selection = 0
    /// File dates, read in the background after the bubble opens.
    @Published var fileFacts: [String: StackFacts] = [:]
    var root: [StackItem] = []
    /// The tint that follows the dock or the wallpaper, for `style.tint == -1`.
    var tint: Color?
    var anchor = UnitPoint.bottom
    var alignment = Alignment.bottom
    var offset = CGSize.zero
    /// Bundle paths of running apps, for the running dot.
    var running: Set<String> = []
    var background: NSImage?

    var heading: String { path.last?.name ?? title }

    var tintColor: Color? {
        switch style.tint {
        case -2: nil
        case -1: tint
        default: Palette.colors.indices.contains(style.tint) ? Color(nsColor: Palette.colors[style.tint]) : tint
        }
    }

    func facts(_ item: StackItem) -> StackFacts {
        if let known = fileFacts[item.value] { return known }
        return item.kind == .app ? AppCatalog.shared.facts(item) : StackFacts()
    }

    /// What shows right now, under headings when grouped. A search is one flat list.
    var groups: [StackGroup] {
        let items = path.last?.children ?? root
        guard query.isEmpty else {
            let found = items.compactMap { item in Fuzzy.score(query, in: item.name).map { (item, $0) } }
                .sorted { $0.1 > $1.1 }.map(\.0)
            return [StackGroup(title: "", items: found)]
        }
        return StackQuery.apply(items, style: style, facts: facts)
    }

    var visible: [StackItem] { groups.flatMap(\.items) }

    /// Columns the grid draws, for moving up and down with the keyboard.
    var columns: Int {
        switch style.layout {
        case .grid, .honeycomb: StackGeometry.columns(visible.count, style: style)
        default: 1
        }
    }
}

// MARK: - Views

struct ItemCell: View {
    let item: StackItem
    let selected: Bool
    let index: Int
    @ObservedObject var model: BubbleModel
    let motion: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let style = model.style, icon = style.iconSize
        Button(action: action) {
            VStack(spacing: 7) {
                Image(nsImage: ItemIcon.image(for: item))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: icon, height: icon)
                    .shadow(color: .black.opacity(hovering ? 0.32 : 0.18), radius: hovering ? 10 : 5, y: hovering ? 6 : 3)
                    .overlay(alignment: .topTrailing) { if style.badges { BubbleBadge(item: item, model: model, size: icon) } }
                    .scaleEffect(hovering ? 1.1 : 1)
                    .offset(y: hovering ? -3 : 0)
                if style.labels {
                    Text(item.name)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: BubbleMetrics.cell(style).width, height: BubbleMetrics.cell(style).height)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(selected ? 0.16 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.26, dampingFraction: 0.62), value: hovering)
        .modifier(BubbleQuickActions(item: item, on: style.quickActions))
        .modifier(BubbleStagger(open: model.open, index: index, motion: motion, kind: style.animation))
        .accessibilityLabel(item.name)
    }
}

enum BubbleMetrics {
    static func cell(_ style: StackStyle) -> CGSize {
        CGSize(width: max(style.iconSize + 26, 70), height: style.iconSize + (style.labels ? 30 : 12))
    }
}

/// A count on groups and folders, a dot on running apps.
struct BubbleBadge: View {
    let item: StackItem
    @ObservedObject var model: BubbleModel
    let size: Double

    var body: some View {
        if item.kind == .group, !item.children.isEmpty {
            Text("\(item.children.count)")
                .font(.system(size: max(size * 0.16, 9), weight: .bold)).monospacedDigit()
                .foregroundStyle(.white).padding(.horizontal, 5).frame(minHeight: max(size * 0.26, 14))
                .background(Capsule().fill(Color.accentColor))
                .offset(x: 4, y: -4)
        } else if item.kind == .app, model.running.contains(item.value) {
            Circle().fill(.white.opacity(0.9)).frame(width: 6, height: 6)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .offset(x: 2, y: size + 4)
        }
    }
}

/// Items arrive one after another for the bloom, all at once for the others.
struct BubbleStagger: ViewModifier {
    let open: Bool
    let index: Int
    let motion: Bool
    let kind: StackOpenAnimation

    func body(content: Content) -> some View {
        let stagger = kind == .bloom || kind == .unfold
        content
            .scaleEffect(open || !stagger ? 1 : 0.35)
            .opacity(open ? 1 : 0)
            .animation(motion && stagger
                ? .spring(response: 0.46, dampingFraction: 0.68).delay(open ? Double(min(index, 24)) * 0.018 : 0)
                : .easeOut(duration: 0.14), value: open)
    }
}

/// Open, Open With, Show in Finder and Copy Path on a secondary click.
struct BubbleQuickActions: ViewModifier {
    let item: StackItem
    let on: Bool

    func body(content: Content) -> some View {
        if on, item.kind != .group {
            content.contextMenu {
                Button("Open") { Launcher.open(item) }
                if item.kind == .app || item.kind == .file {
                    let url = URL(fileURLWithPath: item.value)
                    if item.kind == .file {
                        Menu("Open With") {
                            ForEach(NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(10), id: \.self) { app in
                                Button(app.deletingPathExtension().lastPathComponent) {
                                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                                }
                            }
                        }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Copy Path") { Self.copy(item.value) }
                } else if item.kind == .url {
                    Button("Copy Link") { Self.copy(item.value) }
                }
            }
        } else {
            content
        }
    }

    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The bubble's surface: glass, clear glass, a frosted material or a solid card, with the
/// stack's tint and its own corner radius.
struct BubbleSurface: ViewModifier {
    let style: StackStyle
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
        switch style.material {
        case .glass:
            content.atelierGlass(tint.map { AGlass.regular.tint($0.opacity(0.22)) } ?? .regular, in: shape)
        case .clear:
            content.atelierGlass(tint.map { AGlass.clear.tint($0.opacity(0.18)) } ?? .clear, in: shape)
        case .frosted:
            content.background {
                ZStack {
                    if style.blur < 0.34 { shape.fill(.ultraThinMaterial) }
                    else if style.blur < 0.67 { shape.fill(.regularMaterial) }
                    else { shape.fill(.thickMaterial) }
                    if let tint { shape.fill(tint.opacity(0.18)) }
                    shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
                }
            }
        case .solid:
            content.background {
                shape.fill(tint ?? Color(white: 0.13)).overlay(shape.fill(.black.opacity(0.25)))
                    .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
        }
    }
}

/// How the bubble arrives. Implicit animations on `open` only: the render server runs
/// them, so nothing in the bubble is rebuilt per frame.
struct BubbleArrival: ViewModifier {
    let open: Bool
    let kind: StackOpenAnimation
    let anchor: UnitPoint
    let motion: Bool

    func body(content: Content) -> some View {
        let shut = !open
        switch kind {
        case .bloom:
            content
                .scaleEffect(shut ? 0.18 : 1, anchor: anchor)
                .opacity(shut ? 0 : 1)
                .blur(radius: shut ? 16 : 0)
                .animation(motion ? .spring(response: 0.40, dampingFraction: 0.76) : .easeOut(duration: 0.12), value: open)
        case .unfold:
            let vertical = anchor == .top || anchor == .bottom
            content
                .scaleEffect(x: vertical ? 1 : (shut ? 0.04 : 1), y: vertical ? (shut ? 0.04 : 1) : 1, anchor: anchor)
                .opacity(shut ? 0 : 1)
                .animation(motion ? .spring(response: 0.38, dampingFraction: 0.84) : .easeOut(duration: 0.12), value: open)
        case .slide:
            let away: CGSize = switch anchor {
            case .top: CGSize(width: 0, height: -46)
            case .leading: CGSize(width: -46, height: 0)
            case .trailing: CGSize(width: 46, height: 0)
            default: CGSize(width: 0, height: 46)
            }
            content
                .offset(shut ? away : .zero)
                .opacity(shut ? 0 : 1)
                .animation(motion ? .spring(response: 0.34, dampingFraction: 0.9) : .easeOut(duration: 0.12), value: open)
        case .zoom:
            content
                .scaleEffect(shut ? 0.04 : 1, anchor: anchor)
                .opacity(shut ? 0 : 1)
                .animation(motion ? .easeOut(duration: 0.22) : .easeOut(duration: 0.12), value: open)
        }
    }
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    let motion: Bool
    let activate: (StackItem) -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack(alignment: model.alignment) {
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: dismiss)
            bubble.offset(model.offset).padding(10)
        }
    }

    private var bubble: some View {
        let style = model.style
        return VStack(spacing: 12) {
            header
            content
                .id(model.path.last?.id)
                .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                        removal: .scale(scale: 1.06).combined(with: .opacity)))
        }
        .padding(16)
        .background {
            if let picture = model.background {
                Image(nsImage: picture).resizable().scaledToFill()
                    .blur(radius: style.blur * 24)
                    .opacity(style.backgroundOpacity)
                    .clipShape(RoundedRectangle(cornerRadius: style.radius, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .modifier(BubbleSurface(style: style, tint: model.tintColor))
        .scaleEffect(style.scale, anchor: model.anchor)
        .modifier(BubbleArrival(open: model.open, kind: style.animation, anchor: model.anchor, motion: motion))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !model.path.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { _ = model.path.popLast() }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Text(model.heading)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .contentTransition(.opacity)
            if model.style.search {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold))
                    Text(model.query.isEmpty ? "Type to search" : model.query).lineLimit(1)
                }
                .font(.system(size: 11.5, weight: model.query.isEmpty ? .regular : .semibold))
                .foregroundStyle(model.query.isEmpty ? .secondary : .primary)
                .padding(.horizontal, 9).frame(height: 22)
                .background(.white.opacity(model.query.isEmpty ? 0.06 : 0.14), in: .capsule)
                .accessibilityLabel(model.query.isEmpty ? "Type to search" : "Searching \(model.query)")
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var content: some View {
        let groups = model.groups
        let items = groups.flatMap(\.items)
        if items.isEmpty {
            Text(model.query.isEmpty ? "Nothing here" : "No results").font(.callout).foregroundStyle(.secondary).frame(width: 200, height: 60)
        } else {
            switch model.style.layout {
            case .grid: scrolling(grouped(groups) { grid($0, offset: $1) })
            case .list: scrolling(grouped(groups) { list($0, offset: $1) }, width: 280)
            case .fan: fan(items)
            case .carousel: carousel(items)
            case .arc, .spiral, .honeycomb: placed(items)
            }
        }
    }

    private var selecting: Bool { model.style.keyboard && (!model.query.isEmpty || model.selection > 0) }

    /// A long grid or list scrolls instead of running off the screen.
    private func scrolling(_ inner: some View, width: Double? = nil) -> some View {
        ScrollView(.vertical) { inner }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: width.map { CGFloat($0) }, height: nil)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: width == nil, vertical: true)
    }

    private func grouped<Body: View>(_ groups: [StackGroup], @ViewBuilder _ body: @escaping ([StackItem], Int) -> Body) -> some View {
        var starts: [Int] = []
        var start = 0
        for group in groups { starts.append(start); start += group.items.count }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if !group.title.isEmpty {
                    Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(.secondary).padding(.leading, 6)
                }
                body(group.items, starts[index])
            }
        }
    }

    private func grid(_ items: [StackItem], offset: Int) -> some View {
        let cell = BubbleMetrics.cell(model.style)
        let count = StackGeometry.columns(model.visible.count, style: model.style)
        let columns = Array(repeating: GridItem(.fixed(cell.width), spacing: 4), count: min(count, max(items.count, 1)))
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ItemCell(item: item, selected: selecting && offset + index == model.selection,
                         index: offset + index, model: model, motion: motion) { activate(item) }
            }
        }
    }

    private func list(_ items: [StackItem], offset: Int) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item, index: offset + index)
            }
        }
    }

    /// The macOS Fan: a column that leans away from the tile, nearest item first.
    private func fan(_ items: [StackItem]) -> some View {
        let shown = Array(items.prefix(12))
        return VStack(spacing: 2) {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { index, item in
                let t = shown.count > 1 ? Double(index) / Double(shown.count - 1) : 0
                row(item, index: index)
                    .rotationEffect(.degrees(-6 * t), anchor: .trailing)
                    .offset(x: -70 * sin(t * .pi / 2))
            }
        }
        .frame(width: 340)
    }

    private func carousel(_ items: [StackItem]) -> some View {
        let icon = max(model.style.iconSize, 72)
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { activate(item) } label: {
                        VStack(spacing: 10) {
                            Image(nsImage: ItemIcon.image(for: item)).resizable().interpolation(.high)
                                .frame(width: icon, height: icon)
                                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                                .overlay(alignment: .topTrailing) { if model.style.badges { BubbleBadge(item: item, model: model, size: icon) } }
                            if model.style.labels {
                                Text(item.name).font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    .lineLimit(2).multilineTextAlignment(.center)
                                    .frame(width: icon + 28, height: 34, alignment: .top)
                            }
                        }
                        .frame(width: icon + 46, height: icon + (model.style.labels ? 76 : 36))
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.white.opacity(selecting && index == model.selection ? 0.18 : 0.07)))
                        .contentShape(.rect(cornerRadius: 20))
                    }
                    .buttonStyle(PressStyle())
                    .modifier(BubbleQuickActions(item: item, on: model.style.quickActions))
                    .modifier(BubbleStagger(open: model.open, index: index, motion: motion, kind: model.style.animation))
                    .accessibilityLabel(item.name)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.never)
        .scrollTargetBehavior(.viewAligned)
        .frame(width: min(Double(max(items.count, 1)) * (icon + 58) + 12, 640), height: icon + (model.style.labels ? 84 : 44))
    }

    /// Arc, Spiral and Honeycomb: each item at a point worked out once per change.
    private func placed(_ items: [StackItem]) -> some View {
        let shown = Array(items.prefix(48))
        let cell = BubbleMetrics.cell(model.style)
        let columns = StackGeometry.columns(shown.count, style: model.style)
        let placement = StackGeometry.place(model.style.layout, count: shown.count, cell: cell, columns: columns)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                ItemCell(item: item, selected: selecting && index == model.selection, index: index, model: model, motion: motion) {
                    activate(item)
                }
                .rotationEffect(.degrees(placement.angles[index]))
                .position(placement.points[index])
            }
        }
        .frame(width: placement.size.width, height: placement.size.height)
    }

    private func row(_ item: StackItem, index: Int) -> some View {
        Button { activate(item) } label: {
            HStack(spacing: 10) {
                Image(nsImage: ItemIcon.image(for: item)).resizable().frame(width: 32, height: 32)
                    .overlay(alignment: .topTrailing) { if model.style.badges { BubbleBadge(item: item, model: model, size: 32) } }
                Text(item.name).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1)
                Spacer(minLength: 0)
                if item.kind == .group {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(selecting && index == model.selection ? 0.16 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .modifier(BubbleQuickActions(item: item, on: model.style.quickActions))
        .opacity(model.open ? 1 : 0)
        .offset(y: model.open ? 0 : 14)
        .animation(motion
            ? .spring(response: 0.42, dampingFraction: 0.74).delay(model.open ? Double(min(index, 16)) * 0.02 : 0)
            : .easeOut(duration: 0.12), value: model.open)
    }
}

// MARK: - Host

/// One bubble panel: its model, monitors, keys and folder navigation. The macOS Dock's
/// stacks and the Atelier Dock's each own one and only decide where it goes.
@MainActor
final class BubbleHost {
    static let size = NSSize(width: 920, height: 780)
    let model = BubbleModel()
    private var panel: FloatingPanel?
    private(set) var url: URL?
    private var outside: Any?
    private var keys: Any?
    private(set) var closedAt = Date.distantPast
    private(set) var closedURL: URL?

    var isOpen: Bool { model.open }
    func isShowing(_ url: URL) -> Bool { model.open && self.url == url }
    /// A click on the tile first closes through the mouse monitor, then arrives as an open.
    func justClosed(_ url: URL) -> Bool { url == closedURL && Date().timeIntervalSince(closedAt) < 0.35 }

    /// Fills the model. Placement is the caller's, then `present`.
    func load(_ url: URL, title: String, items: [StackItem], style: StackStyle, tint: Color?) {
        self.url = url
        model.title = title
        model.style = style
        model.path = []
        model.query = ""
        model.selection = 0
        model.root = items
        model.tint = tint
        model.fileFacts = [:]
        model.running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        model.background = style.background.isEmpty ? nil : NSImage(contentsOfFile: style.background)
        readFacts(items)
    }

    func present(frame: NSRect) {
        let panel = self.panel ?? make()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        DispatchQueue.main.async { self.model.open = true }
        startMonitors()
    }

    /// The bubble's drawn width, for keeping it over its tile near a screen edge.
    var drawnWidth: Double {
        let cell = BubbleMetrics.cell(model.style)
        let count = min(model.root.count, StackGeometry.columns(model.root.count, style: model.style))
        return (Double(max(count, 2)) * (cell.width + 4) + 52) * model.style.scale
    }

    /// Dates for files, off the main thread; only needed when they sort or filter.
    private func readFacts(_ items: [StackItem]) {
        let style = model.style
        guard style.sort == .added || style.sort == .kind || style.age != .any || !style.kinds.isEmpty || style.groupByKind else { return }
        let paths = items.filter { $0.kind == .file }.map(\.value)
        guard !paths.isEmpty else { return }
        let url = self.url
        Task.detached(priority: .userInitiated) {
            let found = Self.facts(paths)
            await MainActor.run {
                guard self.url == url else { return }
                self.model.fileFacts = found
            }
        }
    }

    nonisolated static func facts(_ paths: [String]) -> [String: StackFacts] {
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey, .isDirectoryKey, .isPackageKey]
        var result: [String: StackFacts] = [:]
        for path in paths.prefix(400) {
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys)
            result[path] = StackFacts(added: values?.addedToDirectoryDate, modified: values?.contentModificationDate,
                                      folder: values?.isDirectory == true && values?.isPackage != true)
        }
        return result
    }

    private func make() -> FloatingPanel {
        let panel = FloatingPanel(frame: NSRect(origin: .zero, size: Self.size))
        panel.contentView = NSHostingView(rootView: BubbleView(
            model: model, motion: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            activate: { [weak self] in self?.activate($0) },
            dismiss: { [weak self] in self?.close() }))
        self.panel = panel
        return panel
    }

    func activate(_ item: StackItem) {
        if item.kind == .group {
            push(item)
        } else if item.kind == .file, model.style.nested, Self.isFolder(item.value) {
            let path = item.value, name = item.name, url = self.url
            Task.detached(priority: .userInitiated) {
                let children = Self.children(of: path)
                await MainActor.run {
                    guard self.url == url, self.model.open else { return }
                    guard let children, !children.isEmpty else { Launcher.open(item); self.close(); return }
                    var folder = StackItem(kind: .group, name: name, value: path, children: children)
                    folder.id = item.id
                    self.push(folder)
                    self.readFacts(children)
                }
            }
        } else {
            Launcher.open(item)
            close()
        }
    }

    private func push(_ item: StackItem) {
        model.query = ""
        model.selection = 0
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.path.append(item) }
    }

    nonisolated static func isFolder(_ path: String) -> Bool {
        guard !path.hasSuffix(".app") else { return false }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// A folder's contents, newest first, capped so a huge folder stays quick.
    nonisolated static func children(of path: String) -> [StackItem]? {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let dated = entries.map { entry -> (String, Date) in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            return (entry.path, values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(120).map { StackItem.path($0.0) }
    }

    private func startMonitors() {
        stopMonitors()
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
        }
    }

    private func stopMonitors() {
        if let outside { NSEvent.removeMonitor(outside) }
        if let keys { NSEvent.removeMonitor(keys) }
        outside = nil
        keys = nil
    }

    /// Esc steps back, then closes. With keyboard navigation: arrows move, Return opens.
    /// With search: typing filters.
    private func handle(_ event: NSEvent) -> Bool {
        guard panel?.isKeyWindow == true else { return false }
        let style = model.style
        let count = model.visible.count
        switch event.keyCode {
        case 53:
            if !model.query.isEmpty { model.query = ""; model.selection = 0 }
            else if !model.path.isEmpty { withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { _ = model.path.popLast() } }
            else { close() }
            return true
        case 36, 76:
            guard style.keyboard else { return false }
            let visible = model.visible
            if visible.indices.contains(model.selection) { activate(visible[model.selection]) }
            return true
        case 51:
            guard style.search, !model.query.isEmpty else { return false }
            model.query.removeLast()
            model.selection = 0
            return true
        case 123, 124, 125, 126:
            guard style.keyboard, count > 0 else { return false }
            let step = event.keyCode == 125 || event.keyCode == 126 ? max(model.columns, 1) : 1
            let forward = event.keyCode == 124 || event.keyCode == 125
            model.selection = forward ? min(model.selection + step, count - 1) : max(model.selection - step, 0)
            return true
        default:
            guard style.search, let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
                  event.modifierFlags.intersection([.command, .control]).isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return false }
            model.query += characters
            model.selection = 0
            return true
        }
    }

    func close() {
        guard model.open else { return }
        closedURL = url
        closedAt = Date()
        model.open = false
        url = nil
        stopMonitors()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self, !self.model.open else { return }
            self.panel?.orderOut(nil)
        }
    }
}

// MARK: - macOS Dock stacks

/// The bubble for `.dockstack` tiles in the macOS Dock. It opens at the pointer, since the
/// Dock does not say where its tile is.
@MainActor
final class BubbleController {
    static let shared = BubbleController()
    private let host = BubbleHost()

    var moodEnabled: Bool {
        UserDefaults.standard.object(forKey: "mood") as? Bool ?? true
    }

    func toggle(_ url: URL) {
        if host.justClosed(url) { return }
        if host.isShowing(url) { close(); return }
        guard let document = try? StackStore.load(url) else { return }
        let mouse = NSEvent.mouseLocation
        let tint = moodEnabled ? Mood.shared.color.map(Color.init(nsColor:)) : nil
        if let smart = document.smart {
            let limit = document.style.limit > 0 ? document.style.limit : 60
            Task { @MainActor in
                let items = await StackFill.items(smart, limit: limit, sort: document.style.sort)
                self.show(document, items: items, url: url, mouse: mouse, tint: tint)
            }
        } else {
            show(document, items: document.items, url: url, mouse: mouse, tint: tint)
        }
    }

    private func show(_ document: StackDocument, items: [StackItem], url: URL, mouse: NSPoint, tint: Color?) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        host.load(url, title: document.title, items: items, style: document.style, tint: tint)
        let frame = frame(on: screen, mouse: mouse)
        place(frame, mouse: mouse)
        host.present(frame: frame)
    }

    private func frame(on screen: NSScreen, mouse: NSPoint) -> NSRect {
        let size = BubbleHost.size, area = screen.visibleFrame
        var origin = NSPoint(x: mouse.x - size.width / 2, y: area.minY + 4)
        switch DockEdge.current {
        case .bottom: break
        case .left: origin = NSPoint(x: area.minX + 4, y: mouse.y - size.height / 2)
        case .right: origin = NSPoint(x: area.maxX - size.width - 4, y: mouse.y - size.height / 2)
        }
        origin.x = min(max(origin.x, area.minX + 4), area.maxX - size.width - 4)
        origin.y = min(max(origin.y, area.minY + 4), area.maxY - size.height - 4)
        return NSRect(origin: origin, size: size)
    }

    private func place(_ frame: NSRect, mouse: NSPoint) {
        let model = host.model
        switch DockEdge.current {
        case .bottom:
            let limit = max(0, (frame.width - host.drawnWidth) / 2 - 12)
            model.offset = CGSize(width: min(max(mouse.x - frame.midX, -limit), limit), height: 0)
            model.alignment = .bottom
            model.anchor = .bottom
        case .left:
            model.offset = CGSize(width: 0, height: frame.midY - mouse.y)
            model.alignment = .leading
            model.anchor = .leading
        case .right:
            model.offset = CGSize(width: 0, height: frame.midY - mouse.y)
            model.alignment = .trailing
            model.anchor = .trailing
        }
    }

    func close() { host.close() }
}

/// What a smart stack holds right now, for either dock.
@MainActor
enum StackFill {
    static func items(_ smart: StackSmart, limit: Int, sort: StackSort) async -> [StackItem] {
        var stack = DockSmartStack(name: "", source: smart.source)
        stack.folder = smart.folder
        stack.query = smart.query
        stack.style.limit = limit
        stack.style.sort = sort
        return await DockHubContents.shared.items(for: stack)
    }
}
