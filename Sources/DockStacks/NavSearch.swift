import AppKit
import DockCore
import SwiftUI

// One search for the whole Studio: every place, every tweak and every catalogue setting. The
// sidebar (⌘F) and the Command palette both read it. Picking a setting opens its place, scrolls
// to its row and lights it up; rows opt in with `.navTarget(id)`.

/// One thing search can find.
struct NavEntry: Identifiable {
    enum Kind { case place, setting }
    let id: String
    let kind: Kind
    let title: String
    /// Where it lives, as "Section › Place" or "Place › Section".
    let path: String
    let symbol: String
    let chapter: Chapter
    /// The row to light up, for a setting.
    let target: String?
    /// Lowercased title, keywords and detail, matched word by word.
    fileprivate let haystack: String
}

@MainActor
enum NavIndex {
    /// Built once, on the first search: a few hundred plain strings.
    static let entries: [NavEntry] = {
        var list: [NavEntry] = []
        for item in NavRegistry.items where item.chapter != .home {
            list.append(NavEntry(id: "place." + item.id, kind: .place, title: item.title, path: item.section.rawValue,
                                 symbol: item.symbol, chapter: item.chapter, target: nil,
                                 haystack: ([item.title, item.section.rawValue] + item.keywords).joined(separator: " ").lowercased()))
        }
        for tweak in TweakCatalog.all where tweak.isAvailableHere {
            let chapter = NavRegistry.chapter(for: tweak)
            guard let item = NavRegistry.item(for: chapter) else { continue }
            list.append(NavEntry(id: "tweak." + tweak.id, kind: .setting, title: tweak.title, path: item.title,
                                 symbol: item.symbol, chapter: chapter, target: TweakList.target(tweak),
                                 haystack: [tweak.title, tweak.detail, tweak.key, item.title].joined(separator: " ").lowercased()))
        }
        for setting in PersonalCatalog.all where setting.isAvailable() {
            guard let chapter = NavRegistry.chapter(for: setting), let item = NavRegistry.item(for: chapter) else { continue }
            let path = item.title == setting.section ? item.title : item.title + " › " + setting.section
            list.append(NavEntry(id: "personal." + setting.id, kind: .setting, title: setting.title, path: path,
                                 symbol: item.symbol, chapter: chapter, target: PersonalRow.target(setting),
                                 haystack: [setting.title, setting.detail, setting.section, setting.key, item.title]
                                     .joined(separator: " ").lowercased()))
        }
        // Mods › Create, the plugin Playground: a tab, so it is found by name and opens in place.
        list.append(NavEntry(id: "place.mods.playground", kind: .place, title: "Mod Playground", path: "Mods › Create",
                             symbol: "hammer", chapter: Chapter("mods"), target: "playground",
                             haystack: "mod playground create make write plugin javascript script run console sdk developer"))
        return list
    }()

    /// Best first. A title that matches beats a keyword, a place beats a setting of the same score.
    static func search(_ query: String, limit: Int = 40) -> [NavEntry] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let words = clean.lowercased().split(separator: " ").map(String.init)
        var scored: [(NavEntry, Int)] = []
        for entry in entries {
            var score: Int?
            if let fuzzy = Fuzzy.score(clean, in: entry.title) { score = fuzzy + 30 }
            if words.allSatisfy({ entry.haystack.contains($0) }) { score = max(score ?? 0, 20 - min(entry.haystack.count / 40, 8)) }
            guard var value = score else { continue }
            if entry.kind == .place { value += 6 }
            if entry.title.lowercased().hasPrefix(clean.lowercased()) { value += 12 }
            scored.append((entry, value))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}

/// The row search asked to show. The panel scrolls to it and the row glows for a moment.
@MainActor
final class NavFocus: ObservableObject {
    static let shared = NavFocus()
    @Published private(set) var target: String?
    private var clear: Task<Void, Never>?

    /// Opens the entry's place, then points at its row.
    func reveal(_ entry: NavEntry, in model: ManagerModel) {
        model.go(entry.chapter)
        point(at: entry.target)
    }

    /// From outside the Studio window (Command): opens the window at the entry's place first.
    func open(_ entry: NavEntry) {
        ManagerWindow.shared.show(chapter: entry.chapter.rawValue)
        point(at: entry.target)
    }

    /// A deep link to a card: opens the Studio at `chapter`, scrolls to the view marked
    /// `.navTarget(focus)` and lights it. `atelier://studio?chapter=dock&focus=vitals` lands here.
    func open(chapter: String, focus: String?) {
        ManagerWindow.shared.show(chapter: chapter)
        point(at: focus)
    }

    private func point(at target: String?) {
        clear?.cancel()
        self.target = target
        guard target != nil else { return }
        clear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.target = nil
        }
    }
}

/// Marks a row search can jump to. Costs one id while nothing is targeted.
struct NavTargetModifier: ViewModifier {
    let id: String
    @ObservedObject private var focus = NavFocus.shared

    func body(content: Content) -> some View {
        let lit = focus.target == id
        content
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Ink.accent, lineWidth: 2)
                    .shadow(color: DS.Ink.accent.opacity(0.6), radius: 8)
                    .opacity(lit ? 1 : 0)
                    .animation(DS.Motion.arrive, value: lit)
                    .allowsHitTesting(false)
            }
            .id(id)
    }
}

extension View {
    func navTarget(_ id: String) -> some View { modifier(NavTargetModifier(id: id)) }
}
