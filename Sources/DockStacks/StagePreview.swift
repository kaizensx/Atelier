import AppKit
import SwiftUI

// MARK: - Hover previews
//
// Any control can show on the stage what it would do, before it is done.
//
// Adopting it takes one modifier, on the control or on the whole card or row it sits in:
//
//     Card { SettingRow(title: "Day Line") { LuxSwitch(isOn: $effects.dayLine, label: "Day Line") } }
//         .stagePreview(.toggle("dayLine", "Day Line", isOn: effects.dayLine, region: StageRegion.menuBar) {
//             $0.dayLine.toggle()
//         })
//
// - `region`, in stage fractions (0...1, top left to bottom right), is where the change shows. The camera
//   leans toward it and a soft halo marks it, so even a setting with nothing to draw says where it acts.
//   `StageRegion` has the usual places: `.menuBar`, `.desktop`, `.clock`, `.vitals`, `.window`, `.whole`,
//   `.dock(edge)`, `.ownDock(edge)`.
// - `apply` edits a copy of the Mac as the stage draws it (`StageSnapshot`): set what the control would set.
//   The replica draws that copy while the pointer rests on the view, the way it draws the moment before a
//   change for Before and After. Nil only points at the region.
// - Nothing real changes. Leaving the view, changing chapter, or a real change settling ends the preview.
// - Controls with options take one spec per option: `Segments(selection:options:preview:)`, or the
//   modifier on each swatch or chip. Nested previews stack: leaving a chip returns to its card's preview.

/// What hovering a view would do, and where it shows on the stage.
struct StagePreviewSpec {
    var id: String
    /// The name of the setting, shown beside the halo. Nil shows no caption.
    var title: String?
    /// The outcome in a few words, for example "Off → On" or "Left".
    var detail: String?
    /// Where on the stage it acts, in stage fractions.
    var region: CGRect?
    /// Edits the stage's copy of the Mac. Runs once, when the pointer arrives.
    var apply: (@MainActor (inout StageSnapshot) -> Void)?
    /// The automatic preview every setting row has. Any specific preview under the pointer wins.
    var fallback = false
    /// A before-and-after the stage plays, for what the replica cannot draw itself.
    var demo: DemoSpec?
    /// Which side of the demo is the Mac as it is now.
    var applied = false
    /// Changes the stage's Atelier Dock while the pointer rests: look, design, size, behaviour.
    var dock: (@MainActor (inout StageDockLook) -> Void)?
    /// Drawn over the stage's screen, for effects that sit over everything: the effect itself.
    var overlay: (@MainActor (CGSize) -> AnyView)?

    init(id: String, title: String? = nil, detail: String? = nil, region: CGRect? = nil,
         apply: (@MainActor (inout StageSnapshot) -> Void)? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.region = region
        self.apply = apply
    }

    /// A switch: the stage shows it flipped, and the caption says which way.
    static func toggle(_ id: String, _ title: String, isOn: Bool, region: CGRect?,
                       apply: (@MainActor (inout StageSnapshot) -> Void)? = nil) -> StagePreviewSpec {
        StagePreviewSpec(id: id, title: title, detail: isOn ? "On → Off" : "Off → On", region: region, apply: apply)
    }

    /// One option of several: the stage shows that option.
    static func option(_ id: String, _ title: String, _ option: String, region: CGRect?,
                       apply: (@MainActor (inout StageSnapshot) -> Void)? = nil) -> StagePreviewSpec {
        StagePreviewSpec(id: id + "." + option, title: title, detail: option, region: region, apply: apply)
    }

    /// Only where it acts: for a slider, or for a setting the replica cannot draw.
    static func focus(_ id: String, _ title: String? = nil, region: CGRect) -> StagePreviewSpec {
        StagePreviewSpec(id: id, title: title, region: region)
    }
}

/// The preview the stage is drawing now. One instance, read by the stage and the camera.
@MainActor
final class StagePreview: ObservableObject {
    static let shared = StagePreview()

    struct Active {
        let id: String
        let title: String?
        let detail: String?
        let region: CGRect?
        /// The Mac with the change made, or nil when the preview only points.
        let snapshot: StageSnapshot?
        var demo: DemoSpec? = nil
        var applied = false
        var overlay: (@MainActor (CGSize) -> AnyView)? = nil
    }

    @Published private(set) var active: Active?
    private var waitingForPanel = false

    /// The panel has landed: show what the pointer rests on now, if anything.
    func panelSettled() {
        guard waitingForPanel else { return }
        waitingForPanel = false
        show()
    }
    /// Views under the pointer, outermost first. The last one shows.
    private var stack: [StagePreviewSpec] = []
    private var leaving: DispatchWorkItem?

    private init() {}

    func begin(_ spec: StagePreviewSpec) {
        stack.removeAll { $0.id == spec.id }
        stack.append(spec)
        // Scrolling, or a panel arriving, slides row after row under a still pointer. Each would
        // start a preview and move the stage's camera on every frame. Wait until all rests.
        if ManagerModel.current?.panelArriving == true {
            waitingForPanel = true
            return
        }
        if ScrollActivity.scrolling {
            ScrollActivity.whenSettled { StagePreview.shared.show() }
            return
        }
        show()
    }

    /// Waits a moment, so sliding from one control to the next does not flash the plain Mac between them.
    func end(_ id: String) {
        guard stack.contains(where: { $0.id == id }) else { return }
        stack.removeAll { $0.id == id }
        leaving?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.show() } }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// A chapter change or a real change ends every preview at once.
    func clear() {
        leaving?.cancel()
        leaving = nil
        stack.removeAll()
        if StageDockOverride.shared.look != nil { StageDockOverride.shared.look = nil }
        if active != nil { withAnimation(.smooth(duration: 0.35)) { active = nil } }
    }

    fileprivate func show() {
        leaving?.cancel()
        leaving = nil
        guard let spec = stack.last(where: { !$0.fallback }) ?? stack.last else {
            if StageDockOverride.shared.look != nil { StageDockOverride.shared.look = nil }
            if active != nil { withAnimation(.spring(response: 0.7, dampingFraction: 1)) { active = nil } }
            return
        }
        guard active?.id != spec.id else { return }
        // The last settled moment is a copy already made: no preference is read on the hover frame.
        var snapshot: StageSnapshot?
        if let apply = spec.apply, var base = StageChanges.shared.latest {
            apply(&base)
            snapshot = base
        }
        // The camera's lean rides on this: a soft spring, shorter than a chapter's move.
        // The stage's Atelier Dock wears the setting while the pointer rests on it.
        if let change = spec.dock {
            var look = StageDockLook.now()
            change(&look)
            StageDockOverride.shared.look = look
        } else if StageDockOverride.shared.look != nil {
            StageDockOverride.shared.look = nil
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 1)) {
            active = Active(id: spec.id, title: spec.title, detail: spec.detail, region: spec.region, snapshot: snapshot,
                            demo: spec.demo, applied: spec.applied, overlay: spec.overlay)
        }
    }
}

private struct StagePreviewHover: ViewModifier {
    let spec: StagePreviewSpec?

    func body(content: Content) -> some View {
        if let spec {
            content
                .onHover { over in
                    if over { StagePreview.shared.begin(spec) } else { StagePreview.shared.end(spec.id) }
                }
                .onDisappear { StagePreview.shared.end(spec.id) }
        } else {
            content
        }
    }
}

/// Builds the spec only when the pointer arrives, for long lists where reading state per row costs.
private struct LazyStagePreviewHover: ViewModifier {
    let make: @MainActor () -> StagePreviewSpec?
    @State private var shown: String?

    func body(content: Content) -> some View {
        content
            .onHover { over in
                if over, let spec = make() {
                    shown = spec.id
                    StagePreview.shared.begin(spec)
                } else if let id = shown {
                    shown = nil
                    StagePreview.shared.end(id)
                }
            }
            .onDisappear { if let shown { StagePreview.shared.end(shown) } }
    }
}

extension View {
    /// Shows on the stage what this control would do while the pointer rests on it. See `StagePreviewSpec`.
    func stagePreview(_ spec: StagePreviewSpec?) -> some View {
        modifier(StagePreviewHover(spec: spec))
    }

    /// The same, with the spec made when the pointer arrives instead of on every redraw.
    func stagePreview(lazy make: @escaping @MainActor () -> StagePreviewSpec?) -> some View {
        modifier(LazyStagePreviewHover(make: make))
    }
}

// MARK: - Camera

/// Where the camera looks: the chapter's own view, leaning toward whatever is being previewed.
@MainActor
func stageCamera(_ chapter: Chapter, preview: CGRect?) -> (zoom: Double, focus: UnitPoint) {
    // A preview points at its place (a spotlight and a locator ring); the camera stays where the
    // chapter put it. Leaning in made the stage grow under the panel and menus and cut it off.
    chapter.camera
}

/// The stage's place in the window for a camera: never leaving a gap on a side it overflows,
/// never sliding out of the room on a side it fits.
struct StageFraming: Equatable {
    /// The stage's centre offset from the viewport's centre, in window points.
    var offset: CGSize
    /// The drawn stage size, in window points.
    var shown: CGSize

    static func make(canvas: CGSize, scale: Double, focus: UnitPoint, viewport: CGSize) -> StageFraming {
        let shown = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        func axis(_ size: Double, _ view: Double, _ f: Double) -> Double {
            // A stage smaller than the viewport on this axis stays centred: leaning it
            // would leave an empty band on one side only.
            guard size > view else { return 0 }
            let wanted = (0.5 - f) * size
            let reach = abs(size - view) / 2
            return min(max(wanted, -reach), reach)
        }
        return StageFraming(offset: CGSize(width: axis(shown.width, viewport.width, focus.x),
                                           height: axis(shown.height, viewport.height, focus.y)),
                            shown: shown)
    }
}

// MARK: - Stage to panel

/// What the stage picked, for the chapter it opens. The Dock chapter reads `dockTile` to open that tile's inspector.
@MainActor
final class StageFocus: ObservableObject {
    static let shared = StageFocus()
    /// The id of the Atelier Dock tile clicked on the stage (`OwnDockItem.id`).
    @Published var dockTile: String?
    private init() {}
}

/// What can be dropped on the stage, as plain text so any `.draggable` can carry it.
enum StageDrop {
    static let widgetPrefix = "atelier-widget:"
    static func widget(_ kind: WidgetKind) -> String { widgetPrefix + kind.rawValue }
    static func widgetKind(_ text: String) -> WidgetKind? {
        guard text.hasPrefix(widgetPrefix) else { return nil }
        return WidgetKind(rawValue: String(text.dropFirst(widgetPrefix.count)))
    }
}

// MARK: - Stage drawing

/// A soft ring around the place a hovered control acts on. Its name and outcome are `StageCaption`.
struct PreviewHalo: View {
    let active: StagePreview.Active
    let canvas: CGSize
    let zoom: Double

    var body: some View {
        if let region = active.region {
            let rect = CGRect(x: region.minX * canvas.width, y: region.minY * canvas.height,
                              width: region.width * canvas.width, height: region.height * canvas.height)
            let whole = region.width > 0.9 && region.height > 0.9
            ZStack(alignment: .topLeading) {
                if !whole {
                    // A spotlight, not a box: the rest of the screen dims softly around where the
                    // setting acts. A gradient, not a blur, so it costs nothing while the camera moves.
                    let centre = UnitPoint(x: rect.midX / canvas.width, y: rect.midY / canvas.height)
                    let reach = max(rect.width / canvas.width, rect.height / canvas.height)
                    EllipticalGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .clear, location: min(reach * 0.55, 0.7)),
                                               .init(color: .black.opacity(0.4), location: min(reach * 0.55 + 0.35, 1))],
                                       center: centre)
                        .frame(width: canvas.width, height: canvas.height)
                }
                // The locator: two soft rings breathing out from where the setting acts. Not for
                // what covers the whole screen, where "here" means everywhere.
                if !whole, region.width < 0.6 || region.height < 0.6 {
                    PreviewLocator(zoom: zoom)
                        .position(x: rect.midX, y: rect.midY)
                }
                // The caption is not drawn here: inside the scaled canvas it shrank to a few
                // points. `StageCaption` shows it at a fixed size, under the stage.
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}


/// The hovered setting's name and outcome ("Window Borders  Off → On"), in a glass chip at a fixed
/// 13 points under the stage. It lives outside the scaled canvas, so it reads the same at any
/// camera zoom. The only view besides the stage that watches the preview.
struct StageCaption: View {
    @ObservedObject private var preview = StagePreview.shared

    var body: some View {
        ZStack {
            if let active = preview.active, let title = active.title {
                HStack(spacing: 7) {
                    Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.accent)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                    if let detail = active.detail {
                        Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14).frame(height: 30)
                .atelierGlass(.regular.tint(.black.opacity(0.25)), in: .capsule)
                .id(active.id)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(DS.Motion.hover, value: preview.active?.id)
        .allowsHitTesting(false)
    }
}

/// Whether the Studio is being scrolled. Hover previews hold off until it rests.
@MainActor
enum ScrollActivity {
    private static var until = Date.distantPast
    private static var waiting: [() -> Void] = []
    private static var timer: Timer?
    private static var monitor: Any?

    static var scrolling: Bool { Date() < until }

    /// Called once at launch: every scroll in the app's windows marks the moment.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            ScrollActivity.note()
            return event
        }
    }

    static func note() {
        // A trackpad pauses between flicks; a preview should wait for a real rest, not a pause.
        until = Date().addingTimeInterval(0.35)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.36, repeats: false) { _ in
            MainActor.assumeIsolated { settle() }
        }
    }

    static func whenSettled(_ work: @escaping () -> Void) {
        waiting.append(work)
    }

    private static func settle() {
        guard !scrolling else { return }
        let work = waiting
        waiting = []
        work.forEach { $0() }
    }
}


/// Every setting row's own preview: the camera leans to where the chapter acts and the row's name
/// and outcome show there. A specific preview on the row, or on a control in it, takes over.
struct FallbackStagePreview: ViewModifier {
    let title: String
    let detail: String?
    @State private var shown: String?

    func body(content: Content) -> some View {
        content
            .onHover { over in
                if over, let model = ManagerModel.current, model.panelChapter != .home {
                    let chapter = model.panelChapter
                    var spec = StagePreviewSpec(id: "row." + chapter.rawValue + "." + title, title: title,
                                                detail: detail.map(Self.short),
                                                region: StageRegion.area(chapter, dockEdge: model.dock.string("orientation", "bottom")))
                    spec.fallback = true
                    shown = spec.id
                    StagePreview.shared.begin(spec)
                } else if let id = shown {
                    shown = nil
                    StagePreview.shared.end(id)
                }
            }
            .onDisappear { if let shown { StagePreview.shared.end(shown) } }
    }

    /// The first sentence, so the caption stays a caption.
    private static func short(_ text: String) -> String {
        let first = text.split(separator: ".", maxSplits: 1).first.map(String.init) ?? text
        return first.count > 90 ? String(first.prefix(88)) + "…" : first
    }
}


// MARK: - The stage's Atelier Dock, previewed

/// What a dock setting changes, applied to the stage's dock only while hovered.
struct StageDockLook {
    var appearance: DockAppearance
    var design: DockDesignPrefs
    var tile: Double
    var large: Double
    var magnify: Bool
    var autoHide: Bool
    var edge: OwnDockEdge
    var focusMode: Bool

    @MainActor static func now() -> StageDockLook {
        let dock = OwnDock.shared
        return StageDockLook(appearance: dock.appearance, design: dock.design, tile: dock.tile, large: dock.large,
                             magnify: dock.magnify, autoHide: dock.autoHide, edge: dock.edge, focusMode: dock.hub.focusMode)
    }
}

/// Read only by the stage's dock, so a preview redraws nothing else.
@MainActor
final class StageDockOverride: ObservableObject {
    static let shared = StageDockOverride()
    @Published var look: StageDockLook?
}

extension StagePreviewSpec {
    /// A dock setting: the stage's Atelier Dock shows it, and a pointer sweeps along it so a
    /// lens, a curve or a bounce can be seen moving.
    @MainActor static func dock(_ id: String, _ title: String, detail: String? = nil,
                     _ change: @escaping @MainActor (inout StageDockLook) -> Void) -> StagePreviewSpec {
        var spec = StagePreviewSpec(id: "dock." + id, title: title, detail: detail,
                                    region: StageRegion.ownDock(OwnDock.shared.edge))
        spec.dock = change
        return spec
    }

    /// Any setting the replica cannot draw: a before-and-after the stage plays.
    static func demo(_ id: String, _ title: String, isOn: Bool, region: CGRect? = nil, _ demo: DemoSpec) -> StagePreviewSpec {
        var spec = StagePreviewSpec(id: "demo." + id, title: title, detail: isOn ? "On → Off" : "Off → On", region: region)
        spec.demo = demo
        spec.applied = isOn
        return spec
    }
}


/// Two rings that keep opening from a point: "here", without covering what is there.
struct PreviewLocator: View {
    let zoom: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<2, id: \.self) { ring in
                    let p = (t / 1.6 + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder(.white.opacity(0.7 * (1 - p)), lineWidth: 2 / zoom)
                        .frame(width: (14 + 60 * p) / zoom, height: (14 + 60 * p) / zoom)
                }
                // A dark rim instead of a shadow: nothing blurred inside a view redrawn every frame.
                Circle().fill(.white).frame(width: 7 / zoom, height: 7 / zoom)
                    .overlay { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1 / zoom) }
            }
        }
        .allowsHitTesting(false)
    }
}


extension StagePreviewSpec {
    /// An effect over the whole screen, drawn on the stage as it would look.
    @MainActor static func overlay<V: View>(_ id: String, _ title: String, isOn: Bool,
                                            @ViewBuilder _ draw: @escaping @MainActor (CGSize) -> V) -> StagePreviewSpec {
        var spec = StagePreviewSpec(id: "overlay." + id, title: title, detail: isOn ? "As it is now" : "Off → On", region: StageRegion.whole)
        spec.overlay = { AnyView(draw($0)) }
        return spec
    }
}

/// The screen effects of Effects, drawn at stage size.
enum EffectPreviews {
    static func vignette(_ strength: Double) -> some View {
        RadialGradient(colors: [.clear, .black.opacity(0.25 + 0.5 * strength)], center: .center, startRadius: 0, endRadius: 520)
            .blendMode(.multiply)
    }

    static func grain(_ strength: Double) -> some View {
        Canvas { context, size in
            for i in 0..<2600 {
                let x = Double((i * 7919) % max(Int(size.width), 1)), y = Double((i * 104_729) % max(Int(size.height), 1))
                context.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                             with: .color(.white.opacity((0.04 + Double(i % 7) * 0.025) * (0.4 + strength))))
            }
        }
        .blendMode(.overlay)
    }

    static func focus(_ dim: Double, size: CGSize) -> some View {
        let window = CGRect(x: size.width * 0.24, y: size.height * 0.2, width: size.width * 0.52, height: size.height * 0.5)
        return Rectangle().fill(.black.opacity(dim))
            .mask {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .frame(width: window.width, height: window.height)
                        .offset(x: window.minX, y: window.minY)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    .frame(width: window.width, height: window.height)
                    .offset(x: window.minX, y: window.minY)
            }
    }

    static func nightTint(_ warmth: Double) -> some View {
        Color(red: 1, green: 0.55, blue: 0.2).opacity(0.18 + 0.22 * warmth).blendMode(.multiply)
    }

    static func edgeGlow(_ color: Color) -> some View {
        // Three strokes stepping down in strength read as a glow without a blur pass, so the
        // preview costs nothing extra while the stage scales.
        ZStack {
            Rectangle().strokeBorder(color.opacity(0.08), lineWidth: 18)
            Rectangle().strokeBorder(color.opacity(0.2), lineWidth: 10)
            Rectangle().strokeBorder(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)],
                                                    startPoint: .top, endPoint: .bottom), lineWidth: 4)
        }
    }
}
