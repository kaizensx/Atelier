import AppKit
import Combine
import DockCore
import IOKit
import IOKit.ps
import SwiftUI

extension ManagerModel {
    func go(_ requested: Chapter) {
        // Chapters folded into others still open from old links and shortcuts.
        let chapter = requested.routed
        preview = nil
        previewSize = nil
        previewLook = nil
        previewTint = nil
        hoverTweak = nil
        StagePreview.shared.clear()
        guard chapter != self.chapter || chapter != panelChapter else { return }
        // The stage moves when the camera changes, and also when a panel comes or goes: the
        // viewport changes width, so the canvas rescales. Either way its heavy shadow rests.
        let stageMoves = chapter.camera != self.chapter.camera || chapter.hasPanel != self.chapter.hasPanel
        guard chapter.hasPanel else {
            // Leaving for a chapter without a panel: the old panel fades out first, then goes.
            if stageMoves { noteCameraMove() }
            withAnimation(DS.Motion.camera) { self.chapter = chapter }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if self.chapter == chapter { self.panelChapter = chapter }
            }
            return
        }
        panelChapter = chapter
        notePanelArrival()
        if stageMoves { noteCameraMove(); noteChapterFlight() }
        DispatchQueue.main.async {
            withAnimation(DS.Motion.camera) { self.chapter = chapter }
        }
    }
}

@MainActor
final class Tilt: ObservableObject {
    @Published var angle = CGSize.zero
}

/// The only view that watches the pointer.
struct Tilted: ViewModifier {
    @ObservedObject var tilt: Tilt

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(tilt.angle.width), axis: (0, 1, 0), perspective: 0.35)
            .rotation3DEffect(.degrees(tilt.angle.height), axis: (1, 0, 0), perspective: 0.35)
    }
}

/// Where everything in the Studio window goes. The sidebar on the left, the panel on the right and
/// the band below are the stage's to keep clear of: the stage is framed in the viewport between them.
struct StudioLayout: Equatable {
    /// Clear of the title bar and its traffic lights.
    static let top = 34.0
    /// The band for the change card and the Home title.
    /// Only air: the band below the stage floats over it, it reserves no room.
    static let bottom = 22.0
    /// Time keeps its scrubber in the band too.
    static let timeBottom = 196.0
    /// Home: the stage stands at the top and the Impossible shelf takes the band under it.
    /// A slot for the preview caption (36), the tiles (112) and air (20).
    static let homeBottom = 168.0
    /// The caption's slot between the stage and whatever is under it.
    static let captionSlot = 36.0
    static let panel = 430.0
    /// The sidebar's glass, its rail when collapsed, and the air around either.
    static let sidebar = 228.0
    /// Wide enough for the window's traffic lights, which sit in its glass.
    static let rail = 72.0
    static let sidebarInset = 10.0
    /// Below this width the full sidebar would squeeze the stage, so it stays a rail.
    static let narrowWidth = 1220.0
    /// Room between the stage at rest and the viewport's edges, where the feathered edge lives.
    static let margin = 12.0

    let bounds: CGSize
    let viewport: CGRect
    /// The stage is laid out once at this size and only scaled after that: a size that animates
    /// would lay out the whole replica on every frame. It depends on the window alone, never on the
    /// sidebar or the panel, so opening or folding either only rescales the stage.
    let base: CGSize
    /// The scale at which the stage fills the viewport at rest.
    let fit: Double

    static func leading(collapsed: Bool) -> Double { sidebarInset * 2 + (collapsed ? rail : sidebar) }

    init(bounds: CGSize, chapter: Chapter, collapsed: Bool = false) {
        self.bounds = bounds
        let panel = chapter.hasPanel ? Self.panel : 0
        let bottom = chapter == .time ? Self.timeBottom : chapter == .home ? Self.homeBottom : Self.bottom
        let left = Self.leading(collapsed: collapsed)
        viewport = CGRect(x: left, y: Self.top, width: max(bounds.width - panel - left, 1),
                          height: max(bounds.height - Self.top - bottom, 1))
        let room = bounds.height - Self.top - Self.bottom - Self.margin * 2
        let baseWidth = max(min(bounds.width * 0.9, room * 1.6, 1500), 480)
        base = CGSize(width: baseWidth, height: baseWidth / 1.6)
        // Home stands the stage on its plinth, 24 points in from each side of its viewport.
        let wide = chapter == .home ? viewport.width - 48 : viewport.width * 0.97
        let fitWidth = max(min(wide, (viewport.height - Self.margin * 2) * 1.6, 1500), 240)
        fit = fitWidth / baseWidth
        home = chapter == .home
    }

    /// Home pins the stage to the top of its viewport instead of centring it, so the dead band
    /// sits nowhere: the shelf follows right under it.
    let home: Bool

    /// Where the stage is drawn in the window for a camera, in window points. The stage, the room's
    /// light, the caption and Home's shelf all read this one rect.
    @MainActor func stageFrame(camera: (zoom: Double, focus: UnitPoint)) -> CGRect {
        let canvas = MacStage.canvas(in: base)
        let framing = StageFraming.make(canvas: canvas, scale: fit * camera.zoom, focus: camera.focus, viewport: viewport.size)
        var centre = CGPoint(x: viewport.midX + framing.offset.width, y: viewport.midY + framing.offset.height)
        if home, framing.shown.height < viewport.height {
            centre.y = viewport.minY + Self.margin * 0.5 + framing.shown.height / 2
        }
        return CGRect(x: centre.x - framing.shown.width / 2, y: centre.y - framing.shown.height / 2,
                      width: framing.shown.width, height: framing.shown.height)
    }
}

/// Fades the stage into the room at the viewport's edges, so a camera that zooms past them reads as
/// a lens, not a cut. Gradients only: no blur, nothing to redraw while the camera moves.
struct StageFeather: View {
    let layout: StudioLayout
    var feather = 26.0

    var body: some View {
        let w = max(layout.bounds.width, 1), h = max(layout.bounds.height, 1)
        let v = layout.viewport
        let clamp: (Double) -> Double = { min(max($0, 0), 1) }
        let left = v.minX <= 0 ? 0 : v.minX
        let horizontal = [
            Gradient.Stop(color: .clear, location: clamp(left / w)),
            Gradient.Stop(color: .white, location: clamp((left + feather) / w)),
            Gradient.Stop(color: .white, location: clamp((v.maxX - feather) / w)),
            Gradient.Stop(color: .clear, location: clamp(v.maxX / w)),
        ]
        let vertical = [
            Gradient.Stop(color: .clear, location: clamp((v.minY - 10) / h)),
            Gradient.Stop(color: .white, location: clamp((v.minY + feather * 0.55) / h)),
            Gradient.Stop(color: .white, location: clamp((v.maxY - feather * 0.55) / h)),
            Gradient.Stop(color: .clear, location: clamp((v.maxY + 10) / h)),
        ]
        LinearGradient(stops: horizontal, startPoint: .leading, endPoint: .trailing)
            .mask(LinearGradient(stops: vertical, startPoint: .top, endPoint: .bottom))
            .frame(width: layout.bounds.width, height: layout.bounds.height)
    }
}

/// The room and the stage in it, framed by the camera. Watches the hover preview so the camera can
/// lean toward what a control would change; the rest of the window does not redraw for it.
struct StageViewport: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject var theme: StudioTheme
    @ObservedObject private var preview = StagePreview.shared
    /// The camera pulls back while the dock is on a side edge, so it never hides under a panel.
    @ObservedObject private var dockSide = StageDockSide.shared
    let tilt: Tilt
    let entered: Bool
    let layout: StudioLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let camera = stageCamera(model.chapter, preview: preview.active?.region)
        let scale = layout.fit * camera.zoom
        let frame = layout.stageFrame(camera: camera)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let w = max(layout.bounds.width, 1), h = max(layout.bounds.height, 1)
        ZStack {
            StudioRoom(theme: theme, entered: entered, stage: CGRect(
                x: frame.minX / w, y: frame.minY / h, width: frame.width / w, height: frame.height / h))
            MacStage(model: model, size: layout.base, entered: entered)
                // Opening shot, once per launch: the Mac settles onto its plinth from just under
                // its size. Reduce Motion: it is simply there, and fades up.
                .scaleEffect(entered || reduceMotion ? scale : 0.96 * scale)
                .offset(x: centre.x - w / 2, y: centre.y - h / 2)
                .modifier(Tilted(tilt: tilt))
                .opacity(entered ? 1 : 0)
                // While the camera flies, the stage takes no pointer: handles and hotspots sliding
                // under a still cursor would each react on the way.
                .allowsHitTesting(!model.chapterFlying)
                .modifier(LightWave(origin: UnitPoint(x: 0.5, y: 0.82), trigger: model.applied))
                .frame(width: layout.bounds.width, height: layout.bounds.height)
                // A zoomed camera fades out at the viewport's edges instead of being cut by them.
                .mask { StageFeather(layout: layout) }
        }
        .onChange(of: model.dock.string("orientation", "bottom"), initial: true) { _, edge in
            StageDockSide.shared.systemEdge = edge
        }
    }
}

struct StudioView: View {
    @StateObject private var model = ManagerModel()
    @State private var entered = false
    /// Held in @State so the pointer only moves the tilt, not the whole studio.
    @State private var tilt = Tilt()
    @ObservedObject private var theme = StudioTheme.shared
    /// Read by the camera (`Chapter.camera`), so the band under the stage follows it too.
    @ObservedObject private var dockSide = StageDockSide.shared
    @AppStorage("studio.sidebarCollapsed") private var sidebarCollapsed = false

    var body: some View {
        GeometryReader { geometry in
            let bounds = geometry.size
            let narrow = bounds.width < StudioLayout.narrowWidth
            let collapsed = sidebarCollapsed || narrow
            let layout = StudioLayout(bounds: bounds, chapter: model.chapter, collapsed: collapsed)

            ZStack(alignment: .trailing) {
                StageViewport(model: model, theme: theme, tilt: tilt, entered: entered, layout: layout)
                if model.panelChapter.hasPanel {
                    let showing = model.chapter.hasPanel && model.chapter == model.panelChapter
                    ChapterPanel(model: model)
                        .frame(width: 400)
                        .padding(.vertical, 14)
                        .padding(.trailing, 16)
                        .opacity(showing ? 1 : 0)
                        // Not while it slides in: rows passing under a still pointer would each
                        // light up, lift or preview on the way.
                        .allowsHitTesting(showing && !model.panelArriving)
                }
                overlays(layout)
                if model.chapter == .home {
                    HomeShelf(model: model, stage: layout.stageFrame(camera: Chapter.home.camera), viewport: layout.viewport,
                              entered: entered)
                        .transition(.opacity)
                }
                NavSidebar(model: model, collapsed: collapsed, narrow: narrow) {
                    withAnimation(DS.Motion.camera) { sidebarCollapsed.toggle() }
                }
                .padding(StudioLayout.sidebarInset)
                // Clear of the window's close, minimise and zoom buttons, which sat on its glass.
                .padding(.top, StudioLayout.top - StudioLayout.sidebarInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .opacity(entered ? 1 : 0)
                .offset(x: entered ? 0 : -16)
                .animation(DS.Motion.arrive.delay(0.6), value: entered)
                // While the camera flies, one clear sheet takes the pointer. Otherwise SwiftUI
                // works out hover again for every view sliding under a still cursor, every frame.
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(model.chapterFlying || model.panelArriving)
            }
            .animation(DS.Motion.arrive, value: model.chapter)
            .animation(DS.Motion.camera, value: collapsed)
            .onContinuousHover { phase in
                guard theme.tilt, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    if tilt.angle != .zero { tilt.angle = .zero }
                    return
                }
                // The stage leans toward the pointer only while the pointer is over the stage.
                // Over the panel or the sidebar (reading, scrolling, toggling) it rests level,
                // so working there costs no redraw of the stage at all.
                var target = CGSize.zero
                if case .active(let point) = phase, layout.viewport.contains(point), !ScrollActivity.scrolling, !model.chapterFlying {
                    target = CGSize(width: (point.x / bounds.width - 0.5) * 2.4,
                                    height: (0.5 - point.y / bounds.height) * 1.6)
                }
                guard abs(target.width - tilt.angle.width) > 0.02 || abs(target.height - tilt.angle.height) > 0.02 else { return }
                withAnimation(.spring(response: 0.9, dampingFraction: 1)) { tilt.angle = target }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 680)
        // The first-launch Welcome and the Permissions sheet (Permissions.swift).
        .modifier(PermissionsSheetHost())
        .onAppear {
            model.reload()
            // Room, stage and sidebar arrive once per launch; Reduce Motion makes it a 0.15 s fade.
            withAnimation(DS.Motion.gentle(DS.Motion.arrive)) { entered = true }
        }
        // A new chapter starts level: easing a tilt back during the camera's flight doubled its cost.
        .onChange(of: model.chapter) {
            var level = Transaction()
            level.disablesAnimations = true
            withTransaction(level) { tilt.angle = .zero }
        }
        .onReceive(NotificationCenter.default.publisher(for: .studioChapter)) { note in
            if let raw = note.object as? String, let chapter = Chapter(rawValue: raw) { model.go(chapter) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Only the Studio's own window: pickers, widgets and the dock's panels become key too.
            guard (note.object as? NSWindow)?.title == "Atelier" else { return }
            model.refreshQuietly()
        }
        .onExitCommand { model.go(.home) }
        .onReceive(Effects.shared.$notice) { text in
            if let text { model.failure = text; Effects.shared.notice = nil }
        }
        .alert("That didn’t work", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.failure ?? "") }
    }

    /// The band below the stage, over the stage's viewport only.
    @ViewBuilder private func overlays(_ layout: StudioLayout) -> some View {
        let stage = layout.stageFrame(camera: model.chapter.camera)
        // On Home the band's bottom is the caption slot's, so the busy pill and the change card
        // never land on the shelf.
        let bandBottom = model.chapter == .home ? max(layout.bounds.height - stage.maxY - StudioLayout.captionSlot, 8) : 8
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    if model.busy {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text(model.status).font(.system(size: 12.5, weight: .medium))
                        }
                        .padding(.horizontal, 16).frame(height: 38)
                        .atelierGlass(.regular.tint(.black.opacity(0.2)), in: .capsule)
                        .transition(.offset(y: 16).combined(with: .opacity))
                    } else {
                        StageHeader(model: model, entered: entered, width: layout.viewport.width)
                    }
                }
                .frame(height: 78)
                .padding(.bottom, bandBottom)
            }
            .frame(width: layout.viewport.width)
            .padding(.leading, layout.viewport.minX)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The hovered setting's caption, at a fixed size just under the stage (or the
            // window's lower edge, when a zoomed stage runs past it).
            StageCaption()
                .position(x: min(max(stage.midX, layout.viewport.minX + 160), layout.viewport.maxX - 160),
                          y: min(stage.maxY + StudioLayout.captionSlot / 2, layout.bounds.height - 22))
            if model.chapter == .time {
                TimeOverlay(model: model)
                    .frame(width: layout.viewport.width)
                    .padding(.leading, layout.viewport.minX)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.offset(y: 40).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(DS.Motion.arrive, value: model.busy)
    }
}

/// The title on Home, and the card for the latest change wherever you are. Sits in the band under the stage.
struct StageHeader: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var changes = StageChanges.shared
    @ObservedObject private var preview = StagePreview.shared
    let entered: Bool
    let width: Double

    var body: some View {
        ZStack {
            // Steps aside while a hovered setting's caption holds the band.
            if !changes.facts.isEmpty, preview.active?.title == nil {
                ChangeCard(changes: changes)
            }
        }
        .frame(width: max(width, 0))
        .padding(.bottom, 8)
        .animation(DS.Motion.arrive, value: changes.facts.isEmpty)
        .animation(DS.Motion.hover, value: preview.active?.title == nil)
    }
}

// MARK: - Panels

/// The open place's panel, from the registry. Scrolls to a row that search pointed at.
struct ChapterPanel: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var focus = NavFocus.shared
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        let item = NavRegistry.item(for: model.panelChapter)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                    // Title text lines up with card content: panel inset 12 + card inset 16.
                    ChapterHeader(title: item?.title ?? model.panelChapter.title,
                                  eyebrow: item?.section.rawValue, hue: item?.section.hue ?? DS.Ink.accent)
                        .padding(.horizontal, DS.Inset.card)
                        .padding(.top, DS.Space.l)
                        .padding(.bottom, DS.Space.xs)
                    Cascade { if let item { item.content(model) } }
                }
                .padding(DS.Inset.panel)
                .id(model.panelChapter)
            }
            .scrollIndicators(.never)
            .clipShape(.rect(cornerRadius: DS.Radius.panel, style: .continuous))
            // Keyed on the panel's chapter too: a link that opens another chapter sets the target
            // before that chapter's rows exist. A second pass once the panel has landed catches a
            // freshly opened window, whose scroll view has no size yet at the first one.
            .task(id: "\(focus.target ?? "")|\(model.panelChapter.rawValue)") {
                guard let target = focus.target else { return }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                withAnimation(DS.Motion.arrive) { proxy.scrollTo(target, anchor: .center) }
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, focus.target == target else { return }
                withAnimation(DS.Motion.arrive) { proxy.scrollTo(target, anchor: .center) }
            }
        }
        .background {
            if solid { RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(Color(white: 0.1)) }
        }
        .atelierGlass(solid ? .identity : .regular.tint(Color(red: 0.03, green: 0.035, blue: 0.05).opacity(0.35)),
                     in: .rect(cornerRadius: DS.Radius.panel, style: .continuous))
    }
}


struct DockChapter: View {
    @ObservedObject var model: ManagerModel
    @State private var size = 64.0
    @State private var large = 76.0

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { model.dock.bool(key) }, set: { on in
            if key == "autohide", LiveDock.available {
                LiveDock.setAutoHide(on)
                model.refreshDock(after: 0.5)
            } else {
                model.setDock(key, on)
            }
        })
    }

    private var region: CGRect { StageRegion.dock(model.dock.string("orientation", "bottom")) }

    /// The stage shows the Dock with this key flipped.
    private func flip(_ key: String, _ title: String) -> StagePreviewSpec {
        let on = model.dock.bool(key)
        return .toggle("dock." + key, title, isOn: on, region: region) { $0.dock[key] = !on }
    }

    /// A slider row in the group: title, slider, the value in points.
    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, label: String,
                        commit: @escaping () -> Void) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                .frame(width: DockHubLayout.labelWidth, alignment: .leading)
            LuxSlider(value: value, range: range, label: label, onCommit: commit)
            Text("\(Int(value.wrappedValue.rounded())) pt").font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .frame(minHeight: 36)
    }

    var body: some View {
        let fullWidth = model.dock.fullWidth
        RowGroup {
            slider("Icons", $size, 24...128, label: "Icon Size") { model.previewSize = nil; model.refreshDock(after: 0.4) }
                .onChange(of: size) { _, value in
                    model.previewSize = value
                    LiveDock.setSize(value) // The real Dock follows the slider, with no restart.
                }
                .stagePreview(.focus("dock.size", "Icon Size", region: region))
            SettingRow(title: "Magnification", density: .compact) { LuxSwitch(isOn: flag("magnification"), label: "Magnification") }
                .dockHubRow()
                .stagePreview(flip("magnification", "Magnification"))
            slider("Magnify to", $large, 32...128, label: "Magnify To") { model.refreshDock(after: 0.4) }
                .onChange(of: large) { _, value in LiveDock.setMagnification(value) }
                .stagePreview(.focus("dock.largesize", "Magnify To", region: region))
            DockHubWideRow("Position") {
                Segments(selection: Binding(get: { model.dock.string("orientation", "bottom") },
                                            set: { value in
                                                LiveDock.setOrientation(value)
                                                model.refreshDock(after: 0.6)
                                            }),
                         options: [("left", "Left"), ("bottom", "Bottom"), ("right", "Right")],
                         preview: { value in
                             .option("dock.orientation", "Dock Position", value.capitalized, region: StageRegion.dock(value)) {
                                 $0.dock["orientation"] = value
                             }
                         })
            }
            SettingRow(title: "Auto-hide", density: .compact) { LuxSwitch(isOn: flag("autohide"), label: "Auto-hide") }
                .dockHubRow()
                .stagePreview(flip("autohide", "Auto-hide"))
            SettingRow(title: "Recent Apps", density: .compact) { LuxSwitch(isOn: flag("show-recents"), label: "Recent Apps") }
                .dockHubRow()
                .stagePreview(.toggle("dock.show-recents", "Recent Apps", isOn: model.dock.plist["show-recents"] as? Bool ?? true,
                                      region: region) { $0.dock["show-recents"] = !(model.dock.plist["show-recents"] as? Bool ?? true) })
            SettingRow(title: "Full Width", detail: "Folders and Trash move to the far edge of the screen.", density: .compact) {
                LuxSwitch(isOn: Binding(get: { model.dock.fullWidth }, set: { on in
                    model.changeTiles("Full Width") { Tiles.setFullWidth(on, in: &$0) }
                }), label: "Full Width")
            }
            .dockHubRow()
            .stagePreview(.toggle("dock.fullWidth", "Full Width", isOn: fullWidth, region: StageRegion.dock(model.dock.string("orientation", "bottom"))) {
                Tiles.setFullWidth(!fullWidth, in: &$0.dock)
            })
            // Three chips beside a title and detail squeezed every word: the chips go below.
            DockHubWideRow("Spacers", detail: "Blank room between tiles, to group them.") {
                HStack(spacing: 6) {
                    Chip("Small") { model.changeTiles("Small spacer") { Tiles.addSpacer(.small, to: &$0) } }
                        .stagePreview(.init(id: "dock.spacer.small", title: "Small Spacer", detail: "Added", region: region) {
                            Tiles.addSpacer(.small, to: &$0.dock)
                        })
                    Chip("Regular") { model.changeTiles("Regular spacer") { Tiles.addSpacer(.regular, to: &$0) } }
                        .stagePreview(.init(id: "dock.spacer.regular", title: "Spacer", detail: "Added", region: region) {
                            Tiles.addSpacer(.regular, to: &$0.dock)
                        })
                    Chip("Remove All") { model.changeTiles("Remove spacers") { Tiles.removeSpacers(from: &$0) } }
                        .stagePreview(.init(id: "dock.spacer.none", title: "Spacers", detail: "Removed", region: region) {
                            Tiles.removeSpacers(from: &$0.dock)
                        })
                }
            }
        }
        .onAppear {
            Task.detached { if let plist = try? DockStore.read() { try? Timeline.record(plist, label: "Before live Dock edits") } }
            size = model.dock.double("tilesize", 64)
            large = model.dock.double("largesize", 76)
        }
        // The Dock's hidden keys, here and nowhere else now that All Tweaks is gone.
        SectionHeader("More macOS Dock Tweaks", symbol: "dock.rectangle", detail: "Hidden Dock settings. The Dock restarts once after each.")
        TweakList(model: model, tweaks: TweakCatalog.tweaks(for: .dock))
        SettingsCompatHiddenGroup(items: TweakCatalog.unsupported(for: .dock).map(\.compatHiddenItem))
    }
}

struct Chip: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            // Never squeezed into two lines or clipped: a chip keeps its label's width.
            Text(title).font(.system(size: 12, weight: .medium))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 12).frame(height: 30)
                .background(DS.Ink.fillStrong, in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.95))
    }
}

struct StacksChapter: View {
    @ObservedObject var model: ManagerModel
    private let hue = DockHubHue.tint

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.stacks, id: \.self) { url in
                    let selected = model.selected == url
                    Button { withAnimation(DS.Motion.arrive) { model.pick(url) } } label: {
                        HStack(spacing: 7) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
                            Text(url.deletingPathExtension().lastPathComponent).font(DS.Typo.rowTitle)
                        }
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(selected ? hue.opacity(0.18) : DS.Ink.fill, in: .capsule)
                        .overlay { Capsule().strokeBorder(selected ? hue : .clear, lineWidth: 1) }
                    }.buttonStyle(Pressable(scale: 0.96))
                }
                Chip("New") { withAnimation(DS.Motion.arrive) { model.pick(nil) } }
                ForEach(model.convertible) { folder in
                    Chip("Convert \(folder.title)") {
                        model.perform("Converting…", {
                            try StackActions.convert(folderPath: folder.path, title: folder.title, apps: folder.apps,
                                                     text: folder.text, style: folder.style, color: folder.color)
                        })
                    }
                }
            }
        }
        .scrollIndicators(.never)

        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: IconRenderer.image(model.draft.icon, title: model.draft.title, items: model.draft.items))
                        .resizable().frame(width: 76, height: 76)
                    TextField("Title", text: $model.draft.title)
                        .textFieldStyle(.plain).font(DS.display(24))
                }
                Segments(selection: $model.draft.icon.style, options: [(.apps, "Apps"), (.text, "Text"), (.symbol, "Symbol")])
                if model.draft.icon.style == .text {
                    TextField("Text on the icon", text: $model.draft.icon.text).textFieldStyle(.plain).padding(9)
                        .background(DS.Ink.fill, in: .rect(cornerRadius: 10))
                }
                if model.draft.icon.style == .symbol {
                    TextField("SF Symbol name", text: $model.draft.icon.symbol).textFieldStyle(.plain).padding(9)
                        .background(DS.Ink.fill, in: .rect(cornerRadius: 10))
                }
                HStack(spacing: 6) {
                    ForEach(Palette.colors.indices, id: \.self) { index in
                        Button { withAnimation(DS.Motion.settle) { model.draft.icon.color = index } } label: {
                            Circle().fill(Color(nsColor: Palette.colors[index])).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white.opacity(model.draft.icon.color == index ? 0.95 : 0.1),
                                                               lineWidth: model.draft.icon.color == index ? 2 : 0.5))
                                .frame(width: 34, height: 34).contentShape(Circle())
                        }.buttonStyle(Pressable(scale: 0.9)).accessibilityLabel("Colour \(index + 1)")
                    }
                }
            }
        }
        SectionHeader("Live Stacks", symbol: "sparkle.magnifyingglass",
                      detail: "Native Dock folders that Spotlight keeps up to date, even with this app closed.", hue: hue)
        Card {
            let live = Tiles.smartLabels(model.dock.plist)
            FlowChips(presets: LivePreset.all, active: live, add: model.addLive, remove: model.removeLive)
        }
        SectionHeader("Bubble", symbol: "bubble.middle.bottom", hue: hue)
        RowGroup {
            SettingRow(title: "Layout", density: .compact) {
                Segments(selection: $model.draft.layout, options: [(.grid, "Grid"), (.arc, "Arc"), (.list, "List")])
                    .frame(width: DockHubLayout.segmentsWidth)
            }
            .dockHubRow()
            SettingRow(title: "Content", density: .compact) {
                Picker("Content", selection: $model.draft.rule) {
                    Text("Chosen by me").tag(SmartRule.none)
                    Text("Open Apps").tag(SmartRule.running)
                    Text("Recently Used").tag(SmartRule.recentlyUsed)
                    Text("Recently Installed").tag(SmartRule.recentlyInstalled)
                }.labelsHidden().fixedSize()
            }
            .dockHubRow()
        }
        if model.draft.rule == .none {
            Card { ItemsEditor(items: $model.draft.items) }
        }
        HStack(spacing: 8) {
            if model.selected != nil {
                Chip("Export") { model.exportStack() }
                Chip("Remove") { model.deleteStack() }
            }
            Chip("Import") { model.importStack() }
            Spacer()
            Button { model.applyStack() } label: {
                Text(model.selected == nil ? "Add to Dock" : "Apply")
                    .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).frame(height: 36)
                    .background(hue, in: .capsule).foregroundStyle(.black)
            }
            .buttonStyle(Pressable(scale: 0.96)).disabled(model.busy)
        }
    }
}

/// The macOS Dock's native Spotlight folders, as a grid of presets: lit in the Dock's hue
/// while one is in the Dock.
struct FlowChips: View {
    let presets: [LivePreset]
    let active: [String]
    let add: (LivePreset) -> Void
    let remove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 6)], spacing: 6) {
            ForEach(presets) { preset in
                let on = active.contains(preset.title)
                Button { on ? remove(preset.title) : add(preset) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: on ? "checkmark" : preset.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? DockHubHue.tint : DS.Ink.secondary)
                            .frame(width: 18)
                            .contentTransition(.symbolEffect(.replace))
                        Text(preset.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(minHeight: 36)
                    .background(DS.Ink.fill.opacity(on ? 0 : 1), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                    .modifier(DockHubPickFrame(selected: on, hover: false, radius: DS.Radius.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(Pressable(scale: 0.97))
                .accessibilityLabel(preset.title)
                .accessibilityValue(on ? "In the Dock" : "Not in the Dock")
            }
        }
    }
}

struct ScenesChapter: View {
    @ObservedObject var model: ManagerModel
    @State private var name = ""
    private var hue: Color { DS.Ink.accent }
    private let gallery = [GridItem(.adaptive(minimum: 236), spacing: DS.Space.m)]

    var body: some View {
        Text("A scene saves the whole Dock. Hover one to see it on the stage.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary)
        hero
        if !model.profiles.isEmpty {
            SectionHeader("Your scenes", symbol: "theatermasks",
                          detail: "Apply switches the Dock in one move. Pick an hour and it switches by itself.", hue: hue)
            LazyVGrid(columns: gallery, alignment: .leading, spacing: DS.Space.m) {
                ForEach(model.profiles) { profile in
                    ScenesTile(model: model, profile: profile, hue: hue)
                }
            }
        }
    }

    private var nameField: some View {
        TextField("Scene name", text: $name).textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).frame(minWidth: 110).frame(height: 32)
            .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
            .onSubmit { if !name.isEmpty && !model.busy { model.saveProfile(named: name); name = "" } }
    }

    @ViewBuilder private var ideas: some View {
        if model.profiles.isEmpty {
            ForEach(["Work", "Play", "Focus"], id: \.self) { idea in
                Chip(idea) { name = idea }
            }
        }
    }

    private var savePill: some View {
        ScenesPill(title: "Save Current", hue: hue, filled: true) { model.saveProfile(named: name); name = "" }
            .disabled(name.isEmpty || model.busy)
            .opacity(name.isEmpty || model.busy ? 0.45 : 1)
            .fixedSize()
    }

    /// The Dock as it is now, on a lit plate, with the field that saves it.
    private var hero: some View {
        let paths = Tiles.apps(model.dock.plist).compactMap(Tiles.path(of:))
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [hue.opacity(name.isEmpty ? 0.22 : 0.42), .clear],
                               center: UnitPoint(x: 0.5, y: 1.15), startRadius: 0, endRadius: 300)
                // As many icons as the plate holds: a fixed twelve pushed the card wider than a
                // narrow panel, clipping the plate and its readout.
                ViewThatFits(in: .horizontal) {
                    ForEach([12, 9, 7, 5, 3], id: \.self) { limit in
                        ScenesDockStrip(paths: paths, icon: 30, limit: limit)
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 26)
                HeroBadge(text: "Beyond macOS", hue: hue).padding(10)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(model.profiles.count)").font(DS.Typo.readout).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(model.profiles.count == 1 ? "SCENE SAVED" : "SCENES SAVED")
                        .font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
                }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 148)
            .background(Color(red: 0.06, green: 0.065, blue: 0.08))
            .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityLabel("Your Dock now, \(paths.count) apps")
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save this setup").font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                    Text("Set up a Dock for work, another for play, then switch in one move or by the hour.")
                        .font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // One line while it fits; in a narrow panel the ideas move to a line of their own,
                // so the field and the button are never squeezed.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s) { nameField; ideas; savePill }
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        HStack(spacing: DS.Space.s) { nameField; savePill }
                        HStack(spacing: DS.Space.s) { ideas }
                    }
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, 14)
            .padding(.bottom, DS.Space.s)
        }
        .padding(DS.Inset.plate)
        .background { CardSurface(style: name.isEmpty ? .standard : .lit(hue)) }
        .animation(DS.Motion.hover, value: name.isEmpty)
    }
}

/// A row of Dock icons on a little shelf.
private struct ScenesDockStrip: View {
    let paths: [String]
    var icon: Double = 22
    var limit = 9

    var body: some View {
        let shown = Array(paths.prefix(limit))
        HStack(spacing: icon * 0.18) {
            if shown.isEmpty {
                Text("Empty Dock").font(DS.caption).foregroundStyle(DS.Ink.tertiary).frame(height: icon)
            }
            ForEach(shown.indices, id: \.self) { index in
                Image(nsImage: NSWorkspace.shared.icon(forFile: shown[index])).resizable().interpolation(.high)
                    .frame(width: icon, height: icon)
            }
            if paths.count > limit {
                Text("+\(paths.count - limit)").font(.system(size: max(icon * 0.38, 10), weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Ink.secondary).frame(height: icon)
            }
        }
        .padding(.horizontal, icon * 0.3).padding(.vertical, icon * 0.2)
        .background(Color.white.opacity(0.09), in: .rect(cornerRadius: icon * 0.42, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: icon * 0.42, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
    }
}

/// A capsule action in a scene's light.
private struct ScenesPill: View {
    let title: String
    let hue: Color
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(filled ? Color.black.opacity(0.85) : DS.Ink.primary)
                .padding(.horizontal, 14).frame(height: 30)
                .background(filled ? AnyShapeStyle(hue) : AnyShapeStyle(hue.opacity(0.2)), in: .capsule)
                .overlay { Capsule().strokeBorder(hue.opacity(filled ? 0 : 0.5), lineWidth: 0.75) }
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.95))
    }
}

/// One saved scene: its Dock in small, its name, its hour, Apply. Hover shows it on the stage
/// and tints the card; nothing moves.
private struct ScenesTile: View {
    @ObservedObject var model: ManagerModel
    let profile: Profile
    let hue: Color
    @State private var paths: [String]?
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ZStack {
                RadialGradient(colors: [hue.opacity(hover ? 0.4 : 0.18), .clear],
                               center: UnitPoint(x: 0.5, y: 1.2), startRadius: 0, endRadius: 180)
                ScenesDockStrip(paths: paths ?? [], icon: 20, limit: 8)
            }
            .frame(height: 72)
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.06, green: 0.065, blue: 0.08))
            .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name).font(DS.title).foregroundStyle(DS.Ink.primary).lineLimit(2)
                    Spacer(minLength: 4)
                    if let hour = profile.hour {
                        Label(String(format: "%02d:00", hour), systemImage: "clock")
                            .font(DS.Typo.value).foregroundStyle(hue)
                    }
                }
                HStack(spacing: DS.Space.s) {
                    Picker("Hour", selection: Binding(get: { profile.hour }, set: { model.setHour($0, for: profile) })) {
                        Text("Manual").tag(Int?.none)
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag(Int?.some($0)) }
                    }
                    .labelsHidden().frame(width: 96)
                    Spacer(minLength: 0)
                    Button { model.removeProfile(profile) } label: {
                        Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.secondary)
                            .frame(width: 30, height: 30).background(DS.Ink.fill, in: .circle).contentShape(Circle())
                    }
                    .buttonStyle(Pressable()).accessibilityLabel("Delete \(profile.name)")
                    ScenesPill(title: "Apply", hue: hue) { model.apply(profile) }
                }
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.bottom, DS.Space.xs)
        }
        .padding(DS.Inset.plate)
        .background { shape.fill(hover ? DS.Ink.fillStrong : DS.Ink.fill) }
        .overlay { shape.strokeBorder(hover ? hue.opacity(0.5) : DS.Ink.hairline, lineWidth: hover ? 0.75 : 0.5) }
        .animation(DS.Motion.hover, value: hover)
        .onAppear {
            guard paths == nil else { return }
            paths = (try? DockStore.plist(at: profile.url)).map { Tiles.apps($0).compactMap(Tiles.path(of:)) } ?? []
        }
        .onHover { over in
            hover = over
            withAnimation(DS.Motion.arrive) {
                model.preview = over ? (try? DockStore.plist(at: profile.url)).map(DockPlistBox.init) : nil
            }
        }
        .stagePreview(.focus("scene." + profile.name, profile.name, region: StageRegion.dock(model.dock.string("orientation", "bottom"))))
    }
}

/// Night Shift and True Tone, in Display & Appearance. Keeping the screen awake is Caffeinate, in Effects.
struct DisplayCards: View {
    @ObservedObject private var display = Display.shared

    var body: some View {
        SectionHeader("Display", symbol: "display", detail: "The switches System Settings has too, one click closer.")
            .onAppear { display.refresh() }
        if display.nightShiftAvailable || display.trueToneAvailable {
            RowGroup {
                if display.nightShiftAvailable {
                    SettingRow(title: "Night Shift", detail: "Warm the screen now, no schedule needed.", density: .compact) {
                        LuxSwitch(isOn: Binding(get: { display.nightShift }, set: { display.setNightShift($0) }), label: "Night Shift")
                    }
                    .stagePreview(.toggle("display.nightShift", "Night Shift", isOn: display.nightShift, region: StageRegion.whole) {
                        $0.nightShift.toggle()
                    })
                    SettingRow(title: "Warmth", density: .compact) {
                        LuxSlider(value: Binding(get: { display.warmth }, set: { display.setWarmth($0, commit: false) }),
                                  range: 0...1, label: "Night Shift warmth") {
                            display.setWarmth(display.warmth, commit: true)
                        }
                        .frame(width: 220)
                    }
                    .stagePreview(.init(id: "display.warmth", title: "Warmth", detail: display.nightShift ? nil : "With Night Shift on",
                                        region: StageRegion.whole) { $0.nightShift = true })
                }
                if display.trueToneAvailable {
                    SettingRow(title: "True Tone", detail: "Adapts the display to the light around you.", density: .compact) {
                        LuxSwitch(isOn: Binding(get: { display.trueTone }, set: { display.setTrueTone($0) }), label: "True Tone")
                    }
                    .stagePreview(.toggle("display.trueTone", "True Tone", isOn: display.trueTone, region: StageRegion.whole) { $0.trueTone.toggle() })
                }
            }
        }
    }
}

struct TweakList: View {
    @ObservedObject var model: ManagerModel
    let tweaks: [Tweak]

    var body: some View {
        // One surface for the list, compact rows with hairlines, not a card per tweak.
        RowGroup {
            ForEach(tweaks) { tweak in
                row(tweak)
            }
        }
    }

    private func row(_ tweak: Tweak) -> some View {
        SettingRow(title: tweak.title, detail: tweak.shortDetail, density: .compact) {
            HStack(spacing: 6) {
                tweak.applyHint
                LuxSwitch(isOn: Binding(get: { Prefs.matches(tweak.key, value: tweak.value, domain: tweak.domain) },
                                        set: { on in model.setTweak(tweak, on: on) }), label: tweak.title)
            }
        }
        .padding(.vertical, DS.Space.s)
        // Domain, key and proof: debug builds only.
        .help(tweak.debugHelp)
        .onHover { over in
            // While scrolling, only the row the pointer rests on once it stops counts.
            guard ScrollActivity.scrolling else {
                withAnimation(DS.Motion.arrive) { model.hoverTweak = over ? tweak : nil }
                return
            }
            if over {
                TweakHover.pending = tweak.id
                ScrollActivity.whenSettled { [model] in
                    guard TweakHover.pending == tweak.id else { return }
                    TweakHover.pending = nil
                    withAnimation(DS.Motion.arrive) { model.hoverTweak = tweak }
                }
            } else {
                if TweakHover.pending == tweak.id { TweakHover.pending = nil }
                if model.hoverTweak?.id == tweak.id { model.hoverTweak = nil }
            }
        }
        .stagePreview(lazy: { [model] in Self.focus(tweak, dockEdge: model.dock.string("orientation", "bottom")) })
        .navTarget(Self.target(tweak))
    }

    /// The id search uses to point at this tweak's row.
    nonisolated static func target(_ tweak: Tweak) -> String { "tweak." + tweak.id }
}

extension TweakList {
    /// A tweak drawn on the replica itself also leans the camera toward it. One shown as a card
    /// in the middle of the stage needs no lean: the card is the preview.
    @MainActor static func focus(_ tweak: Tweak, dockEdge: String) -> StagePreviewSpec? {
        let region: CGRect
        switch TweakStage.surface(tweak) {
        case .dock: region = StageRegion.dock(dockEdge)
        case .menu: region = StageRegion.menuBar
        case .finder, .tiling, .capture: region = StageRegion.window
        case .demo: return nil
        }
        let on = Prefs.matches(tweak.key, value: tweak.value, domain: tweak.domain)
        return StagePreviewSpec(id: "tweak." + tweak.id, title: tweak.title, detail: on ? "On" : "Off → On", region: region)
    }
}

/// Recolours every app icon in the system. Keys found with REA, effect seen on this Mac.
struct IconStudio: View {
    @ObservedObject var model: ManagerModel
    @State private var theme = Prefs.current("AppleIconAppearanceTheme", domain: "NSGlobalDomain") ?? "Default"
    @State private var custom = Color(red: 0.1, green: 0.85, blue: 0.75)
    /// The custom colour waiting to be written. Each write restarts the Dock, so a drag across
    /// the colour wheel writes once, 0.6 s after it comes to rest, instead of queuing a restart
    /// for every colour it passed.
    @State private var pendingTint: Task<Void, Never>?

    private static let presets: [(String, Color)] = [
        ("Blue", .blue), ("Purple", .purple), ("Pink", .pink), ("Orange", .orange),
        ("Yellow", .yellow), ("Green", .green), ("Graphite", .gray),
    ]

    private var family: String {
        if theme.hasPrefix("Tinted") { return "Tinted" }
        if theme.hasPrefix("Clear") { return "Clear" }
        if theme.hasPrefix("Regular") { return "Dark" }
        return "Default"
    }

    private func apply(theme: String?, tint: String? = nil, rgb: String? = nil) {
        pendingTint?.cancel()
        pendingTint = nil
        self.theme = theme ?? "Default"
        model.perform("Recolouring your Mac…", { try IconTint.write(theme: theme, tint: tint, rgb: rgb) }) {
            Effects.shared.iconRevision += 1
        }
    }

    var body: some View {
        card.disabled(!MacPlatform.atLeast(26))
    }

    private var card: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "System Icons")
                // Dark, Clear and Tinted icon styles arrived with macOS 26.
                AvailabilityNote(availability: .needsMacOS(26))
                Segments(selection: Binding(get: { family }, set: { value in
                    switch value {
                    case "Dark": apply(theme: "RegularDark")
                    case "Clear": apply(theme: "ClearDark")
                    case "Tinted": apply(theme: "TintedDark", tint: "Purple")
                    default: apply(theme: nil)
                    }
                }), options: [("Default", "Default"), ("Dark", "Dark"), ("Clear", "Clear"), ("Tinted", "Tinted")],
                    preview: { value in
                        .option("icons.family", "System Icons", value, region: StageRegion.dock(model.dock.string("orientation", "bottom"))) {
                            let key = "NSGlobalDomain.AppleIconAppearanceTheme"
                            switch value {
                            case "Dark": $0.prefs[key] = "RegularDark"
                            case "Clear": $0.prefs[key] = "ClearDark"
                            case "Tinted":
                                $0.prefs[key] = "TintedDark"
                                $0.prefs["NSGlobalDomain.AppleIconAppearanceTintColor"] = "Purple"
                            default: $0.prefs[key] = nil
                            }
                        }
                    })
                .onChange(of: custom) { _, color in model.previewTint = color }
                HStack(spacing: 6) {
                    ForEach(Self.presets, id: \.0) { name, color in
                        Button { apply(theme: "TintedDark", tint: name) } label: {
                            Circle().fill(color).frame(width: 22, height: 22).frame(width: 32, height: 32).contentShape(Circle())
                        }
                        .buttonStyle(Pressable(scale: 0.9)).accessibilityLabel("Tint \(name)")
                        .onHover { over in withAnimation(DS.Motion.arrive) { model.previewTint = over ? color : nil } }
                        .stagePreview(.focus("icons.tint." + name, "Tint " + name, region: StageRegion.dock(model.dock.string("orientation", "bottom"))))
                    }
                    ColorPicker("Any colour", selection: $custom, supportsOpacity: false).labelsHidden()
                        .onChange(of: custom) { _, color in
                            let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
                            let text = String(format: "%f %f %f 1.000000", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                            pendingTint?.cancel()
                            pendingTint = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(600))
                                guard !Task.isCancelled else { return }
                                apply(theme: "TintedDark", tint: "Other", rgb: text)
                            }
                        }
                }
                Text("Any colour, on every app icon. Applying restarts the Dock.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
            }
        }
    }
}

@MainActor
final class Vitals: ObservableObject {
    @Published var memory = 0.0
    @Published var disk = 0.0
    @Published var battery: Double?
    @Published var uptime = 0.0
    /// All cores together, 0 to 1, since the last sample.
    @Published var cpu = 0.0
    /// Swap in use against physical memory, 0 to 1.
    @Published var swap = 0.0
    /// The system's thermal state as 0, ⅓, ⅔ or 1.
    @Published var thermal = 0.0
    /// Download speed in bytes per second. Read only while `wanted` asks for it.
    @Published var network: Double?
    /// Recent fills, oldest first, for each metric in `wanted`: the Dock tile's graph.
    @Published private(set) var history: [VitalMetric: [Double]] = [:]
    nonisolated static let historyLength = 40
    /// Seconds between samples. The Dock's Vitals tile lets the owner choose; never under one.
    var interval: TimeInterval = 3 {
        didSet {
            interval = max(interval, 1)
            if timer != nil, interval != oldValue { schedule() }
        }
    }
    /// What the face shows. Only these keep a history, and network and the hardware sensors
    /// are read only when asked for.
    var wanted: Set<VitalMetric> = [] {
        didSet {
            guard wanted != oldValue else { return }
            history = history.filter { wanted.contains($0.key) }
            if timer != nil { holdSensors(wanted.contains { $0.isSensor }) }
        }
    }
    /// Asked before each timed sample: false while nothing that shows these values can be seen,
    /// so a hidden dock costs one call a tick and no reading.
    var gate: (@MainActor () -> Bool)?
    private var timer: Timer?
    private var ticks = 0
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var counters: [String: UInt32] = [:]
    private var countersAt: Date?
    private var sensorsHeld = false

    /// A ring's fill for the Dock's Vitals tile, 0 to 1; nil for what this Mac cannot show
    /// (no battery, no fans) or has not read yet.
    func value(_ metric: VitalMetric) -> Double? {
        switch metric {
        case .cpu: cpu
        case .memory: memory
        case .disk: disk
        case .battery: battery
        case .thermal: max(thermal, 0.08)
        case .uptime: min(uptime / 604_800, 1)
        // A log scale: 1 KB/s barely moves it, 100 MB/s fills it. The same as the widget's.
        case .network: network.map { min(max(log10(max($0, 1)) - 3, 0) / 5, 1) }
        case .cpuTemp: Sensors.shared.cpu.map { HeatScale.temperature($0) }
        case .gpuTemp: Sensors.shared.gpu.map { HeatScale.temperature($0) }
        case .power: Sensors.shared.watts.map { HeatScale.watts($0) }
        case .fans:
            Sensors.shared.fans.map { rpm in
                let fan = Sensors.shared.latest?.fans.first
                return HeatScale.fan(rpm, min: fan?.min ?? 0, max: fan?.max ?? 6000)
            }
        }
    }

    /// The reading as words: a percentage, a speed, degrees or a state.
    func text(_ metric: VitalMetric) -> String {
        switch metric {
        case .cpu: Units.percent(cpu)
        case .memory: Units.percent(memory)
        case .disk: Units.percent(disk)
        case .battery: battery.map(Units.percent) ?? "—"
        case .thermal: thermal < 0.2 ? "Normal" : thermal < 0.5 ? "Fair" : thermal < 0.9 ? "Serious" : "Critical"
        case .uptime: Units.uptime(since: Date(timeIntervalSinceNow: -uptime), now: Date())
        case .network: Units.rate(network)
        case .cpuTemp: ThermalsFormat.degrees(Sensors.shared.cpu)
        case .gpuTemp: ThermalsFormat.degrees(Sensors.shared.gpu)
        case .power: ThermalsFormat.watts(Sensors.shared.watts)
        case .fans: ThermalsFormat.rpm(Sensors.shared.fans)
        }
    }

    func start() {
        sample()
        schedule()
        holdSensors(wanted.contains { $0.isSensor })
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        holdSensors(false)
    }

    private func schedule() {
        timer?.invalidate()
        let tick = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.gate?() ?? true else { return }
                self.sample()
            }
        }
        tick.tolerance = interval * 0.2
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    private func holdSensors(_ on: Bool) {
        guard on != sensorsHeld else { return }
        sensorsHeld = on
        on ? Sensors.shared.acquire() : Sensors.shared.release()
    }

    private func sample() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * Double(sysconf(_SC_PAGESIZE))
            memory = used / Double(ProcessInfo.processInfo.physicalMemory)
        }
        // The volume query costs ~15 ms on the main thread, and disk use barely moves.
        ticks += 1
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if ticks % 20 == 1, let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
           let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage, total > 0 {
            disk = 1 - Double(free) / Double(total)
        }
        uptime = ProcessInfo.processInfo.systemUptime
        battery = Self.batteryLevel()
        sampleCPU()
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
            swap = min(Double(usage.xsu_used) / Double(ProcessInfo.processInfo.physicalMemory), 1)
        }
        thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: 0
        case .fair: 1.0 / 3
        case .serious: 2.0 / 3
        case .critical: 1
        @unknown default: 0
        }
        if wanted.contains(.network) { sampleNetwork() } else if network != nil { network = nil; counters = [:]; countersAt = nil }
        guard !wanted.isEmpty else { return }
        var next = history
        for metric in wanted {
            guard let fill = value(metric) else { continue }
            var line = next[metric] ?? []
            line.append(fill)
            if line.count > Self.historyLength { line.removeFirst(line.count - Self.historyLength) }
            next[metric] = line
        }
        history = next
    }

    /// Bytes received across Wi‑Fi, Ethernet and cellular since the last sample, per second.
    private func sampleNetwork() {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        var current: [String: UInt32] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            let flags = Int32(item.ifa_flags)
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let data = item.ifa_data else { continue }
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            current[name] = data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes
        }
        let now = Date()
        defer { counters = current; countersAt = now }
        // A long gap (the dock was hidden) would average over minutes: start over instead.
        guard let countersAt, case let elapsed = now.timeIntervalSince(countersAt), elapsed > 0.5, elapsed < interval * 3 + 1 else {
            // Nothing to compare with yet: show it idle rather than leave it out.
            if network == nil { network = 0 }
            return
        }
        var received: UInt64 = 0
        for (name, value) in current {
            // 32-bit kernel counters: wrapping subtraction reads straight across a rollover.
            if let old = counters[name] { received += UInt64(value &- old) }
        }
        network = Double(received) / elapsed
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        if let last = lastTicks, total > last.total {
            cpu = Double(busy - last.busy) / Double(total - last.total)
        }
        lastTicks = (busy, total)
    }

    private static func batteryLevel() -> Double? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Double(current) / Double(maximum)
        }
        return nil
    }
}

struct Ring: View {
    let title: String
    let value: Double
    let tint: Color
    @State private var shown = 0.0

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(DS.Ink.fillStrong, lineWidth: 11)
                Circle().trim(from: 0, to: shown)
                    .stroke(tint, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 112, height: 112)
            Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary)
        }
        .onAppear { withAnimation(.spring(response: 1.1, dampingFraction: 1)) { shown = value } }
        .onChange(of: value) { _, new in withAnimation(DS.Motion.arrive) { shown = new } }
    }
}

struct SystemChapter: View {
    @ObservedObject var model: ManagerModel
    @AppStorage("mood") private var mood = true

    var body: some View {
        let hue = DS.Ink.accent
        SectionHeader("Permissions", symbol: "lock.shield", detail: "What Atelier may reach on your Mac, and the switch for each.", hue: hue)
        // `atelier://studio?chapter=system&focus=permissions`.
        PermissionsCard().navTarget("permissions")

        SectionHeader("Studio", symbol: "paintbrush.pointed", detail: "How Atelier's own window looks. Nothing here touches your Mac.", hue: hue)
        StudioLookCard()
        StudioIconCard()

        SectionHeader("General", symbol: "gearshape", hue: hue)
        RowGroup {
            SettingRow(title: "Glass Mood", detail: "Bubble glass follows your wallpaper.", symbol: "drop", density: .compact) {
                LuxSwitch(isOn: $mood, label: "Glass Mood")
            }
            LoginItemRow()
            SettingRow(title: "Clipboard History", detail: "Text only, kept in memory, skips passwords. Find it in Command.",
                       symbol: "doc.on.clipboard", density: .compact) {
                LuxSwitch(isOn: Binding(get: { ClipboardHistory.shared.enabled }, set: { ClipboardHistory.shared.enabled = $0 }),
                          label: "Clipboard History")
            }
        }

        SectionHeader("Shortcuts", symbol: "command", hue: hue)
        RowGroup {
            CommandShortcutRow()
            SettingRow(title: "Shortcuts", detail: "Open a stack from the Shortcuts app.", symbol: "square.stack.3d.up", density: .compact) {
                Text("atelier://open?name=Stack").font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Ink.secondary).textSelection(.enabled)
            }
        }

        SectionHeader("This Mac", symbol: "info.circle", hue: hue)
        StudioThisMacCard()

        SectionHeader("Remove Atelier", symbol: "trash", hue: DS.Ink.tertiary)
        RemoveAtelierCard()
    }
}

/// Undoing Atelier, in two strengths. Each opens a summary of exactly what will be put back
/// before anything happens (RevertSheet, AtelierRevert.swift).
private struct RemoveAtelierCard: View {
    @State private var sheet: RevertSheet.Mode?

    var body: some View {
        Card(style: .quiet) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SettingRow(title: "Revert All macOS Changes", detail: "Puts back every setting Atelier changed and turns those features off. Atelier stays.",
                           symbol: "arrow.uturn.backward", density: .compact) {
                    Button("Review…") { sheet = .revert }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remove Everything").font(DS.title).foregroundStyle(DS.Ink.primary)
                    Text("Puts back every macOS change, removes stacks from the Dock, deletes app data including the timeline, and quits. You see the full list first.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HoldButton(title: "Hold to Remove") { sheet = .remove }
            }
        }
        .sheet(item: $sheet) { mode in RevertSheet(mode: mode) }
    }
}

/// Command's shortcut, or why it is not Command's: a failed ⌥ Space registration used to be
/// ignored while this row still showed the keycaps.
private struct CommandShortcutRow: View {
    @State private var failure = HotKey.failure

    var body: some View {
        SettingRow(title: "Command", detail: failure ?? "Search Atelier, apps and your clipboard.", symbol: "magnifyingglass",
                   density: .compact) {
            if failure == nil {
                HStack(spacing: 4) {
                    SystemKeycap(text: "⌥")
                    SystemKeycap(text: "Space")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Option Space")
            } else {
                Button("Try Again") {
                    HotKey.install()
                    failure = HotKey.failure
                }
                .controlSize(.small)
            }
        }
    }
}

/// A key, drawn small: how Settings shows a shortcut.
private struct SystemKeycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 22)
            .background(DS.Ink.fillStrong, in: .rect(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.Ink.edge, lineWidth: 0.5)
            }
    }
}

// MARK: - On-stage chapters

/// Scrub through every past Dock and watch it on the stage.
struct TimeOverlay: View {
    @ObservedObject var model: ManagerModel
    @State private var position = 0.0
    @State private var ordered: [Snapshot] = []
    @State private var loaded = false

    private var index: Int { ordered.isEmpty ? 0 : min(max(Int(position.rounded()), 0), ordered.count - 1) }

    private var selected: Snapshot? {
        guard !ordered.isEmpty else { return nil }
        return ordered[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if let selected {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index == ordered.count - 1 ? "Now" : selected.date.formatted(.relative(presentation: .named)))
                            .font(DS.Typo.readout).foregroundStyle(DS.Ink.primary)
                            .contentTransition(.numericText())
                        Text("\(selected.label) · \(selected.date.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute()))")
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(index + 1) of \(ordered.count)").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                    HStack(spacing: 4) {
                        step("chevron.left", label: "Earlier change", by: -1).disabled(index == 0)
                        step("chevron.right", label: "Later change", by: 1).disabled(index >= ordered.count - 1)
                    }
                    Chip("Go Back Here") { model.perform("Going back…", { try DockStore.restore(selected) }) }
                        .disabled(model.busy)
                }
                TimeTrack(dates: ordered.map(\.date), position: $position)
            } else if !loaded {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading the timeline…").font(DS.body).foregroundStyle(DS.Ink.secondary)
                }
            } else {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(DS.Ink.accent)
                    Text("No changes yet. Every Dock change leaves a point here to come back to.")
                        .font(DS.body).foregroundStyle(DS.Ink.secondary)
                }
            }
        }
        .padding(DS.Inset.card)
        .frame(maxWidth: 680)
        .atelierGlass(.regular.tint(.black.opacity(0.25)), in: .rect(cornerRadius: 24))
        .frame(maxHeight: .infinity, alignment: .bottom)
        // In the band under the stage, above the change card: it never covers the Dock it shows.
        .padding(.bottom, StudioLayout.bottom + 4)
        .task {
            // An empty Dock is never a place worth going back to. Reading up to 200 snapshots is
            // file work, so it runs off the main thread and the overlay fills in when it is done.
            let snapshots = Array(model.snapshots.reversed())
            let kept = await Task.detached(priority: .userInitiated) {
                snapshots.filter { !Tiles.apps((try? DockStore.plist(at: $0.url)) ?? [:]).isEmpty }
            }.value
            ordered = kept
            loaded = true
            position = Double(max(ordered.count - 1, 0))
            show()
        }
        .onChange(of: index) { _, _ in show() }
    }

    private func step(_ symbol: String, label: String, by delta: Int) -> some View {
        Button {
            withAnimation(DS.Motion.settle) { position = Double(min(max(index + delta, 0), max(ordered.count - 1, 0))) }
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Ink.primary)
                .frame(width: 30, height: 30).background(DS.Ink.fillStrong, in: .circle).contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.92))
        .accessibilityLabel(label)
    }

    private func show() {
        guard let selected else { return }
        model.preview = (try? DockStore.plist(at: selected.url)).map(DockPlistBox.init)
    }
}

/// The timeline itself: a tick per change, a taller tick and a label where each day begins,
/// lit up to the knob. Drag or click anywhere on it; arrow keys step through changes.
private struct TimeTrack: View {
    let dates: [Date]
    @Binding var position: Double
    @State private var dragging = false
    private let hue = DS.Ink.accent

    private var last: Double { Double(max(dates.count - 1, 1)) }

    /// Where each new day starts, by index.
    private var dayStarts: [Int] {
        let calendar = Calendar.current
        return dates.indices.filter { $0 == 0 || !calendar.isDate(dates[$0], inSameDayAs: dates[$0 - 1]) }
    }

    var body: some View {
        let starts = dayStarts
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let x = { (i: Double) -> Double in dates.count < 2 ? width / 2 : width * i / last }
                let knob = x(min(max(position, 0), last))
                ZStack(alignment: .leading) {
                    // Ticks: drawn once per change of position, no per-tick views.
                    Canvas { context, size in
                        let mid = size.height / 2
                        let starts = Set(starts)
                        for i in dates.indices {
                            let tx = x(Double(i))
                            let tall = starts.contains(i)
                            let h = tall ? 18.0 : 9.0
                            let lit = Double(i) <= position + 0.001
                            let rect = CGRect(x: tx - (tall ? 1 : 0.75), y: mid - h / 2, width: tall ? 2 : 1.5, height: h)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                         with: .color(lit ? hue.opacity(tall ? 0.95 : 0.7) : Color.white.opacity(tall ? 0.38 : 0.2)))
                        }
                    }
                    // The lit run behind the ticks.
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
                    Capsule().fill(LinearGradient(colors: [hue.opacity(0.15), hue.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(knob, 3), height: 3)
                    // The knob.
                    Circle().fill(.white)
                        .frame(width: dragging ? 18 : 16, height: dragging ? 18 : 16)
                        .overlay { Circle().strokeBorder(hue, lineWidth: 3) }
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: knob - (dragging ? 9 : 8))
                        .animation(DS.Motion.touch, value: dragging)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        position = min(max((value.location.x / max(width, 1)) * last, 0), last).rounded()
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(height: 28)
            // Day labels under the first change of each day, thinned so they never collide.
            GeometryReader { geometry in
                let width = geometry.size.width
                let every = max(1, Int((Double(starts.count) * 64 / max(width, 1)).rounded(.up)))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(starts.enumerated()).filter { $0.offset % every == 0 && $0.element < dates.count - 1 }, id: \.element) { _, i in
                        let tx = dates.count < 2 ? width / 2 : width * Double(i) / last
                        Text(dates[i].formatted(.dateTime.weekday(.abbreviated).day()))
                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(DS.Ink.tertiary)
                            .fixedSize()
                            .offset(x: min(max(tx - 2, 0), max(width - 70, 0)))
                    }
                    Text("Now").font(.system(size: 10, weight: .semibold)).foregroundStyle(hue)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("Change \(Int(position.rounded()) + 1) of \(dates.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: position = min(position.rounded() + 1, last)
            case .decrement: position = max(position.rounded() - 1, 0)
            @unknown default: break
            }
        }
    }
}

extension Notification.Name {
    static let studioChapter = Notification.Name("studioChapter")
}

@MainActor
final class ManagerWindow {
    static let shared = ManagerWindow()
    private var window: NSWindow?

    /// The Studio window, so the rest of the app can tell it from Atelier's panels.
    var studioWindow: NSWindow? { window }

    /// Atelier's own Dock tile: the Studio comes forward, or, already in front, closes to the
    /// menu bar. Atelier itself never hides: its Dock, widgets and effects stay on screen.
    func toggle() {
        if let window, window.isVisible, window.isKeyWindow, NSApp.isActive {
            window.close()
        } else {
            show()
        }
    }

    func show(chapter: String? = nil) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: StudioView()))
            window.title = "Atelier"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Off on purpose: with it on, AppKit rebuilt the draggable region from every SwiftUI view on
            // every frame of an animation (a quarter of the main thread). The title bar still drags.
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.setContentSize(NSSize(width: 1440, height: 860))
            window.center()
            self.window = window
            // The close button sends Atelier to the menu bar: the window goes, the app stays,
            // and its Dock icon leaves with the window. Quit is in the menu bar item and ⌘Q.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    NSApp.setActivationPolicy(.accessory)
                    StudioIconCard.restore()
                }
            }
            StudioIconCard.restore()
            // Frame timing for atelier://diag, only when asked: the link wakes the main thread 120 times a second.
            if ProcessInfo.processInfo.environment["ATELIER_FPS"] != nil, let view = window.contentView { FrameMeter.shared.attach(view) }
        }
        // Already in front: just change chapter. Activating again reloads the model for nothing.
        // While the Studio is open Atelier is a normal app, with its icon in the Dock.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            StudioIconCard.restore()
        }
        if !(window?.isKeyWindow ?? false) || !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        if let chapter {
            NotificationCenter.default.post(name: .studioChapter, object: chapter)
        }
    }
}



/// The tweak row the pointer reached during a scroll, shown once the scroll rests.
@MainActor
enum TweakHover {
    static var pending: String?
}






struct LoginItemRow: View {
    @ObservedObject private var login = LoginItemState.shared

    var body: some View {
        SettingRow(title: "Open at Login", detail: login.note, symbol: "power", density: .compact) {
            LuxSwitch(isOn: Binding(get: { login.enabled }, set: { login.set($0) }), label: "Open at Login")
        }
    }
}

// MARK: - This Mac

/// What Atelier sees of the Mac it runs on, gathered on demand. Bug reports for an open-source app
/// come from every Mac from Sonoma on, Intel and Apple silicon, with and without a notch or a
/// Force Touch trackpad; this is the paragraph that makes them reproducible.
@MainActor
enum StudioThisMac {
    static func facts() -> ShellMacFacts {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        // AtelierVersion ("1.0.0-beta.1"), the one the updater and the release notes use.
        let app = "\(AtelierInfo.version) (\(AtelierInfo.build ?? "-"))"
        return ShellMacFacts(osVersion: os, osBuild: sysctlString("kern.osversion") ?? "?", model: sysctlString("hw.model") ?? "Mac",
                             chip: sysctlString("machdep.cpu.brand_string") ?? (MacPlatform.appleSilicon ? "Apple silicon" : "Intel"),
                             appleSilicon: MacPlatform.appleSilicon, translated: MacPlatform.translated,
                             displays: displays(), trackpad: trackpad(), sip: sip(), appVersion: app)
    }

    /// A display with real XDR headroom (Liquid Retina XDR, Pro Display XDR report 16x; ordinary
    /// HDR panels report 2 to 5 and SDR panels 1). Read live, since displays come and go.
    static var hasXDRDisplay: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue >= 8 }
    }

    /// Any trackpad, built in or Magic Trackpad. Cached for a minute: the registry walk is cheap,
    /// but Home asks on every layout.
    static var hasTrackpad: Bool {
        if let cached = trackpadCache, Date().timeIntervalSince(cached.at) < 60 { return cached.found }
        let found = trackpad() != "None found"
        trackpadCache = (Date(), found)
        return found
    }
    private static var trackpadCache: (at: Date, found: Bool)?

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func displays() -> [ShellMacFacts.Display] {
        NSScreen.screens.enumerated().map { index, screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return ShellMacFacts.Display(name: screen.localizedName, main: index == 0, builtIn: id != 0 && CGDisplayIsBuiltin(id) != 0,
                                         points: "\(Int(screen.frame.width))×\(Int(screen.frame.height))",
                                         scale: Double(screen.backingScaleFactor), refreshRate: screen.maximumFramesPerSecond,
                                         notch: screen.safeAreaInsets.top > 0,
                                         edrHeadroom: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
        }
    }

    /// Multitouch devices in the I/O Registry: the built-in trackpad and any Magic Trackpad.
    /// Read-only, public IOKit, so it works the same on Intel and Apple silicon. A Mac mini or
    /// iMac with only a mouse reports none, which is exactly what a gestures bug report needs.
    private static func trackpad() -> String {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else {
            return "Unknown"
        }
        defer { IOObjectRelease(iterator) }
        var found: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            func flag(_ key: String) -> Bool {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
            }
            let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            // Keyboards with Touch Bar and some mice are multitouch devices too; only trackpads have force or a built-in flag.
            let builtIn = flag("MT Built-In"), force = flag("ForceSupported")
            if builtIn || force || (product?.localizedCaseInsensitiveContains("trackpad") ?? false) {
                found.append([builtIn ? "Built-in" : (product ?? "Trackpad"), force ? "Force Touch" : "no Force Touch"].joined(separator: ", "))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return found.isEmpty ? "None found" : found.joined(separator: "; ")
    }

    private typealias CSRGetActiveConfig = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32

    /// SIP straight from the kernel, resolved at run time so nothing links against it.
    private static func sip() -> String {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csr_get_active_config") else { return "Unknown" }
        var config: UInt32 = 0
        guard unsafeBitCast(symbol, to: CSRGetActiveConfig.self)(&config) == 0 else { return "Unknown" }
        if config == 0 { return "On" }
        let decoded = BridgeSIP(config: config)
        let off = [decoded.filesystemProtectionsOff ? "filesystem" : nil, decoded.debuggingRestrictionsOff ? "debugging" : nil,
                   decoded.nvramProtectionsOff ? "NVRAM" : nil].compactMap { $0 }
        return (off.isEmpty ? "Customised" : "Partly off (\(off.joined(separator: ", ")))") + String(format: ", csr 0x%02X", config)
    }
}

/// Settings card: the Mac as Atelier sees it, and one chip that copies it for an issue.
struct StudioThisMacCard: View {
    @State private var facts: ShellMacFacts?
    @State private var copied = false

    var body: some View {
        Card(padding: DS.Inset.plate) {
            VStack(alignment: .leading, spacing: 0) {
                // The Mac itself, named large, on a plate of its own.
                HStack(spacing: DS.Space.m) {
                    Image(systemName: facts.map { $0.displays.contains(where: \.builtIn) ? "laptopcomputer" : "desktopcomputer" } ?? "desktopcomputer")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(DS.Ink.accent)
                        .frame(width: 48, height: 48)
                        .background(DS.Ink.accent.opacity(0.12), in: .rect(cornerRadius: DS.Radius.pill, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(facts?.chip ?? "This Mac").font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let facts {
                            Text("macOS \(facts.osVersion) \(ShellMacFacts.releaseName(major: MacPlatform.major)) · \(facts.model)")
                                .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Chip(copied ? "Copied" : "Copy for a bug report") { copy() }
                        .accessibilityHint("Copies the details below to paste into an issue")
                }
                .padding(DS.Space.m)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.plate, style: .continuous))
                if let facts {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
                        row("macOS", "\(facts.osVersion) \(ShellMacFacts.releaseName(major: MacPlatform.major)) (\(facts.osBuild))")
                        row("Mac", "\(facts.model), \(facts.chip)")
                        row("Architecture", facts.architecture)
                        ForEach(Array(facts.displays.enumerated()), id: \.offset) { _, display in
                            row(display.builtIn ? "Built-in display" : "Display",
                                "\(display.points) pt, \(display.refreshRate) Hz, \(display.range)\(display.notch ? ", notch" : "")")
                        }
                        row("Trackpad", facts.trackpad)
                        row("SIP", facts.sip)
                    }
                    .padding(.horizontal, DS.Space.s)
                    .padding(.top, DS.Space.m)
                    .padding(.bottom, DS.Space.s)
                } else {
                    ProgressView().controlSize(.small).padding(DS.Space.m)
                }
            }
        }
        .onAppear { if facts == nil { facts = StudioThisMac.facts() } }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(DS.caption).foregroundStyle(DS.Ink.tertiary).gridColumnAlignment(.trailing)
            Text(value).font(DS.caption).foregroundStyle(DS.Ink.primary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy() {
        // Gathered again: a display may have been plugged in since the card appeared.
        let fresh = StudioThisMac.facts()
        facts = fresh
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("```\n" + fresh.report + "\n```", forType: .string)
        withAnimation(DS.Motion.touch) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(DS.Motion.touch) { copied = false } }
    }
}
