import AppKit
import Combine
import DockCore
import SwiftUI

/// Everything the replica draws, frozen at one moment. Comparing two of these says what
/// changed, and drawing an old one shows the Mac as it was.
struct StageSnapshot {
    var skin = SkinPreset.none
    var hue: Hue?
    var clock = false
    var clockStyle = ClockStyle.thin
    var glow = false
    var vitals = false
    var focus = false
    var dayLine = false
    var rounded = 0.0
    var nightShift = false
    var warmth = 0.5
    var trueTone = false
    var livingOn = false
    var shader = LivingShader.liquidLight
    var boardOn = false
    var widgets: [WidgetKind] = []
    /// Where every widget sits, so Before puts a moved widget back where it was.
    var placements: [WidgetPlacement] = []
    /// The Atelier Dock's items, in order.
    var ownDockItems: [String] = []
    var ownDockOn = false
    var ownDockEdge = OwnDockEdge.bottom
    var systemReplaced = false
    var stillOn = false
    var dock = DockPlist()
    /// Stored preference text, keyed `domain.key`, for every key the stage reads.
    var prefs: [String: String] = [:]

    static let iconKeys = ["AppleIconAppearanceTheme", "AppleIconAppearanceTintColor", "AppleIconAppearanceCustomTintColor"]

    @MainActor static func now(dock: DockPlist) -> StageSnapshot {
        let effects = Effects.shared, display = Display.shared
        var snapshot = StageSnapshot()
        snapshot.skin = effects.skin
        snapshot.hue = effects.living
        snapshot.clock = effects.clock
        snapshot.clockStyle = effects.clockStyle
        snapshot.glow = effects.dockGlow
        snapshot.vitals = effects.widgets
        snapshot.focus = effects.focus
        snapshot.dayLine = effects.dayLine
        snapshot.rounded = effects.rounded
        snapshot.nightShift = display.nightShift
        snapshot.warmth = display.warmth
        snapshot.trueTone = display.trueTone
        snapshot.livingOn = LiveWallpaper.shared.enabled
        snapshot.shader = LiveWallpaper.shared.shader
        snapshot.boardOn = WidgetBoard.shared.enabled
        snapshot.placements = WidgetBoard.shared.placements
        snapshot.widgets = snapshot.placements.map(\.kind)
        snapshot.ownDockItems = OwnDock.shared.items.map(\.id)
        snapshot.ownDockOn = OwnDock.shared.enabled
        snapshot.ownDockEdge = OwnDock.shared.edge
        snapshot.systemReplaced = OwnDock.shared.systemReplaced
        snapshot.stillOn = StillBackground.shared.enabled
        snapshot.dock = dock
        for tweak in TweakCatalog.all {
            if let value = Prefs.current(tweak.key, domain: tweak.domain) { snapshot.prefs[tweak.id] = value }
        }
        for key in iconKeys {
            if let value = Prefs.current(key, domain: "NSGlobalDomain") { snapshot.prefs["NSGlobalDomain." + key] = value }
        }
        return snapshot
    }

    func pref(_ key: String, domain: String) -> String? { prefs[domain + "." + key] }
}

/// One difference between two snapshots, and where on the stage it shows.
struct StageFact: Identifiable, Equatable {
    let id: String
    let title: String
    let before: String
    let after: String
    /// In stage fractions: (0, 0) is the top left, (1, 1) the bottom right.
    let region: CGRect
}

enum StageRegion {
    static let menuBar = CGRect(x: 0, y: 0, width: 1, height: 0.045)
    static let desktop = CGRect(x: 0.03, y: 0.07, width: 0.94, height: 0.74)
    static let clock = CGRect(x: 0.02, y: 0.62, width: 0.34, height: 0.22)
    static let vitals = CGRect(x: 0.7, y: 0.74, width: 0.29, height: 0.16)
    static let window = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5)
    static let whole = CGRect(x: 0.005, y: 0.005, width: 0.99, height: 0.99)

    static func dock(_ edge: String) -> CGRect {
        switch edge {
        case "left": CGRect(x: 0, y: 0.2, width: 0.08, height: 0.6)
        case "right": CGRect(x: 0.92, y: 0.2, width: 0.08, height: 0.6)
        default: CGRect(x: 0.2, y: 0.86, width: 0.6, height: 0.14)
        }
    }

    static func ownDock(_ edge: OwnDockEdge) -> CGRect {
        switch edge {
        case .left: CGRect(x: 0, y: 0.15, width: 0.1, height: 0.7)
        case .right: CGRect(x: 0.9, y: 0.15, width: 0.1, height: 0.7)
        // Around the bar where the stage draws it, at the screen's edge like the macOS Dock.
        case .top: CGRect(x: 0.15, y: 0.045, width: 0.7, height: 0.14)
        case .bottom: CGRect(x: 0.15, y: 0.85, width: 0.7, height: 0.145)
        }
    }

    static func area(_ chapter: Chapter, dockEdge: String) -> CGRect {
        switch chapter {
        case .dock, .stacks: dock(dockEdge)
        case .menubar: menuBar
        case .finder, .windows, .appearance, .input, .capture: window
        default:
            // Places named by the registry rather than by a constant.
            switch chapter.rawValue {
            case "controlCenter": menuBar
            case "engine", "spotlight", "quickLook", "apps", "appKit", "accessibility": window
            case "wallpaper", "livewall", "widgets", "folders", "effects": desktop
            case "time": clock
            default: whole
            }
        }
    }
}

/// Watches everything the stage draws. Each settled change becomes a fact the stage
/// spotlights, and the moment before it is kept so the stage can show it again.
@MainActor
final class StageChanges: ObservableObject {
    static let shared = StageChanges()

    /// The latest group of changes, newest first.
    @Published private(set) var facts: [StageFact] = []
    @Published private(set) var stamp = 0
    /// While true the stage draws `before` instead of the Mac as it is now.
    @Published var showingBefore = false
    private(set) var before: StageSnapshot?
    /// The Mac as it was when things last settled: a ready copy for hover previews to edit.
    var latest: StageSnapshot? { settled }

    private var settled: StageSnapshot?
    private var dock: () -> DockPlist = { [:] }
    private var bag = Set<AnyCancellable>()
    private var pending: DispatchWorkItem?

    private init() {}

    /// The model owns the Dock plist the stage draws, so it is read through here.
    func attach(dock read: @escaping () -> DockPlist, model: some ObservableObject) {
        dock = read
        guard bag.isEmpty else { return }
        settled = StageSnapshot.now(dock: read())
        let publishers: [AnyPublisher<Void, Never>] = [
            Effects.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            Display.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            LiveWallpaper.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            WidgetBoard.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            OwnDock.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            StillBackground.shared.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            (model.objectWillChange as? ObservableObjectPublisher)?.map { _ in }.eraseToAnyPublisher()
                ?? Empty().eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(publishers)
            .sink { [weak self] in self?.schedule() }
            .store(in: &bag)
    }

    /// A slider sends dozens of changes. Waiting for a pause keeps the start of the drag
    /// as the "before".
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settle() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func settle() {
        guard !showingBefore else { return }
        let now = StageSnapshot.now(dock: dock())
        guard let old = settled else { settled = now; return }
        let found = Self.diff(old, now)
        settled = now
        guard !found.isEmpty else { return }
        before = old
        // A real change ends any hover preview, so the stage shows what happened.
        StagePreview.shared.clear()
        withAnimation(DS.Motion.arrive) {
            facts = found
            stamp += 1
        }
        // The light fades on its own unless the owner is comparing.
        let shown = stamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.stamp == shown, !self.showingBefore else { return }
                withAnimation(DS.Motion.arrive) { self.facts = [] }
            }
        }
    }

    func dismiss() {
        showingBefore = false
        withAnimation(DS.Motion.arrive) { facts = [] }
    }

    // MARK: Diff

    private static func onOff(_ value: Bool) -> String { value ? "On" : "Off" }

    static func diff(_ a: StageSnapshot, _ b: StageSnapshot) -> [StageFact] {
        var out: [StageFact] = []
        func add(_ id: String, _ title: String, _ x: String, _ y: String, _ region: CGRect) {
            if x != y { out.append(StageFact(id: id, title: title, before: x, after: y, region: region)) }
        }
        let edge = (b.dock["orientation"] as? String) ?? "bottom"
        add("skin", "Menu Bar Skin", a.skin.title, b.skin.title, StageRegion.menuBar)
        add("hue", "Living Wallpaper", a.hue?.title ?? "Off", b.hue?.title ?? "Off", StageRegion.whole)
        add("clock", "Desktop Clock", onOff(a.clock), onOff(b.clock), StageRegion.clock)
        if a.clock && b.clock { add("clockStyle", "Clock Style", a.clockStyle.title, b.clockStyle.title, StageRegion.clock) }
        add("glow", "Dock Glow", onOff(a.glow), onOff(b.glow), StageRegion.dock(edge))
        add("vitals", "Desktop Vitals", onOff(a.vitals), onOff(b.vitals), StageRegion.vitals)
        add("focus", "Focus Light", onOff(a.focus), onOff(b.focus), StageRegion.whole)
        add("dayLine", "Day Line", onOff(a.dayLine), onOff(b.dayLine), StageRegion.menuBar)
        add("rounded", "Rounded Screen", "\(Int(a.rounded)) pt", "\(Int(b.rounded)) pt", StageRegion.whole)
        add("nightShift", "Night Shift", onOff(a.nightShift), onOff(b.nightShift), StageRegion.whole)
        if a.nightShift && b.nightShift {
            add("warmth", "Warmth", "\(Int(a.warmth * 100))%", "\(Int(b.warmth * 100))%", StageRegion.whole)
        }
        add("trueTone", "True Tone", onOff(a.trueTone), onOff(b.trueTone), StageRegion.whole)
        add("living", "Live Wallpaper", a.livingOn ? a.shader.title : "Off", b.livingOn ? b.shader.title : "Off", StageRegion.whole)
        add("still", "Still Background", onOff(a.stillOn), onOff(b.stillOn), StageRegion.whole)
        add("board", "Widgets", onOff(a.boardOn), onOff(b.boardOn), StageRegion.desktop)
        if a.boardOn && b.boardOn {
            for kind in WidgetKind.allCases {
                add("widget." + kind.rawValue, kind.title, onOff(a.widgets.contains(kind)), onOff(b.widgets.contains(kind)), StageRegion.desktop)
            }
            let old = Dictionary(a.placements.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
            for place in b.placements {
                guard let was = old[place.uid], was.column != place.column || was.row != place.row else { continue }
                add("moved." + place.uid, place.kind.title + " Position", "Column \(was.column + 1), row \(was.row + 1)",
                    "Column \(place.column + 1), row \(place.row + 1)", StageRegion.desktop)
            }
        }
        add("ownDock", "Atelier Dock", onOff(a.ownDockOn), onOff(b.ownDockOn), StageRegion.ownDock(b.ownDockEdge))
        if a.ownDockOn && b.ownDockOn {
            add("ownDockEdge", "Atelier Dock Edge", a.ownDockEdge.title, b.ownDockEdge.title, StageRegion.ownDock(b.ownDockEdge))
        }

        if a.ownDockOn && b.ownDockOn, Set(a.ownDockItems) == Set(b.ownDockItems), a.ownDockItems != b.ownDockItems {
            add("ownDockOrder", "Atelier Dock Order", "As it was", "Rearranged", StageRegion.ownDock(b.ownDockEdge))
        }
        add("replaced", "Replace System Dock", onOff(a.systemReplaced), onOff(b.systemReplaced),
            StageRegion.dock((b.dock["orientation"] as? String) ?? "bottom"))

        // The real Dock.
        let dockRegion = StageRegion.dock(edge)
        func number(_ plist: DockPlist, _ key: String) -> String {
            (plist[key] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))" } ?? "Default"
        }
        func flag(_ plist: DockPlist, _ key: String) -> String {
            onOff(plist[key] as? Bool ?? (plist[key] as? Int).map { $0 != 0 } ?? false)
        }
        add("tilesize", "Icon Size", number(a.dock, "tilesize"), number(b.dock, "tilesize"), dockRegion)
        add("magnification", "Magnification", flag(a.dock, "magnification"), flag(b.dock, "magnification"), dockRegion)
        add("largesize", "Magnify To", number(a.dock, "largesize"), number(b.dock, "largesize"), dockRegion)
        add("orientation", "Dock Position", ((a.dock["orientation"] as? String) ?? "bottom").capitalized,
            edge.capitalized, dockRegion)
        add("autohide", "Auto-hide", flag(a.dock, "autohide"), flag(b.dock, "autohide"), dockRegion)
        add("recents", "Recent Apps", flag(a.dock, "show-recents"), flag(b.dock, "show-recents"), dockRegion)
        func tiles(_ plist: DockPlist) -> Int {
            ((plist["persistent-apps"] as? [Any])?.count ?? 0) + ((plist["persistent-others"] as? [Any])?.count ?? 0)
        }
        let tilesA = tiles(a.dock), tilesB = tiles(b.dock)
        if tilesA != tilesB { add("tiles", "Dock Items", "\(tilesA)", "\(tilesB)", dockRegion) }

        // Tweaks from the catalogue, and icon colour.
        for tweak in TweakCatalog.all {
            let was = a.prefs[tweak.id] == tweak.value, now = b.prefs[tweak.id] == tweak.value
            add(tweak.id, tweak.title, onOff(was), onOff(now), StageRegion.area(tweak.area, dockEdge: edge))
        }
        let iconA = StageSnapshot.iconKeys.map { a.prefs["NSGlobalDomain." + $0] ?? "" }
        let iconB = StageSnapshot.iconKeys.map { b.prefs["NSGlobalDomain." + $0] ?? "" }
        if iconA != iconB {
            out.append(StageFact(id: "icons", title: "Icon Colour", before: iconName(iconA[0]), after: iconName(iconB[0]), region: dockRegion))
        }
        return out
    }

    private static func iconName(_ theme: String) -> String {
        if theme.hasPrefix("Tinted") { return "Tinted" }
        if theme.hasPrefix("Clear") { return "Clear" }
        if theme.hasPrefix("Dark") { return "Dark" }
        return "Default"
    }
}

// MARK: - Stage chrome

/// A soft light around what just changed, with its name and the old and new value.
struct ChangeSpotlight: View {
    @ObservedObject var changes: StageChanges
    let canvas: CGSize
    let zoom: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var regions: [CGRect] {
        // Several facts in one place draw one light, not a stack of them.
        var seen: [CGRect] = []
        for fact in changes.facts where !seen.contains(fact.region) { seen.append(fact.region) }
        return seen.prefix(3).map { CGRect(x: $0.minX * canvas.width, y: $0.minY * canvas.height,
                                           width: $0.width * canvas.width, height: $0.height * canvas.height) }
    }

    var body: some View {
        ZStack {
            ForEach(Array(regions.enumerated()), id: \.offset) { _, rect in
                let radius = min(rect.width, rect.height) * 0.18 + 6
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Ink.accent.opacity(changes.showingBefore ? 0.35 : 0.95), lineWidth: 1.5 / zoom)
                    .background {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(DS.Ink.accent.opacity(0.08))
                    }
                    .shadow(color: DS.Ink.accent.opacity(breathe ? 0.75 : 0.35), radius: (breathe ? 22 : 10) / zoom)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.scale(scale: 1.06).combined(with: .opacity))
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .allowsHitTesting(false)
        .id(changes.stamp)
        .onAppear {
            guard !reduceMotion else { return }
            breathe = false
            withAnimation(.easeInOut(duration: 1.6).repeatCount(3, autoreverses: true)) { breathe = true }
        }
    }
}

/// What changed, in words, and a way to look at the Mac as it was a moment ago.
struct ChangeCard: View {
    @ObservedObject var changes: StageChanges

    var body: some View {
        if let first = changes.facts.first {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(changes.facts.count > 1 ? "\(first.title) and \(changes.facts.count - 1) more" : first.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(first.before).foregroundStyle(DS.Ink.secondary).strikethrough(!changes.showingBefore, color: DS.Ink.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.secondary)
                        Text(first.after).foregroundStyle(changes.showingBefore ? DS.Ink.secondary : DS.Ink.accent)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                }
                CompareSwitch(showingBefore: $changes.showingBefore)
                Button { changes.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Ink.secondary)
                        .frame(width: 24, height: 24).contentShape(Circle())
                }
                .buttonStyle(Pressable(scale: 0.9))
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 16).padding(.trailing, 8).frame(height: 54)
            .atelierGlass(.regular, in: .capsule)
            .fixedSize()
            .id(changes.stamp)
            .transition(.offset(y: -10).combined(with: .opacity))
        }
    }
}

/// Before and After, with the stage crossfading between them.
struct CompareSwitch: View {
    @Binding var showingBefore: Bool
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            option("Before", selected: showingBefore) { showingBefore = true }
            option("After", selected: !showingBefore) { showingBefore = false }
        }
        .padding(3)
        .background(DS.Ink.fill, in: .capsule)
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.55)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? DS.Ink.primary : DS.Ink.secondary)
                .padding(.horizontal, 12).frame(height: 28)
                .background {
                    if selected { Capsule().fill(DS.Ink.fillStrong).matchedGeometryEffect(id: "compare", in: space) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.96))
    }
}
