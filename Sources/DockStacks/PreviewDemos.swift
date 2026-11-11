import SwiftUI

// MARK: - Before-and-after sketches for settings the replica cannot draw
//
// Every setting has a preview. Where the stage's replica can show the change (a wallpaper, a
// skin, the Atelier Dock's look), the setting edits the stage's copy of the Mac. Where it cannot
// (a behaviour, a gesture, a timing), one of these plays in a card on the stage: the same small
// scene twice, Off and On, looping, drawn in a 300 x 186 pane. Add one by writing a `DemoSpec`
// here and hanging `.stagePreview(.demo(id, title, isOn:, region:, Demos.x))` on the row.

/// The parts every sketch is drawn from.
private enum Mini {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow]

    /// 0 to 1 and back over a period, smooth at both ends.
    static func wave(_ t: Double, _ period: Double) -> Double { 0.5 - 0.5 * cos(t / period * 2 * .pi) }

    /// 0 until `from`, 1 after `to`, eased between.
    static func step(_ t: Double, _ from: Double, _ to: Double) -> Double {
        let x = min(max((t - from) / max(to - from, 0.001), 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func icon(_ index: Int, size: Double = 22) -> some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [colors[index % colors.count], colors[index % colors.count].opacity(0.65)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
    }

    /// A dock bar. `lift` raises one icon, `dim` fades all but the first, `offset` slides it down.
    static func dock(count: Int = 6, lift: (index: Int, amount: Double)? = nil, dim: Double = 0, scale: [Double]? = nil,
                     badge: Bool = false, offset: Double = 0) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                let s = scale?[safe: index] ?? 1
                icon(index, size: 22 * s)
                    .overlay(alignment: .topTrailing) {
                        if badge, index == 2 { Circle().fill(.red).frame(width: 9, height: 9).offset(x: 3, y: -3) }
                    }
                    .offset(y: lift?.index == index ? -12 * (lift?.amount ?? 0) : 0)
                    .opacity(index == 0 ? 1 : 1 - dim)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.white.opacity(0.14), in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
        .offset(y: offset)
    }

    static func window(_ w: Double, _ h: Double, tint: Color = Color(white: 0.18)) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 5, height: 5) }
                Spacer()
            }
            .padding(.horizontal, 6).frame(height: 13)
            .background(Color(white: 0.24))
            tint
        }
        .frame(width: w, height: h)
        .clipShape(.rect(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }

    static func menuBar(height: Double = 14, fill: Color = .black.opacity(0.35), inset: Double = 0, radius: Double = 0) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "apple.logo").font(.system(size: 8))
            ForEach(["File", "Edit", "View"], id: \.self) { Text($0).font(.system(size: 7, weight: .medium)) }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 7))
            Text("9:41").font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).frame(height: height)
        .background(fill, in: .rect(cornerRadius: radius, style: .continuous))
        .padding(.horizontal, inset).padding(.top, inset * 0.6)
    }

    static func pointer(_ at: CGPoint) -> some View {
        Image(systemName: "cursorarrow").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 1).position(at)
    }

    static func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6).frame(height: 16).background(.black.opacity(0.35), in: .capsule)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private let W = 300.0, H = 186.0  // DemoCard.paneW, DemoCard.paneH

@MainActor
enum Demos {
    // MARK: Atelier Dock behaviour

    static let attentionBounce = DemoSpec(period: 2.4, off: "No hop", on: "Hops when an app needs you") { on, t in
        let hop = on ? abs(sin(t * 2 * .pi / 0.8)) * (t < 1.6 ? 1 : 0) : 0
        ZStack { Mini.dock(lift: (2, hop), badge: true).position(x: W / 2, y: H - 26) }
    }

    static let focusMode = DemoSpec(period: 3, off: "All the same", on: "Others fade back") { on, t in
        ZStack {
            Mini.window(150, 82).position(x: W / 2, y: 64)
            Mini.dock(dim: on ? 0.6 * Mini.step(t, 0.3, 0.9) : 0).position(x: W / 2, y: H - 26)
        }
    }

    static let autoHide = DemoSpec(period: 3.2, off: "Always there", on: "Slides away, back at the edge") { on, t in
        let hidden = on ? Mini.step(t, 0.4, 0.9) * (1 - Mini.step(t, 2.0, 2.4)) : 0
        let y = 166 - 20 * Mini.step(t, 1.6, 2.0)
        ZStack {
            Mini.dock(offset: hidden * 46).position(x: W / 2, y: H - 26)
            if on { Mini.pointer(CGPoint(x: W / 2 + 20, y: y)) }
        }
    }

    static let clickToHide = DemoSpec(period: 3, off: "Click does nothing", on: "Click hides the app") { on, t in
        let gone = on ? Mini.step(t, 1.0, 1.4) : 0
        ZStack {
            Mini.window(150, 82).opacity(1 - gone).scaleEffect(1 - gone * 0.1).position(x: W / 2, y: 64)
            Mini.dock().position(x: W / 2, y: H - 26)
            Mini.pointer(CGPoint(x: W / 2 - 63, y: H - 22 + (t > 0.9 && t < 1.1 ? 2 : 0)))
        }
    }

    static let scrollWindows = DemoSpec(period: 3, off: "Scroll does nothing", on: "Windows come forward in turn") { on, t in
        let turn = on ? Int(t / 1) % 3 : 0
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let order = (index - turn + 3) % 3
                Mini.window(130, 74, tint: Mini.colors[index].opacity(0.35))
                    .position(x: W / 2 - 14 + Double(order) * 14, y: 52 + Double(order) * 10)
                    .zIndex(Double(3 - order))
            }
            Mini.dock().position(x: W / 2, y: H - 26)
        }
    }

    static let everyDesktop = DemoSpec(period: 3, off: "Stays on one desktop", on: "On every desktop") { on, t in
        let slide = Mini.step(t, 0.8, 1.6) * W
        ZStack {
            HStack(spacing: 0) {
                ZStack { Mini.dock().position(x: W / 2, y: H - 26) }.frame(width: W, height: H)
                ZStack { if on { Mini.dock().position(x: W / 2, y: H - 26) } }
                    .frame(width: W, height: H).background(Color.purple.opacity(0.15))
            }
            .offset(x: W / 2 - slide)
        }
        .frame(width: W, height: H).clipped()
    }

    // MARK: Hot Corners

    static func corner(_ title: String, ripple: Bool = false) -> DemoSpec {
        DemoSpec(period: 2.8, off: "Nothing happens", on: title) { on, t in
            let reach = Mini.step(t, 0.2, 0.9)
            let lit = on ? Mini.step(t, 0.9, 1.2) * (1 - Mini.step(t, 2.2, 2.6)) : 0
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [Color.accentColor.opacity(0.8 * lit), .clear], center: .topLeading, startRadius: 0, endRadius: 90)
                if ripple, on {
                    Circle().strokeBorder(.white.opacity(0.6 * (1 - Mini.step(t, 1.0, 1.9))), lineWidth: 3)
                        .frame(width: 220 * Mini.step(t, 1.0, 1.9), height: 220 * Mini.step(t, 1.0, 1.9))
                        .position(x: 4, y: 4)
                }
                if lit > 0.5 { Mini.caption(title).position(x: 90, y: 40) }
                Mini.pointer(CGPoint(x: 150 - 142 * reach, y: 100 - 92 * reach))
            }
            .frame(width: W, height: H)
        }
    }

    static let pauseFullScreen = DemoSpec(period: 2.8, off: "Fires in full screen too", on: "A full-screen app keeps its corners") { on, t in
        let reach = Mini.step(t, 0.2, 0.9)
        let lit = on ? 0 : Mini.step(t, 0.9, 1.2) * (1 - Mini.step(t, 2.2, 2.6))
        ZStack {
            Color.black.opacity(0.55)
            Image(systemName: "play.rectangle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.4))
            RadialGradient(colors: [Color.accentColor.opacity(0.8 * lit), .clear], center: .topLeading, startRadius: 0, endRadius: 90)
            Mini.pointer(CGPoint(x: 150 - 142 * reach, y: 100 - 92 * reach))
        }
        .frame(width: W, height: H)
    }

    static let pauseDragging = DemoSpec(period: 2.8, off: "A drag can trigger it", on: "Dragging into a corner does nothing") { on, t in
        let reach = Mini.step(t, 0.2, 1.0)
        let lit = on ? 0 : Mini.step(t, 1.0, 1.3) * (1 - Mini.step(t, 2.2, 2.6))
        ZStack {
            RadialGradient(colors: [Color.accentColor.opacity(0.8 * lit), .clear], center: .topLeading, startRadius: 0, endRadius: 90)
            Mini.window(80, 50).position(x: 160 - 120 * reach, y: 110 - 80 * reach)
            Mini.pointer(CGPoint(x: 168 - 120 * reach, y: 95 - 80 * reach))
        }
        .frame(width: W, height: H)
    }

    // MARK: Windows

    static let snapZones = DemoSpec(period: 3, off: "Drops where it lands", on: "Snaps to half the screen") { on, t in
        let drag = Mini.step(t, 0.2, 1.1)
        let snap = on ? Mini.step(t, 1.2, 1.5) : 0
        let x = 150 - 110 * drag, y = 80.0
        ZStack {
            if on, drag > 0.95 { RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.15 * (1 - snap))).frame(width: W / 2 - 8, height: H - 16).position(x: W / 4, y: H / 2) }
            Mini.window(110 + (W / 2 - 8 - 110) * snap, 70 + (H - 16 - 70) * snap)
                .position(x: x + (W / 4 - x) * snap, y: y + (H / 2 - y) * snap)
            Mini.pointer(CGPoint(x: x - 40, y: y - 30))
        }
        .frame(width: W, height: H)
    }

    static let hotKeys = DemoSpec(period: 3, off: "Keys do nothing", on: "⌃⌥← sends it left") { on, t in
        let move = on ? Mini.step(t, 1.0, 1.35) : 0
        ZStack {
            Mini.window(120 + (W / 2 - 128) * move, 74 + (H - 90) * move)
                .position(x: W / 2 + (W / 4 - W / 2 + 2) * move, y: H / 2)
            if t > 0.6, t < 1.6 { Mini.caption("⌃ ⌥ ←").position(x: W / 2, y: H - 18) }
        }
        .frame(width: W, height: H)
    }

    static let shuffle = DemoSpec(period: 3, off: "Windows stay put", on: "A shortcut deals them out") { on, t in
        let deal = on ? Mini.step(t, 0.8, 1.4) : 0
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                let col = Double(index % 2), row = Double(index / 2)
                Mini.window(110 - 20 * deal, 70 - 6 * deal, tint: Mini.colors[index].opacity(0.3))
                    .position(x: W / 2 + Double(index) * 6 + (W / 4 + col * W / 2 - W / 2 - Double(index) * 6) * deal,
                              y: H / 2 + Double(index) * 5 + (H / 4 + row * H / 2 - H / 2 - Double(index) * 5) * deal)
            }
        }
        .frame(width: W, height: H)
    }

    static let stageGlow = DemoSpec(period: 2.6, off: "No light", on: "A soft light marks where it lands") { on, t in
        let glow = on ? Mini.wave(t, 2.6) : 0
        ZStack {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.9 * glow), lineWidth: 2)
                .shadow(color: Color.accentColor.opacity(glow), radius: 10)
                .frame(width: W / 2 - 10, height: H - 18).position(x: W / 4 + 2, y: H / 2)
            Mini.window(W / 2 - 14, H - 22).position(x: W / 4 + 2, y: H / 2)
        }
        .frame(width: W, height: H)
    }

    // MARK: Menu bar

    static let floatingBar = DemoSpec(period: 2.6, off: "Against the top edge", on: "Floats, rounded, inset") { on, _ in
        VStack { Mini.menuBar(height: on ? 16 : 14, inset: on ? 8 : 0, radius: on ? 8 : 0); Spacer() }.frame(width: W, height: H)
    }

    static let notchBlend = DemoSpec(period: 2.6, off: "Notch stands out", on: "Bar goes black around it") { on, _ in
        VStack {
            ZStack {
                Mini.menuBar(fill: on ? .black : .black.opacity(0.3))
                Capsule().fill(.black).frame(width: 52, height: 16).offset(y: -4)
            }
            Spacer()
        }
        .frame(width: W, height: H)
    }

    static let menuMotion = DemoSpec(period: 2.6, off: "Still", on: "Its light drifts slowly") { on, t in
        VStack {
            Mini.menuBar(fill: on ? Color(hue: Mini.wave(t, 2.6) * 0.3 + 0.55, saturation: 0.6, brightness: 0.5) : .black.opacity(0.35))
            Spacer()
        }
        .frame(width: W, height: H)
    }

    static let readableText = DemoSpec(period: 2.6, off: "Text can wash out", on: "Text stays readable") { on, _ in
        ZStack(alignment: .top) {
            LinearGradient(colors: [.white, Color(white: 0.85)], startPoint: .top, endPoint: .bottom)
            Mini.menuBar(fill: on ? .black.opacity(0.35) : .white.opacity(0.1))
                .foregroundStyle(on ? .white : .white.opacity(0.7))
        }
        .frame(width: W, height: H)
    }

    static let nightSkin = DemoSpec(period: 3, off: "One skin all day", on: "A darker skin at night") { on, t in
        let night = on ? Mini.step(t, 1.0, 1.6) : 0
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.4, green: 0.6, blue: 0.9).opacity(1 - night), Color(red: 0.05, green: 0.06, blue: 0.2).opacity(night)],
                           startPoint: .top, endPoint: .bottom)
            Mini.menuBar(fill: Color(white: 0.9 - 0.85 * night).opacity(0.5))
            Image(systemName: night > 0.5 ? "moon.fill" : "sun.max.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.8))
                .position(x: W - 40, y: 60)
        }
        .frame(width: W, height: H)
    }

    // MARK: Orbit

    static func orbit(rings: Int = 2, lines: Bool = false, labels: Bool = false, nebula: Bool = false, stars: Bool = false,
                      drift: Bool = false, running: Bool = false) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !drift)) { context in
            let spin = drift ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60) * 0.25 : 0
            ZStack {
                if nebula { RadialGradient(colors: [.purple.opacity(0.55), .blue.opacity(0.2), .clear], center: .center, startRadius: 4, endRadius: 110) }
                if stars {
                    ForEach(0..<40, id: \.self) { i in
                        Circle().fill(.white.opacity(0.6)).frame(width: 1.6, height: 1.6)
                            .position(x: Double((i * 73) % Int(W)), y: Double((i * 41) % Int(H)))
                    }
                }
                ForEach(0..<rings, id: \.self) { ring in
                    let radius = 34.0 + Double(ring) * 30
                    if lines { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.6).frame(width: radius * 2, height: radius * 2) }
                    ForEach(0..<(6 + ring * 4), id: \.self) { i in
                        let a = Double(i) / Double(6 + ring * 4) * 2 * .pi + spin * (ring % 2 == 0 ? 1 : -1)
                        VStack(spacing: 1) {
                            Mini.icon(i + ring, size: 16)
                                .overlay(alignment: .bottom) { if running, i % 3 == 0 { Circle().fill(.white).frame(width: 3, height: 3).offset(y: 5) } }
                            if labels { Text("App").font(.system(size: 5)).foregroundStyle(.white.opacity(0.8)) }
                        }
                        .position(x: W / 2 + cos(a) * radius, y: H / 2 + sin(a) * radius * 0.82)
                    }
                }
                Circle().fill(.white.opacity(0.85)).frame(width: 7, height: 7)
            }
            .frame(width: W, height: H)
        }
    }

    static func orbitToggle(_ off: String, _ on: String, _ build: @escaping @MainActor (Bool) -> AnyView) -> DemoSpec {
        DemoSpec(period: 3, off: off, on: on) { isOn, _ in build(isOn) }
    }

    static let orbitRings = orbitToggle("One ring", "More rings") { AnyView(orbit(rings: $0 ? 3 : 1)) }
    static let orbitLines = orbitToggle("No lines", "Ring lines") { AnyView(orbit(lines: $0)) }
    static let orbitLabels = orbitToggle("Icons only", "Names under icons") { AnyView(orbit(labels: $0)) }
    static let orbitRunning = orbitToggle("No marks", "Dots under open apps") { AnyView(orbit(running: $0)) }
    static let orbitNebula = orbitToggle("Plain dark", "A nebula behind") { AnyView(orbit(nebula: $0)) }
    static let orbitStars = orbitToggle("Plain dark", "A field of stars") { AnyView(orbit(stars: $0)) }
    static let orbitDrift = orbitToggle("Still", "Rings turn slowly") { AnyView(orbit(drift: $0)) }

    static let typeToSearch = DemoSpec(period: 3, off: "Typing does nothing", on: "Typing filters the ring") { on, t in
        let typed = on ? min(Int(t / 0.35), 3) : 0
        ZStack {
            orbit(rings: 1).opacity(on && typed > 1 ? 0.35 : 1)
            if on { Mini.caption(String("Saf".prefix(typed))).position(x: W / 2, y: H - 20) }
            if on, typed > 1 { Mini.icon(0, size: 26).position(x: W / 2, y: H / 2) }
        }
    }

    // MARK: Widgets

    static let interactiveWidgets = DemoSpec(period: 2.8, off: "Clicks pass through", on: "Clicks reach the widget") { on, t in
        let ticked = on && t > 1.1
        ZStack {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 6) {
                        Image(systemName: i == 0 && ticked ? "checkmark.circle.fill" : "circle").font(.system(size: 10))
                        Capsule().fill(.white.opacity(0.5)).frame(width: 60, height: 4)
                    }
                }
            }
            .foregroundStyle(.white).padding(12).background(.white.opacity(0.14), in: .rect(cornerRadius: 12))
            Mini.pointer(CGPoint(x: W / 2 - 30, y: H / 2 - 12 + (t > 1.0 && t < 1.15 ? 2 : 0)))
        }
        .frame(width: W, height: H)
    }

    static let fahrenheit = DemoSpec(period: 2.6, off: "21 °C", on: "70 °F") { on, _ in
        VStack(spacing: 4) {
            Image(systemName: "sun.max.fill").font(.system(size: 26)).foregroundStyle(.yellow)
            Text(on ? "70°F" : "21°C").font(.system(size: 30, weight: .light, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: W, height: H)
    }

    static let southern = DemoSpec(period: 2.6, off: "December is winter", on: "December is summer") { on, _ in
        VStack(spacing: 6) {
            Text("December").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            Image(systemName: on ? "sun.max.fill" : "snowflake").font(.system(size: 34)).foregroundStyle(on ? .yellow : .white)
        }
        .frame(width: W, height: H)
    }

    static let rotate = DemoSpec(period: 2.6, off: "Level", on: "Turned a little") { on, t in
        RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.16)).frame(width: 110, height: 80)
            .overlay { Text("12:30").font(.system(size: 22, weight: .light)).foregroundStyle(.white) }
            .rotationEffect(.degrees(on ? -6 * Mini.step(t, 0.3, 0.8) : 0))
            .frame(width: W, height: H)
    }

    static let pomodoro = DemoSpec(period: 3, off: "Plain timer", on: "Work, then a break") { on, t in
        let p = t / 3
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 8).frame(width: 90, height: 90)
            Circle().trim(from: 0, to: p).stroke(on && p > 0.7 ? Color.green : Color.red, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 90, height: 90)
            Text(on && p > 0.7 ? "Break" : "Focus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: W, height: H)
    }

    // MARK: Wallpaper and backgrounds

    static let pauseOnBattery = DemoSpec(period: 3, off: "Plays on battery", on: "Rests on battery") { on, t in
        let moving = !(on && t > 1.0)
        ZStack {
            LinearGradient(colors: [.purple, .blue], startPoint: UnitPoint(x: moving ? Mini.wave(t, 3) : 0.3, y: 0), endPoint: .bottomTrailing)
            HStack(spacing: 4) {
                Image(systemName: t > 1.0 ? "battery.50percent" : "bolt.fill").font(.system(size: 14))
                if !moving { Image(systemName: "pause.fill").font(.system(size: 10)) }
            }
            .foregroundStyle(.white).position(x: W - 30, y: 18)
        }
        .frame(width: W, height: H)
    }

    static let followPointer = DemoSpec(period: 3, off: "Light stays put", on: "Light leans to the pointer") { on, t in
        let x = 40 + 220 * Mini.wave(t, 3)
        ZStack {
            Color(red: 0.08, green: 0.1, blue: 0.25)
            RadialGradient(colors: [.white.opacity(0.45), .clear], center: UnitPoint(x: on ? x / W : 0.5, y: 0.45), startRadius: 0, endRadius: 90)
            Mini.pointer(CGPoint(x: x, y: H * 0.45))
        }
        .frame(width: W, height: H)
    }

    static let changeWithDay = DemoSpec(period: 3.6, off: "Same all day", on: "Follows the sun") { on, t in
        let hour = on ? t / 3.6 : 0.3
        ZStack {
            LinearGradient(colors: [Color(hue: 0.6 - 0.1 * sin(hour * .pi), saturation: 0.6, brightness: 0.25 + 0.6 * sin(hour * .pi)), .black],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(.yellow.opacity(0.9)).frame(width: 18, height: 18)
                .position(x: 30 + (W - 60) * hour, y: H - 30 - 110 * sin(hour * .pi))
        }
        .frame(width: W, height: H)
    }

    static let sameEveryDisplay = DemoSpec(period: 3, off: "Each display its own", on: "One look on all") { on, _ in
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 6).fill(on ? LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom)
                                                       : LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: W - 40, height: 90).frame(width: W, height: H)
    }

    static let grain = DemoSpec(period: 2.6, off: "Smooth", on: "Fine film grain") { on, _ in
        ZStack {
            LinearGradient(colors: [Color(red: 0.2, green: 0.25, blue: 0.5), Color(red: 0.5, green: 0.3, blue: 0.4)], startPoint: .top, endPoint: .bottom)
            if on {
                Canvas { context, size in
                    for i in 0..<900 {
                        let x = Double((i * 7919) % Int(size.width)), y = Double((i * 104_729) % Int(size.height))
                        context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(Double(i % 5) * 0.06)))
                    }
                }
            }
        }
        .frame(width: W, height: H)
    }

    // MARK: Tools

    static let shiftDragZones = DemoSpec(period: 3, off: "A plain drag", on: "Hold ⇧ and the zones appear") { on, t in
        let drag = Mini.step(t, 0.2, 1.2)
        ZStack {
            if on, t > 0.3 {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in RoundedRectangle(cornerRadius: 6).fill(.white.opacity(i == 0 && drag > 0.8 ? 0.3 : 0.1)) }
                }
                .padding(8)
                Mini.caption("⇧").position(x: W - 20, y: 18)
            }
            Mini.window(90, 56).position(x: 200 - 140 * drag, y: H / 2)
        }
        .frame(width: W, height: H)
    }
}

// MARK: - Catalogue settings
//
// The catalogue has hundreds of settings; each gets a scene from the family it belongs to,
// tuned by what its title says. The On caption is the catalogue's own sentence for it.

extension Demos {
    static func personal(area: String, section: String, title: String, preview: String) -> DemoSpec {
        let lower = title.lowercased()
        /// A setting that takes something away: on shows the same moment, without it.
        let removes = ["no ", "turn off", "disable", "hide", "still ", "instant", "reduce", "plain"].contains { lower.hasPrefix($0) }
            || lower.contains("turn off")
        let on = Self.short(preview)
        let off = "As macOS ships it"
        let scene: @MainActor (Bool, Double) -> AnyView

        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }

        switch (area, section) {
        case ("controlCenter", "Menu Bar Items"):
            scene = { on, t in AnyView(MenuItemScene(symbol: Self.menuSymbol(lower), on: on, t: t)) }
        case ("controlCenter", "Clock"), ("controlCenter", "Battery"):
            scene = { on, t in AnyView(ClockScene(on: on, t: t, variant: lower)) }
        case ("controlCenter", "Menu Bar"):
            scene = { on, t in AnyView(MenuHideScene(on: on, t: t)) }
        case ("spotlight", _):
            scene = { on, t in AnyView(SpotlightScene(on: on, t: t, removes: removes, wide: has("wider"))) }
        case ("lockScreen", _):
            scene = { on, t in AnyView(LockScene(on: on, t: t, variant: lower)) }
        case ("input", "Text"), ("appKit", "Text"):
            scene = { on, t in AnyView(TypingScene(on: on, t: t, variant: lower)) }
        case ("input", "Keyboard"):
            scene = { on, t in AnyView(KeyScene(on: on, t: t, variant: lower)) }
        case ("input", "Pointer"), ("accessibility", "Pointer"):
            scene = { on, t in AnyView(PointerScene(on: on, t: t, variant: lower)) }
        case ("input", "Trackpad"), ("input", "Haptics"):
            scene = { on, t in AnyView(TrackpadScene(on: on, t: t, haptic: section == "Haptics", variant: lower)) }
        case ("sounds", _):
            scene = { on, t in AnyView(SoundScene(on: on, t: t, flash: has("flash"))) }
        case ("missionControl", _), ("windows", _):
            scene = { on, t in AnyView(SpreadScene(on: on, t: t, removes: removes, stage: section == "Stage Manager", tiles: section == "Tiling")) }
        case ("quickLook", _):
            scene = { on, t in AnyView(OpenScene(on: on, t: t, removes: removes || has("instant", "fast"), look: true)) }
        case ("capture", _):
            scene = { on, t in AnyView(ShotScene(on: on, t: t)) }
        case ("accessibility", "Zoom"), ("accessibility", "Hover"):
            scene = { on, t in AnyView(LensScene(on: on, t: t)) }
        case ("accessibility", _):
            scene = { on, t in AnyView(ContrastScene(on: on, t: t, variant: lower)) }
        case ("appKit", "Scrolling"), ("animations", "Apps") where has("scroll", "rubber"):
            scene = { on, t in AnyView(ScrollScene(on: on, t: t, removes: removes)) }
        case ("animations", "Dock"), ("animations", "Dock (Hidden)"):
            scene = { on, t in AnyView(DockMotionScene(on: on, t: t, removes: removes)) }
        case ("finder", "Desktop"), ("finder", "Files"), ("finder", "Trash"):
            scene = { on, t in AnyView(FilesScene(on: on, t: t)) }
        case ("corners", _):
            return corner(on, ripple: true)
        default:
            scene = { on, t in AnyView(OpenScene(on: on, t: t, removes: removes, look: false)) }
        }
        return DemoSpec(period: 3, still: 1.6, off: off, on: on) { on, t in scene(on, t) }
    }

    static func short(_ text: String) -> String {
        let first = text.split(separator: ".", maxSplits: 1).first.map(String.init) ?? text
        return first.count > 46 ? String(first.prefix(44)) + "…" : first
    }

    static func menuSymbol(_ title: String) -> String {
        let table: [(String, String)] = [
            ("battery", "battery.75percent"), ("wi-fi", "wifi"), ("bluetooth", "wave.3.right"), ("sound", "speaker.wave.2.fill"),
            ("now playing", "play.fill"), ("focus", "moon.fill"), ("display", "sun.max.fill"), ("mirroring", "rectangle.on.rectangle"),
            ("airdrop", "dot.radiowaves.left.and.right"), ("keyboard", "light.max"), ("hearing", "ear"),
            ("accessibility", "accessibility"), ("music", "shazam.logo"), ("user", "person.crop.circle"),
            ("spotlight", "magnifyingglass"), ("siri", "waveform.circle"), ("airplay", "airplayvideo"),
        ]
        return table.first { title.contains($0.0) }?.1 ?? "circle.grid.2x2"
    }
}

// MARK: Scenes

private struct SceneMenuBar<Extra: View>: View {
    var opacity = 1.0
    @ViewBuilder var extra: Extra
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.logo").font(.system(size: 9))
            ForEach(["Finder", "File", "Edit"], id: \.self) { Text($0).font(.system(size: 8, weight: .medium)) }
            Spacer()
            extra
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).frame(width: W, height: 20)
        .background(.black.opacity(0.32))
        .opacity(opacity)
    }
}

private struct MenuItemScene: View {
    let symbol: String, on: Bool, t: Double
    var body: some View {
        let show = on ? Mini.step(t, 0.6, 1.0) : 0
        VStack(spacing: 0) {
            SceneMenuBar {
                Image(systemName: "wifi").font(.system(size: 8))
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                    .frame(width: 14 * show).opacity(show).scaleEffect(0.6 + 0.4 * show)
                Text("9:41").font(.system(size: 8, weight: .semibold))
            }
            Spacer()
            Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.12 + 0.5 * show))
            Spacer()
        }
        .frame(width: W, height: H)
    }
}

private struct ClockScene: View {
    let on: Bool, t: Double, variant: String
    private var text: String {
        guard on else { return "Mon 9:41" }
        if variant.contains("date") { return "Mon 9 Nov 9:41" }
        if variant.contains("am/pm") { return "Mon 9:41 AM" }
        if variant.contains("24") { return "Mon 21:41" }
        if variant.contains("day") { return "9:41" }
        return "Mon 9:41"
    }
    var body: some View {
        let battery = variant.contains("battery") || variant.contains("energy")
        VStack(spacing: 0) {
            SceneMenuBar {
                if battery {
                    if on { Text("82%").font(.system(size: 8, weight: .semibold)).transition(.opacity) }
                    Image(systemName: "battery.75percent").font(.system(size: 10))
                }
                Text(text).font(.system(size: 8, weight: .semibold)).monospacedDigit()
            }
            Spacer()
            Text(battery ? (on ? "82%" : "") : text)
                .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .scaleEffect(0.96 + 0.04 * Mini.wave(t, 3))
            Spacer()
        }
        .frame(width: W, height: H)
    }
}

private struct MenuHideScene: View {
    let on: Bool, t: Double
    var body: some View {
        let hidden = on ? Mini.step(t, 0.4, 0.8) * (1 - Mini.step(t, 1.8, 2.2)) : 0
        ZStack(alignment: .top) {
            Mini.window(170, 96).position(x: W / 2, y: H / 2 + 8)
            SceneMenuBar { Text("9:41").font(.system(size: 8, weight: .semibold)) }
                .offset(y: -22 * hidden)
            if on { Mini.pointer(CGPoint(x: W / 2 + 40, y: 60 - 50 * Mini.step(t, 1.4, 1.8))) }
        }
        .frame(width: W, height: H, alignment: .top)
    }
}

private struct SpotlightScene: View {
    let on: Bool, t: Double, removes: Bool, wide: Bool
    var body: some View {
        let instant = on && removes
        let open = instant ? (t > 0.5 ? 1 : 0) : Mini.step(t, 0.5, 1.1)
        let results = instant ? (t > 0.9 ? 1 : 0) : Mini.step(t, 1.2, 1.8)
        let width = on && wide ? 250.0 : 200.0
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                Text("Safari").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 30)
            VStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 7) {
                        Mini.icon(i, size: 14)
                        Capsule().fill(.white.opacity(0.4)).frame(width: [70, 54, 62][i], height: 5)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            .frame(height: 60 * results, alignment: .top).clipped().opacity(results)
        }
        .frame(width: width)
        .background(.ultraThinMaterial.opacity(0.9), in: .rect(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
        .scaleEffect(0.86 + 0.14 * open).opacity(open)
        .frame(width: W, height: H)
    }
}

private struct LockScene: View {
    let on: Bool, t: Double, variant: String
    var body: some View {
        let weight: Font.Weight = on && variant.contains("weight") ? .black : .semibold
        let name = !(on && variant.contains("hide"))
        let dim = on && variant.contains("screen saver after") ? Mini.step(t, 1.0, 1.6) : 0
        ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.2, blue: 0.5), Color(red: 0.9, green: 0.5, blue: 0.4)],
                           startPoint: .top, endPoint: .bottom).opacity(0.5)
            VStack(spacing: 2) {
                Text("Monday 9 November").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                Text("9:41").font(.system(size: 50, weight: weight, design: .rounded)).foregroundStyle(.white)
                Spacer()
                if name {
                    Circle().fill(.white.opacity(0.3)).frame(width: 22, height: 22)
                    Text("Atelier").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.vertical, 18)
            Color.black.opacity(0.7 * dim)
            if on && variant.contains("clock over") {
                Text("9:41").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                    .opacity(Mini.step(t, 1.2, 1.6)).offset(y: 50)
            }
        }
        .frame(width: W, height: H)
    }
}

private struct TypingScene: View {
    let on: Bool, t: Double, variant: String
    private var typed: String {
        let full = "dont worry -- its fine"
        let count = Int(min(t / 1.8, 1) * Double(full.count))
        return String(full.prefix(count))
    }
    private var shown: String {
        guard on, t > 1.9 else { return typed }
        if variant.contains("quote") || variant.contains("autocorrect") { return "don’t worry -- it’s fine" }
        if variant.contains("dash") { return "dont worry — its fine" }
        if variant.contains("capital") { return "Dont worry -- its fine" }
        if variant.contains("full stop") { return "dont worry -- its fine." }
        return typed
    }
    var body: some View {
        let caretPeriod = variant.contains("caret") ? (on ? 0.35 : 1.0) : 1.0
        let caret = (t / caretPeriod).truncatingRemainder(dividingBy: 1) < 0.5
        let suggests = on && (variant.contains("predict") || variant.contains("completion")) && t > 1.0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(shown).font(.system(size: 14, weight: .regular, design: .serif)).foregroundStyle(.white)
                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 17).opacity(caret ? 1 : 0)
                if suggests {
                    Text(" and calm").font(.system(size: 14, design: .serif)).foregroundStyle(.white.opacity(0.35))
                }
            }
            ForEach([0.8, 0.6], id: \.self) { w in Capsule().fill(.white.opacity(0.12)).frame(width: 220 * w, height: 5) }
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
        .background(Color(white: 0.16).opacity(0.9), in: .rect(cornerRadius: 10, style: .continuous))
        .frame(width: W, height: H)
    }
}

private struct KeyScene: View {
    let on: Bool, t: Double, variant: String
    var body: some View {
        let rate = on ? 0.06 : 0.16
        let held = t > 0.4 && t < 2.2
        let count = held ? min(Int((t - 0.4 - (on ? 0.15 : 0.45)) / rate), 16) : 0
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                Text("e" + String(repeating: "e", count: max(count, 0))).font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.white).lineLimit(1)
                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 16)
            }
            .frame(width: 240, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(["Q", "W", "E", "R", "T"], id: \.self) { key in
                    Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 30, height: 28)
                        .background(.white.opacity(key == "E" && held ? 0.32 : 0.12), in: .rect(cornerRadius: 6, style: .continuous))
                        .offset(y: key == "E" && held ? 1.5 : 0)
                }
            }
        }
        .frame(width: W, height: H)
    }
}

private struct PointerScene: View {
    let on: Bool, t: Double, variant: String
    var body: some View {
        let shake = variant.contains("shake")
        let x = W / 2 + (shake && t > 0.6 && t < 1.6 ? sin(t * 40) * 40 : (t - 1.5) * 50)
        let grow = shake ? (on && t > 0.9 && t < 2.2 ? 2.6 : 1) : (on && variant.contains("size") ? 2 : 1)
        let speed = variant.contains("speed") && on ? 1.8 : 1
        ZStack {
            Mini.window(160, 90).position(x: W / 2, y: H / 2)
            Image(systemName: "cursorarrow").font(.system(size: 14 * grow, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .position(x: shake ? x : W / 2 + (x - W / 2) * speed, y: H / 2 + 20)
                .animation(.spring(duration: 0.3), value: grow)
        }
        .frame(width: W, height: H).clipped()
    }
}

private struct TrackpadScene: View {
    let on: Bool, t: Double, haptic: Bool, variant: String
    var body: some View {
        let tap = t > 1.0 && t < 1.25
        let natural = variant.contains("natural")
        let fingers = variant.contains("three") ? 3 : (natural || variant.contains("swipe") ? 2 : 1)
        let slide = natural || variant.contains("swipe") || variant.contains("drag") ? Mini.step(t, 0.6, 1.8) : 0
        HStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.2)))
                HStack(spacing: 8) {
                    ForEach(0..<fingers, id: \.self) { _ in Circle().fill(.white.opacity(0.7)).frame(width: 14) }
                }
                .offset(y: 20 - 40 * slide)
                if tap && on {
                    Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.5).frame(width: 46).transition(.opacity)
                }
                if haptic && on && tap {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .frame(width: 130, height: 96)
            .offset(x: haptic && on && tap ? sin(t * 120) * 1.5 : 0)
            Mini.window(90, 70, tint: Color(white: 0.2))
                .overlay(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.35)).frame(width: 50, height: 4)
                        .offset(y: -10 - 30 * (natural && on ? slide : (natural ? 1 - slide : 0)))
                }
                .opacity(tap && on && !natural ? 0.6 : 1)
        }
        .frame(width: W, height: H)
    }
}

private struct SoundScene: View {
    let on: Bool, t: Double, flash: Bool
    var body: some View {
        let ping = t > 0.8 && t < 1.4
        ZStack {
            Mini.window(170, 96).position(x: W / 2, y: H / 2)
            HStack(spacing: 4) {
                Image(systemName: "speaker.fill").font(.system(size: 20))
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(.white.opacity(ping ? 0.8 - Double(i) * 0.2 : 0.15))
                        .frame(width: 3, height: 10 + Double(i) * 7 + (on && !flash && ping ? 6 : 0))
                }
            }
            .foregroundStyle(.white).position(x: W / 2, y: H / 2 + 6)
            if flash && on { Color.white.opacity(ping ? 0.55 * (1 - Mini.step(t, 0.8, 1.4)) : 0) }
        }
        .frame(width: W, height: H)
    }
}

private struct SpreadScene: View {
    let on: Bool, t: Double, removes: Bool, stage: Bool, tiles: Bool
    var body: some View {
        let spread = removes ? (on ? 0 : Mini.step(t, 0.6, 1.2)) : (on ? Mini.step(t, 0.6, 1.2) : 0)
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                let rest = CGPoint(x: W / 2 + Double(i) * 6 - 9, y: H / 2 + Double(i) * 5 - 8)
                let target: CGPoint = stage
                    ? (i == 0 ? CGPoint(x: W / 2 + 20, y: H / 2) : CGPoint(x: 34, y: 40 + Double(i) * 34))
                    : tiles ? CGPoint(x: i % 2 == 0 ? W * 0.27 : W * 0.73, y: i < 2 ? H * 0.3 : H * 0.72)
                    : CGPoint(x: i % 2 == 0 ? W * 0.3 : W * 0.7, y: i < 2 ? H * 0.32 : H * 0.7)
                let scale = stage ? (i == 0 ? 1 : 0.42) : (tiles ? 0.92 : 0.7)
                Mini.window(140, 82, tint: Mini.colors[i].opacity(0.3))
                    .scaleEffect(1 + (scale - 1) * spread)
                    .position(x: rest.x + (target.x - rest.x) * spread, y: rest.y + (target.y - rest.y) * spread)
                    .zIndex(Double(4 - i))
            }
        }
        .frame(width: W, height: H)
    }
}

private struct OpenScene: View {
    let on: Bool, t: Double, removes: Bool, look: Bool
    var body: some View {
        let instant = on && removes
        let grow = instant ? (t > 0.8 ? 1 : 0) : Mini.step(t, 0.8, on ? 1.15 : 1.4)
        let extra = on && !removes
        ZStack {
            if look {
                RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.85)).frame(width: 26, height: 32)
                    .position(x: 60, y: H - 40).opacity(1 - grow)
            }
            Mini.window(180, 110, tint: Color(white: 0.17))
                .overlay {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach([0.7, 0.9, 0.5], id: \.self) { w in Capsule().fill(.white.opacity(0.18)).frame(width: 140 * w, height: 5) }
                    }
                    .padding(.top, 14)
                }
                .overlay(alignment: .topTrailing) {
                    if extra {
                        Capsule().fill(Color.accentColor).frame(width: 36, height: 10).padding(.top, 20).padding(.trailing, 10)
                            .opacity(Mini.step(t, 1.4, 1.7))
                    }
                }
                .scaleEffect(0.3 + 0.7 * grow, anchor: look ? .bottomLeading : .center)
                .opacity(grow)
                .position(x: W / 2, y: H / 2)
        }
        .frame(width: W, height: H)
    }
}

private struct ShotScene: View {
    let on: Bool, t: Double
    var body: some View {
        let flash = t > 0.8 && t < 1.0
        let thumb = Mini.step(t, 1.0, 1.3)
        ZStack {
            Mini.window(170, 96).position(x: W / 2, y: H / 2 - 6)
            Color.white.opacity(flash ? 0.5 : 0)
            VStack(spacing: 3) {
                Image(systemName: on ? "doc.richtext" : "photo").font(.system(size: 18))
                Text(on ? "Shot.jpg" : "Screenshot.png").font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(.white).opacity(thumb).position(x: W - 40, y: 36)
        }
        .frame(width: W, height: H)
    }
}

private struct LensScene: View {
    let on: Bool, t: Double
    var body: some View {
        let zoom = on ? Mini.step(t, 0.6, 1.2) * (1 - Mini.step(t, 2.3, 2.8)) : 0
        ZStack {
            VStack(alignment: .leading, spacing: 7) {
                Text("The quick brown fox").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                ForEach([0.9, 0.7, 0.8], id: \.self) { w in Capsule().fill(.white.opacity(0.18)).frame(width: 180 * w, height: 5) }
            }
            .scaleEffect(1 + 1.2 * zoom, anchor: .topLeading)
            .frame(width: 220, height: 120, alignment: .topLeading)
            .padding(12)
            .background(Color(white: 0.16).opacity(0.9), in: .rect(cornerRadius: 10, style: .continuous))
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
        }
        .frame(width: W, height: H)
    }
}

private struct ContrastScene: View {
    let on: Bool, t: Double, variant: String
    var body: some View {
        let contrast = on && variant.contains("contrast")
        let solid = on && variant.contains("transparency")
        let ring = on && variant.contains("focus ring")
        let shapes = on && (variant.contains("shapes") || variant.contains("differentiate"))
        let still = on && variant.contains("motion")
        let bob = still ? 0 : sin(t * 2.2) * 6
        HStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { i in
                VStack(spacing: 6) {
                    Mini.icon(i, size: 30)
                        .overlay {
                            if shapes { Image(systemName: ["circle", "triangle", "square"][i]).font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                        }
                        .offset(y: i == 1 ? bob : 0)
                    Text(["Mail", "Notes", "Music"][i]).font(.system(size: 9, weight: contrast ? .bold : .medium))
                        .foregroundStyle(.white.opacity(contrast ? 1 : 0.7))
                        .padding(.horizontal, 6).frame(height: 18)
                        .background {
                            if ring && i == 1 {
                                Capsule().strokeBorder(Color.accentColor, lineWidth: variant.contains("large") ? 3.5 : 2)
                            } else if shapes || contrast {
                                Capsule().strokeBorder(.white.opacity(contrast ? 0.9 : 0.4), lineWidth: 1)
                            }
                        }
                }
            }
        }
        .padding(18)
        .background(solid ? AnyShapeStyle(Color(white: 0.2)) : AnyShapeStyle(.white.opacity(0.08)),
                    in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            if contrast { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 1.5) }
        }
        .frame(width: W, height: H)
    }
}

private struct ScrollScene: View {
    let on: Bool, t: Double, removes: Bool
    var body: some View {
        let offset = Mini.wave(t, 3) * 60
        let bar = removes ? !on : (on || (t > 0.5 && t < 2.0))
        Mini.window(200, 120, tint: Color(white: 0.17))
            .overlay {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<12, id: \.self) { i in Capsule().fill(.white.opacity(0.18)).frame(width: [150, 120, 160, 90][i % 4], height: 5) }
                }
                .offset(y: 10 - offset)
                .frame(width: 180, height: 100, alignment: .top).clipped().padding(.top, 13)
            }
            .overlay(alignment: .topTrailing) {
                Capsule().fill(.white.opacity(0.5)).frame(width: 4, height: 30)
                    .padding(.top, 18 + offset * 0.8).padding(.trailing, 4).opacity(bar ? 1 : 0)
            }
            .frame(width: W, height: H)
    }
}

private struct DockMotionScene: View {
    let on: Bool, t: Double, removes: Bool
    var body: some View {
        let hop = on != removes ? abs(sin(t * 2 * .pi / 0.7)) * (t > 0.5 && t < 1.9 ? 1 : 0) : 0
        let open = Mini.step(t, 1.9, 2.3)
        ZStack {
            Mini.window(150, 82).scaleEffect(0.3 + 0.7 * open).opacity(open).position(x: W / 2, y: 64)
            Mini.dock(lift: (2, hop)).position(x: W / 2, y: H - 26)
        }
        .frame(width: W, height: H)
    }
}

private struct FilesScene: View {
    let on: Bool, t: Double
    var body: some View {
        let added = on ? Mini.step(t, 0.7, 1.1) : 0
        Mini.window(200, 116, tint: Color(white: 0.17))
            .overlay {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(["Projects", "Budget", "Notes"], id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: name == "Projects" ? "folder.fill" : "doc").foregroundStyle(name == "Projects" ? .blue : .white.opacity(0.7))
                            Text(name + (on && name != "Projects" ? [".pdf", ".txt"][name == "Notes" ? 1 : 0] : ""))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.fill").foregroundStyle(.white.opacity(0.7))
                        Text("Backup").foregroundStyle(.white.opacity(0.85))
                    }
                    .opacity(added)
                }
                .font(.system(size: 10))
                .padding(.top, 14)
            }
            .frame(width: W, height: H)
    }
}

// MARK: - Appearance and sound

extension Demos {
    static let darkHours = DemoSpec(period: 4, still: 2.4, off: "Follows the sun, or by hand", on: "Dark at 19:00, light at 07:30") { on, t in
        let evening = on ? Mini.step(t, 1.2, 2.0) * (1 - Mini.step(t, 3.2, 3.8)) : 0
        ZStack {
            LinearGradient(colors: [Color(red: 0.55 - 0.45 * evening, green: 0.7 - 0.55 * evening, blue: 0.95 - 0.6 * evening),
                                    Color(red: 0.95 - 0.8 * evening, green: 0.8 - 0.65 * evening, blue: 0.6 - 0.3 * evening)],
                           startPoint: .top, endPoint: .bottom)
            Mini.window(150, 82, tint: Color(white: 0.92 - 0.75 * evening)).position(x: W / 2, y: H / 2)
            Text(evening > 0.5 ? "19:00" : "18:59").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white).padding(.horizontal, 7).frame(height: 18).background(.black.opacity(0.35), in: .capsule)
                .position(x: W - 34, y: 18)
            Image(systemName: evening > 0.5 ? "moon.fill" : "sun.max.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.9))
                .position(x: 24, y: 20)
        }
    }

    static let lightApp = DemoSpec(period: 3, still: 1.5, off: "Every app dark", on: "Your chosen app stays light") { on, _ in
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.14)
            Mini.window(120, 76, tint: Color(white: 0.16)).position(x: W / 2 - 62, y: H / 2 + 6)
            Mini.window(120, 76, tint: Color(white: on ? 0.94 : 0.16))
                .overlay { VStack(spacing: 5) { ForEach([0.7, 0.5, 0.8], id: \.self) { Capsule().fill((on ? Color.black : .white).opacity(0.2)).frame(width: 90 * $0, height: 4) } }.padding(.top, 12) }
                .position(x: W / 2 + 62, y: H / 2 - 4)
        }
    }

    static let typingSounds = DemoSpec(period: 2.4, still: 0.5, off: "Silent keys", on: "A soft thock on each key") { on, t in
        let pressed = Int(t / 0.3) % 5
        ZStack {
            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(i == pressed ? 0.35 : 0.14))
                        .frame(width: 32, height: 30).offset(y: i == pressed ? 2 : 0)
                }
            }
            .position(x: W / 2, y: H / 2 + 22)
            if on {
                let wave = 1 - (t.truncatingRemainder(dividingBy: 0.3)) / 0.3
                ForEach(0..<3, id: \.self) { ring in
                    Circle().strokeBorder(.white.opacity(0.5 * wave), lineWidth: 1.5)
                        .frame(width: 20 + Double(ring) * 16 * (1.4 - wave), height: 20 + Double(ring) * 16 * (1.4 - wave))
                        .position(x: W / 2 - 74 + Double(pressed) * 37, y: H / 2 - 12)
                }
            }
        }
    }
}
