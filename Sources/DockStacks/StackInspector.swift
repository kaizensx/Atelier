import AppKit
import DockCore
import SwiftUI

// One inspector for every stack, in either dock: what it holds, its icon, its bubble and
// how it behaves. Four short tabs, so no screen runs long and no control appears twice.

enum StackTab: String, CaseIterable, Identifiable {
    case content, icon, bubble, behaviour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .content: "Content"
        case .icon: "Icon"
        case .bubble: "Bubble"
        case .behaviour: "Behaviour"
        }
    }
}

/// Rows in the inspector share one look.
@MainActor
enum StackRow {
    static func line(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.secondary)
                .frame(width: 112, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }

    static func toggle(_ title: String, _ value: Binding<Bool>, detail: String? = nil) -> some View {
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
        .frame(minHeight: 30)
    }

    static func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ shown: String) -> some View {
        line(title) {
            LuxSlider(value: value, range: range, label: title, tint: DockHubHue.tint).frame(maxWidth: 220).frame(height: 22)
            Text(shown).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary).fixedSize().frame(minWidth: 48, alignment: .leading)
        }
    }

    static func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(DS.Typo.section).foregroundStyle(DS.Ink.primary.opacity(0.92))
            content()
        }
    }

    static func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func pickImage() -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Picture"
        return panel.runModal() == .OK ? panel.url.flatMap { NSImage(contentsOf: $0) } : nil
    }

    /// Keeps a picture in Application Support and returns its path.
    static func keep(_ image: NSImage) -> String? {
        DockCustomStore.store(image).map { DockCustomStore.folder.appendingPathComponent($0).path }
    }
}

// MARK: - Content

/// What a Smart Stack reads from. The presets include the old Live Stacks' searches.
struct StackSourceEditor: View {
    @Binding var smart: StackSmart
    @Binding var name: String

    static let presets: [(String, String)] = [
        ("Recent Images", "kMDItemContentTypeTree == \"public.image\" && kMDItemFSContentChangeDate >= $time.today(-30)"),
        ("Recent PDFs", "kMDItemContentType == \"com.adobe.pdf\" && kMDItemFSContentChangeDate >= $time.today(-30)"),
        ("Screenshots", "kMDItemIsScreenCapture == 1"),
        ("Videos", "kMDItemContentTypeTree == \"public.movie\""),
        ("New Apps", "kMDItemContentType == \"com.apple.application-bundle\" && kMDItemDateAdded >= $time.today(-30)"),
        ("Changed Today", "modified today"),
        ("Presentations", "kind:presentation"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StackRow.line("Shows") {
                DockMenuPill(selection: $smart.source, options: StackSource.allCases.map { ($0, $0.title) })
            }
            if smart.source == .folder {
                StackRow.line("Folder") {
                    Text(smart.folder.isEmpty ? "None chosen" : FileManager.default.displayName(atPath: smart.folder))
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                    DockPillButton(title: "Choose…") { if let path = StackRow.pickFolder() { smart.folder = path } }
                }
            }
            if smart.source == .spotlight {
                StackRow.line("Search") { DockCommitField(prompt: "kind:image modified this week", value: $smart.query) }
                FlowRow {
                    ForEach(Self.presets, id: \.0) { title, query in
                        Chip(title) {
                            smart.query = query
                            if name.isEmpty || Self.presets.contains(where: { $0.0 == name }) { name = title }
                        }
                    }
                }
                Text("Words match names. Add kind:, modified or created, or a raw query with ==.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                    .help("Words match names. kind: image, movie, audio, pdf, document, app, folder, presentation, spreadsheet, code. modified or created today, this week, this month. A query with == goes to Spotlight as it is.")
            }
        }
    }
}

/// Sort, filters, limit and grouping: the same for every stack.
struct StackContentRules: View {
    @Binding var style: StackStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StackRow.line("Sort By") { DockMenuPill(selection: $style.sort, options: StackSort.allCases.map { ($0, $0.title) }) }
            StackRow.line("Kinds") {
                FlowRow {
                    ForEach(StackKind.allCases) { kind in
                        let on = style.kinds.contains(kind)
                        Button {
                            if on { style.kinds.removeAll { $0 == kind } } else { style.kinds.append(kind) }
                        } label: {
                            Text(kind.title).font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(on ? DS.Ink.primary : DS.Ink.secondary)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(on ? DockHubHue.tint.opacity(0.22) : DS.Ink.fill, in: .capsule)
                                .overlay { Capsule().strokeBorder(on ? DockHubHue.tint.opacity(0.7) : .clear, lineWidth: 0.75) }
                        }
                        .buttonStyle(Pressable(scale: 0.95))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            if style.kinds.isEmpty {
                Text("Every kind shows. Pick kinds to show only those.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
            StackRow.line("Changed") { DockMenuPill(selection: $style.age, options: StackAge.allCases.map { ($0, $0.title) }) }
            StackRow.line("At Most") {
                DockMenuPill(selection: $style.limit, options: [(0, "All"), (12, "12"), (24, "24"), (40, "40"), (60, "60")])
            }
            StackRow.toggle("Group by Kind", $style.groupByKind)
        }
    }
}

// MARK: - Icon

/// A stack's icon: its apps in a grid, text, a symbol, or a picture, including one from
/// the macOSicons library.
struct StackIconEditor: View {
    @Binding var icon: IconSpec
    let title: String
    let items: [StackItem]
    @State private var library = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: IconRenderer.image(icon, title: title, items: items)).resizable().interpolation(.high)
                    .frame(width: 58, height: 58)
                    .padding(6)
                    .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                Segments(selection: $icon.style, options: IconStyle.allCases.map { ($0, $0.title) })
            }
            switch icon.style {
            case .text:
                StackRow.line("Text") { DockCommitField(prompt: title, value: $icon.text) }
            case .symbol:
                StackRow.line("Symbol") { DockCommitField(prompt: "sparkles", value: $icon.symbol) }
            case .image, .apps:
                EmptyView()
            }
            if icon.style != .image {
                StackRow.line("Colour") {
                    HStack(spacing: 4) {
                        ForEach(Palette.colors.indices, id: \.self) { index in
                            Button { icon.color = index } label: {
                                Circle().fill(Color(nsColor: Palette.colors[index])).frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(.white.opacity(icon.color == index ? 0.95 : 0.12),
                                                                   lineWidth: icon.color == index ? 2 : 0.5))
                                    .frame(width: 28, height: 28).contentShape(Circle())
                            }
                            .buttonStyle(Pressable(scale: 0.9))
                            .accessibilityLabel("Colour \(index + 1)")
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                DockPillButton(title: "Icon Library…", symbol: "magnifyingglass") { library = true }
                    .popover(isPresented: $library) {
                        IconLibraryPicker(query: title) { image in
                            if let path = StackRow.keep(image) { icon.image = path; icon.style = .image }
                            library = false
                        }
                        .frame(width: 400, height: 420).padding(14)
                    }
                DockPillButton(title: "Choose Picture…", symbol: "photo") {
                    if let image = StackRow.pickImage(), let path = StackRow.keep(image) { icon.image = path; icon.style = .image }
                }
            }
        }
    }
}

// MARK: - Bubble

struct StackBubbleEditor: View {
    @Binding var style: StackStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StackRow.group("Layout") {
                StackRow.line("View As") { DockMenuPill(selection: $style.layout, options: StackLayout.allCases.map { ($0, $0.title) }) }
                StackRow.slider("Icon Size", $style.iconSize, StackStyle.iconSizes, "\(Int(style.iconSize)) pt")
                if style.layout == .grid || style.layout == .honeycomb {
                    StackRow.line("Columns") {
                        DockMenuPill(selection: $style.columns, options: [(0, "Automatic")] + (2...8).map { ($0, "\($0)") })
                    }
                }
                StackRow.slider("Bubble Size", $style.scale, StackStyle.scales, "\(Int((style.scale * 100).rounded()))%")
            }
            StackRow.group("Surface") {
                StackRow.line("Material") { Segments(selection: $style.material, options: StackMaterial.allCases.map { ($0, $0.title) }) }
                StackRow.line("Tint") { tints }
                if style.material == .frosted || !style.background.isEmpty {
                    StackRow.slider("Blur", $style.blur, 0...1, "\(Int((style.blur * 100).rounded()))%")
                }
                StackRow.slider("Corners", $style.radius, StackStyle.radii, "\(Int(style.radius)) pt")
                StackRow.line("Background") {
                    DockPillButton(title: style.background.isEmpty ? "Choose Picture…" : "Change…") {
                        if let image = StackRow.pickImage(), let path = StackRow.keep(image) { style.background = path }
                    }
                    if !style.background.isEmpty { DockPillButton(title: "Remove") { style.background = "" } }
                }
                if !style.background.isEmpty {
                    StackRow.slider("Picture", $style.backgroundOpacity, 0...1, "\(Int((style.backgroundOpacity * 100).rounded()))%")
                }
            }
            StackRow.group("Opening") {
                StackRow.line("Animation") {
                    DockMenuPill(selection: Binding(get: { style.animation }, set: { style.animation = $0 }), options: StackOpenAnimation.allCases.map { ($0, $0.title) })
                }
            }
        }
    }

    private var tints: some View {
        HStack(spacing: 4) {
            Chip(style.tint == -1 ? "• Auto" : "Auto") { style.tint = -1 }
            Chip(style.tint == -2 ? "• None" : "None") { style.tint = -2 }
            ForEach(Palette.colors.indices.dropFirst(), id: \.self) { index in
                Button { style.tint = index } label: {
                    Circle().fill(Color(nsColor: Palette.colors[index])).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white.opacity(style.tint == index ? 0.95 : 0.12), lineWidth: style.tint == index ? 2 : 0.5))
                        .frame(width: 24, height: 24).contentShape(Circle())
                }
                .buttonStyle(Pressable(scale: 0.9))
                .accessibilityLabel("Tint \(index)")
            }
        }
    }
}

// MARK: - Behaviour

struct StackBehaviourEditor: View {
    @Binding var style: StackStyle
    /// The stack is in the Atelier Dock, where hovering can open it.
    let atelier: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StackRow.group("Opening") {
                StackRow.toggle("Open on Hover", $style.hoverOpen,
                                detail: atelier ? nil : "Works in the Atelier Dock. The macOS Dock opens stacks on click.")
                if style.hoverOpen {
                    StackRow.slider("Delay", $style.hoverDelay, StackStyle.delays, String(format: "%.2f s", style.hoverDelay))
                }
            }
            StackRow.group("Items") {
                StackRow.toggle("Names", $style.labels)
                StackRow.toggle("Badges", $style.badges, detail: "A count on groups, a dot on apps that are open.")
                StackRow.toggle("Open Folders Inside", $style.nested, detail: "A folder in the stack opens in the bubble, with Back to return.")
                StackRow.toggle("Quick Actions", $style.quickActions, detail: "Open With, Show in Finder and Copy Path on a secondary click.")
            }
            StackRow.group("Keyboard") {
                StackRow.toggle("Type to Search", $style.search)
                StackRow.toggle("Arrow Keys and Return", $style.keyboard)
            }
        }
    }
}

/// The four tabs over one stack's values. The caller decides where they are saved.
struct StackTabs: View {
    @Binding var style: StackStyle
    @Binding var icon: IconSpec
    let title: String
    let items: [StackItem]
    let atelier: Bool
    /// Content that is not shared: the items, or the smart source.
    let content: AnyView
    /// Tile options that only exist in the Atelier Dock.
    var tile: AnyView?
    @State private var tab = StackTab.content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Segments(selection: $tab, options: StackTab.allCases.map { ($0, $0.title) })
            Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
            switch tab {
            case .content:
                content
                StackContentRules(style: $style)
            case .icon:
                StackIconEditor(icon: $icon, title: title, items: items)
                if let tile { tile }
            case .bubble:
                StackBubbleEditor(style: $style)
            case .behaviour:
                StackBehaviourEditor(style: $style, atelier: atelier)
            }
        }
    }
}

/// How a stack tile looks on the Atelier Dock's bar. Stored with the tile, as before.
struct StackTileOptions: View {
    let id: String
    let smart: Bool
    @ObservedObject private var dock = OwnDock.shared

    private var options: Binding<DockTileOptions> {
        let id = id
        return Binding(get: { OwnDock.shared.options(for: id) }, set: { OwnDock.shared.setOptions($0, for: id) })
    }

    var body: some View {
        StackRow.group("In the Atelier Dock") {
            if !smart {
                StackRow.line("Tile Shows") {
                    Segments(selection: options.folderLook, options: [(.folder, "Stack Icon"), (.stack, "Newest Items")])
                }
                StackRow.toggle("Item Count", options.badge)
            }
            StackRow.toggle("Name Under Tile", options.caption)
        }
    }
}
