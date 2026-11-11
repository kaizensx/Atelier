import AppKit
import DockCore
import simd
import Metal
import QuartzCore
import SwiftUI

/// The Studio's own room: the stage lights it. A soft bloom in the wallpaper's colours spills
/// from behind the stage and rims its edges, slow beams sweep through haze, and dust drifts at
/// three depths. The light glides after the camera, and the pointer is a gentle spotlight. One
/// fragment pass at reduced resolution, driven by the screen's display link at the display's own
/// rate (60 Hz on most Macs, up to 120 on ProMotion). Intel and AMD GPUs get a lighter tier.
@MainActor
final class StudioLightView: NSView {
    struct Uniforms {
        var size: SIMD2<Float>
        var time: Float
        var glow: Float
        var pointer: SIMD2<Float>
        var presence: Float
        var motion: Float
        var stage: SIMD4<Float>
        var colorA: SIMD4<Float>
        var colorB: SIMD4<Float>
        var colorC: SIMD4<Float>
    }

    /// The integrated GPU when there is a choice. On a dual-GPU Intel MacBook Pro the system default
    /// is the discrete Radeon, and creating it switches the whole Mac onto that GPU for as long as
    /// the Studio is open, at a real cost in battery and heat, for a soft decorative glow.
    private static let device: MTLDevice? = {
        let all = MTLCopyAllDevices()
        if all.count > 1, let integrated = all.first(where: { $0.isLowPower && !$0.isRemovable && !$0.isHeadless }) {
            return integrated
        }
        return MTLCreateSystemDefaultDevice()
    }()
    /// Apple GPUs (Apple silicon) carry the full room; Intel and AMD draw less of it.
    private static let appleGPU: Bool = device?.supportsFamily(.apple7) ?? false
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = try? device.makeLibrary(source: StudioLightView.shader, options: nil),
              let vertex = library.makeFunction(name: "studio_vertex"),
              let fragment = library.makeFunction(name: "studio_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()
    private static let queue = device?.makeCommandQueue()

    static var available: Bool { pipeline != nil }

    private let metal = CAMetalLayer()
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private var pointer = SIMD2<Float>(0.5, 0.45)
    private var pointerTarget = SIMD2<Float>(0.5, 0.45)
    private var presence: Float = 0
    private var presenceTarget: Float = 0
    private var tracking: NSTrackingArea?

    var palette: [SIMD4<Float>] = StudioLightView.defaultPalette
    var glow: Float = 0.5
    /// Where the stage is now, as drawn, and where the camera is taking it.
    private var stage = SIMD4<Float>(0.5, 0.48, 0.62, 0.52)
    private var stageSet = false
    var stageTarget = SIMD4<Float>(0.5, 0.48, 0.62, 0.52) {
        didSet { if !stageSet { stage = stageTarget; stageSet = true } }
    }
    private var tier = ShellLightTier(resolution: 0.5, maxFPS: 120)
    private var lastStep: CFTimeInterval?
    private var lastDraw: CFTimeInterval = 0
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    static let defaultPalette: [SIMD4<Float>] = [
        SIMD4(0.20, 0.32, 0.62, 1), SIMD4(0.62, 0.36, 0.55, 1), SIMD4(0.95, 0.62, 0.38, 1),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metal
        metal.device = Self.device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = true
        metal.contentsGravity = .resize
        metal.magnificationFilter = .linear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        chooseTier()
        let link = displayLink(target: self, selector: #selector(step(_:)))
        let rate = Float(tier.maxFPS)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        resize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resize()
    }

    /// Picked per window and screen: the window can move to a 60 Hz display, and Low Power Mode
    /// can come on, between two openings of the Studio.
    private func chooseTier() {
        let rate = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        tier = ShellLightTier.choose(appleGPU: Self.appleGPU, lowPowerDevice: Self.device?.isLowPower ?? false,
                                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, refreshRate: rate)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseEntered(with event: NSEvent) { presenceTarget = 1; follow(event) }
    override func mouseExited(with event: NSEvent) { presenceTarget = 0 }
    // The room is decoration: clicks fall through to whatever SwiftUI put on top.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func follow(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }
        pointerTarget = SIMD2(Float(point.x / bounds.width), Float(1 - point.y / bounds.height))
        presenceTarget = 1
    }

    /// Half resolution on Apple GPUs, less on Intel and AMD: everything here is soft, and a quarter
    /// of the pixels keeps a full window frame well under a millisecond of GPU. On a non-Retina
    /// display the backing scale is 1, so the same fraction keeps the cost in proportion.
    private func resize() {
        let scale = (window?.backingScaleFactor ?? 2) * tier.resolution
        metal.contentsScale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        if metal.drawableSize != size { metal.drawableSize = size }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window, window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { lastStep = nil; return }
        // Easing by elapsed time, not by frame: the light moves the same at 60 and 120 Hz.
        let dt = Float(min(max(link.timestamp - (lastStep ?? link.timestamp - 1.0 / 120), 0), 0.1))
        lastStep = link.timestamp
        func approach(_ rate: Float) -> Float { 1 - exp(-rate * dt) }
        pointer += (pointerTarget - pointer) * approach(9.6)
        presence += (presenceTarget - presence) * approach(6)
        // The camera's spring settles in about 0.85 s; the light follows a touch behind it, like a lamp on a boom.
        stage += (stageTarget - stage) * approach(reduceMotion ? 60 : 7)
        // At rest only the dust twinkles, and 30 frames a second carries that. Drawing every
        // frame cost the main thread up to a fifth of each frame while the panel scrolled:
        // nextDrawable() waits whenever the GPU is busy with the rest of the window.
        let moving = simd_length(pointerTarget - pointer) > 0.002 || abs(presenceTarget - presence) > 0.01
            || simd_length(stageTarget - stage) > 0.002
        // While the stage camera flies the window is already at its busiest: the light follows
        // at 30 frames a second, which its soft glow hides, and returns to full rate on landing.
        let flying = ManagerModel.current?.cameraMoving == true
        let minimumGap = 1.0 / Double(tier.maxFPS) - 0.002
        guard link.timestamp - lastDraw >= minimumGap else { return }
        guard (moving && !flying) || link.timestamp - lastDraw >= 1.0 / 30 - 0.002 else { return }
        lastDraw = link.timestamp
        draw(time: Float(link.timestamp - start))
    }

    private func draw(time: Float) {
        guard let pipeline = Self.pipeline, let queue = Self.queue, let drawable = metal.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let colors = palette.count >= 3 ? palette : Self.defaultPalette
        var uniforms = Uniforms(
            size: SIMD2(Float(metal.drawableSize.width), Float(metal.drawableSize.height)),
            time: reduceMotion ? 12 : time, glow: glow, pointer: pointer, presence: presence,
            motion: reduceMotion ? 0 : 1, stage: stage,
            colorA: colors[0], colorB: colors[1], colorC: colors[2])
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Compiled at run time so the room does not depend on the wallpaper library.
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 size; float time; float glow;
        float2 pointer; float presence; float motion;
        float4 stage;
        float4 colorA; float4 colorB; float4 colorC;
    };

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut studio_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        VOut o; o.position = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
    }

    static float hash21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    static float noise(float2 p) {
        float2 i = floor(p), f = fract(p); float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x), mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
    }
    static float fbm(float2 p) { float v = 0, a = 0.5; for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + 11.7; a *= 0.5; } return v; }

    // Dust: one layer of soft motes on a jittered grid.
    static float dust(float2 uv, float scale, float t, float2 drift, float aspect) {
        float2 p = float2(uv.x * aspect, uv.y) * scale + drift * t;
        float2 cell = floor(p), f = fract(p) - 0.5;
        float h = hash21(cell);
        if (h < 0.72) return 0.0;
        float2 offset = float2(hash21(cell + 3.1), hash21(cell + 7.7)) - 0.5;
        float d = length(f - offset * 0.7);
        float twinkle = 0.55 + 0.45 * sin(t * (0.6 + h * 1.4) + h * 40.0);
        return smoothstep(0.08, 0.0, d) * twinkle * (h - 0.72) * 3.5;
    }

    fragment float4 studio_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.size.x / max(u.size.y, 1.0);
        float t = u.time * u.motion;
        float2 parallax = (u.pointer - 0.5) * u.presence;

        float3 base = float3(0.018, 0.02, 0.03);
        float3 a = u.colorA.rgb, b = u.colorB.rgb, c = u.colorC.rgb;

        // The stage as a light: a wide bloom behind it, warmer near its lower edge.
        float2 sc = u.stage.xy; float2 ss = u.stage.zw;
        float2 q = (uv - sc) / (ss * float2(1.0, 1.0));
        float r = length(q * float2(0.9, 1.25));
        float bloom = exp(-r * r * 0.42) * (0.75 + 0.75 * u.glow);
        float sweep = fbm(float2(uv.x * 2.2 + t * 0.03, uv.y * 1.4 - t * 0.02));
        // Sky colour above, the middle band across, the ground's warmth pooling low.
        float3 light = mix(a, b, smoothstep(0.1, 0.9, uv.x + 0.25 * sin(t * 0.07) + (sweep - 0.5) * 0.6) * 0.55);
        light = mix(light, c, smoothstep(0.45, 1.0, uv.y + (sweep - 0.5) * 0.25) * 0.85);
        float3 col = base + light * bloom * 0.95;

        // Beams: slow diagonal shafts through haze.
        float beam = 0.0;
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float angle = 0.35 + fi * 0.22 + 0.05 * sin(t * 0.05 + fi);
            float2 dir = float2(cos(angle), sin(angle));
            float x = dot(uv - float2(0.15 + 0.3 * fi + parallax.x * 0.05, -0.1), float2(-dir.y, dir.x));
            float shaft = exp(-pow(x * (9.0 + fi * 3.0), 2.0)) * (0.5 + 0.5 * sin(t * 0.11 + fi * 2.1));
            beam += shaft * smoothstep(1.1, 0.0, uv.y) * (0.6 - fi * 0.15);
        }
        float haze = fbm(uv * float2(3.0, 2.0) + float2(t * 0.02, -t * 0.015));
        // Aurora ribbons drifting across the top of the room.
        float ribbons = 0.0;
        for (int i = 0; i < 2; i++) {
            float fi = float(i);
            float y0 = 0.14 + 0.11 * fi + 0.05 * sin(uv.x * 2.6 + t * 0.09 + fi * 2.0) + 0.05 * (fbm(float2(uv.x * 3.0 + t * 0.04, fi)) - 0.5);
            float band = exp(-pow((uv.y - y0) * (16.0 - fi * 4.0), 2.0));
            float curtain = 0.45 + 0.55 * sin(uv.x * 9.0 - t * 0.25 + fi * 1.7 + fbm(uv * 4.0 + t * 0.05) * 3.0);
            ribbons += band * curtain * (1.0 - fi * 0.35);
        }
        col += mix(a, b, 0.6 + 0.4 * sin(uv.x * 2.0 + t * 0.05)) * ribbons * (0.18 + 0.22 * u.glow);
        col += mix(a, c, 0.5) * beam * (0.22 + 0.25 * u.glow) * (0.6 + haze);

        // Rim: light spilling past the stage's edges, strongest just outside them. No floor, no mirror.
        float2 rp = (uv - sc) * float2(aspect, 1.0);
        float2 rh = ss * 0.5 * float2(aspect, 1.0);
        float2 rd = abs(rp) - rh;
        float edge = length(max(rd, 0.0)) + min(max(rd.x, rd.y), 0.0);
        float rim = exp(-edge * edge * 260.0) * step(0.0, edge);
        col += light * rim * (0.16 + 0.22 * u.glow);

        // Pointer spotlight.
        float2 pd = (uv - u.pointer) * float2(aspect, 1.0);
        col += mix(b, float3(1.0), 0.35) * exp(-dot(pd, pd) * 7.0) * 0.12 * u.presence;

        // Dust at three depths, nearer layers move more with the pointer.
        // One sparse layer of large, soft motes: three dense layers read as dirt on the screen.
        float motes = dust(uv + parallax * 0.040, 6.0, t, float2(0.008, -0.012), aspect) * 0.45;
        col += mix(float3(1.0), light, 0.5) * motes * (0.45 + bloom * 1.2);

        // Vignette and grain.
        float2 v = uv - 0.5; col *= 1.0 - dot(v, v) * 0.8;
        col = col / (1.0 + col * 0.35);
        col += (hash21(uv * u.size + fract(t) * 91.0) - 0.5) * 0.012;
        return float4(max(col, 0.0), 1.0);
    }
    """
}

/// SwiftUI host for the room.
struct StudioLight: NSViewRepresentable {
    let palette: [SIMD4<Float>]
    let glow: Double
    /// The stage's centre and size in window fractions, so the light comes from it.
    let stage: CGRect

    func makeNSView(context: Context) -> StudioLightView { StudioLightView(frame: .zero) }

    func updateNSView(_ view: StudioLightView, context: Context) {
        view.palette = palette
        view.glow = Float(glow)
        view.stageTarget = SIMD4(Float(stage.midX), Float(stage.midY), Float(stage.width), Float(stage.height))
    }
}

/// The wallpaper's three strongest colours, found once per wallpaper.
@MainActor
enum StudioPalette {
    private static var cache: (path: String, colors: [SIMD4<Float>])?

    static func current() -> [SIMD4<Float>] {
        guard let url = Wallpaper.current().first else { return StudioLightView.defaultPalette }
        if let cache, cache.path == url.path { return cache.colors }
        guard let image = Wallpaper.image(), let colors = sample(image) else { return StudioLightView.defaultPalette }
        cache = (url.path, colors)
        return colors
    }

    /// Average colour of three horizontal bands, pushed brighter and more saturated so they
    /// read as light, not paint.
    private static func sample(_ image: NSImage) -> [SIMD4<Float>]? {
        let width = 48, height = 30
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var bands: [SIMD4<Float>] = []
        for band in 0..<3 {
            var sum = SIMD3<Float>(repeating: 0)
            var count: Float = 0
            for y in (band * height / 3)..<((band + 1) * height / 3) {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let c = SIMD3<Float>(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255
                    // Weight vivid pixels more, so a sky or a sunset wins over grey ground.
                    let weight = (c.max() - c.min()) + 0.05
                    sum += c * weight
                    count += weight
                }
            }
            var color = sum / max(count, 0.0001)
            let peak = max(color.max(), 0.001)
            color = color / peak * min(peak * 1.6 + 0.15, 1)
            let grey = (color.x + color.y + color.z) / 3
            color = grey + (color - grey) * 1.35
            bands.append(SIMD4(color.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)), 1))
        }
        // Image rows run top to bottom here: sky, middle, ground.
        return bands
    }
}
