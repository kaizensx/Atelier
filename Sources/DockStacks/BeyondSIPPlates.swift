import SwiftUI

// MARK: - Beyond SIP: plates and stage previews
//
// Plates are the heroes' miniatures. Each is a still picture of the effect at rest (that is what
// Reduce Motion and a locked Mac see) and plays only while hovered, through LivePlate/PlateClock.
// Transforms, opacity and trims only: no blur, no `.shadow` on anything that moves.
//
// Stage previews draw the effect over the stage's replica of the Mac, at stage size, with the
// same MockWindows the rest of the stage uses. They are still pictures.

private func smooth(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// 0 → 1 → 0 over `period` seconds, eased; 0 at t = 0.
private func wave(_ t: Double, period: Double) -> Double { 0.5 - 0.5 * cos(t / period * 2 * .pi) }

/// The plate's wallpaper: three soft pools of light, gradients only, so a faded window shows through.
private struct PlateWallpaper: View {
    let size: CGSize
    var body: some View {
        ZStack {
            pool(DS.Spectrum.windows, x: 0.22, y: 0.35, r: 0.5)
            pool(DS.Spectrum.surfaces, x: 0.62, y: 0.75, r: 0.42)
            pool(DS.Spectrum.light, x: 0.82, y: 0.2, r: 0.3)
        }
        .allowsHitTesting(false)
    }

    private func pool(_ color: Color, x: Double, y: Double, r: Double) -> some View {
        RadialGradient(colors: [color.opacity(0.32), color.opacity(0)], center: UnitPoint(x: x, y: y),
                       startRadius: 0, endRadius: size.width * r)
    }
}

/// A round hue badge with a glyph, pinned to a window's corner.
private struct CornerBadge: View {
    let symbol: String
    var diameter = 16.0
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.5, weight: .bold))
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: diameter, height: diameter)
            .background(DS.Spectrum.windows, in: .circle)
            .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5) }
    }
}

// MARK: The Dock Bridge plate

/// The Dock at the bottom, the windows above, and the threads between them. Locked: the threads
/// are dashed and a padlock sits on the Dock. Ready: they are lit and light runs up them.
struct BridgePlate: View {
    let size: CGSize
    let since: Date?
    let ready: Bool

    var body: some View {
        PlateClock(since: since, rest: 0.35) { t in scene(t) }
    }

    private func scene(_ t: Double) -> some View {
        let w = size.width, h = size.height
        let dockWidth = min(w * 0.46, 270.0)
        let dockY = h - 24
        let hub = CGPoint(x: w / 2, y: dockY - 14)
        let windows: [(CGRect, Bool)] = [
            (CGRect(x: w * 0.5 - 150, y: 30, width: 92, height: 56), false),
            (CGRect(x: w * 0.5 - 52, y: 18, width: 104, height: 66), true),
            (CGRect(x: w * 0.5 + 64, y: 34, width: 88, height: 52), false),
        ]
        let hue = DS.Spectrum.windows
        return ZStack(alignment: .topLeading) {
            // A faint horizon behind it all.
            RadialGradient(colors: [hue.opacity(ready ? 0.22 : 0.08), .clear], center: UnitPoint(x: 0.5, y: 0.95),
                           startRadius: 0, endRadius: w * 0.45)
            // Threads from the Dock to each window.
            ForEach(windows.indices, id: \.self) { index in
                let target = CGPoint(x: windows[index].0.midX, y: windows[index].0.maxY + 2)
                let path = thread(from: hub, to: target)
                if ready {
                    path.stroke(hue.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    let p = (t * 0.55 + Double(index) * 0.33).truncatingRemainder(dividingBy: 1)
                    path.trim(from: max(p - 0.18, 0), to: p)
                        .stroke(LinearGradient(colors: [hue.opacity(0), .white], startPoint: .bottom, endPoint: .top),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                } else {
                    path.stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4],
                                                                       dashPhase: -t * 14))
                }
            }
            ForEach(windows.indices, id: \.self) { index in
                let (rect, focused) = windows[index]
                PlateWindow(tint: hue, focused: focused && ready, corner: 6)
                    .frame(width: rect.width, height: rect.height)
                    .opacity(ready ? (index == 0 ? 0.55 : 1) : 0.7)
                    .offset(x: rect.minX, y: rect.minY + (ready ? sin(t * 1.4 + Double(index)) * 2 : 0))
            }
            dock(width: dockWidth).offset(x: (w - dockWidth) / 2, y: dockY - 13)
            hubView(t).position(hub)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    private func thread(from a: CGPoint, to b: CGPoint) -> Path {
        Path { p in
            p.move(to: a)
            p.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y - 30), control2: CGPoint(x: b.x, y: b.y + 30))
        }
    }

    private func dock(width: Double) -> some View {
        let colors: [Color] = [.blue, .orange, .green, DS.Spectrum.windows, .pink, .teal, .yellow]
        return HStack(spacing: 6) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(colors: [colors[index].opacity(0.85), colors[index].opacity(0.5)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 16, height: 16)
            }
        }
        .frame(width: width, height: 26)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 0.5)
        }
    }

    @ViewBuilder private func hubView(_ t: Double) -> some View {
        if ready {
            ZStack {
                Circle().fill(RadialGradient(colors: [DS.Spectrum.windows.opacity(0.7), .clear], center: .center,
                                             startRadius: 0, endRadius: 18))
                    .frame(width: 36, height: 36)
                    .opacity(0.75 + 0.25 * sin(t * 2.4))
                Circle().fill(.white).frame(width: 6, height: 6)
            }
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Color(white: 0.1), in: .circle)
                .overlay { Circle().strokeBorder(DS.Spectrum.sensors.opacity(0.4 + 0.3 * wave(t, period: 2.4)), lineWidth: 1) }
        }
    }
}

// MARK: Feature plates

/// Two windows over a lit wallpaper: the one you are not using fades until the light shows through.
struct BridgeOpacityPlate: View {
    let size: CGSize
    let since: Date?

    var body: some View {
        PlateClock(since: since) { t in
            let alpha = 0.38 + 0.62 * wave(t, period: 3.2)
            ZStack {
                PlateWallpaper(size: size)
                PlateWindow(tint: DS.Ink.secondary, focused: false, corner: 6)
                    .frame(width: 150, height: 92)
                    .opacity(alpha)
                    .offset(x: -64, y: -2)
                PlateWindow(tint: DS.Spectrum.windows, focused: true, corner: 6)
                    .frame(width: 140, height: 86)
                    .offset(x: 78, y: 14)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// A window pinned above, while another passes beneath it.
struct BridgePinPlate: View {
    let size: CGSize
    let since: Date?

    var body: some View {
        PlateClock(since: since, rest: 0.6) { t in
            ZStack {
                PlateWindow(tint: DS.Ink.secondary, focused: false, corner: 6)
                    .frame(width: 170, height: 100)
                    .offset(x: -70, y: 8)
                PlateWindow(tint: DS.Ink.secondary, focused: true, corner: 6)
                    .frame(width: 140, height: 84)
                    .offset(x: sin(t * 0.9) * size.width * 0.16, y: 14 + sin(t * 1.8) * 6)
                PlateWindow(tint: DS.Spectrum.windows, focused: true, corner: 6)
                    .frame(width: 108, height: 66)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .strokeBorder(DS.Spectrum.windows.opacity(0.85), lineWidth: 1.25)
                            .padding(-1.5)
                    }
                    .overlay(alignment: .topTrailing) { CornerBadge(symbol: "pin.fill").offset(x: 6, y: -6) }
                    .offset(x: 92, y: -12)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// Desktops slide past; one window stays, because it is on all of them.
struct BridgeStickyPlate: View {
    let size: CGSize
    let since: Date?

    var body: some View {
        PlateClock(since: since) { t in
            let phase = t / 2.2
            let k = floor(phase)
            let f = smooth((phase - k - 0.5) / 0.5)
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    desktop(Int(k) + i)
                        .offset(x: (Double(i) - f) * size.width)
                }
                PlateWindow(tint: DS.Spectrum.windows, focused: true, corner: 6)
                    .frame(width: 118, height: 72)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .strokeBorder(DS.Spectrum.windows.opacity(0.85), lineWidth: 1.25)
                            .padding(-1.5)
                    }
                    .overlay(alignment: .topTrailing) { CornerBadge(symbol: "square.stack.3d.down.right").offset(x: 6, y: -6) }
                    .offset(x: 40, y: -6)
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { d in
                        let current = (Int(k) + (f > 0.5 ? 1 : 0)) % 3 == d
                        Capsule().fill(.white.opacity(current ? 0.9 : 0.3)).frame(width: current ? 14 : 5, height: 5)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func desktop(_ index: Int) -> some View {
        let d = ((index % 3) + 3) % 3
        let tints: [Color] = [DS.Spectrum.surfaces, DS.Spectrum.light, DS.Spectrum.input]
        let spots: [(CGFloat, CGFloat)] = [(-120, 6), (-90, -10), (-140, 12)]
        return ZStack {
            RadialGradient(colors: [tints[d].opacity(0.26), .clear], center: UnitPoint(x: 0.3, y: 0.6),
                           startRadius: 0, endRadius: size.width * 0.5)
            PlateWindow(tint: tints[d], focused: false, corner: 6)
                .frame(width: 130, height: 80)
                .offset(x: spots[d].0, y: spots[d].1)
            Text("Desktop \(d + 1)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 14).padding(.trailing, 14)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A window shrinks into the corner, leaving the outline of where it was.
struct BridgePiPPlate: View {
    let size: CGSize
    let since: Date?
    let corner: BridgeCorner

    var body: some View {
        // At rest it is small: the picture-in-picture is the point.
        PlateClock(since: since, rest: 1.9) { t in
            let e = wave(t, period: 3.8)
            let s = 1 - (1 - bridgePiPScale) * e
            ZStack {
                PlateWallpaper(size: size).opacity(0.6)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.28 * e), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 180, height: 108)
                PlateWindow(tint: DS.Spectrum.windows, focused: true, corner: 6)
                    .frame(width: 180, height: 108)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .strokeBorder(DS.Spectrum.windows.opacity(0.85 * e), lineWidth: 1.5 / max(s, 0.3))
                            .padding(-1.5)
                    }
                    // Room kept for the badges along the top and the readout at the bottom right.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(s, anchor: corner.unit)
                    .padding(EdgeInsets(top: 36, leading: 14, bottom: 12,
                                        trailing: corner == .bottomRight ? 104 : 14))
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// Two windows: their shadows breathe away to nothing, and stay gone.
struct BridgeNoShadowPlate: View {
    let size: CGSize
    let since: Date?

    var body: some View {
        PlateClock(since: since) { t in
            let shade = wave(t, period: 3.0)
            ZStack {
                window(focused: false, shade: shade).frame(width: 150, height: 92).offset(x: -56, y: -6)
                window(focused: true, shade: shade).frame(width: 150, height: 92).offset(x: 54, y: 16)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func window(focused: Bool, shade: Double) -> some View {
        PlateWindow(tint: focused ? DS.Spectrum.windows : DS.Ink.secondary, focused: focused, corner: 6)
            .background {
                // A shadow made of four static rings: costs nothing to fade.
                ZStack {
                    ForEach(1..<5) { k in
                        RoundedRectangle(cornerRadius: 6 + Double(k) * 2, style: .continuous)
                            .fill(.black.opacity(0.16 * shade))
                            .padding(-Double(k) * 2.5)
                            .offset(y: 3 + Double(k) * 1.5)
                    }
                }
            }
    }
}

/// Desktops in a row: two trade places, the new one waits at the end.
struct BridgeSpacesPlate: View {
    let size: CGSize
    let since: Date?

    var body: some View {
        PlateClock(since: since) { t in
            let p = smooth(wave(t, period: 3.4) * 1.4 - 0.2)
            let w = 74.0, gap = 12.0
            let total = 5 * w + 4 * gap
            let x0 = (size.width - total) / 2 + w / 2
            let slot = { (i: Double) in x0 + i * (w + gap) - size.width / 2 }
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    let position: Double = i == 1 ? 1 + p : (i == 2 ? 2 - p : Double(i))
                    let lifted = i == 1 && p > 0.02 && p < 0.98
                    BridgeSpaceThumb(number: i + 1, current: i == 0, lifted: lifted)
                        .frame(width: w, height: w * 0.62)
                        .offset(x: slot(position), y: lifted ? -8 : 0)
                        .zIndex(i == 1 ? 1 : 0)
                }
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(DS.Spectrum.windows.opacity(0.7))
                    .frame(width: w, height: w * 0.62)
                    .overlay { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Spectrum.windows) }
                    .offset(x: slot(4))
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

// MARK: - Stage previews

/// The effects drawn over the stage's Mac. Still pictures, stage size.
@MainActor
enum BridgeStagePreviews {
    private static func notes(_ w: Double) -> some View {
        MockWindow(width: w, title: "Notes") { NotesContent(width: w).frame(height: w * 0.5) }
    }

    private static func safari(_ w: Double, shadow: Bool = true) -> some View {
        MockWindow(width: w, title: "Safari", shadow: shadow) { BrowserContent(width: w).frame(height: w * 0.56) }
    }

    private static func ring(_ w: Double) -> some View {
        RoundedRectangle(cornerRadius: min(w * 0.035, 18) + 3, style: .continuous)
            .strokeBorder(DS.Spectrum.windows.opacity(0.9), lineWidth: 2)
            .padding(-3)
    }

    private static func tag(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 26)
            .background(.black.opacity(0.55), in: .capsule)
            .overlay { Capsule().strokeBorder(DS.Spectrum.windows.opacity(0.6), lineWidth: 0.75) }
    }

    static func opacity(_ size: CGSize) -> some View {
        let w = size.width * 0.4
        return ZStack {
            safari(w).opacity(0.42).position(x: size.width * 0.6, y: size.height * 0.42)
            notes(w * 0.9).position(x: size.width * 0.36, y: size.height * 0.52)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    static func pin(_ size: CGSize) -> some View {
        let w = size.width * 0.5, small = size.width * 0.26
        return ZStack {
            notes(w).position(x: size.width * 0.42, y: size.height * 0.5)
            safari(small)
                .overlay { ring(small) }
                .overlay(alignment: .topTrailing) { CornerBadge(symbol: "pin.fill", diameter: 26).offset(x: 10, y: -10) }
                .position(x: size.width * 0.74, y: size.height * 0.32)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    static func sticky(_ size: CGSize) -> some View {
        let w = size.width * 0.34
        let thumb = size.width * 0.12
        return ZStack {
            safari(w).overlay { ring(w) }.position(x: size.width * 0.5, y: size.height * 0.4)
            VStack(spacing: 10) {
                tag("On every desktop", symbol: "square.stack.3d.down.right")
                HStack(spacing: 10) {
                    ForEach(1...4, id: \.self) { n in
                        BridgeSpaceThumb(number: n, current: n == 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(DS.Spectrum.windows.opacity(0.85))
                                    .frame(width: thumb * 0.34, height: thumb * 0.22)
                                    .offset(y: -thumb * 0.06)
                            }
                            .frame(width: thumb, height: thumb * 0.62)
                    }
                }
            }
            .position(x: size.width * 0.5, y: size.height * 0.76)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    static func pip(_ size: CGSize, corner: BridgeCorner) -> some View {
        let w = size.width * 0.46
        let h = w * 0.56 + w * 0.06
        let small = w * bridgePiPScale
        let smallH = h * bridgePiPScale
        // The desktop, between the menu bar and the Dock.
        let area = CGRect(x: size.width * 0.03, y: size.height * 0.07, width: size.width * 0.94, height: size.height * 0.74)
        let x = corner == .topLeft || corner == .bottomLeft ? area.minX + small / 2 : area.maxX - small / 2
        let y = corner == .topLeft || corner == .topRight ? area.minY + smallH / 2 : area.maxY - smallH / 2
        return ZStack {
            RoundedRectangle(cornerRadius: min(w * 0.035, 18), style: .continuous)
                .strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .frame(width: w, height: h)
                .position(x: size.width * 0.5, y: size.height * 0.45)
            safari(w)
                .scaleEffect(bridgePiPScale)
                .frame(width: small, height: smallH)
                .overlay { ring(small) }
                .position(x: x, y: y)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    static func noShadow(_ size: CGSize) -> some View {
        let w = size.width * 0.4
        return ZStack {
            MockWindow(width: w * 0.9, title: "Notes", shadow: false) { NotesContent(width: w * 0.9).frame(height: w * 0.45) }
                .position(x: size.width * 0.38, y: size.height * 0.4)
            safari(w, shadow: false).position(x: size.width * 0.6, y: size.height * 0.52)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    static func spaces(_ size: CGSize, count: Int) -> some View {
        let n = min(max(count, 2), 8)
        let thumb = min(size.width * 0.13, size.width * 0.8 / Double(n + 1))
        return VStack(spacing: 0) {
            HStack(spacing: thumb * 0.16) {
                ForEach(1...n, id: \.self) { i in
                    BridgeSpaceThumb(number: i, current: i == 1).frame(width: thumb, height: thumb * 0.62)
                }
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(DS.Spectrum.windows)
                    .frame(width: thumb, height: thumb * 0.62)
                    .overlay { Image(systemName: "plus").font(.system(size: thumb * 0.2, weight: .semibold)).foregroundStyle(DS.Spectrum.windows) }
            }
            .padding(.vertical, size.height * 0.03)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.45))
            .padding(.top, size.height * 0.045)
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
