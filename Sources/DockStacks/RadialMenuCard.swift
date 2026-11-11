import DockCore
import SwiftUI

// MARK: - Radial Menu card
//
// Lives in the Window Engine chapter, under "Snap and layouts", right after the Layouts grid.
// The plate plays the gesture in miniature: the ring's highlight travels from pick to pick and
// a window glides into each layout on the little screen beside it.

struct RadialMenuCard: View {
    let trusted: Bool
    @ObservedObject private var model = RadialMenu.shared
    @ObservedObject private var hyper = HyperKey.shared
    @ObservedObject private var access = AccessWatch.shared
    private let hue = DS.Spectrum.windows

    var body: some View {
        HeroCard("Radial Menu", pitch: "Hold a key, flick the pointer, and the window lands there.",
                 isOn: $model.enabled, hue: hue, readout: model.trigger.title, readoutCaption: "Trigger",
                 preview: .overlay("engine.radial", "Radial Menu", isOn: model.enabled) { size in
                     RadialPlate(size: size, t: 1.2, hue: hue, thirds: model.thirds)
                 }) {
            LivePlate { size, since in
                PlateClock(since: since, rest: 1.2) { t in RadialPlate(size: size, t: t, hue: hue, thirds: model.thirds) }
            }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                NeedsAccessRow(reason: "To read keys and move windows.", previewTrusted: trusted ? nil : false)
                if access.trusted { AvailabilityNote(availability: model.availability) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRIGGER").font(DS.eyebrow).tracking(0.6).foregroundStyle(DS.Ink.tertiary)
                    ChipPicker(selection: $model.trigger, options: RadialTrigger.allCases.map { ($0, $0.title) }, minimum: 64)
                    Text(triggerNote).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 2) {
                    SettingRow(title: "Middle Button", detail: "Hold the wheel button to open it too. A quick click still clicks.",
                               density: .compact) {
                        LuxSwitch(isOn: $model.middleButton, label: "Middle Button", tint: hue)
                    }
                    SettingRow(title: "Thirds Ring", detail: "Go further out for thirds, two thirds and Center.", density: .compact) {
                        LuxSwitch(isOn: $model.thirds, label: "Thirds Ring", tint: hue)
                    }
                    SettingRow(title: "Haptic Tick", detail: "The trackpad ticks as the pick changes.", density: .compact) {
                        LuxSwitch(isOn: $model.haptics, label: "Haptic Tick", tint: hue)
                    }
                }
                legend
                HStack {
                    Text("Escape cancels. Letting go glides the front window into place; Undo in Window Shuffle puts it back.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Chip("Show Ring") { model.handleTest([URLQueryItem(name: "show", value: "1"), URLQueryItem(name: "hold", value: "3")]) }
                        .disabled(!access.trusted)
                }
            }
        }
    }

    private var triggerNote: String {
        switch model.trigger {
        case .hyper: hyper.enabled ? "Hold Caps Lock. A quick tap is still Escape." : "Turn on Hyper Key first: Caps Lock becomes the trigger."
        case .controlOption: "Hold ⌃⌥ on its own for a moment. ⌃⌥ shortcuts still work when typed quickly."
        case .rightOption: "Hold the right ⌥ on its own. The left one types as usual."
        case .rightCommand: "Hold the right ⌘ on its own. Shortcuts with it still work."
        case .function: "Hold fn on its own."
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            legendRow("Centre", "Maximize")
            legendRow("Inner ring", "Halves and corners")
            if model.thirds { legendRow("Outer ring", "Thirds, two thirds, Center") }
            legendRow("Arrows", model.thirds ? "Pick a side; the same arrow again for its third" : "Pick a side; two for a corner")
        }
    }

    private func legendRow(_ keys: String, _ action: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(keys).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DS.Ink.primary)
                .frame(width: 84, alignment: .leading)
            Text(action).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The ring and a little screen, drawn from the same picking map as the real thing.
struct RadialPlate: View {
    let size: CGSize
    let t: Double
    var hue: Color = DS.Spectrum.windows
    var thirds = true

    private static let tour: [RadialSelection] = [
        RadialSelection(band: .inner, sector: .east), RadialSelection(band: .inner, sector: .northEast),
        RadialSelection(band: .center, sector: nil), RadialSelection(band: .outer, sector: .west),
        RadialSelection(band: .inner, sector: .southWest), RadialSelection(band: .outer, sector: .northEast),
    ]

    var body: some View {
        let tour = thirds ? Self.tour : Self.tour.filter { $0.band != .outer }
        let step = Int(t / 1.1) % tour.count
        let selection = tour[step]
        let ring = min(size.height * 0.42, size.width * 0.2)
        let screen = CGRect(x: size.width * 0.1, y: size.height * 0.24, width: size.width * 0.42, height: size.height * 0.62)
        let layout = WindowGeometry.Layout(rawValue: selection.pick.rawValue) ?? .maximize
        let tile = layout.frame(in: CGRect(origin: .zero, size: screen.size).insetBy(dx: 0, dy: 8), gap: 4,
                                current: CGSize(width: screen.width * 0.55, height: screen.height * 0.6))
        ZStack(alignment: .topLeading) {
            MeshCanvas(hue: .ocean, hour: 20)
            // The little screen with the slab and the window that follows it.
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.28))
                Rectangle().fill(.black.opacity(0.3)).frame(height: 8)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hue.opacity(0.22))
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.45), lineWidth: 0.75) }
                    .frame(width: tile.width + 4, height: tile.height + 4)
                    .offset(x: tile.minX - 2, y: tile.minY + 6)
                PlateWindow(tint: hue, focused: true, corner: 5)
                    .frame(width: tile.width, height: tile.height)
                    .offset(x: tile.minX, y: tile.minY + 8)
                    .animation(.spring(response: 0.34, dampingFraction: 0.88), value: step)
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
            .offset(x: screen.minX, y: screen.minY)
            RadialRingArt(selection: selection, hue: hue, thirds: thirds)
                .frame(width: ring * 2, height: ring * 2)
                .offset(x: size.width * 0.74 - ring, y: size.height / 2 - ring)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// The ring in SwiftUI, for plates. The live ring is Core Animation (RadialMenu.swift).
private struct RadialRingArt: View {
    let selection: RadialSelection
    let hue: Color
    let thirds: Bool

    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let scale = r / (thirds ? 150 : 98)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func annulus(_ low: Double, _ high: Double) -> Path {
                var path = Path(ellipseIn: CGRect(x: c.x - high, y: c.y - high, width: high * 2, height: high * 2))
                path.addPath(Path(ellipseIn: CGRect(x: c.x - low, y: c.y - low, width: low * 2, height: low * 2)))
                return path
            }
            func wedge(_ segment: RadialMap.Segment, _ low: Double, _ high: Double) -> Path {
                var path = Path()
                // Canvas is y-down: compass angles turn the other way.
                let start = Angle.degrees(-(segment.angle - segment.span / 2 + 1)), end = Angle.degrees(-(segment.angle + segment.span / 2 - 1))
                path.addArc(center: c, radius: high, startAngle: start, endAngle: end, clockwise: true)
                path.addArc(center: c, radius: low, startAngle: end, endAngle: start, clockwise: false)
                path.closeSubpath()
                return path
            }
            var bands: [(RadialBand, Double, Double)] = [(.inner, 34 * scale, 98 * scale)]
            if thirds { bands.append((.outer, 106 * scale, 150 * scale)) }
            let core = Path(ellipseIn: CGRect(x: c.x - 26 * scale, y: c.y - 26 * scale, width: 52 * scale, height: 52 * scale))
            for (_, low, high) in bands {
                context.fill(annulus(low, high), with: .color(.white.opacity(0.1)), style: FillStyle(eoFill: true))
                context.stroke(annulus(low, high), with: .color(.white.opacity(0.2)), lineWidth: 0.6)
            }
            context.fill(core, with: .color(.white.opacity(0.1)))
            context.stroke(core, with: .color(.white.opacity(0.2)), lineWidth: 0.6)
            for (band, low, high) in bands {
                for segment in RadialMap.segments(band) {
                    let edge = (segment.first.angle - 22.5) * .pi / 180
                    var line = Path()
                    line.move(to: CGPoint(x: c.x + cos(edge) * (low + 3), y: c.y - sin(edge) * (low + 3)))
                    line.addLine(to: CGPoint(x: c.x + cos(edge) * (high - 3), y: c.y - sin(edge) * (high - 3)))
                    context.stroke(line, with: .color(.white.opacity(0.14)), lineWidth: 0.6)
                }
            }
            var lit = context
            lit.addFilter(.shadow(color: hue, radius: 8))
            if let segment = RadialMap.segment(for: selection), let band = bands.first(where: { $0.0 == selection.band }) {
                lit.fill(wedge(segment, band.1 + 1, band.2 - 1), with: .color(hue.opacity(0.6)))
            } else {
                lit.fill(core, with: .color(hue.opacity(0.65)))
            }
            // The pointer, out along the pick.
            let angle = (RadialMap.segment(for: selection)?.angle ?? 0) * .pi / 180
            let distance = selection.band == .center ? 0 : (selection.band == .outer ? 128 : 66) * scale
            let dot = CGPoint(x: c.x + cos(angle) * distance, y: c.y - sin(angle) * distance)
            lit.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: selection.pick)
    }
}
