import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

// The Dock chapter is the only place the Atelier Dock is set; Stacks keeps what belongs to
// stacks themselves, and the Dock only places them.
//
// The Dock chapter as one place: while the Atelier Dock is on, every card here sets the
// Atelier Dock, and the macOS Dock's own settings sit in a separate card at the end. While it
// is off, the chapter is the macOS Dock's, with a way in to the Atelier Dock at the top.
// Each card is a separate view, so the panel's lazy stack builds them as they scroll in.
//
// Layout: two heroes first (the dock itself, its lens), then the design gallery, then quiet
// grouped rows by subject, each under its own section header.

// MARK: - Shared furniture for Dock & Launch

/// The light Dock & Launch gives off: the Surfaces sky, the same as its sidebar section.
enum DockHubHue {
    static let tint = DS.Spectrum.surfaces
}

enum DockHubLayout {
    /// The title column of slider and picker rows, so their controls line up down a group.
    static let labelWidth = 128.0
    /// Segments at the end of a compact row.
    static let segmentsWidth = 288.0
}

extension View {
    /// A compact row's breathing room inside a RowGroup.
    func dockHubRow() -> some View { padding(.vertical, DS.Space.s) }
}

/// Selection and hover for a gallery tile: a hue ring when chosen, a quiet tint under the
/// pointer. Nothing scales on hover.
struct DockHubPickFrame: ViewModifier {
    let selected: Bool
    let hover: Bool
    var radius = DS.Radius.plate
    var hue = DockHubHue.tint

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(selected ? hue.opacity(0.12) : (hover ? DS.Ink.fill : .clear))
            }
            .overlay { shape.strokeBorder(selected ? hue : (hover ? DS.Ink.hairline : .clear), lineWidth: selected ? 1.5 : 0.5) }
            .animation(DS.Motion.hover, value: hover)
            .animation(DS.Motion.settle, value: selected)
    }
}

/// A row whose control needs the whole width: its title (and detail) above, the control below.
struct DockHubWideRow<Control: View>: View {
    let title: String
    var detail: String?
    var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                if let detail {
                    Text(detail).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            control
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(FallbackStagePreview(title: title, detail: detail))
    }
}

/// A hero for a place that is not one switch (Stacks, Orbit): the same plate, numeral and
/// light as `HeroCard`, but the plate and its button do the place's main thing instead of
/// toggling. `lit` says whether it gives off its light.
struct DockHubActionHero<Plate: View>: View {
    let title: String
    let pitch: String
    let lit: Bool
    var readout: String?
    var readoutCaption: String?
    let button: String
    var symbol = "plus"
    /// A quiet button, for a Cancel.
    var quiet = false
    var buttonLabel: String?
    let action: () -> Void
    @ViewBuilder var plate: Plate
    @State private var hover = false
    private let hue = DockHubHue.tint

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: action) { plateView }
                .buttonStyle(Pressable(scale: 0.985))
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                    Text(pitch).font(DS.body).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: action) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                        Text(button).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(quiet ? DS.Ink.primary : Color.black.opacity(0.85))
                    .padding(.horizontal, 16).frame(height: 34)
                    .background(quiet ? AnyShapeStyle(DS.Ink.fillStrong) : AnyShapeStyle(hue), in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(Pressable(scale: 0.96))
                .accessibilityLabel(buttonLabel ?? button)
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, 14)
            .padding(.bottom, DS.Space.s)
        }
        .padding(DS.Inset.plate)
        .background { CardSurface(style: lit ? .lit(hue) : .standard) }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(hover ? 0.1 : 0), lineWidth: 0.5)
        }
        .animation(DS.Motion.hover, value: hover)
        .animation(DS.Motion.reveal, value: lit)
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
    }

    private var plateView: some View {
        ZStack(alignment: .topLeading) {
            RadialGradient(colors: [hue.opacity(lit ? 0.4 : 0.14), .clear],
                           center: UnitPoint(x: 0.42, y: 1.1), startRadius: 0, endRadius: 260)
            plate.frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.black.opacity(lit ? 0 : 0.28).allowsHitTesting(false)
            HeroBadge(text: "Beyond macOS", hue: hue).padding(10)
            if let readout {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(readout).font(DS.Typo.readout).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    if let readoutCaption {
                        Text(readoutCaption.uppercased()).font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
                    }
                }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
            }
        }
        .frame(height: 148)
        .background(Color(red: 0.06, green: 0.065, blue: 0.08))
        .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - Chapter

struct DockHubChapter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var dock = OwnDock.shared
    private let hue = DockHubHue.tint

    var body: some View {
        OwnDockSwitchCard()
        if dock.enabled {
            OwnDockLensHero()
            SectionHeader("Design", symbol: "paintbrush", detail: "Every design drawn live. Hover one to see it on the stage.", hue: hue)
            DockDesignCard()
            SectionHeader("On the Bar", symbol: "square.grid.3x1.below.line.grid.1x2",
                          detail: "What it keeps, in bar order, and what it adds by itself.", hue: hue)
            DockHubItemsCard()
            DockHubBarContentsCard()
            DockOwnTilesCard()
            SectionHeader("Size and Place", symbol: "arrow.up.and.down.and.arrow.left.and.right", hue: hue)
            OwnDockPlaceCard()
            SectionHeader("Behaviour", symbol: "hand.point.up.left",
                          detail: "Drop files on an app to open them with it. ⌥-click an app hides the others, ⌘-click shows it in Finder, a middle click opens a new window.",
                          hue: hue)
            OwnDockBehaviourCard()
            SectionHeader("Hover", symbol: "cursorarrow.motionlines", hue: hue)
            DockHubHoverCard()
            SectionHeader("Effects", symbol: "sparkles",
                          detail: "Try them on the plate at the top: hover it, or press Try the Launch.", hue: hue)
            DockEffectsCard()
            SectionHeader("Keyboard Shortcuts", symbol: "command",
                          detail: "They work in any app. Show or Hide the Dock works while it is off; the others only while it is on.",
                          hue: hue)
            DockHubShortcutsCard()
            SectionHeader("Profiles", symbol: "person.2.crop.square.stack",
                          detail: "A profile keeps what is in the dock, its sections and its look. Switch by hand, from the dock's menu, by shortcut, desktop or hour.",
                          hue: hue)
            OwnDockProfilesCard()
            SectionHeader("macOS Dock", symbol: "dock.rectangle", hue: DS.Ink.secondary)
            DockHubMacOSCard(model: model)
        } else {
            SectionHeader("macOS Dock", symbol: "dock.rectangle",
                          detail: "These change the macOS Dock. Turn on the Atelier Dock above and this chapter sets it instead.",
                          hue: DS.Ink.secondary)
            DockChapter(model: model)
        }
    }
}

/// The macOS Dock's own settings, kept apart and folded away while the Atelier Dock is on.
struct DockHubMacOSCard: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var dock = OwnDock.shared
    @State private var open = false

    var body: some View {
        RowGroup {
            Button { withAnimation(DS.Motion.reveal) { open.toggle() } } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("macOS Dock Settings").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        Text(dock.systemReplaced ? "Hidden while the Atelier Dock takes its place. These are for when it returns."
                                                 : "Still shown beside the Atelier Dock. These change it, not the Atelier Dock.")
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Ink.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .frame(minHeight: 36)
                .contentShape(.rect)
            }
            .buttonStyle(Pressable(scale: 0.99))
            .dockHubRow()
            .accessibilityLabel(open ? "Hide macOS Dock settings" : "Show macOS Dock settings")
        }
        if open { DockChapter(model: model) }
    }
}

// MARK: - Items

/// The kept tiles, by section, in bar order: drag to reorder or into a section, remove with ×,
/// set each tile's options in place. What the dock adds by itself follows in the next card.
struct DockHubItemsCard: View {
    @ObservedObject private var dock = OwnDock.shared
    @State private var dragging: String?
    @State private var expanded: String?
    @State private var newSection = ""
    @State private var stacks: [URL] = []
    private let hue = DockHubHue.tint

    private struct Group: Identifiable {
        var id: String
        var title: String
        var section: DockSection?
        var items: [OwnDockItem]
    }

    private var groups: [Group] {
        let known = Set(dock.sections.map(\.id))
        let loose = dock.items.filter { $0.section.map { !known.contains($0) } ?? true }
        var list = [Group(id: "left", title: "Left Side", section: nil, items: loose.filter { !$0.rightSide })]
        for section in dock.sections {
            list.append(Group(id: section.id.uuidString, title: section.name, section: section,
                              items: dock.items.filter { $0.section == section.id }))
        }
        list.append(Group(id: "right", title: "Right Side", section: nil, items: loose.filter(\.rightSide)))
        return list
    }

    var body: some View {
        // A click on a tile in the stage opens that tile's inspector here.
        itemsCard.onReceive(StageFocus.shared.$dockTile) { id in
            if let id { expanded = id; StageFocus.shared.dockTile = nil }
        }
    }

    private var itemsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text("Kept").font(DS.title).foregroundStyle(DS.Ink.primary)
                    Text("\(dock.items.count)").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                    Spacer()
                    DockTogglePill(title: "Arrange Dock", symbol: "hand.draw", on: dock.arranging) { dock.arranging.toggle() }
                        .help("Shows a × on each tile in the dock itself and makes spacers visible, so you can remove them there.")
                }
                addRow
                // Lazy: a long Dock is dozens of rows, and every one costs on each frame the panel moves.
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { group in
                        header(group)
                        if group.items.isEmpty {
                            Text(group.section == nil ? "Nothing here" : "Drag items here, or right-click a tile and choose Move to Section.")
                                .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background {
                                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                        .strokeBorder(DS.Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                }
                                .onDrop(of: [.text], delegate: ItemDrop(target: nil, section: group.section?.id, dragging: $dragging))
                        }
                        ForEach(group.items) { item in
                            row(item, section: group.section?.id)
                        }
                    }
                }
                Text("Drag a row to move it, also into another section.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                sectionsEditor
            }
        }
        .onAppear(perform: readStacks)
        .onChange(of: dock.items) { readStacks() }
    }

    private func readStacks() {
        let kept = Set(dock.items.map(\.id))
        stacks = StackStore.list().filter { !kept.contains($0.path) }
    }

    // MARK: Adding

    private var addRow: some View {
        FlowRow {
            DockPillButton(title: "App", symbol: "plus") { pick([.application], folders: false) }
            DockPillButton(title: "Folder or File", symbol: "plus") { pick([.item], folders: true) }
            Menu {
                ForEach(stacks, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { dock.addStack(url) }
                }
                if stacks.isEmpty { Text("Every stack is in the dock") }
            } label: { pill("Stack", "square.stack.fill") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                ForEach(Self.tiles, id: \.rawValue) { kind in
                    let title = OwnDockItem(kind: kind, path: "").title
                    Button(dock.hasTile(kind) ? title + " (in the dock)" : title) { dock.addTile(kind) }
                        .disabled(dock.hasTile(kind))
                }
            } label: { pill("Tile", "square.grid.2x2") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            DockPillButton(title: "Small Spacer", symbol: "plus") { dock.addTile(.spacer) }
            DockPillButton(title: "Spacer", symbol: "plus") { dock.addTile(.spacerLarge) }
            DockPillButton(title: "Copy from macOS Dock", symbol: "arrow.down.to.line") { dock.copyFromSystemDock() }
        }
    }

    static let tiles: [OwnDockItem.Kind] = [.clock, .battery, .downloads, .clipboard, .orbit]

    private func pill(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
        }
        .foregroundStyle(DS.Ink.primary)
        .padding(.horizontal, 12).frame(height: 30)
        .background(DS.Ink.fillStrong, in: .capsule)
    }

    private func pick(_ types: [UTType], folders: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = true
        panel.directoryURL = folders ? nil : URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add to Dock"
        if panel.runModal() == .OK { panel.urls.forEach(dock.add) }
    }

    // MARK: Rows

    @ViewBuilder private func header(_ group: Group) -> some View {
        HStack(spacing: 6) {
            if group.section != nil {
                Image(systemName: "square.split.2x1").font(.system(size: 10, weight: .semibold)).foregroundStyle(hue)
            }
            Text(group.title).font(DS.Typo.section)
                .foregroundStyle(group.section == nil ? DS.Ink.tertiary : DS.Ink.secondary)
            Text("\(group.items.count)").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
            Spacer()
        }
        .padding(.top, 8)
        .contentShape(.rect)
        .onDrop(of: [.text], delegate: ItemDrop(target: nil, section: group.section?.id, dragging: $dragging))
    }

    private func roundButton(_ symbol: String, on: Bool = false, size: Double = 11) -> some View {
        Image(systemName: symbol).font(.system(size: size, weight: .semibold))
            .foregroundStyle(on ? hue : DS.Ink.secondary)
            .frame(width: 26, height: 26).background(on ? DS.Ink.fillStrong : DS.Ink.fill, in: .circle)
    }

    private func row(_ item: OwnDockItem, section: UUID?) -> some View {
        let open = expanded == item.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Ink.glyph)
                DockHubItemIcon(item: item).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dock.displayTitle(item)).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    Text(Self.kindTitle(item.kind)).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
                Spacer(minLength: 6)
                if !dock.sections.isEmpty {
                    Menu {
                        ForEach(dock.sections) { target in
                            Button(target.name) { dock.assign(item.id, to: target.id) }.disabled(target.id == item.section)
                        }
                        Divider()
                        Button("No Section") { dock.assign(item.id, to: nil) }.disabled(item.section == nil)
                    } label: {
                        roundButton("square.split.2x1")
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Move \(item.title) to a section")
                }
                if !item.isSpacer {
                    Button { withAnimation(DS.Motion.reveal) { expanded = open ? nil : item.id } } label: {
                        roundButton("slider.horizontal.3", on: open)
                    }
                    .buttonStyle(Pressable(scale: 0.92))
                    .accessibilityLabel("Options for \(item.title)")
                }
                if section == nil {
                    // Any tile, app or stack, goes to either side of the divider.
                    Button { withAnimation(DS.Motion.settle) { dock.setSide(item.id, right: !item.rightSide) } } label: {
                        roundButton(item.rightSide ? "arrow.left" : "arrow.right", size: 10)
                    }
                    .buttonStyle(Pressable(scale: 0.92))
                    .help(item.rightSide ? "Move to the left side" : "Move to the right side")
                    .accessibilityLabel(item.rightSide ? "Move \(item.title) to the left side" : "Move \(item.title) to the right side")
                }
                Button { withAnimation(DS.Motion.settle) { dock.remove(item) } } label: {
                    roundButton("xmark", size: 10)
                }
                .buttonStyle(Pressable(scale: 0.92))
                .accessibilityLabel("Remove \(item.title)")
            }
            .padding(.horizontal, 10).frame(minHeight: 42)
            if open {
                DockHubInspector(item: item)
                    .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(dragging == item.id ? DS.Ink.fillStrong : DS.Ink.fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(open ? hue.opacity(0.45) : .clear, lineWidth: 0.75)
        }
        .onDrag {
            dragging = item.id
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(of: [.text], delegate: ItemDrop(target: item, section: section, dragging: $dragging))
    }

    static func kindTitle(_ kind: OwnDockItem.Kind) -> String {
        switch kind {
        case .app: "App"
        case .stack: "Stack"
        case .file: "File"
        case .folder: "Folder"
        case .smart: "Smart Stack"
        case .spacer: "Small Spacer"
        case .spacerLarge: "Spacer"
        default: "Tile"
        }
    }

    // MARK: Sections

    private var sectionsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(DS.Ink.hairline).frame(height: 0.5).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 2) {
                DockSubhead(text: "Sections")
                Text("Name groups of tiles, like Work or Media. Each starts with a separator.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(dock.sections) { section in
                DockHubSectionRow(section: section,
                                  first: section.id == dock.sections.first?.id,
                                  last: section.id == dock.sections.last?.id)
            }
            HStack(spacing: 8) {
                TextField("New section", text: $newSection)
                    .textFieldStyle(.plain).font(DS.body)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(DS.Ink.fill, in: .capsule)
                    .onSubmit(addSection)
                DockPillButton(title: "Add Section", symbol: "plus", action: addSection)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                Text("Separator").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    .frame(width: DockHubLayout.labelWidth - DS.Space.l, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Segments(selection: $dock.hub.sectionStyle, options: DockSectionStyle.allCases.map { ($0, $0.title) })
                    Text((dock.hub.sectionStyle == .label ? "A line, and the section's name in small type over its tiles."
                         : dock.hub.sectionStyle == .gap ? "Just a little room. Names show while you arrange."
                         : "Names show over each section while you arrange.") + " The dock's own separators use it too.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func addSection() {
        dock.addSection(named: newSection)
        newSection = ""
    }
}

/// The rest of the bar, the parts the dock fills by itself, grouped as on the bar: open and
/// recent apps with Keep in Dock, minimised windows, then Now Vitals and the Trash. Each group
/// carries its own switch here, so there is one place for it. A card of its own, so the
/// chapter's lazy stack builds it when it scrolls in.
struct DockHubBarContentsCard: View {
    @ObservedObject private var dock = OwnDock.shared
    @ObservedObject private var live = OwnDock.shared.live
    @ObservedObject private var access = DockAccessWatch.shared
    @State private var allOpen = false
    /// Bumped when apps open or quit, which the dock does not publish.
    @State private var apps = 0
    private static let fold = 6
    private let hue = DockHubHue.tint

    /// What the dock adds by itself, from the same list the bar draws.
    private struct Extras {
        var open: [DockSlot] = []
        var recent: [DockSlot] = []
        var windows: [DockSlot] = []
        var shown = 0
    }

    private var extras: Extras {
        _ = apps
        _ = live.version
        var extras = Extras()
        for slot in dock.slots() where !slot.empty {
            extras.shown += 1
            guard !slot.pinned else { continue }
            switch slot.kind {
            case .app: if slot.recent { extras.recent.append(slot) } else { extras.open.append(slot) }
            case .window: extras.windows.append(slot)
            default: break
            }
        }
        return extras
    }

    var body: some View {
        let extras = extras
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text("Also on the Bar").font(DS.title).foregroundStyle(DS.Ink.primary)
                    Text("\(extras.shown) tiles in all").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                    Spacer()
                }
                groups(extras)
            }
        }
        .watchingDockAccess()
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in apps &+= 1 }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in apps &+= 1 }
    }

    // MARK: What the dock adds itself

    @ViewBuilder private func groups(_ extras: Extras) -> some View {
        autoHeader("Open Apps", detail: "Running, not kept.", on: $dock.showRunning)
        if dock.showRunning {
            if extras.open.isEmpty { quiet("Every open app is kept.") }
            ForEach(extras.open.prefix(allOpen ? .max : Self.fold)) { slot in
                autoRow(slot, caption: "Open") {
                    DockPillButton(title: "Keep in Dock", symbol: "pin") { dock.add(URL(fileURLWithPath: slot.path)) }
                }
            }
        }
        if dock.showRunning, extras.open.count > Self.fold {
            Button { withAnimation(DS.Motion.reveal) { allOpen.toggle() } } label: {
                Text(allOpen ? "Show Fewer" : "Show \(extras.open.count - Self.fold) More")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(hue)
            }
            .buttonStyle(Pressable()).padding(.horizontal, 10)
        }
        autoHeader("Recent Apps", detail: "Used lately, not kept and not open.", on: $dock.appearance.recents)
        if dock.appearance.recents {
            HStack(spacing: DS.Space.m) {
                Text("How many").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                Segments(selection: $dock.appearance.recentCount, options: (1...6).map { ($0, "\($0)") })
                    .accessibilityLabel("How many recent apps")
            }
            if extras.recent.isEmpty { quiet(dock.appearance.runningOnly ? "Hidden while Open Apps Only is on." : "None yet.") }
            ForEach(extras.recent) { slot in
                autoRow(slot, caption: "Recent") {
                    DockPillButton(title: "Keep in Dock", symbol: "pin") { dock.add(URL(fileURLWithPath: slot.path)) }
                }
            }
        }
        autoHeader("Minimised Windows", detail: "Each with its title and its app's icon.", on: $dock.appearance.minimized)
        if dock.appearance.minimized {
            DockNeedsAccess()
            if extras.windows.isEmpty, access.trusted { quiet("No windows are minimised.") }
            ForEach(extras.windows) { slot in
                autoRow(slot, caption: "Minimised") {
                    DockPillButton(title: "Restore", symbol: "arrow.up.left.and.arrow.down.right") { dock.activateSlot(slot.id) }
                }
            }
        }
        autoHeader("End of the Bar", detail: nil, on: nil)
        systemRow("Now Vitals", detail: "Live readings of your Mac. Set it up below.", symbol: "gauge.with.dots.needle.33percent",
                  on: $dock.showVitals)
        systemRow("Trash", detail: "Always last. Drop files on it to trash them.", symbol: "trash",
                  on: Binding(get: { dock.showsTrash }, set: { dock.appearance.showTrash = $0 }))
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Open Apps Only", detail: "Kept tiles show only while they are open.", density: .compact) {
                LuxSwitch(isOn: $dock.appearance.runningOnly, label: "Open Apps Only", tint: hue)
            }
            .dockHubRow()
            .help("Kept apps, stacks, files and tiles show only while they are open.")
            Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
            SettingRow(title: "Separators", detail: "Thin lines between kept, open and recent apps.", density: .compact) {
                LuxSwitch(isOn: $dock.appearance.divider, label: "Separators", tint: hue)
            }
            .dockHubRow()
            .help("Thin lines between kept apps, open apps, recent apps and the right side.")
        }
        .padding(.top, 6)
    }

    private func autoHeader(_ title: String, detail: String?, on: Binding<Bool>?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Typo.section).foregroundStyle(DS.Ink.primary.opacity(0.92))
                if let detail { Text(detail).font(DS.caption).foregroundStyle(DS.Ink.tertiary) }
            }
            Spacer()
            if let on { LuxSwitch(isOn: on, label: title, tint: hue) }
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(DS.caption).foregroundStyle(DS.Ink.tertiary).padding(.horizontal, 10).frame(minHeight: 26)
    }

    private func autoRow(_ slot: DockSlot, caption: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: DockIcons.image(slot.path)).resizable().interpolation(.high).frame(width: 24, height: 24)
                .overlay(alignment: .bottomTrailing) {
                    if slot.kind == .window {
                        Image(systemName: "minus.square.fill").font(.system(size: 9)).foregroundStyle(.white)
                            .background(Circle().fill(.black.opacity(0.5)).frame(width: 12, height: 12))
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(slot.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                Text(caption).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
            Spacer(minLength: 6)
            action()
        }
        .padding(.horizontal, 10).frame(minHeight: 42)
        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func systemRow(_ title: String, detail: String, symbol: String, on: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on.wrappedValue ? hue : DS.Ink.secondary)
                .frame(width: 24, height: 24)
                .background(DS.Ink.fillStrong, in: .rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                Text(detail).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            LuxSwitch(isOn: on, label: title, tint: hue)
        }
        .padding(.horizontal, 10).frame(minHeight: 44)
        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
    }

}

private struct ItemDrop: DropDelegate {
    let target: OwnDockItem?
    let section: UUID?
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target?.id else { return }
        MainActor.assumeIsolated {
            let dock = OwnDock.shared
            guard let moving = dock.items.first(where: { $0.id == dragging }) else { return }
            // Dropped on the other side of the divider: it moves to that side, then into place.
            if section == nil, let target, target.rightSide != moving.rightSide {
                withAnimation(DS.Motion.settle) {
                    dock.setSide(dragging, right: target.rightSide)
                    dock.move(dragging, before: target.id, section: nil)
                }
                return
            }
            withAnimation(DS.Motion.settle) { dock.move(dragging, before: target?.id, section: section) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct DockHubSectionRow: View {
    let section: DockSection
    let first: Bool
    let last: Bool
    @State private var name = ""

    var body: some View {
        let dock = OwnDock.shared
        HStack(spacing: 8) {
            Image(systemName: "square.split.2x1").font(.system(size: 11)).foregroundStyle(DockHubHue.tint)
            TextField("Name", text: $name)
                .textFieldStyle(.plain).font(DS.Typo.rowTitle)
                .onSubmit { dock.renameSection(section.id, to: name) }
            Text("\(dock.items.filter { $0.section == section.id }.count)").font(DS.Typo.value)
                .foregroundStyle(DS.Ink.tertiary)
            Button { dock.moveSection(section.id, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 22) }
                .buttonStyle(Pressable()).disabled(first).accessibilityLabel("Move \(section.name) up")
            Button { dock.moveSection(section.id, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 22) }
                .buttonStyle(Pressable()).disabled(last).accessibilityLabel("Move \(section.name) down")
            Button { withAnimation(DS.Motion.settle) { dock.removeSection(section.id) } } label: {
                Image(systemName: "trash").foregroundStyle(DS.Ink.secondary).frame(width: 22, height: 22)
            }
            .buttonStyle(Pressable()).accessibilityLabel("Remove section \(section.name). Its tiles stay in the dock.")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(DS.Ink.secondary)
        .padding(.horizontal, 10).frame(height: 36)
        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .onAppear { name = section.name }
        .onChange(of: section.name) { _, new in name = new }
    }
}

/// The icon a row shows: the file's own icon from the cache, or the tile's symbol.
struct DockHubItemIcon: View {
    let item: OwnDockItem

    var body: some View {
        if item.isTile {
            Image(systemName: Self.symbol(item)).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Ink.primary)
                .frame(width: 24, height: 24)
                .background(DS.Ink.fillStrong, in: .rect(cornerRadius: 7, style: .continuous))
        } else {
            BitmapIcon(image: DockIcons.image(item.path))
        }
    }

    static func symbol(_ item: OwnDockItem) -> String {
        switch item.kind {
        case .clock: "clock"
        case .battery: "battery.75percent"
        case .downloads: "arrow.down.circle"
        case .clipboard: "doc.on.clipboard"
        case .orbit: "circle.hexagongrid"
        case .smart: OwnDock.shared.smart[item.id]?.source.symbol ?? "sparkles"
        case .spacer, .spacerLarge: "space"
        default: "square"
        }
    }
}

// MARK: - Inspector

/// A tile's options. Only what fits its kind is shown.
struct DockHubInspector: View {
    let item: OwnDockItem
    @ObservedObject private var dock = OwnDock.shared
    @State private var library = false

    private var options: Binding<DockTileOptions> {
        let id = item.id
        return Binding(get: { OwnDock.shared.options(for: id) }, set: { OwnDock.shared.setOptions($0, for: id) })
    }

    private var glyph: Bool { [.clock, .battery, .downloads, .clipboard, .orbit, .smart].contains(item.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
            line("Size") { Segments(selection: options.size, options: DockTileSize.allCases.map { ($0, $0.title) }) }
            if glyph {
                line("Style") { Segments(selection: options.look, options: DockTileLook.allCases.map { ($0, $0.title) }) }
            }
            toggle("Name Under Icon", options.caption)
            switch item.kind {
            case .clock:
                line("Face") { Segments(selection: options.analog, options: [(false, "Digital"), (true, "Analog")]) }
                line("Hours") { Segments(selection: options.hours, options: DockClockHours.allCases.map { ($0, $0.title) }) }
                toggle("Seconds", options.seconds)
                toggle("Date", options.date)
            case .battery:
                line("Shows") { Segments(selection: options.battery, options: DockBatteryShows.allCases.map { ($0, $0.title) }) }
            case .downloads:
                toggle("Progress Ring", options.ring)
                toggle("Download Count", options.count)
                folderOptions(display: false)
            case .folder:
                folderOptions(display: true)
            case .stack, .smart:
                HStack(spacing: 10) {
                    Text(item.kind == .smart ? "What it shows, its layout and sorting are set in Stacks."
                         : "Its layout, icon and sorting are set in Stacks.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    DockPillButton(title: "Open in Stacks", symbol: "arrow.right") {
                        ManagerWindow.shared.show(chapter: Chapter.stacks.rawValue)
                    }
                }
            case .app:
                field("Launch Arguments", "--incognito", options.arguments)
                field("Open a URL", "https://…", options.url)
                toggle("Quick Actions", options.quickActions, detail: "A few of the app's menu commands in its right-click menu.",
                       help: "Read through Accessibility.")
            default:
                EmptyView()
            }
            if item.kind != .app {
                line("Click") {
                    DockMenuPill(selection: options.click, options: DockClickAction.allCases.filter { action in
                        action != .finder || !item.isTile || item.kind == .downloads
                    }.map { ($0, $0.title) })
                }
                if options.wrappedValue.click == .url { field("URL", "https://…", options.target) }
                if options.wrappedValue.click == .app {
                    HStack {
                        Text(options.wrappedValue.target.isEmpty ? "No app chosen"
                             : URL(fileURLWithPath: options.wrappedValue.target).deletingPathExtension().lastPathComponent)
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        Spacer()
                        DockPillButton(title: "Choose App…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.application]
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            if panel.runModal() == .OK, let url = panel.url { options.wrappedValue.target = url.path }
                        }
                    }
                }
            }
            if !item.isSpacer {
                HStack(spacing: 8) {
                    // A stack's name and icon are set in Stacks, with the rest of it.
                    if item.kind != .stack, item.kind != .smart {
                    DockPillButton(title: "Rename…", symbol: "character.cursor.ibeam") {
                        dock.rename(item.id, original: item.title)
                    }
                    Menu {
                        Button("Choose a Picture…") { dock.chooseIcon(for: item.id, title: item.title) }
                        if IconLibrary.available {
                            Button("Find in Icon Library…") { library = true }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "photo").font(.system(size: 11, weight: .semibold))
                            Text("Icon…").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(DS.Ink.primary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(DS.Ink.fillStrong, in: .capsule)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Icon for \(item.title)")
                    .popover(isPresented: $library) {
                        IconLibraryPicker(query: dock.displayTitle(item)) { image in
                            dock.setIcon(image, for: item.id)
                            library = false
                        }
                        .frame(width: 400, height: 420).padding(14)
                    }
                    }
                    if dock.customs[item.id] != nil || !options.wrappedValue.isDefault {
                        DockPillButton(title: "Reset") {
                            dock.resetCustom(item.id)
                            dock.setOptions(DockTileOptions(), for: item.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func folderOptions(display: Bool) -> some View {
        line("Sort By") { DockMenuPill(selection: options.sort, options: DockSort.allCases.map { ($0, $0.title) }) }
        line("View As") { layoutPicker }
        if display {
            line("Display As") { Segments(selection: options.folderLook, options: DockFolderLook.allCases.map { ($0, $0.title) }) }
            toggle("Item Count", options.badge)
        }
        toggle("Open on Hover", options.openOnHover)
    }

    private var layoutPicker: some View {
        DockMenuPill(selection: Binding(get: { options.wrappedValue.layout ?? .grid }, set: { options.wrappedValue.layout = $0 }),
                     options: DockStackLayout.allCases.map { ($0, $0.title) })
    }

    private func line(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.secondary).frame(width: 112, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    private func toggle(_ title: String, _ value: Binding<Bool>, detail: String? = nil, help: String? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.secondary)
                if let detail {
                    Text(detail).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            LuxSwitch(isOn: value, label: title, tint: DockHubHue.tint)
        }
        .help(help ?? "")
    }

    private func field(_ title: String, _ prompt: String, _ value: Binding<String>) -> some View {
        line(title) { DockCommitField(prompt: prompt, value: value) }
    }
}

/// A text field that saves on Return or when it goes, not on every key.
struct DockCommitField: View {
    let prompt: String
    @Binding var value: String
    @State private var text = ""

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain).font(DS.body)
            .padding(.horizontal, 10).frame(height: 28)
            .background(DS.Ink.fill, in: .capsule)
            .onSubmit { value = text }
            .onAppear { text = value }
            .onDisappear { if text != value { value = text } }
    }
}

// MARK: - Hover

struct DockHubHoverCard: View {
    @ObservedObject private var dock = OwnDock.shared
    @ObservedObject private var permissions = DockPermissions.shared
    private let hue = DockHubHue.tint

    var body: some View {
        RowGroup {
            DockHubWideRow("On Hover", detail: "What a tile shows while the pointer rests on it.") {
                VStack(alignment: .leading, spacing: 6) {
                    Segments(selection: $dock.appearance.hover, options: DockHover.allCases.map { ($0, $0.title) })
                    Segments(selection: $dock.appearance.labelPosition, options: DockLabelPosition.allCases.map { ($0, $0.title) })
                        .disabled(dock.appearance.hover == .none).opacity(dock.appearance.hover == .none ? 0.45 : 1)
                }
            }
            SettingRow(title: "Window Previews",
                       detail: "Live Peek shows each window as a still picture. Click one to bring it forward.",
                       density: .compact) {
                LuxSwitch(isOn: $dock.hub.windowPreviews, label: "Window Previews", tint: hue)
            }
            .dockHubRow()
            .help("Atelier takes one picture per window when the pointer rests on the tile, never a recording, keeps it in memory for a few seconds, and saves nothing. It uses Screen Recording, so macOS may show its recording indicator for a moment.")
            .disabled(dock.appearance.hover != .peek)
            .opacity(dock.appearance.hover == .peek ? 1 : 0.45)
            // Kept current while the page is open: a grant shows here, and in the dock, at once.
            if dock.hub.windowPreviews, !permissions.screen {
                DockPermissionNote(kind: .screen, sentence: "Window pictures need Screen Recording. Until then Live Peek shows each window's icon and title.")
                    .dockHubRow()
            }
            if dock.hub.windowPreviews, !permissions.trusted {
                DockPermissionNote(kind: .accessibility, sentence: "Window titles, minimised windows and picking a window need Accessibility.")
                    .dockHubRow()
            }
        }
    }
}

// MARK: - Shortcuts

struct DockHubShortcutsCard: View {
    var body: some View {
        DockHubShortcutRows()
    }
}


/// The tiles the dock makes itself rather than keeps: the Trash, Vitals and minimised windows.
/// Each can be given its own icon; Vitals sets its readings, style, pace and click.
struct DockOwnTilesCard: View {
    @ObservedObject private var dock = OwnDock.shared

    private var region: CGRect { StageRegion.ownDock(dock.edge) }

    var body: some View {
        // Showing or hiding these lives in the item list above; here they get their look.
        RowGroup {
            tileRow("Trash", detail: "At the far end, like the macOS Dock.", symbol: "trash", id: "trash")
            tileRow("Vitals", detail: dock.showVitals ? "Replaces the live face with a picture." : "Turn on Now Vitals above to see it.",
                    symbol: "gauge.with.dots.needle.67percent", id: "vitals")
            if dock.showVitals, !dock.hasOwnIcon("vitals") { DockVitalsSettingsView() }
        }
        // The Vitals tile's "Vitals Options…" and `atelier://studio?chapter=dock&focus=vitals`.
        .navTarget(Self.vitalsTarget)
    }

    nonisolated static let vitalsTarget = "vitals"

    private func tileRow(_ title: String, detail: String, symbol: String, id: String) -> some View {
        SettingRow(title: title + " Icon", detail: detail, symbol: symbol, density: .compact) {
            IconChooserMenu(query: title, canReset: dock.hasOwnIcon(id),
                            onPick: { dock.setIcon($0, for: id) },
                            onReset: { dock.resetIcon(id) })
        }
        .dockHubRow()
        .stagePreview(.focus("dock.own." + title, title, region: region))
    }
}
