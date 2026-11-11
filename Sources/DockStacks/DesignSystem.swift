import SwiftUI

// Hover previews: every control here can show on the stage what it would do. Hang
// `.stagePreview(StagePreviewSpec)` on the control or its card (see StagePreview.swift for the full
// guide), or pass `preview:` to `Segments` for one preview per option.

enum DS {
    enum Motion {
        /// The camera: long, weighty, never bounces.
        static let camera = Animation.spring(response: 0.85, dampingFraction: 1)
        /// Panels and content arriving. Critically damped: nothing that merely appears overshoots.
        static let arrive = Animation.spring(response: 0.45, dampingFraction: 1)
        /// Direct feedback under the pointer.
        static let touch = Animation.spring(response: 0.2, dampingFraction: 0.9)
        /// Controls settling, the one place a little bounce is earned.
        static let settle = Animation.spring(response: 0.3, dampingFraction: 0.8)
        static let exit = Animation.easeOut(duration: 0.14)
        /// Hover tints. Seen constantly: short, and nothing moves.
        static let hover = Animation.easeOut(duration: 0.12)
        /// A hero's tuning controls opening and closing.
        static let reveal = Animation.spring(response: 0.36, dampingFraction: 1)
        /// One pass of light across a hero plate when it turns on.
        static let sweep = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.8)
        /// Reduce Motion: movement becomes a short cross-fade.
        @MainActor static func gentle(_ animation: Animation) -> Animation {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.15) : animation
        }
    }

    /// 4-point scale. Nothing in the panel uses a value off it.
    enum Space {
        static let xxs = 2.0, xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 20.0, xxl = 28.0, xxxl = 40.0
    }

    /// Concentric: each inner radius is its container's radius less the inset between them.
    enum Radius {
        static let panel = 32.0      // card 20 + panel inset 12
        static let card = 20.0
        static let plate = 12.0      // card 20 − plate inset 8
        static let control = 12.0
        static let pill = 9.0        // segments 12 − padding 3
    }

    enum Inset {
        static let panel = 12.0
        static let card = 16.0
        static let plate = 8.0
    }

    enum Ink {
        static let primary = Color.white
        static let secondary = Color.white.opacity(0.66)
        /// The floor for text: keeps 4.5:1 on the panel glass. Fainter is for glyphs only.
        static let tertiary = Color.white.opacity(0.5)
        static let glyph = Color.white.opacity(0.36)
        static let hairline = Color.white.opacity(0.09)
        /// The lit top edge of a surface.
        static let edge = Color.white.opacity(0.16)
        static let fill = Color.white.opacity(0.055)
        static let fillStrong = Color.white.opacity(0.13)
        /// An off switch's track. With `edge` around it, 3:1 against the panel.
        static let track = Color.white.opacity(0.2)
        /// Set by StudioTheme. Read everywhere as `accent`.
        nonisolated(unsafe) static var current = Color(red: 0.55, green: 0.72, blue: 1)
        static var accent: Color { current }
    }

    /// Light that a feature family gives off when it is on. Never used as decoration.
    enum Spectrum {
        static let light = Color(red: 1.0, green: 0.76, blue: 0.38)     // display, brightness, colour
        static let input = Color(red: 0.42, green: 0.92, blue: 0.76)    // trackpad, mouse, keys
        static let windows = Color(red: 0.68, green: 0.56, blue: 1.0)   // window superpowers
        static let surfaces = Color(red: 0.48, green: 0.74, blue: 1.0)  // HUDs, menu bar, Dock
        static let sensors = Color(red: 1.0, green: 0.48, blue: 0.36)   // temperatures, fans, power
        static let sound = Color(red: 1.0, green: 0.5, blue: 0.7)       // sounds and haptics
    }

    enum Typo {
        static let chapter = Font.system(size: 30, weight: .semibold)
        static let hero = Font.system(size: 20, weight: .semibold)
        static let readout = Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
        static let rowTitle = Font.system(size: 13, weight: .medium)
        static let section = Font.system(size: 12, weight: .semibold)
        static let value = Font.system(size: 11.5, weight: .medium).monospacedDigit()
        static let badge = Font.system(size: 9.5, weight: .bold)
    }

    static func display(_ size: Double) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static let title = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let caption = Font.system(size: 12, weight: .regular)
    static let eyebrow = Font.system(size: 11, weight: .semibold)
}

extension NavSection {
    /// The light a place gives off. Interim mapping until the sidebar is regrouped by capability.
    var hue: Color {
        switch self {
        case .mac, .history, .atelier: DS.Ink.accent
        case .desktop, .dock, .menuBar: DS.Spectrum.surfaces
        case .windows: DS.Spectrum.windows
        case .files, .apps: DS.Spectrum.input
        case .system: DS.Spectrum.light
        case .tools: DS.Spectrum.sensors
        }
    }
}

/// A pressable surface that answers on pointer-down.
struct Pressable: ButtonStyle {
    var scale = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(DS.Motion.touch, value: configuration.isPressed)
    }
}

/// Big titles: tight, luminous, lit from above like the glass around them.
struct DisplayTitle: View {
    let text: String
    var size = 34.0
    var body: some View {
        Text(text)
            .font(DS.display(size))
            .tracking(-size * 0.028)
            .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.82)], startPoint: .top, endPoint: .bottom))
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DS.eyebrow)
            .tracking(1.4)
            .foregroundStyle(DS.Ink.tertiary)
    }
}

enum CardStyle: Equatable { case standard, quiet, lit(Color) }

/// A card's surface. Gradients and strokes only: no blur, no shadow, so it costs nothing to scroll.
struct CardSurface: View {
    var style: CardStyle = .standard
    var radius = DS.Radius.card

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .quiet:
            shape.strokeBorder(DS.Ink.hairline, lineWidth: 0.5)
        case .standard:
            shape.fill(DS.Ink.fill)
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [DS.Ink.edge, DS.Ink.hairline.opacity(0.4)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                }
        case .lit(let hue):
            shape.fill(DS.Ink.fill)
                .overlay { shape.fill(LinearGradient(colors: [hue.opacity(0.14), hue.opacity(0.02)], startPoint: .top, endPoint: .bottom)) }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: [hue.opacity(0.6), hue.opacity(0.12)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                }
        }
    }
}

struct Card<Content: View>: View {
    var style: CardStyle
    var padding: Double
    var content: Content

    init(style: CardStyle = .standard, padding: Double = DS.Inset.card, @ViewBuilder content: () -> Content) {
        self.style = style
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CardSurface(style: style) }
    }
}

enum RowDensity { case regular, compact }

struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    var density: RowDensity
    var trailing: Trailing

    init(title: String, detail: String? = nil, symbol: String? = nil, density: RowDensity = .regular,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.density = density
        self.trailing = trailing()
    }

    var body: some View {
        let compact = density == .compact
        // Title and detail keep a readable column: when the trailing controls would squeeze them,
        // the controls move under the text instead (AdaptiveRowLayout).
        AdaptiveRowLayout(spacing: compact ? 10 : 14, hasSymbol: symbol != nil) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 12 : 14, weight: .medium))
                    .foregroundStyle(DS.Ink.secondary)
                    .frame(width: compact ? 18 : 22)
            }
            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                Text(title)
                    .font(compact ? DS.Typo.rowTitle : DS.title)
                    .foregroundStyle(DS.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    // Wraps as far as it needs, never an ellipsis: write details short.
                    Text(detail)
                        .font(DS.caption)
                        .foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, compact ? DS.Space.xs : 0)
        .frame(minHeight: compact ? 36 : nil)
        // Every row previews on the stage; a row's own, specific preview takes over.
        .contentShape(Rectangle())
        .modifier(FallbackStagePreview(title: title, detail: detail))
    }
}

/// A setting row's geometry: [symbol] text [trailing…]. The trailing controls keep their ideal
/// width and sit on the right while the text column keeps at least `minText` points; past that
/// they move under the text, so a wide control never squeezes a title into a narrow column and
/// a control never clips. A flexible control (a slider) shares the row with the text, as in an HStack.
struct AdaptiveRowLayout: Layout {
    var spacing: Double
    var hasSymbol: Bool
    var minText = 160.0
    /// Between the text and controls that moved under it.
    var stackSpacing = DS.Space.s

    private struct Plan {
        var stacked: Bool
        var indent: Double
        var textWidth: Double
        var trailing: [CGSize]
        var size: CGSize
    }

    private func plan(_ width: Double?, _ subviews: Subviews) -> Plan {
        guard !subviews.isEmpty else { return Plan(stacked: false, indent: 0, textWidth: 0, trailing: [], size: .zero) }
        let symbol = hasSymbol ? subviews.first : nil
        let textIndex = hasSymbol ? 1 : 0
        guard textIndex < subviews.count else { return Plan(stacked: false, indent: 0, textWidth: 0, trailing: [], size: .zero) }
        let text = subviews[textIndex]
        let items = subviews.indices.filter { $0 > textIndex }.map { subviews[$0] }
        let symbolWidth = symbol.map { $0.sizeThatFits(.unspecified).width } ?? 0
        let indent = symbol == nil ? 0 : symbolWidth + spacing
        let ideals = items.map { $0.sizeThatFits(.unspecified) }
        let visible = ideals.filter { $0.width > 0 || $0.height > 0 }
        let gaps = spacing * Double(max(visible.count - 1, 0))

        guard let width else {
            // Ideal size: everything on one line.
            let textSize = text.sizeThatFits(.unspecified)
            let trailingWidth = visible.reduce(0) { $0 + $1.width } + gaps
            let height = max(textSize.height, visible.map(\.height).max() ?? 0, symbol?.sizeThatFits(.unspecified).height ?? 0)
            return Plan(stacked: false, indent: indent, textWidth: textSize.width, trailing: ideals,
                        size: CGSize(width: indent + textSize.width + (visible.isEmpty ? 0 : spacing + trailingWidth), height: height))
        }

        let room = max(width - indent, 0)
        if visible.isEmpty {
            let textHeight = text.sizeThatFits(ProposedViewSize(width: room, height: nil)).height
            let height = max(textHeight, symbol?.sizeThatFits(.unspecified).height ?? 0)
            return Plan(stacked: false, indent: indent, textWidth: room, trailing: ideals, size: CGSize(width: width, height: height))
        }

        // A control that grows when offered more (a slider) is flexible; the rest keep their ideal width.
        let flexible = items.indices.map { i -> Bool in
            guard ideals[i].width > 0 else { return false }
            return items[i].sizeThatFits(ProposedViewSize(width: room, height: nil)).width > ideals[i].width + 1
        }
        let fixedWidth = items.indices.filter { !flexible[$0] }.reduce(0) { $0 + ideals[$1].width }
        let flexCount = flexible.filter { $0 }.count
        let inlineText = room - spacing - fixedWidth - gaps
        var sizes = ideals
        // Inline when the column stays readable, or when the text fits it on one line anyway.
        if inlineText >= minText || (flexCount == 0 && inlineText >= text.sizeThatFits(.unspecified).width) {
            var textWidth = inlineText
            if flexCount > 0 {
                // Like an HStack: the text and the flexible controls share what is left.
                textWidth = max(minText, inlineText / 2)
                let each = max((inlineText - textWidth) / Double(flexCount), 0)
                for i in items.indices where flexible[i] {
                    sizes[i] = items[i].sizeThatFits(ProposedViewSize(width: each, height: nil))
                    sizes[i].width = each
                }
            }
            let textHeight = text.sizeThatFits(ProposedViewSize(width: textWidth, height: nil)).height
            let height = max(textHeight, sizes.map(\.height).max() ?? 0, symbol?.sizeThatFits(.unspecified).height ?? 0)
            return Plan(stacked: false, indent: indent, textWidth: textWidth, trailing: sizes, size: CGSize(width: width, height: height))
        }

        // Stacked: the text takes the whole column, the controls follow it on their own line,
        // each no wider than the column and a flexible one as wide as it.
        let lineRoom = room
        let flexEach = max((lineRoom - fixedWidth - gaps) / Double(max(flexCount, 1)), 0)
        for i in items.indices {
            if flexible[i] {
                sizes[i] = items[i].sizeThatFits(ProposedViewSize(width: flexEach, height: nil))
                sizes[i].width = flexEach
            } else if ideals[i].width > lineRoom {
                sizes[i] = items[i].sizeThatFits(ProposedViewSize(width: lineRoom, height: nil))
                sizes[i].width = min(sizes[i].width, lineRoom)
            }
        }
        let lines = Self.lines(sizes, room: lineRoom, spacing: spacing)
        let controlsHeight = lines.reduce(0) { $0 + $1.height } + DS.Space.s * Double(max(lines.count - 1, 0))
        let textHeight = text.sizeThatFits(ProposedViewSize(width: room, height: nil)).height
        return Plan(stacked: true, indent: indent, textWidth: room, trailing: sizes,
                    size: CGSize(width: width, height: textHeight + stackSpacing + controlsHeight))
    }

    /// Controls that moved under the text, wrapped like words when one line is not enough.
    private static func lines(_ sizes: [CGSize], room: Double, spacing: Double) -> [(items: [Int], height: Double)] {
        var lines: [(items: [Int], height: Double)] = []
        var used = 0.0
        for (i, size) in sizes.enumerated() where size.width > 0 || size.height > 0 {
            if lines.isEmpty || (used + size.width > room + 0.5 && !lines[lines.count - 1].items.isEmpty) {
                lines.append(([], 0))
                used = 0
            }
            lines[lines.count - 1].items.append(i)
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
            used += size.width + spacing
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal.width.map(Double.init), subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(bounds.width, subviews)
        let textIndex = hasSymbol ? 1 : 0
        guard textIndex < subviews.count else { return }
        let text = subviews[textIndex]
        let textSize = text.sizeThatFits(ProposedViewSize(width: plan.textWidth, height: nil))
        if hasSymbol, let symbol = subviews.first {
            let size = symbol.sizeThatFits(.unspecified)
            // Beside the title line when stacked, centred on the row otherwise.
            let y = plan.stacked ? bounds.minY + min(textSize.height, 20) / 2 : bounds.midY
            symbol.place(at: CGPoint(x: bounds.minX, y: y), anchor: .leading, proposal: ProposedViewSize(size))
        }
        let items = subviews.indices.filter { $0 > textIndex }.map { subviews[$0] }
        if !plan.stacked {
            text.place(at: CGPoint(x: bounds.minX + plan.indent, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: plan.textWidth, height: textSize.height))
            var x = bounds.maxX
            for (i, item) in items.enumerated().reversed() {
                let size = plan.trailing[i]
                guard size.width > 0 || size.height > 0 else { continue }
                item.place(at: CGPoint(x: x, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(size))
                x -= size.width + spacing
            }
            return
        }
        text.place(at: CGPoint(x: bounds.minX + plan.indent, y: bounds.minY), anchor: .topLeading,
                   proposal: ProposedViewSize(width: plan.textWidth, height: textSize.height))
        var y = bounds.minY + textSize.height + stackSpacing
        for line in Self.lines(plan.trailing, room: plan.textWidth, spacing: spacing) {
            var x = bounds.minX + plan.indent
            for i in line.items {
                let size = plan.trailing[i]
                items[i].place(at: CGPoint(x: x, y: y + line.height / 2), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + DS.Space.s
        }
    }
}

/// Wraps its children like words: as many on a line as fit, then the next line. For rows of
/// chips and buttons, so the last one never runs off the card or gets clipped. A child wider
/// than the line is offered the line's width.
struct WrapStack: Layout {
    var spacing = DS.Space.s
    var lineSpacing = DS.Space.s

    private func lines(_ subviews: Subviews, width: Double) -> [[(Int, CGSize)]] {
        var lines: [[(Int, CGSize)]] = [[]]
        var used = 0.0
        for (i, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if size.width == 0 && size.height == 0 { continue }
            if used + size.width > width + 0.5, !(lines.last?.isEmpty ?? true) {
                lines.append([])
                used = 0
            }
            lines[lines.count - 1].append((i, size))
            used += size.width + spacing
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = lines(subviews, width: width)
        let height = lines.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + lineSpacing * Double(max(lines.count - 1, 0))
        let widest: Double = lines.map { line in Double(line.reduce(0) { $0 + $1.1.width }) + spacing * Double(max(line.count - 1, 0)) }.max() ?? 0
        // Hugs its lines, so a row of chips never claims space it does not use.
        return CGSize(width: min(widest, proposal.width.map(Double.init) ?? widest), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let height = line.map(\.1.height).max() ?? 0
            var x = bounds.minX
            for (i, size) in line {
                subviews[i].place(at: CGPoint(x: x, y: y + height / 2), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

/// Plain settings, grouped: one surface per section with hairlines between rows, not a card per row.
struct RowGroup<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if #available(macOS 15, *) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                        if row.id != rows.last?.id {
                            Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                        }
                    }
                }
            } else {
                // macOS 14 has no `Group(subviews:)`; SwiftUI's variadic tree, public since
                // macOS 10.15 and what `Group(subviews:)` is built on, lists the rows instead.
                _VariadicView.Tree(RowGroupHairlines()) { content }
            }
        }
        .padding(.horizontal, DS.Inset.card)
        .padding(.vertical, DS.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(style: .standard) }
    }
}

/// Hairlines between a group's rows on macOS 14, the same as `Group(subviews:)` draws later.
private struct RowGroupHairlines: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        ForEach(children) { row in
            row
            if row.id != children.last?.id {
                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
            }
        }
    }
}

/// A section inside a panel: tinted glyph, sentence-case name, a hairline running out to the edge.
struct SectionHeader: View {
    let title: String
    var symbol: String?
    var detail: String?
    var hue: Color?

    init(_ title: String, symbol: String? = nil, detail: String? = nil, hue: Color? = nil) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.hue = hue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(hue ?? DS.Ink.accent)
                        .frame(width: 16)
                }
                // The name takes the room it needs; the hairline only what is left.
                Text(title).font(DS.Typo.section).foregroundStyle(DS.Ink.primary.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5).frame(minWidth: DS.Space.l, maxWidth: .infinity)
            }
            if let detail {
                Text(detail).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, symbol == nil ? 0 : 24)
            }
        }
        .padding(.top, DS.Space.xl)
        .padding(.horizontal, DS.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The panel's title, with the family it belongs to in its own light.
struct ChapterHeader: View {
    let title: String
    var eyebrow: String?
    var hue: Color = DS.Ink.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let eyebrow {
                HStack(spacing: 6) {
                    Capsule().fill(hue).frame(width: 14, height: 3)
                    Text(eyebrow).font(DS.Typo.section).foregroundStyle(hue)
                }
            }
            DisplayTitle(text: title, size: 30)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Was a staggered entrance per card. Measured at 120 Hz it doubled the late frames of
/// every chapter change, so the panel now arrives as one piece and the cards just sit in it.
struct Cascade<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content }
}

enum SwitchSize { case regular, large }

struct LuxSwitch: View {
    @Binding var isOn: Bool
    var label: String
    var tint: Color?
    var size: SwitchSize
    @Environment(\.isEnabled) private var enabled

    init(isOn: Binding<Bool>, label: String, tint: Color? = nil, size: SwitchSize = .regular) {
        self._isOn = isOn
        self.label = label
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Button { isOn.toggle() } label: { EmptyView() }
            .buttonStyle(SwitchFace(isOn: isOn, tint: tint ?? DS.Ink.accent,
                                    width: size == .large ? 52 : 40, height: size == .large ? 30 : 24,
                                    enabled: enabled))
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// The knob widens under the pointer and settles with a small bounce.
private struct SwitchFace: ButtonStyle {
    let isOn: Bool
    let tint: Color
    let width: Double
    let height: Double
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let knob = height - 4
        let stretch = configuration.isPressed ? 5.0 : 0
        return ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? tint : DS.Ink.track)
                .overlay { Capsule().strokeBorder(isOn ? Color.white.opacity(0.18) : DS.Ink.edge, lineWidth: 0.5) }
                .frame(width: width, height: height)
            Capsule()
                .fill(.white)
                .frame(width: knob + stretch, height: knob)
                .padding(2)
                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
        }
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Capsule())
        .animation(DS.Motion.settle, value: isOn)
        .animation(DS.Motion.touch, value: configuration.isPressed)
    }
}


/// A headline tweak, the kind a stock Mac cannot do: a live plate, a numeral, its own light when on.
struct HeroCard<Plate: View, Controls: View>: View {
    let title: String
    let pitch: String
    @Binding var isOn: Bool
    var hue: Color
    var badge: String?
    var readout: String?
    var readoutCaption: String?
    var preview: StagePreviewSpec?
    var plate: Plate
    var controls: Controls
    @State private var hover = false
    @State private var sweeps = 0

    init(_ title: String, pitch: String, isOn: Binding<Bool>, hue: Color = DS.Ink.accent,
         badge: String? = "Beyond macOS", readout: String? = nil, readoutCaption: String? = nil,
         preview: StagePreviewSpec? = nil,
         @ViewBuilder plate: () -> Plate, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.pitch = pitch
        self._isOn = isOn
        self.hue = hue
        self.badge = badge
        self.readout = readout
        self.readoutCaption = readoutCaption
        self.preview = preview
        self.plate = plate()
        self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The whole plate is the switch's biggest target.
            Button { isOn.toggle() } label: { plateView }
                .buttonStyle(Pressable(scale: 0.985))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                        Text(pitch).font(DS.body).foregroundStyle(DS.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    LuxSwitch(isOn: $isOn, label: title, tint: hue, size: .large)
                }
                if isOn {
                    controls.transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, 14)
            .padding(.bottom, DS.Space.s)
        }
        .padding(DS.Inset.plate)
        .background { CardSurface(style: isOn ? .lit(hue) : .standard) }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(hover ? 0.1 : 0), lineWidth: 0.5)
        }
        .animation(DS.Motion.reveal, value: isOn)
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .onChange(of: isOn) { _, on in if on { sweeps += 1 } }
        .stagePreview(preview)
        .accessibilityElement(children: .contain)
    }

    private var plateView: some View {
        ZStack(alignment: .topLeading) {
            // Light rising from below in the feature's hue. A gradient, never a blur.
            RadialGradient(colors: [hue.opacity(isOn ? 0.45 : 0.12), .clear],
                           center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: 260)
            plate.frame(maxWidth: .infinity, maxHeight: .infinity)
            // Off: the plate rests in shade, so ON is visible across the room.
            Color.black.opacity(isOn ? 0 : 0.32).allowsHitTesting(false)
            if let badge { HeroBadge(text: badge, hue: hue).padding(10) }
            if let readout {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(readout).font(DS.Typo.readout).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    if let readoutCaption {
                        Text(readoutCaption.uppercased()).font(DS.Typo.badge).tracking(0.8)
                            .foregroundStyle(DS.Ink.secondary)
                    }
                }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(height: 148)
        .background(Color(red: 0.06, green: 0.065, blue: 0.08))
        .overlay { SweepLight(trigger: sweeps) }
        .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
    }
}

extension HeroCard where Controls == EmptyView {
    init(_ title: String, pitch: String, isOn: Binding<Bool>, hue: Color = DS.Ink.accent,
         badge: String? = "Beyond macOS", readout: String? = nil, readoutCaption: String? = nil,
         preview: StagePreviewSpec? = nil, @ViewBuilder plate: () -> Plate) {
        self.init(title, pitch: pitch, isOn: isOn, hue: hue, badge: badge, readout: readout,
                  readoutCaption: readoutCaption, preview: preview, plate: plate, controls: { EmptyView() })
    }
}

struct HeroBadge: View {
    let text: String
    var hue: Color = DS.Ink.accent

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(hue).frame(width: 5, height: 5)
            Text(text.uppercased()).font(DS.Typo.badge).tracking(0.8).foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(.black.opacity(0.35), in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
    }
}

/// One band of light across a plate, once per change of `trigger`. No blur; absent at rest.
struct SweepLight: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            if !reduceMotion {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .white.opacity(0.22), location: 0.5),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: width * 0.45)
                    .rotationEffect(.degrees(18))
                    .keyframeAnimator(initialValue: -0.6, trigger: trigger) { view, x in
                        view.offset(x: width * x).opacity(x > -0.6 && x < 1.2 ? 1 : 0)
                    } keyframes: { _ in
                        MoveKeyframe(-0.6)
                        CubicKeyframe(1.2, duration: 0.8)
                    }
                    .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Segmented control whose highlight travels between options.
struct Segments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    /// What each option would look like on the stage, shown while the pointer rests on it.
    var preview: ((Value) -> StagePreviewSpec?)?
    @Namespace private var space

    var body: some View {
        // One line of equal options while they fit; past that the options wrap onto more lines
        // instead of truncating their labels.
        SegmentsLayout(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    withAnimation(DS.Motion.settle) { selection = value }
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: selection == value ? .semibold : .medium))
                        .foregroundStyle(selection == value ? DS.Ink.primary : DS.Ink.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, DS.Space.s)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background {
                            if selection == value {
                                RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                                    .fill(Color.white.opacity(0.16))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                                            .strokeBorder(DS.Ink.edge, lineWidth: 0.5)
                                    }
                                    .matchedGeometryEffect(id: "pill", in: space)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(Pressable(scale: 0.98))
                .stagePreview(selection == value ? nil : preview?(value))
                // No preview of its own: the option still shows where it acts, with its name.
                .modifier(FallbackStagePreview(title: label, detail: nil))
            }
        }
        .padding(3)
        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

/// Segments' options: one line, equal widths, when the widest label allows; ideal widths with the
/// slack shared out when only the sum fits; otherwise lines of options, each line filled edge to edge.
struct SegmentsLayout: Layout {
    var spacing = 2.0

    private func lines(_ ideals: [CGSize], width: Double) -> [[Int]] {
        var lines: [[Int]] = [[]]
        var used = 0.0
        for (i, size) in ideals.enumerated() {
            if used + size.width > width + 0.5, !(lines.last?.isEmpty ?? true) {
                lines.append([])
                used = 0
            }
            lines[lines.count - 1].append(i)
            used += size.width + spacing
        }
        return lines
    }

    /// Each option's frame, relative to the layout's origin.
    private func frames(_ subviews: Subviews, width: Double?) -> [CGRect] {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !ideals.isEmpty else { return [] }
        let height = ideals.map(\.height).max() ?? 30
        guard let width, width.isFinite else {
            // Ideal: equal widths, each as wide as the widest label.
            let widest = ideals.map(\.width).max() ?? 0
            return ideals.indices.map { CGRect(x: Double($0) * (widest + spacing), y: 0, width: widest, height: height) }
        }
        var frames: [CGRect] = []
        var y = 0.0
        for line in lines(ideals, width: width) {
            let gaps = spacing * Double(line.count - 1)
            let widest = line.map { ideals[$0].width }.max() ?? 0
            let equal = (width - gaps) / Double(line.count)
            let sum = line.reduce(0) { $0 + ideals[$1].width }
            let slack = max(width - gaps - sum, 0) / Double(line.count)
            var x = 0.0
            for i in line {
                // Equal widths when the widest fits; otherwise each label's own width plus a share.
                let w = widest <= equal ? equal : ideals[i].width + slack
                frames.append(CGRect(x: x, y: y, width: w, height: height))
                x += w + spacing
            }
            y += height + spacing
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.map(Double.init)
        let frames = frames(subviews, width: width)
        let maxX = frames.map { Double($0.maxX) }.max() ?? 0
        let maxY = frames.map { Double($0.maxY) }.max() ?? 0
        return CGSize(width: width.flatMap { $0.isFinite ? $0 : nil } ?? maxX, height: maxY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Slider that tracks the pointer 1:1, shows its thumb, and rubber-bands past its ends.
struct LuxSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var label: String
    var tint: Color?
    var onCommit: () -> Void
    @State private var dragging = false
    /// Overshoot past an end, as a signed fraction of the width. Transform only.
    @State private var stretch = 0.0

    init(value: Binding<Double>, range: ClosedRange<Double>, label: String = "Value",
         tint: Color? = nil, onCommit: @escaping () -> Void = {}) {
        self._value = value
        self.range = range
        self.label = label
        self.tint = tint
        self.onCommit = onCommit
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(Double(geometry.size.width), 1)
            let span = range.upperBound - range.lowerBound
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            let knob = 16.0
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Ink.track)
                Capsule().fill(tint ?? DS.Ink.accent).frame(width: max(knob, width * fraction))
            }
            .frame(height: 6)
            .scaleEffect(x: 1 + abs(stretch), y: dragging ? 1.35 : 1, anchor: stretch < 0 ? .trailing : .leading)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: (width - knob) * fraction + stretch * width)
            }
            .frame(maxHeight: .infinity)
            .animation(DS.Motion.touch, value: dragging)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    dragging = true
                    let raw = Double(gesture.location.x) / width
                    value = range.lowerBound + min(max(raw, 0), 1) * span
                    let over = raw < 0 ? raw : (raw > 1 ? raw - 1 : 0)
                    stretch = over == 0 ? 0 : (over < 0 ? -1.0 : 1.0) * Self.rubber(abs(over) * width, 40) / width
                }
                .onEnded { _ in
                    dragging = false
                    withAnimation(DS.Motion.settle) { stretch = 0 }
                    onCommit()
                })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityLabel(label)
        .accessibilityValue(Text(String(format: "%.0f%%", (value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100)))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: return
            }
            onCommit()
        }
    }

    /// Apple's rubber band: the further past the end, the less it follows. Never more than `limit` points.
    static func rubber(_ overshoot: Double, _ limit: Double, constant: Double = 0.55) -> Double {
        overshoot * limit * constant / (limit + constant * overshoot)
    }
}

/// Destructive action: hold to confirm, release to cancel.
struct HoldButton: View {
    let title: String
    let action: () -> Void
    @State private var holding = false

    var body: some View {
        Text(title)
            .font(DS.title)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle().fill(Color.red.opacity(0.75))
                        .frame(width: holding ? geometry.size.width : 0)
                }
            }
            .background(Color.red.opacity(0.18))
            .clipShape(.rect(cornerRadius: DS.Radius.control, style: .continuous))
            .scaleEffect(holding ? 0.98 : 1)
            .onLongPressGesture(minimumDuration: 1.6, perform: action) { pressing in
                withAnimation(pressing ? .linear(duration: 1.6) : DS.Motion.exit) { holding = pressing }
            }
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
    }
}

/// A ring of light that crosses the stage once for each change of `trigger`.
struct LightWave<Trigger: Equatable>: ViewModifier {
    var origin: UnitPoint
    var trigger: Trigger

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                let reach = max(geometry.size.width, geometry.size.height) * 1.5
                Color.clear.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, t in
                    // The ring exists only while it travels. Left in place at rest, its blur was an
                    // offscreen pass on every frame anything under it moved.
                    view.overlay {
                        if t > 0 && t < 1 {
                        // Soft edges from the gradient itself: a blur here was an offscreen pass per frame.
                        Circle()
                            .strokeBorder(RadialGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                                         center: .center, startRadius: reach * t * 0.5 - 30,
                                                         endRadius: reach * t * 0.5 + 4), lineWidth: 34)
                            .frame(width: reach * t, height: reach * t)
                            .opacity(t > 0 && t < 1 ? (1 - t) : 0)
                            .position(x: geometry.size.width * origin.x, y: geometry.size.height * origin.y)
                            .blendMode(.plusLighter)
                        }
                    }
                } keyframes: { _ in
                    MoveKeyframe(0)
                    CubicKeyframe(1, duration: 1.1)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// An NSImage drawn once into a bitmap and shown as a texture. Icons from NSWorkspace are
/// resolution-independent, so SwiftUI redraws them on the CPU every time their on-screen
/// scale changes, which is every frame of a camera move. A bitmap is only scaled by the GPU.
@MainActor
enum BitmapIcons {
    private static let cache = NSMapTable<NSImage, CGImageBox>.weakToStrongObjects()

    final class CGImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    static func cgImage(_ image: NSImage, pixels: Int = 256) -> CGImage? {
        if let box = cache.object(forKey: image) { return box.image }
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let made = image.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.high]) else { return nil }
        cache.setObject(CGImageBox(made), forKey: image)
        return made
    }
}

/// Use in place of `Image(nsImage:).resizable()` for icons that move or scale.
struct BitmapIcon: View {
    let image: NSImage
    var pixels = 256

    var body: some View {
        if let cg = BitmapIcons.cgImage(image, pixels: pixels) {
            Image(decorative: cg, scale: 1).resizable().interpolation(.high)
        } else {
            Image(nsImage: image).resizable().interpolation(.high)
        }
    }
}
