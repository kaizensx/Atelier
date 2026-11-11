import AppKit
import DockCore
import SwiftUI

// The Stacks chapter: one list of every stack in either dock, plain or smart, each with
// the same four-tab inspector. Smart Stacks are one idea: a stack that fills itself from a
// source. The macOS Dock's native Spotlight folders (once called Live Stacks) are the same
// idea drawn by the Dock itself, so they sit in the same list. Putting a stack on a bar,
// moving or removing it there is the Dock chapter's job.

/// One row in the list.
enum StackEntry: Identifiable, Hashable {
    /// A `.dockstack`, plain or smart, in the macOS Dock, the Atelier Dock, or both.
    case document(URL)
    /// An Atelier Dock Smart Stack, by tile id.
    case atelier(String)
    /// A native Spotlight folder in the macOS Dock, by its label.
    case native(String)

    var id: String {
        switch self {
        case .document(let url): "doc:" + url.path
        case .atelier(let id): "smart:" + id
        case .native(let label): "native:" + label
        }
    }
}

struct DockHubStacksChapter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var dock = OwnDock.shared
    @State private var expanded: String?
    @State private var creating = false
    @State private var preset: StackSmart?
    private let hue = DockHubHue.tint

    private var entries: [StackEntry] {
        model.stacks.map(StackEntry.document)
            + dock.items.filter { $0.kind == .smart }.map { StackEntry.atelier($0.id) }
            + Tiles.smartLabels(model.dock.plist).map(StackEntry.native)
    }

    var body: some View {
        let entries = entries
        let smart = entries.filter { entry in
            if case .document(let url) = entry { return (try? StackStore.load(url))?.source != nil }
            return true
        }.count
        StacksHero(count: entries.count, smart: smart, creating: creating) {
            withAnimation(DS.Motion.reveal) { creating.toggle(); if !creating { preset = nil } }
        }
        if creating {
            StackCreator(model: model, preset: preset) {
                withAnimation(DS.Motion.reveal) { creating = false; preset = nil }
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
        }
        SectionHeader("Your Stacks", symbol: "square.stack.3d.up",
                      detail: "Every stack in both docks, plain or smart. Open one to set what it holds, its icon and its bubble.",
                      hue: hue)
        if entries.isEmpty {
            Card {
                Text("No stacks yet. Make one above, or start from an idea below.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        } else {
            Card(padding: DS.Inset.plate) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        StackEntryRow(entry: entry, model: model, expanded: $expanded)
                    }
                }
            }
        }
        if !creating {
            SectionHeader(entries.isEmpty ? "Start With One" : "More Ideas", symbol: "lightbulb",
                          detail: "Smart Stacks worth having, one click from made.", hue: hue)
            Card(padding: DS.Inset.plate) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 6)], spacing: 6) {
                    ForEach(StackIdea.all) { idea in
                        StackIdeaTile(idea: idea) {
                            withAnimation(DS.Motion.reveal) { preset = idea.smart; creating = true }
                        }
                    }
                }
            }
        }
    }
}

/// The Stacks hero: a bubble that fills itself, shown filling while the pointer is on it.
/// A stack is not one switch, so the plate and button make a new one; it is lit once any exist.
struct StacksHero: View {
    let count: Int
    let smart: Int
    let creating: Bool
    let action: () -> Void

    var body: some View {
        DockHubActionHero(title: "Smart Stacks",
                          pitch: "Stacks that fill themselves each time they open: recent apps, a folder's newest files, a Spotlight search.",
                          lit: count > 0,
                          readout: "\(count)",
                          readoutCaption: "\(smart) smart · " + (count == 1 ? "stack" : "stacks"),
                          button: creating ? "Cancel" : "New Stack", symbol: creating ? "xmark" : "plus", quiet: creating,
                          buttonLabel: creating ? "Cancel the new stack" : "New Stack",
                          action: action) {
            LivePlate { size, since in StacksBubblePlate(size: size, since: since, hue: DockHubHue.tint) }
        }
    }
}

/// A stack's bubble over its tile. At rest it holds still; while hovered, the newest item
/// slides in at the front every second or so, the way a Smart Stack refills.
private struct StacksBubblePlate: View {
    let size: CGSize
    let since: Date?
    let hue: Color
    @State private var icons: [CGImage] = []

    private static let columns = 4, rows = 2

    var body: some View {
        PlateClock(since: since, fps: 60) { time in
            Canvas { context, canvas in draw(&context, canvas, time: time) }
        }
        .task { icons = Self.loadIcons() }
        .accessibilityHidden(true)
    }

    @MainActor private static func loadIcons() -> [CGImage] {
        let recent = AppCatalog.shared.items(for: .recentlyUsed, fallback: []).map(\.value)
        let paths = Array((recent + AppCatalog.shared.apps.map(\.value)).prefix(14))
        return paths.compactMap { BitmapIcons.cgImage(DockIcons.image($0), pixels: 128) }
    }

    private func draw(_ context: inout GraphicsContext, _ canvas: CGSize, time: Double) {
        let cell = 26.0, gap = 8.0, pad = 12.0
        let cols = Self.columns, rows = Self.rows
        let width = Double(cols) * cell + Double(cols - 1) * gap + pad * 2
        let height = Double(rows) * cell + Double(rows - 1) * gap + pad * 2
        let tileSide = 30.0
        let tile = CGRect(x: canvas.width * 0.42 - tileSide / 2, y: canvas.height - tileSide - 8, width: tileSide, height: tileSide)
        let bubble = CGRect(x: tile.midX - width / 2, y: tile.minY - 10 - height, width: width, height: height)

        // The bubble and its point, flat glass.
        var shape = Path(roundedRect: bubble, cornerRadius: 14, style: .continuous)
        shape.move(to: CGPoint(x: tile.midX - 7, y: bubble.maxY))
        shape.addLine(to: CGPoint(x: tile.midX, y: bubble.maxY + 7))
        shape.addLine(to: CGPoint(x: tile.midX + 7, y: bubble.maxY))
        context.fill(shape, with: .color(.white.opacity(0.09)))
        context.stroke(Path(roundedRect: bubble, cornerRadius: 14, style: .continuous), with: .color(.white.opacity(0.18)), lineWidth: 0.5)

        // The stack's tile on a sliver of bar.
        let bar = tile.insetBy(dx: -64, dy: -4)
        context.fill(Path(roundedRect: bar, cornerRadius: 10, style: .continuous), with: .color(.white.opacity(0.06)))
        context.fill(Path(roundedRect: tile, cornerRadius: 8, style: .continuous),
                     with: .linearGradient(Gradient(colors: [hue, hue.opacity(0.55)]),
                                           startPoint: CGPoint(x: tile.midX, y: tile.minY), endPoint: CGPoint(x: tile.midX, y: tile.maxY)))
        context.draw(Text(Image(systemName: "sparkles")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black.opacity(0.7)),
                     at: CGPoint(x: tile.midX, y: tile.midY))

        // Items: every 1.2 s the list moves one along and a new first item fades in. At rest
        // (and for a beat after the pointer arrives) step 0 holds every item in its place.
        let period = 1.2
        let t = max(time - 0.4, 0)
        let moving = t > 0
        let step = moving ? Int(t / period) + 1 : 0
        let phase = moving ? min((t - Double(step - 1) * period) / 0.45, 1) : 1
        let eased = 1 - pow(1 - phase, 3)
        let total = cols * rows
        for slot in 0..<total {
            let col = slot % cols, row = slot / cols
            let target = CGPoint(x: bubble.minX + pad + Double(col) * (cell + gap), y: bubble.minY + pad + Double(row) * (cell + gap))
            // Where this item stood a moment ago: one place earlier in reading order.
            let before = slot - 1
            let from = before >= 0
                ? CGPoint(x: bubble.minX + pad + Double(before % cols) * (cell + gap), y: bubble.minY + pad + Double(before / cols) * (cell + gap))
                : CGPoint(x: target.x - cell * 0.6, y: target.y)
            let x = moving ? from.x + (target.x - from.x) * eased : target.x
            let y = moving ? from.y + (target.y - from.y) * eased : target.y
            let rect = CGRect(x: x, y: y, width: cell, height: cell)
            var layer = context
            if slot == 0 && moving { layer.opacity = eased }
            let index = icons.isEmpty ? slot : (slot - step % max(icons.count, 1) + icons.count * 4) % icons.count
            if icons.isEmpty {
                layer.fill(Path(roundedRect: rect, cornerRadius: cell * 0.24, style: .continuous),
                           with: .color(.white.opacity(0.18 + 0.03 * Double(index % 4))))
            } else {
                layer.draw(Image(decorative: icons[index], scale: 1), in: rect)
            }
        }
        // The last item leaves as the new one arrives.
        if moving, !icons.isEmpty {
            let col = cols - 1, row = rows - 1
            let rect = CGRect(x: bubble.minX + pad + Double(col) * (cell + gap) + cell * 0.6 * eased,
                              y: bubble.minY + pad + Double(row) * (cell + gap), width: cell, height: cell)
            var layer = context
            layer.opacity = 1 - eased
            let index = (total - 1 - (step - 1) % icons.count + icons.count * 4) % icons.count
            layer.draw(Image(decorative: icons[index], scale: 1), in: rect)
        }
    }
}

/// A Smart Stack worth having, one click from made.
struct StackIdea: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let smart: StackSmart

    static let all: [StackIdea] = [
        StackIdea(id: "recent", title: "Recent Apps", detail: "Last opened", symbol: "clock.arrow.circlepath",
                  tint: .blue, smart: StackSmart(source: .recentApps)),
        StackIdea(id: "downloads", title: "Downloads", detail: "Newest first", symbol: "arrow.down.circle.fill",
                  tint: .green, smart: StackSmart(source: .downloads)),
        StackIdea(id: "running", title: "Running", detail: "Open apps", symbol: "play.circle.fill",
                  tint: .orange, smart: StackSmart(source: .running)),
        StackIdea(id: "shots", title: "Screenshots", detail: "This week", symbol: "camera.viewfinder",
                  tint: .pink, smart: {
                      var s = StackSmart(source: .spotlight); s.query = "kind:image name:Screenshot modified this week"; return s
                  }()),
    ]
}

struct StackIdeaTile: View {
    let idea: StackIdea
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DS.Ink.fillStrong)
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: idea.symbol).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hover ? DockHubHue.tint : DS.Ink.primary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(idea.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    Text(idea.detail).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hover ? DockHubHue.tint : DS.Ink.glyph)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(DockHubPickFrame(selected: false, hover: hover))
            .contentShape(.rect(cornerRadius: DS.Radius.plate))
        }
        .buttonStyle(Pressable(scale: 0.97))
        .onHover { hover = $0 }
        .help("New Smart Stack: " + idea.title)
    }
}

// MARK: - New

/// Makes a stack or a Smart Stack, for either dock.
struct StackCreator: View {
    @ObservedObject var model: ManagerModel
    var preset: StackSmart? = nil
    let done: () -> Void
    @ObservedObject private var dock = OwnDock.shared
    @State private var name = ""
    @State private var isSmart = true
    @State private var smart = StackSmart(source: .recentApps)
    @State private var atelier = OwnDock.shared.enabled
    /// A search in the macOS Dock can be a native folder the Dock keeps fresh itself.
    @State private var native = true

    private var nativeSearch: Bool { isSmart && !atelier && smart.source == .spotlight && native }

    var body: some View {
        Card(style: .lit(DockHubHue.tint)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New Stack").font(DS.title).foregroundStyle(DS.Ink.primary)
                Segments(selection: $isSmart, options: [(false, "Stack"), (true, "Smart Stack")])
                StackRow.line("Name") {
                    TextField(isSmart ? smart.source.title : "New Stack", text: $name)
                        .textFieldStyle(.plain).font(DS.body)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(DS.Ink.fill, in: .capsule)
                }
                if isSmart { StackSourceEditor(smart: $smart, name: $name) }
                StackRow.line("Put In") {
                    Segments(selection: $atelier, options: [(false, "macOS Dock")] + (dock.enabled ? [(true, "Atelier Dock")] : []))
                }
                if isSmart, !atelier, smart.source == .spotlight {
                    StackRow.toggle("Native Dock Folder", $native,
                                    detail: "The macOS Dock keeps it fresh itself, even with Atelier closed. Its look is the Dock's own.")
                }
                HStack {
                    Text(atelier ? "Add items and style it in its inspector."
                         : "Adding to the macOS Dock changes the Dock's own settings. Earlier states stay in Snapshots.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(action: add) {
                        Label("Add", systemImage: "plus").font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 16).frame(height: 30)
                            .background(DockHubHue.tint, in: .capsule).foregroundStyle(.black.opacity(0.85))
                    }
                    .buttonStyle(Pressable(scale: 0.96))
                    .disabled(!ready || model.busy)
                    .opacity(!ready || model.busy ? 0.45 : 1)
                }
            }
        }
        .onAppear {
            if let preset { isSmart = true; smart = preset }
        }
    }

    private var ready: Bool {
        guard isSmart else { return true }
        switch smart.source {
        case .folder: return !smart.folder.isEmpty
        case .spotlight: return DockSpotlightQuery.make(smart.query) != nil
        default: return true
        }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let title = trimmed.isEmpty ? (isSmart ? smart.source.title : "New Stack") : trimmed
        if nativeSearch, let query = DockSpotlightQuery.make(smart.query) {
            model.changeTiles("Smart stack \(title)") { Tiles.addSmart(label: title, query: query, to: &$0) }
        } else if isSmart, atelier {
            var stack = DockSmartStack(name: title, source: smart.source)
            stack.folder = smart.folder
            stack.query = smart.query
            dock.addSmart(stack)
        } else {
            var made = StackDocument(title: title)
            made.smart = isSmart ? smart : nil
            let document = made
            if atelier {
                model.perform("Making \(title)…", { _ = try StackActions.make(document) }) {
                    if let url = try? StackStore.url(forTitle: StackStore.cleanTitle(title)) { OwnDock.shared.add(url) }
                }
            } else {
                model.perform("Updating the Dock…", { _ = try StackActions.apply(document, existing: nil) })
            }
        }
        done()
    }
}

// MARK: - Rows

struct StackEntryRow: View {
    let entry: StackEntry
    @ObservedObject var model: ManagerModel
    @Binding var expanded: String?
    @ObservedObject private var dock = OwnDock.shared
    @State private var hover = false

    var body: some View {
        let open = expanded == entry.id
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(DS.Motion.reveal) { expanded = open ? nil : entry.id } } label: {
                HStack(spacing: 10) {
                    icon.frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                        Text(subtitle).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(open ? DockHubHue.tint : DS.Ink.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 26, height: 26)
                }
                .padding(.horizontal, 10).frame(minHeight: 46)
                .contentShape(.rect)
            }
            .buttonStyle(Pressable(scale: 0.99))
            .accessibilityLabel("Options for \(title)")
            .accessibilityValue(open ? "Open" : "Closed")
            if open {
                Group {
                    switch entry {
                    case .document(let url): StackDocumentInspector(url: url, model: model)
                    case .atelier(let id): StackAtelierInspector(id: id)
                    case .native(let label): StackNativeInspector(label: label, model: model)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .modifier(DockHubPickFrame(selected: open, hover: hover && !open))
        .onHover { hover = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch entry {
        case .document(let url):
            Image(nsImage: DockIcons.image(url.path)).resizable().interpolation(.high)
        case .atelier(let id):
            if let item = dock.items.first(where: { $0.id == id }) { DockHubItemIcon(item: item) }
        case .native:
            Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 22)).foregroundStyle(DS.Ink.secondary)
        }
    }

    private var title: String {
        switch entry {
        case .document(let url): url.deletingPathExtension().lastPathComponent
        case .atelier(let id): dock.smart[id]?.name ?? "Smart Stack"
        case .native(let label): label
        }
    }

    private var subtitle: String {
        switch entry {
        case .document(let url):
            let document = try? StackStore.load(url)
            let kind = document?.source.map { "Smart · \($0.title)" } ?? "Stack"
            var places: [String] = []
            if StackPlaces.inSystemDock(url, model.dock.plist) { places.append("macOS Dock") }
            if StackPlaces.inAtelier(url) { places.append("Atelier Dock") }
            return kind + " · " + (places.isEmpty ? "Not in a dock" : places.joined(separator: " and "))
        case .atelier(let id):
            return "Smart · \(dock.smart[id]?.source.title ?? "") · Atelier Dock"
        case .native:
            return "Smart · Spotlight · macOS Dock, kept fresh by the Dock"
        }
    }
}

enum StackPlaces {
    static func inSystemDock(_ url: URL, _ plist: DockPlist) -> Bool {
        Tiles.others(plist).contains { Tiles.path(of: $0) == url.path }
    }

    @MainActor static func inAtelier(_ url: URL) -> Bool {
        OwnDock.shared.items.contains { $0.kind == .stack && ($0.path == url.path || $0.id == url.path) }
    }

    @MainActor static func atelierID(_ url: URL) -> String? {
        OwnDock.shared.items.first { $0.kind == .stack && ($0.path == url.path || $0.id == url.path) }?.id
    }
}

// MARK: - Inspectors

/// A `.dockstack`. Changes collect in a draft; Apply saves them. Only a new icon or name
/// touches the macOS Dock, and only for a stack that is in it.
struct StackDocumentInspector: View {
    let url: URL
    @ObservedObject var model: ManagerModel
    @State private var saved: StackDocument?
    @State private var draft = StackDocument(title: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if saved == nil {
                Text("This stack could not be read.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            } else {
                StackRow.line("Name") { DockCommitField(prompt: "Name", value: $draft.title) }
                StackTabs(style: $draft.style, icon: $draft.icon, title: draft.title, items: draft.items,
                          atelier: StackPlaces.inAtelier(url), content: AnyView(content), tile: tile)
                footer
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.applied) { load() }
    }

    @ViewBuilder private var content: some View {
        let smart = Binding<Bool>(get: { draft.smart != nil }, set: { draft.smart = $0 ? StackSmart(source: .recentApps) : nil })
        Segments(selection: smart, options: [(false, "Chosen Items"), (true, "Smart")])
        if let current = draft.smart {
            StackSourceEditor(smart: Binding(get: { draft.smart ?? current }, set: { draft.smart = $0 }), name: $draft.title)
        } else {
            ItemsEditor(items: $draft.items)
        }
    }

    private var tile: AnyView? {
        StackPlaces.atelierID(url).map { AnyView(StackTileOptions(id: $0, smart: false)) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            DockPillButton(title: "Export…") { model.pick(url); model.exportStack() }
            if !StackPlaces.inSystemDock(url, model.dock.plist) {
                DockPillButton(title: "Add to macOS Dock") {
                    let title = draft.title
                    model.changeTiles("Stack \(title)") { Tiles.attach(Tiles.stack(path: url.path, label: title), to: &$0, at: nil) }
                }
            }
            if OwnDock.shared.enabled, !StackPlaces.inAtelier(url) {
                DockPillButton(title: "Add to Atelier Dock") { OwnDock.shared.add(url) }
            }
            Spacer()
            DockPillButton(title: "Delete") {
                if let id = StackPlaces.atelierID(url) { OwnDock.shared.remove(id: id) }
                model.pick(url)
                model.deleteStack()
            }
            if draft != saved {
                Button(action: apply) {
                    Text("Apply").font(.system(size: 12.5, weight: .semibold)).padding(.horizontal, 16).frame(height: 30)
                        .background(DockHubHue.tint, in: .capsule).foregroundStyle(.black.opacity(0.85))
                }
                .buttonStyle(Pressable(scale: 0.96)).disabled(model.busy)
            }
        }
    }

    private func load() {
        saved = try? StackStore.load(url)
        if let saved { draft = saved }
    }

    private func apply() {
        let document = draft, url = url
        let system = StackPlaces.inSystemDock(url, model.dock.plist)
        model.perform("Saving…", {
            _ = try StackActions.update(document, at: url, systemDock: system)
        }) {
            DockIcons.reload(url.path)
            OwnDock.shared.refresh()
        }
    }
}

/// An Atelier Dock Smart Stack. Every change applies at once.
struct StackAtelierInspector: View {
    let id: String
    @ObservedObject private var dock = OwnDock.shared

    private var stack: Binding<DockSmartStack> {
        let id = id
        return Binding(get: { OwnDock.shared.smart[id] ?? DockSmartStack(name: "Smart Stack", source: .recentApps) },
                       set: { OwnDock.shared.updateSmart(id, $0) })
    }

    private var smart: Binding<StackSmart> {
        Binding(get: { stack.wrappedValue.smart }, set: { value in
            var next = stack.wrappedValue
            next.source = value.source
            next.folder = value.folder
            next.query = value.query
            stack.wrappedValue = next
        })
    }

    private var icon: Binding<IconSpec> {
        Binding(get: { stack.wrappedValue.icon ?? Self.symbolIcon(stack.wrappedValue) }, set: { stack.wrappedValue.icon = $0 })
    }

    static func symbolIcon(_ stack: DockSmartStack) -> IconSpec {
        var spec = IconSpec()
        spec.style = .symbol
        spec.symbol = stack.source.symbol
        return spec
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StackRow.line("Name") { DockCommitField(prompt: "Name", value: stack.name) }
            StackTabs(style: stack.style, icon: icon, title: stack.wrappedValue.name, items: [], atelier: true,
                      content: AnyView(StackSourceEditor(smart: smart, name: stack.name)),
                      tile: AnyView(VStack(alignment: .leading, spacing: 8) {
                          if stack.wrappedValue.icon != nil {
                              DockPillButton(title: "Use the Source's Symbol") { stack.wrappedValue.icon = nil }
                          }
                          StackTileOptions(id: id, smart: true)
                      }))
            HStack {
                Text("Move it on the bar from the Dock chapter.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                DockPillButton(title: "Remove") { OwnDock.shared.remove(id: id) }
            }
        }
    }
}

/// A native Spotlight folder: the macOS Dock draws and fills it, so only its place is ours.
struct StackNativeInspector: View {
    let label: String
    @ObservedObject var model: ManagerModel

    var body: some View {
        HStack {
            Text("The macOS Dock fills and draws this one itself, even with Atelier closed, so its bubble is the Dock's own.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            DockPillButton(title: "Remove") {
                let label = label
                model.changeTiles("Remove \(label)") { Tiles.removeSmart(label: label, from: &$0) }
            }
            .disabled(model.busy)
        }
    }
}
