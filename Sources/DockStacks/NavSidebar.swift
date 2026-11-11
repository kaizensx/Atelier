import AppKit
import SwiftUI

/// The Studio's navigation: sections of places from `NavRegistry`, and one search field (⌘F) that
/// finds any place or setting. Liquid Glass, left of the stage. Collapses to a rail of symbols
/// (⌃⌘S); in a narrow window it stays a rail and opens over the stage only while you search.
///
/// The stage never lays out again for it: the sidebar's width only moves the stage's viewport, and
/// the stage is laid out once at its base size and scaled (see `StudioLayout`).
struct NavSidebar: View {
    @ObservedObject var model: ManagerModel
    /// The width the stage makes room for.
    let collapsed: Bool
    /// The window is too narrow for the full sidebar beside the stage.
    let narrow: Bool
    let toggle: () -> Void

    @State private var query = ""
    @State private var results: [NavEntry] = []
    @State private var selection = 0
    /// Open over the stage for a moment, from the rail.
    @State private var peek = false
    @FocusState private var searching: Bool
    @AppStorage("studio.nav.folded") private var folded = ""
    /// Which places have something on. Publishes only when a feature turns on or off.
    @ObservedObject private var lit = NavLitState.shared

    /// Sections with something in them, built once.
    @MainActor private static let sections: [(NavSection, [NavItem])] = NavSection.allCases.compactMap { section in
        let items = NavRegistry.items(in: section)
        return items.isEmpty ? nil : (section, items)
    }

    private var rail: Bool { collapsed && !peek }

    var body: some View {
        VStack(spacing: 8) {
            // The window's traffic lights sit in the glass here.
            Color.clear.frame(height: 26)
            if rail { railHeader } else { header }
            if rail {
                railList
            } else if query.isEmpty {
                list
            } else {
                resultList
            }
        }
        .frame(width: rail ? StudioLayout.rail : StudioLayout.sidebar)
        .frame(maxHeight: .infinity, alignment: .top)
        .atelierGlass(.regular.tint(.black.opacity(0.2)), in: .rect(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(peek ? 0.4 : 0), radius: 30, x: 10)
        .animation(DS.Motion.arrive, value: rail)
        .background { shortcuts }
        .onChange(of: query) { _, text in
            results = NavIndex.search(text)
            selection = 0
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                TextField("Search settings", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($searching)
                    .onSubmit { pick(selection) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onExitCommand { endSearch() }
                    .accessibilityLabel("Search settings")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(DS.Ink.tertiary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
                } else {
                    Text("⌘F").font(.system(size: 10.5, weight: .medium)).foregroundStyle(DS.Ink.tertiary)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(DS.Ink.fill, in: .capsule)
            Button(action: sidebarButton) {
                Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                    .frame(width: 30, height: 30).contentShape(.rect)
            }
            .buttonStyle(Pressable(scale: 0.92))
            .help(peek ? "Close" : "Hide Sidebar (⌃⌘S)")
            .accessibilityLabel(peek ? "Close sidebar" : "Hide sidebar")
        }
        .padding(.horizontal, 10)
    }

    private var railHeader: some View {
        VStack(spacing: 4) {
            railButton("sidebar.left", narrow ? "Show Places" : "Show Sidebar (⌃⌘S)", action: sidebarButton)
            railButton("magnifyingglass", "Search Settings (⌘F)") { startSearch() }
        }
    }

    private func railButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                .frame(width: 40, height: 30).contentShape(.rect)
        }
        .buttonStyle(Pressable(scale: 0.92))
        .help(help)
        .accessibilityLabel(help)
    }

    /// ⌘F and ⌃⌘S, wherever focus is in the window.
    private var shortcuts: some View {
        ZStack {
            Button("Search Settings") { startSearch() }.keyboardShortcut("f", modifiers: .command)
            Button("Toggle Sidebar") { sidebarButton() }.keyboardShortcut("s", modifiers: [.control, .command])
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Places

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Self.sections, id: \.0) { section, items in
                    sectionHeader(section)
                    if !isFolded(section) {
                        ForEach(items) { item in
                            NavRow(symbol: item.symbol, title: item.title, selected: model.chapter == item.chapter, compact: false, hue: section.hue,
                                   lit: lit.chapters.contains(item.chapter.rawValue), unavailable: item.availability().isUsable ? nil : item.availability().note) {
                                open(item)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 14)
        }
        .scrollIndicators(.never)
    }

    private var railList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Self.sections, id: \.0) { section, items in
                    Capsule().fill(DS.Ink.hairline).frame(width: 18, height: 1).padding(.vertical, 5)
                        .accessibilityHidden(true)
                    ForEach(items) { item in
                        NavRow(symbol: item.symbol, title: item.title, selected: model.chapter == item.chapter, compact: true, hue: section.hue,
                                   lit: lit.chapters.contains(item.chapter.rawValue), unavailable: item.availability().isUsable ? nil : item.availability().note) {
                            open(item)
                        }
                    }
                }
            }
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private func sectionHeader(_ section: NavSection) -> some View {
        Button {
            withAnimation(DS.Motion.arrive) { setFolded(section, !isFolded(section)) }
        } label: {
            HStack(spacing: 4) {
                Text(section.rawValue).font(DS.Typo.section).foregroundStyle(DS.Ink.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
                    .rotationEffect(.degrees(isFolded(section) ? -90 : 0))
            }
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isFolded(section) ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }

    private func isFolded(_ section: NavSection) -> Bool { folded.split(separator: "|").contains { $0 == section.id } }

    private func setFolded(_ section: NavSection, _ value: Bool) {
        var set = Set(folded.split(separator: "|").map(String.init))
        if value { set.insert(section.id) } else { set.remove(section.id) }
        folded = set.sorted().joined(separator: "|")
    }

    // MARK: Search

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if results.isEmpty {
                        Text("Nothing matches “\(query)”. Try another word, like “dock” or “screenshot”.")
                            .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                        NavResultRow(entry: entry, selected: index == selection) { pick(index) }
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .onChange(of: selection) { _, index in
                if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
            }
        }
    }

    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + step + results.count) % results.count
    }

    private func pick(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selection = index
        NavFocus.shared.reveal(results[index], in: model)
        if peek { endSearch() }
    }

    private func startSearch() {
        if collapsed { peek = true }
        DispatchQueue.main.async { searching = true }
    }

    private func endSearch() {
        query = ""
        searching = false
        peek = false
    }

    private func open(_ item: NavItem) {
        model.go(item.chapter)
        if peek { peek = false }
    }

    private func sidebarButton() {
        if peek { endSearch() } else if narrow { peek = true } else { toggle() }
    }
}

/// A place in the sidebar. Its own hover state, so the pointer redraws one row, not the list.
/// A place in the sidebar: a capsule (sidebar 24 − inset 8 = 16 = half its height), its family's
/// light when selected, and a lit dot while something in it is on.
struct NavRow: View {
    let symbol: String
    let title: String
    let selected: Bool
    let compact: Bool
    var hue: Color
    var lit: Bool
    /// Why this place cannot work on this Mac, when it cannot: the row dims and says so.
    var unavailable: String?
    let action: () -> Void
    @State private var hover = false

    init(symbol: String, title: String, selected: Bool, compact: Bool,
         hue: Color = DS.Ink.accent, lit: Bool = false, unavailable: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.selected = selected
        self.compact = compact
        self.hue = hue
        self.lit = lit
        self.unavailable = unavailable
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .symbolVariant(selected ? .fill : .none)
                    .foregroundStyle(selected ? hue : DS.Ink.secondary)
                    .frame(width: 20)
                    .overlay(alignment: .topTrailing) {
                        // On the rail the dot rides the symbol's corner.
                        if compact, lit {
                            Circle().fill(hue).frame(width: 5, height: 5).offset(x: 3, y: -2)
                                .accessibilityHidden(true)
                        }
                    }
                if !compact {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? DS.Ink.primary : DS.Ink.primary.opacity(0.84))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if lit { Circle().fill(hue).frame(width: 5, height: 5).accessibilityLabel("On") }
                    if unavailable != nil {
                        Image(systemName: "nosign").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .opacity(unavailable != nil && !selected ? 0.55 : 1)
            .padding(.horizontal, compact ? 0 : 12)
            .frame(width: compact ? 40 : nil, height: 32)
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .background {
                if selected {
                    Capsule().fill(hue.opacity(0.16)).overlay { Capsule().strokeBorder(hue.opacity(0.28), lineWidth: 0.5) }
                } else if hover {
                    Capsule().fill(DS.Ink.fill)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(Pressable(scale: 0.98))
        .onHover { hover = $0 }
        .help(compact ? [title, unavailable].compactMap { $0 }.joined(separator: " – ") : (unavailable ?? ""))
        .accessibilityLabel(title)
        .accessibilityValue(unavailable ?? (lit ? "Something here is on" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A search result: what it is, and where it lives.
struct NavResultRow: View {
    let entry: NavEntry
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: entry.kind == .place ? entry.symbol : "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(entry.kind == .place ? DS.Ink.accent : DS.Ink.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    Text(entry.path).font(.system(size: 10.5)).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DS.Ink.fillStrong : (hover ? DS.Ink.fill : .clear), in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(Pressable(scale: 0.98))
        .onHover { hover = $0 }
        .accessibilityLabel("\(entry.title), in \(entry.path)")
    }
}
