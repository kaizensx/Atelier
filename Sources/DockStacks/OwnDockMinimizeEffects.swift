import AppKit
import DockCore
import Metal
import MetalKit
import QuartzCore
import SwiftUI

// MARK: - Drawing the minimise effects
//
// DockCore's MinimizeEffects gives a mesh for an effect at a progress; this file draws it: the
// window picture as a texture, warped by the mesh, on a transparent CAMetalLayer, one frame per
// display refresh (120 Hz on ProMotion). Nothing runs when nothing animates: the display link
// exists only while an effect plays, and the overlay is ordered out after.

/// The Metal pieces, made once. The shader is compiled from source on first use.
@MainActor
final class MinimizeRenderer {
    static let shared = MinimizeRenderer()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let loader: MTKTextureLoader

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "minimizeVertex"),
              let fragment = library.makeFunction(name: "minimizeFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        // Premultiplied alpha.
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        loader = MTKTextureLoader(device: device)
    }

    func texture(_ image: CGImage) -> MTLTexture? {
        // Mipmaps keep a window shrunk into a 50-point tile smooth instead of sparkling.
        try? loader.newTexture(cgImage: image, options: [.SRGB: false, .generateMipmaps: true,
                                                         .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                                                         .textureStorageMode: MTLStorageMode.private.rawValue])
    }

    /// Draws one mesh into the layer, clearing it first. `size` is the layer's size in points.
    func draw(_ mesh: MinimizeMesh, texture: MTLTexture, into layer: CAMetalLayer, size: CGSize) {
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !mesh.indices.isEmpty,
           let vertices = mesh.vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
           let indices = mesh.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) {
            var extent = SIMD2<Float>(Float(size.width), Float(size.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            encoder.setVertexBytes(&extent, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indices.count, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: 0)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// MinimizeVertex is six packed floats: position, picture coordinate, alpha, shade.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct MinimizeVertexIn { packed_float2 position; packed_float2 uv; float alpha; float shade; };
    struct MinimizeVertexOut { float4 position [[position]]; float2 uv; float alpha; float shade; };
    vertex MinimizeVertexOut minimizeVertex(uint id [[vertex_id]], const device MinimizeVertexIn *vertices [[buffer(0)]],
                                            constant float2 &size [[buffer(1)]]) {
        MinimizeVertexIn v = vertices[id];
        MinimizeVertexOut out;
        out.position = float4(float2(v.position) / size * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(v.uv);
        out.alpha = v.alpha;
        out.shade = v.shade;
        return out;
    }
    fragment float4 minimizeFragment(MinimizeVertexOut in [[stage_in]], texture2d<float> picture [[texture(0)]],
                                     sampler smooth [[sampler(0)]]) {
        float4 c = picture.sample(smooth, in.uv);
        c.rgb = min(c.rgb * in.shade, float3(c.a));
        return c * in.alpha;
    }
    """
}

/// A transparent layer-backed view that plays one effect with a display link.
@MainActor
final class MinimizeEffectView: NSView {
    private let metal = CAMetalLayer()
    private var texture: MTLTexture?
    private var link: CADisplayLink?
    private var started = 0.0
    private var duration = 0.5
    private var restoring = false
    private var finished: CheckedContinuation<Void, Never>?
    var effect = MinimizeEffect.genie
    var geometry = MinimizeGeometry(window: .zero, tile: .zero, edge: .bottom)
    /// Where the tile is this frame, in this view's coordinates, when it can move while the
    /// effect plays (the dock making room, magnifying). Nil keeps the tile it was given.
    var track: (() -> CGRect?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = metal
        wantsLayer = true
        metal.device = MinimizeRenderer.shared?.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = true
        metal.backgroundColor = .clear
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.needsDisplayOnBoundsChange = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    func set(image: CGImage) { texture = MinimizeRenderer.shared?.texture(image) }

    var ready: Bool { texture != nil && MinimizeRenderer.shared != nil }

    override func layout() {
        super.layout()
        resize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resize()
    }

    private func resize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.frame = bounds
        metal.drawableSize = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
    }

    /// Draws one still frame at a progress (0 the window, 1 in the tile).
    func draw(progress: Double) {
        guard let renderer = MinimizeRenderer.shared, let texture else { return }
        resize()
        if let track { geometry.tile = MinimizeHandoff.aim(live: track(), last: geometry.tile) }
        renderer.draw(MinimizeEffects.mesh(effect, progress: progress, geometry: geometry), texture: texture,
                      into: metal, size: bounds.size)
    }

    func clear() {
        guard let renderer = MinimizeRenderer.shared, let texture else { return }
        renderer.draw(MinimizeMesh(), texture: texture, into: metal, size: bounds.size)
    }

    /// Plays in (0 → 1) or back out (1 → 0), one mesh per display refresh.
    func play(restoring: Bool, duration: Double) async {
        stop()
        self.restoring = restoring
        self.duration = duration
        started = CACurrentMediaTime()
        draw(progress: restoring ? 1 : 0)
        await withCheckedContinuation { continuation in
            finished = continuation
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - started
        let progress = MinimizeTiming.progress(elapsed: elapsed, duration: duration, restoring: restoring)
        draw(progress: progress)
        if elapsed >= duration { stop() }
    }

    func stop() {
        link?.invalidate()
        link = nil
        finished?.resume()
        finished = nil
    }
}

/// The effect over everything, in a click-through panel the size of the screens it crosses.
@MainActor
final class MinimizeOverlay {
    private let panel: NSPanel
    private let view: MinimizeEffectView
    let effect: MinimizeEffect

    /// `window` and `tile` in Cocoa screen coordinates; `track` gives the tile's rect again each
    /// frame, in the same coordinates. Nil without Metal.
    init?(image: CGImage, window: CGRect, tile: CGRect, effect: MinimizeEffect, edge: MinimizeEdge,
          track: (() -> CGRect?)? = nil) {
        let screens = NSScreen.screens.filter { $0.frame.intersects(window) || $0.frame.intersects(tile) }
        let area = (screens.isEmpty ? NSScreen.screens.prefix(1).map(\.frame) : screens.map(\.frame))
            .reduce(CGRect.null) { $0.union($1) }
        guard !area.isNull, MinimizeRenderer.shared != nil else { return nil }
        self.effect = effect
        panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        view = MinimizeEffectView(frame: NSRect(origin: .zero, size: area.size))
        panel.contentView = view
        panel.setFrame(area, display: false)
        view.effect = effect
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -area.minX, dy: -area.minY) }
        view.geometry = MinimizeGeometry(window: local(window), tile: local(tile), edge: edge)
        if let track { view.track = { track().map(local) } }
        view.set(image: image)
        guard view.ready else { return nil }
    }

    /// On screen, still, at a progress: 0 covers the window exactly, 1 is inside the tile.
    func show(progress: Double) {
        view.draw(progress: progress)
        panel.orderFrontRegardless()
    }

    func play(restoring: Bool, slow: Bool) async {
        if !panel.isVisible { show(progress: restoring ? 1 : 0) }
        await view.play(restoring: restoring, duration: MinimizeTiming.duration(effect, restoring: restoring, slow: slow))
    }

    func close(after delay: Double = 0) {
        let panel = panel, view = view
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            view.stop()
            panel.orderOut(nil)
            panel.close()
        }
    }
}

// MARK: - The effect the owner picked

enum MinimizeEffectSetting {
    static let key = "ownDock.minimizeEffect"

    static var chosen: MinimizeEffect {
        get { UserDefaults.standard.string(forKey: key).flatMap(MinimizeEffect.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// macOS's own setting: genie (the default), scale or suck. While the Atelier Dock replaces
    /// the macOS one, the Dock holds the Scale Atelier wrote, and the owner's is in the backup.
    static var systemEffect: String? {
        let current = CFPreferencesCopyAppValue("mineffect" as CFString, "com.apple.dock" as CFString) as? String
        let backup = DefaultsBackupStore().load()
        var saved: String?
        if case .string(let value) = backup?.original("mineffect") { saved = value }
        return MinimizeHandoff.followedEffect(current: current, replaced: backup != nil, saved: saved)
    }

    /// The effect drawn now: the pick, macOS's when following it, Scale with Reduce Motion.
    static var current: MinimizeEffect {
        chosen.resolved(systemEffect: systemEffect).reduced(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

// MARK: - The picker's live plate

/// A small stage: a mock window minimises into a tile of a mock dock and comes back, drawn by
/// the same renderer as the real thing. It runs only while it is on screen.
struct MinimizeEffectPlate: NSViewRepresentable {
    var effect: MinimizeEffect
    var accent: Color

    func makeNSView(context: Context) -> MinimizePlateView {
        let view = MinimizePlateView(frame: .zero)
        view.effect = effect
        return view
    }

    func updateNSView(_ view: MinimizePlateView, context: Context) {
        if view.effect != effect {
            view.effect = effect
            view.restart()
        }
    }
}

@MainActor
final class MinimizePlateView: NSView {
    var effect = MinimizeEffect.genie
    private var stage: MinimizeEffectView?
    private var loop: Task<Void, Never>?
    private let dock = CALayer()
    private let tile = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dock.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        dock.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        dock.borderWidth = 0.5
        dock.cornerRadius = 12
        tile.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        tile.cornerRadius = 7
        layer?.addSublayer(dock)
        layer?.addSublayer(tile)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var geometry: MinimizeGeometry {
        let b = bounds
        let bar = CGRect(x: b.midX - min(b.width * 0.36, 160), y: 8, width: min(b.width * 0.72, 320), height: 34)
        let tileRect = CGRect(x: bar.maxX - 34, y: bar.minY + 4, width: 26, height: 26)
        let window = CGRect(x: b.midX - b.width * 0.26, y: bar.maxY + 14, width: b.width * 0.42, height: max(b.height - bar.maxY - 26, 20))
        return MinimizeGeometry(window: window, tile: tileRect, edge: .bottom)
    }

    override func layout() {
        super.layout()
        let g = geometry
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dock.frame = CGRect(x: bounds.midX - min(bounds.width * 0.36, 160), y: 8, width: min(bounds.width * 0.72, 320), height: 34)
        tile.frame = g.tile
        CATransaction.commit()
        stage?.frame = bounds
        stage?.geometry = g
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? halt() : restart()
    }

    func restart() {
        halt()
        guard window != nil else { return }
        if stage == nil {
            let view = MinimizeEffectView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            stage = view
        }
        guard let stage else { return }
        let resolved = effect.resolved(systemEffect: MinimizeEffectSetting.systemEffect)
        stage.effect = resolved
        loop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, let stage = self.stage else { return }
            stage.frame = self.bounds
            stage.geometry = self.geometry
            stage.set(image: Self.picture(size: stage.geometry.window.size, scale: self.window?.backingScaleFactor ?? 2))
            while !Task.isCancelled {
                // Scrolled away or behind another window: wait without drawing.
                if self.window?.occlusionState.contains(.visible) != true {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                stage.draw(progress: 0)
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled { break }
                await stage.play(restoring: false, duration: MinimizeTiming.duration(resolved, restoring: false, slow: false) * 1.6)
                try? await Task.sleep(for: .milliseconds(650))
                if Task.isCancelled { break }
                await stage.play(restoring: true, duration: MinimizeTiming.duration(resolved, restoring: true, slow: false) * 1.6)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func halt() {
        loop?.cancel()
        loop = nil
        stage?.stop()
    }

    /// A mock window: title bar with its three buttons, a sidebar and some lines of content.
    static func picture(size: CGSize, scale: CGFloat) -> CGImage {
        let w = max(Int(size.width * scale), 8), h = max(Int(size.height * scale), 8)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let s = Double(scale)
        let radius = 9 * s
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: full, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)); ctx.fill(full)
        let bar = 22 * s
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: Double(h) - bar, width: Double(w), height: bar))
        let colors = [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                      CGColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: (8 + Double(i) * 14) * s, y: Double(h) - bar + 6 * s, width: 9 * s, height: 9 * s))
        }
        ctx.setFillColor(CGColor(red: 0.92, green: 0.93, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Double(w) * 0.28, height: Double(h) - bar))
        for row in 0..<14 {
            let y = Double(h) - bar - (14 + Double(row) * 11) * s
            guard y > 4 * s else { break }
            ctx.setFillColor(CGColor(red: 0.25, green: 0.45 + Double(row % 3) * 0.12, blue: 0.95, alpha: row == 0 ? 0.85 : 0.35))
            let width = (Double(w) * 0.62) * (0.45 + 0.5 * abs(sin(Double(row) * 1.7)))
            ctx.fill(CGRect(x: Double(w) * 0.33, y: y, width: width, height: 5 * s))
            ctx.setFillColor(CGColor(gray: 0.6, alpha: 0.35))
            ctx.fill(CGRect(x: 8 * s, y: y, width: Double(w) * 0.18, height: 4 * s))
        }
        return ctx.makeImage()!
    }
}

// MARK: - The picker

/// The window's own minimise effect, drawn by Atelier while this Dock replaces the macOS one,
/// with a live plate of the pick.
struct MinimizeEffectPicker: View {
    @AppStorage(MinimizeEffectSetting.key) private var raw = MinimizeEffect.system.rawValue
    @ObservedObject private var dock = OwnDock.shared

    private var effect: MinimizeEffect { MinimizeEffect(rawValue: raw) ?? .system }

    private var detail: String {
        if effect == .system {
            let macOS = MinimizeEffect.system.resolved(systemEffect: MinimizeEffectSetting.systemEffect)
            return "Now \(macOS.title), as set in Desktop & Dock."
        }
        return effect.detail
    }

    var body: some View {
        DockHubWideRow("Window Minimise Effect", detail: detail) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Segments(selection: Binding(get: { effect }, set: { raw = $0.rawValue }),
                         options: MinimizeEffect.allCases.map { ($0, $0.title) })
                MinimizeEffectPlate(effect: effect, accent: DockHubHue.tint)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.28)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Preview of \(effect.title)")
                if !dock.replacesSystemDock {
                    Text("Played while this Dock replaces the macOS one. Beside it, macOS draws its own.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
            }
        }
    }
}
