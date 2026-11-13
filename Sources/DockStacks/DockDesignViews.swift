import AppKit
import DockCore
import QuartzCore
import SwiftUI

// How each design draws the bar, its marks, its icon plates and its effects.
//
// Cost rules, measured against the 120 Hz frame:
// - Nothing here keeps a clock. Motion that runs by itself (Neon Rim, Aurora, breathing) is a
//   Core Animation animation, played by the render server, and paused (layer speed 0) while
//   the bar is hidden, while Reduce Motion is on, or in a preview nobody is looking at.
// - Textures (scanlines, brushed metal, paper) are small images drawn once and tiled by the
//   GPU, so a bar that changes length every frame under the lens never redraws them.
// - Effects read only values the physics already writes per tile (ring, near, lean, appear).

// MARK: - Backdrop

struct DockBarBackdrop: View {
    let scene: DockScene
    let theme: DockTheme
    /// A flat stand-in for live glass, for previews inside the settings panel's own glass.
    var flat = false
    /// Core Animation may run. False pauses every animated layer where it is.
    var animating = true

    private var design: DockDesign { theme.fx.design }
    private var radius: Double { DockDesignStyle.radius(design, scene.radius) }
    private var size: CGSize { CGSize(width: max(scene.bar.width, 1), height: max(scene.bar.height, 1)) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        ZStack {
            switch design {
            case .liquidGlass:
                glass
            case .islands:
                DockIslandsBackdrop(scene: scene, theme: theme, flat: flat)
            case .neonRim:
                glass
                DockDesignLayer(kind: .neon, size: size, radius: radius, colors: [theme.accent, theme.rings[1]],
                                running: animating)
            case .aurora:
                glass
                DockDesignLayer(kind: .aurora, size: size, radius: radius,
                                colors: [theme.accent, theme.rings[1], Color(red: 0.3, green: 0.95, blue: 0.8)],
                                running: animating)
            case .holographic:
                glass
                DockDesignLayer(kind: .holo, size: size, radius: radius, colors: [],
                                running: animating, angle: holoAngle)
            case .ceramic:
                ceramic
            case .minimalLine:
                hairline
            case .retro:
                retro
            case .paper:
                paper
            case .darkMetal:
                metal
            }
            if theme.fx.breathing, design != .minimalLine {
                DockDesignLayer(kind: .breathe, size: size, radius: radius, colors: [theme.accent], running: animating)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Holographic: the rim's colours turn as the lens travels along the bar.
    private var holoAngle: Double {
        let along = scene.edge.horizontal ? scene.bar.minX : scene.bar.minY
        let length = max(scene.edge.horizontal ? scene.bar.width : scene.bar.height, 1)
        return ((scene.lens - along) / length) * .pi * 1.5 * max(scene.ramp, 0.25)
    }

    @ViewBuilder private var glass: some View {
        Group {
            if flat {
                shape.fill((theme.tint ?? .white).opacity(theme.tint == nil ? 0.16 : 0.4))
            } else {
                Color.clear.atelierGlass(theme.glass, in: .rect(cornerRadius: radius))
            }
        }
        .overlay {
            shape.strokeBorder(LinearGradient(colors: theme.rim, startPoint: .topLeading, endPoint: .bottomTrailing),
                               lineWidth: theme.rimWidth)
        }
        .background {
            if let glow = theme.glow { shape.stroke(glow.opacity(0.75), lineWidth: 3).blur(radius: 9) }
        }
        .shadow(color: .black.opacity(theme.shadow), radius: 18, y: 8)
    }

    private var ceramic: some View {
        shape
            .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
            .opacity(0.94)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white, .white.opacity(0.2)], startPoint: .top, endPoint: .bottom),
                                   lineWidth: 1)
            }
            .overlay { shape.inset(by: -0.5).strokeBorder(.black.opacity(0.14), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.24), radius: 16, y: 7)
    }

    private var hairline: some View {
        let horizontal = scene.edge.horizontal
        let line = LinearGradient(colors: [.clear, .white.opacity(0.6), .white.opacity(0.6), .clear],
                                  startPoint: horizontal ? .leading : .top, endPoint: horizontal ? .trailing : .bottom)
        let base: Alignment = switch scene.edge {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
        return ZStack(alignment: base) {
            Color.clear
            Rectangle().fill(line)
                .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
                .shadow(color: theme.accent.opacity(0.6), radius: 4)
                .padding(horizontal ? .vertical : .horizontal, scene.pad * 0.55)
        }
    }

    private var retro: some View {
        let phosphor = theme.accent
        return shape
            .fill(Color(red: 0.02, green: 0.045, blue: 0.035).opacity(0.94))
            .overlay { shape.fill(ImagePaint(image: DockTextures.scanlines, scale: 1)).opacity(0.55) }
            .overlay { shape.strokeBorder(phosphor.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [3, 1.5])) }
            .background { shape.stroke(phosphor.opacity(0.45), lineWidth: 3).blur(radius: 6) }
            .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
    }

    private var paper: some View {
        shape
            .fill(Color(red: 0.965, green: 0.94, blue: 0.885))
            .overlay { shape.fill(ImagePaint(image: DockTextures.paper, scale: 1)).opacity(0.7) }
            .overlay { shape.strokeBorder(Color(red: 0.55, green: 0.48, blue: 0.38).opacity(0.25), lineWidth: 0.75) }
            .shadow(color: Color(red: 0.2, green: 0.14, blue: 0.08).opacity(0.3), radius: 6, x: 2, y: 4)
    }

    private var metal: some View {
        shape
            .fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.13), Color(white: 0.08)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay { shape.fill(ImagePaint(image: DockTextures.brushed, scale: 1)).opacity(0.5) }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.04), .black.opacity(0.5)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay { shape.inset(by: -0.75).strokeBorder(.black.opacity(0.6), lineWidth: 0.75) }
            .shadow(color: .black.opacity(0.5), radius: 14, y: 7)
    }
}

/// Floating Islands: one glass pill per run of tiles between separators.
private struct DockIslandsBackdrop: View {
    let scene: DockScene
    let theme: DockTheme
    let flat: Bool

    var body: some View {
        let horizontal = scene.edge.horizontal
        let bar = scene.bar
        let start = horizontal ? bar.minX : bar.minY, end = horizontal ? bar.maxX : bar.maxY
        let pieces = scene.tiles.map { (separator: $0.slot.kind == .divider || $0.slot.kind == .section, span: $0.span) }
        let spans = DockIslands.spans(pieces, start: start, end: end, inset: scene.pad)
        let radius = scene.radius
        // Drawn in the bar's own frame.
        ZStack(alignment: .topLeading) {
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                let length = max(span.upperBound - span.lowerBound, 1)
                let rect = horizontal
                    ? CGRect(x: span.lowerBound - bar.minX, y: 0, width: length, height: bar.height)
                    : CGRect(x: 0, y: span.lowerBound - bar.minY, width: bar.width, height: length)
                let shape = RoundedRectangle(cornerRadius: min(radius, min(rect.width, rect.height) / 2), style: .continuous)
                Group {
                    if flat {
                        shape.fill((theme.tint ?? .white).opacity(theme.tint == nil ? 0.16 : 0.4))
                    } else {
                        Color.clear.atelierGlass(theme.glass, in: shape)
                    }
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(colors: theme.rim, startPoint: .topLeading, endPoint: .bottomTrailing),
                                       lineWidth: theme.rimWidth)
                }
                .shadow(color: .black.opacity(theme.shadow * 0.85), radius: 12, y: 6)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: max(bar.width, 1), height: max(bar.height, 1), alignment: .topLeading)
    }
}

/// Values the designs share between the bar, its icons and its marks.
enum DockDesignStyle {
    static func radius(_ design: DockDesign, _ radius: Double) -> Double {
        switch design {
        case .retro: min(radius, 3)
        case .paper: min(radius, 9)
        case .darkMetal: min(radius, 14)
        default: radius
        }
    }

    /// Light designs want dark marks.
    static func ink(_ design: DockDesign) -> Color {
        design.light ? Color(red: 0.12, green: 0.11, blue: 0.1).opacity(0.82) : .white
    }
}

// MARK: - Textures

/// Small tiles drawn once and repeated by the GPU.
@MainActor
enum DockTextures {
    static let scanlines = Image(nsImage: make(CGSize(width: 4, height: 3)) { size in
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 0, width: size.width, height: 1).fill()
    })

    static let brushed = Image(nsImage: make(CGSize(width: 96, height: 24)) { size in
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for row in 0..<Int(size.height) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let light = Double(seed >> 40 & 0xFF) / 255
            NSColor(white: light > 0.5 ? 1 : 0, alpha: 0.05 + 0.07 * abs(light - 0.5)).setFill()
            NSRect(x: 0, y: Double(row), width: size.width, height: 1).fill()
        }
    })

    static let paper = Image(nsImage: make(CGSize(width: 64, height: 64)) { size in
        var seed: UInt64 = 0xD1B5_4A32_D192_ED03
        for _ in 0..<140 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = Double((seed >> 33) % 64), y = Double((seed >> 17) & 63)
            NSColor(red: 0.45, green: 0.36, blue: 0.24, alpha: 0.05 + Double(seed & 7) / 120).setFill()
            NSRect(x: x.truncatingRemainder(dividingBy: size.width), y: y, width: 1 + Double(seed & 1), height: 1).fill()
        }
    })

    private static func make(_ size: CGSize, _ draw: @escaping @Sendable (CGSize) -> Void) -> NSImage {
        NSImage(size: size, flipped: false) { _ in
            draw(size)
            return true
        }
    }
}

// MARK: - Animated layers

/// Core Animation layers for the designs that move by themselves. The render server plays
/// them; this view only sets geometry when the bar changes and pauses them when told.
struct DockDesignLayer: NSViewRepresentable {
    enum Kind { case neon, aurora, holo, breathe }
    let kind: Kind
    let size: CGSize
    let radius: Double
    let colors: [Color]
    let running: Bool
    var angle = 0.0

    func makeNSView(context: Context) -> DockDesignLayerView {
        let view = DockDesignLayerView(kind: kind)
        view.update(size: size, radius: radius, colors: colors.map { NSColor($0).cgColor }, angle: angle)
        view.setRunning(running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        return view
    }

    func updateNSView(_ view: DockDesignLayerView, context: Context) {
        view.update(size: size, radius: radius, colors: colors.map { NSColor($0).cgColor }, angle: angle)
        view.setRunning(running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

final class DockDesignLayerView: NSView {
    private let kind: DockDesignLayer.Kind
    private let wrapper = CALayer()
    private let content = CALayer()
    private let mask = CAShapeLayer()
    private var gradients: [CAGradientLayer] = []
    private var lastSize = CGSize.zero
    private var lastRadius = -1.0
    private var lastColors: [CGColor] = []
    private var lastAngle = Double.nan
    private var running = true

    init(kind: DockDesignLayer.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        wrapper.masksToBounds = false
        layer?.addSublayer(wrapper)
        wrapper.addSublayer(content)
        content.mask = mask
        mask.fillColor = kind == .aurora ? NSColor.black.cgColor : nil
        mask.strokeColor = kind == .aurora ? nil : NSColor.black.cgColor
        switch kind {
        case .neon:
            mask.lineWidth = 2
            let ring = CAGradientLayer()
            ring.type = .conic
            ring.startPoint = CGPoint(x: 0.5, y: 0.5)
            ring.endPoint = CGPoint(x: 0.5, y: 0)
            gradients = [ring]
            wrapper.shadowOpacity = 1
            wrapper.shadowRadius = 5
            wrapper.shadowOffset = .zero
        case .holo:
            mask.lineWidth = 1.6
            let ring = CAGradientLayer()
            ring.type = .conic
            ring.startPoint = CGPoint(x: 0.5, y: 0.5)
            ring.endPoint = CGPoint(x: 0.5, y: 0)
            ring.colors = [0.0, 0.16, 0.33, 0.5, 0.66, 0.83, 1.0].map {
                NSColor(hue: $0, saturation: 0.55, brightness: 1, alpha: 0.95).cgColor
            }
            gradients = [ring]
        case .aurora:
            gradients = (0..<3).map { _ in
                let blob = CAGradientLayer()
                blob.type = .radial
                blob.startPoint = CGPoint(x: 0.5, y: 0.5)
                blob.endPoint = CGPoint(x: 1, y: 1)
                return blob
            }
            content.opacity = 0.85
        case .breathe:
            mask.lineWidth = 1.5
            let rim = CAGradientLayer()
            gradients = [rim]
            wrapper.shadowOpacity = 0.9
            wrapper.shadowRadius = 6
            wrapper.shadowOffset = .zero
        }
        gradients.forEach(content.addSublayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(size: CGSize, radius: Double, colors: [CGColor], angle: Double) {
        let resized = abs(size.width - lastSize.width) > 0.25 || abs(size.height - lastSize.height) > 0.25 || radius != lastRadius
        let recoloured = colors.count != lastColors.count || zip(colors, lastColors).contains { $0 != $1 }
        guard resized || recoloured || angle != lastAngle else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: size)
        if resized {
            let bigJump = abs(size.width - lastSize.width) > lastSize.width * 0.2 || abs(size.height - lastSize.height) > lastSize.height * 0.2
            lastSize = size
            lastRadius = radius
            wrapper.frame = bounds
            content.frame = bounds
            mask.frame = bounds
            let inset = kind == .aurora ? 0 : mask.lineWidth / 2
            let r = max(min(radius - inset, min(size.width, size.height) / 2 - inset), 0)
            mask.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: r, cornerHeight: r, transform: nil)
            layout(bounds, restart: bigJump)
        }
        if recoloured {
            lastColors = colors
            paint(colors)
        }
        if kind == .holo, angle != lastAngle {
            lastAngle = angle
            gradients.first?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
        CATransaction.commit()
    }

    private func layout(_ bounds: CGRect, restart: Bool) {
        let side = hypot(bounds.width, bounds.height)
        switch kind {
        case .neon, .holo:
            gradients.first?.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradients.first?.position = CGPoint(x: bounds.midX, y: bounds.midY)
            if kind == .neon, restart || gradients.first?.animation(forKey: "spin") == nil { spin() }
        case .aurora:
            for (index, blob) in gradients.enumerated() {
                blob.bounds = CGRect(x: 0, y: 0, width: bounds.width * 0.75, height: bounds.height * 2.6)
                blob.position = CGPoint(x: bounds.width * (0.2 + 0.3 * Double(index)), y: bounds.midY)
            }
            if restart || gradients.first?.animation(forKey: "drift") == nil { drift(bounds) }
        case .breathe:
            gradients.first?.frame = bounds
            if gradients.first?.animation(forKey: "breathe") == nil { breathe() }
        }
    }

    private func paint(_ colors: [CGColor]) {
        let clear = NSColor.clear.cgColor
        switch kind {
        case .neon:
            let a = colors.first ?? NSColor.white.cgColor, b = colors.count > 1 ? colors[1] : a
            gradients.first?.colors = [clear, clear, a, NSColor.white.cgColor, clear, clear, clear, b, NSColor.white.cgColor, clear]
            wrapper.shadowColor = a
        case .aurora:
            for (index, blob) in gradients.enumerated() {
                let color = colors.isEmpty ? NSColor.white.cgColor : colors[index % colors.count]
                blob.colors = [color.copy(alpha: 0.6) ?? color, color.copy(alpha: 0) ?? clear]
            }
        case .breathe:
            let a = colors.first ?? NSColor.white.cgColor
            gradients.first?.colors = [a, a.copy(alpha: 0.5) ?? a, a]
            wrapper.shadowColor = a
        case .holo:
            break
        }
    }

    private func spin() {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 5.5
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        gradients.first?.add(spin, forKey: "spin")
    }

    private func drift(_ bounds: CGRect) {
        for (index, blob) in gradients.enumerated() {
            let drift = CABasicAnimation(keyPath: "transform.translation.x")
            let reach = bounds.width * (0.18 + 0.06 * Double(index))
            drift.fromValue = index % 2 == 0 ? -reach : reach
            drift.toValue = index % 2 == 0 ? reach : -reach
            drift.duration = 9 + 3.5 * Double(index)
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drift.isRemovedOnCompletion = false
            blob.add(drift, forKey: "drift")
            let swell = CABasicAnimation(keyPath: "transform.scale")
            swell.fromValue = 0.85
            swell.toValue = 1.2
            swell.duration = 6 + 2 * Double(index)
            swell.autoreverses = true
            swell.repeatCount = .infinity
            swell.isRemovedOnCompletion = false
            blob.add(swell, forKey: "swell")
        }
    }

    private func breathe() {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.04
        breathe.toValue = 0.5
        breathe.duration = 2.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.isRemovedOnCompletion = false
        wrapper.add(breathe, forKey: "breathe")
    }

    /// Pauses in place, so a resumed animation carries on from where it stopped.
    func setRunning(_ on: Bool) {
        guard on != running, let layer else { return }
        running = on
        if on {
            let paused = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = now
        }
    }
}

// MARK: - Marks

/// A design's own open-app mark.
struct DockDesignMarkView: View {
    let mark: DockDesignMark
    let design: DockDesign
    let accent: Color
    let icon: Double
    let horizontal: Bool
    let frontmost: Bool
    let strength: Double

    var body: some View {
        switch mark {
        case .led:
            Circle().fill(accent.opacity(strength))
                .frame(width: 4.5, height: 4.5)
                .overlay(Circle().fill(.white.opacity(0.7 * strength)).frame(width: 1.6, height: 1.6))
                .shadow(color: accent.opacity(frontmost ? 0.95 : 0.55), radius: frontmost ? 4 : 2.5)
        case .pixel:
            let long = frontmost ? 9.0 : 4.0
            Rectangle().fill(accent.opacity(strength))
                .frame(width: horizontal ? long : 4, height: horizontal ? 4 : long)
                .shadow(color: accent.opacity(0.6), radius: 2)
        case .ink:
            Circle().fill(DockDesignStyle.ink(design).opacity(strength))
                .frame(width: frontmost ? 5.5 : 4.5, height: frontmost ? 5.5 : 4.5)
        case .beam:
            let long = icon * (frontmost ? 0.7 : 0.42)
            Capsule().fill(LinearGradient(colors: [.clear, accent, .white, accent, .clear],
                                          startPoint: horizontal ? .leading : .top, endPoint: horizontal ? .trailing : .bottom))
                .frame(width: horizontal ? long : 2, height: horizontal ? 2 : long)
                .opacity(strength)
                .shadow(color: accent, radius: 4)
                .blendMode(.plusLighter)
        }
    }
}

// MARK: - Icon plates

/// The plate behind an icon, in the design's material.
struct DockBackplate: View {
    let design: DockDesign
    let accent: Color
    let size: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * (design == .retro ? 0.06 : 0.26), style: .continuous)
        Group {
            switch design {
            case .ceramic:
                shape.fill(LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            case .paper:
                shape.fill(Color(red: 0.99, green: 0.98, blue: 0.95))
                    .overlay(shape.strokeBorder(Color(red: 0.5, green: 0.42, blue: 0.3).opacity(0.22), lineWidth: 0.6))
            case .darkMetal:
                shape.fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
            case .retro:
                shape.fill(.black.opacity(0.75)).overlay(shape.strokeBorder(accent.opacity(0.7), lineWidth: 1))
            default:
                shape.fill(.white.opacity(0.12)).overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.6))
            }
        }
        .frame(width: size * 1.1, height: size * 1.1)
    }
}

// MARK: - Bursts

/// The effect a tile plays from its ring timer: a launch, a drop or the Trash taking something.
struct DockBurstView: View {
    let progress: Double
    let burst: DockBurst
    let fx: DockFX
    let color: Color
    let size: Double

    var body: some View {
        let style: DockLaunchEffect = switch burst {
        case .launch: fx.launch
        case .drop: fx.drop == .ripple ? .ripple : .none
        case .trash: .none
        }
        let fade = (1 - progress) * (1 - progress)
        switch style {
        case .ring:
            ring(progress, width: 3 * (1 - progress) + 0.5)
        case .ripple:
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    let local = progress * 1.5 - Double(index) * 0.25
                    if local > 0, local < 1 { ring(local, width: 2 * (1 - local) + 0.4) }
                }
            }
        case .sparkle:
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    let angle = Double(index) * .pi / 4 + progress * 0.6
                    let reach = size * (0.42 + 0.5 * progress) * (index % 2 == 0 ? 1 : 0.78)
                    Image(systemName: "sparkle")
                        .font(.system(size: size * (index % 2 == 0 ? 0.2 : 0.14), weight: .bold))
                        .foregroundStyle(index % 3 == 0 ? .white : color)
                        .scaleEffect(1 - 0.6 * progress)
                        .offset(x: cos(angle) * reach, y: sin(angle) * reach)
                }
            }
            .opacity(fade)
            .blendMode(.plusLighter)
        case .bloom:
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.9), color.opacity(0.35), .clear], center: .center,
                                     startRadius: 0, endRadius: size * 0.8))
                .frame(width: size * 1.6, height: size * 1.6)
                .scaleEffect(0.5 + 1.1 * progress)
                .opacity(fade)
                .blendMode(.plusLighter)
        case .none:
            EmptyView()
        }
    }

    private func ring(_ value: Double, width: Double) -> some View {
        Circle()
            .strokeBorder(color, lineWidth: width)
            .frame(width: size * (1 + 1.5 * value), height: size * (1 + 1.5 * value))
            .opacity((1 - value) * (1 - value))
            .blendMode(.plusLighter)
    }

    /// How the icon itself deforms while the burst plays: the Trash crumples or shakes, a
    /// swallowing tile gulps.
    static func deform(progress: Double?, burst: DockBurst, fx: DockFX) -> (x: Double, y: Double, angle: Double) {
        guard let p = progress else { return (1, 1, 0) }
        let hump = sin(.pi * p)
        switch burst {
        case .trash:
            switch fx.trash {
            case .crumple: return (1 - 0.16 * hump, 1 - 0.26 * hump, sin(p * 6 * .pi) * (1 - p) * 7)
            case .shake: return (1, 1, sin(p * 8 * .pi) * (1 - p) * 10)
            case .none: return (1, 1, 0)
            }
        case .drop:
            return fx.drop == .swallow ? (1 - 0.2 * hump, 1 - 0.2 * hump, 0) : (1, 1, 0)
        case .launch:
            return (1, 1, 0)
        }
    }
}

// MARK: - Sounds

/// Quiet sounds for dock events, opt-in. Only the sounds macOS ships in /System/Library/Sounds.
@MainActor
enum DockSounds {
    enum Event { case launch, drop, trash, minimize }

    private static var cache: [String: NSSound] = [:]

    static func name(_ event: Event) -> String {
        switch event {
        case .launch: "Pop"
        case .drop: "Tink"
        case .trash: "Bottle"
        case .minimize: "Purr"
        }
    }

    static func play(_ event: Event, prefs: DockDesignPrefs) {
        guard prefs.sounds else { return }
        // A sound pack in use plays its own, at the same volume.
        let slot: SoundSlot = switch event {
        case .launch: .dockLaunch
        case .drop: .dockDrop
        case .trash: .dockTrash
        case .minimize: .dockMinimize
        }
        if SoundPackRuntime.play(slot, volume: Float(prefs.volume)) { return }
        let name = name(event)
        let sound = cache[name] ?? NSSound(named: NSSound.Name(name))?.copy() as? NSSound
        guard let sound else { return }
        cache[name] = sound
        sound.volume = Float(prefs.volume)
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

// MARK: - Direction

extension OwnDockEdge {
    /// One point away from the screen edge, into the screen.
    var outward: CGSize {
        switch self {
        case .bottom: CGSize(width: 0, height: -1)
        case .top: CGSize(width: 0, height: 1)
        case .left: CGSize(width: 1, height: 0)
        case .right: CGSize(width: -1, height: 0)
        }
    }
}
