import AppKit
import IOKit.ps
import Metal
import MetalKit
import QuartzCore
import SwiftUI

enum LivingShader: String, CaseIterable, Identifiable, Codable {
    case liquidLight, nebula, auroraSilk, topography, glassRain, silkWaves, gradientMesh, starfield, retroHorizon
    case oceanCaustics, northernLights, lavaLamp, inkInWater, fireflies, liquidChrome
    case wallpaperRain, wallpaperRipple, wallpaperDepth
    var id: String { rawValue }

    /// These paint with the owner's own wallpaper image, bound as a texture.
    var usesWallpaper: Bool {
        switch self {
        case .wallpaperRain, .wallpaperRipple, .wallpaperDepth: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .liquidLight: "Liquid Light"
        case .nebula: "Nebula"
        case .auroraSilk: "Aurora Silk"
        case .topography: "Topography"
        case .glassRain: "Glass Rain"
        case .silkWaves: "Silk Waves"
        case .gradientMesh: "Gradient Mesh"
        case .starfield: "Starfield"
        case .retroHorizon: "Retro Horizon"
        case .oceanCaustics: "Ocean Caustics"
        case .northernLights: "Northern Lights"
        case .lavaLamp: "Lava Lamp"
        case .inkInWater: "Ink in Water"
        case .fireflies: "Fireflies"
        case .liquidChrome: "Liquid Chrome"
        case .wallpaperRain: "Rain on Your Wallpaper"
        case .wallpaperRipple: "Pond Ripples"
        case .wallpaperDepth: "Living Photo"
        }
    }

    var blurb: String {
        switch self {
        case .liquidLight: "Thin film colour on a slow liquid. It leans toward your pointer and catches its light."
        case .nebula: "Gas and dust in deep field. Layers shift with depth, and your pointer lights what it nears."
        case .auroraSilk: "Curtains of light over a dark ridge. The fabric reaches for your pointer."
        case .topography: "A living survey map. A hill rises under your pointer, and contours gather around it."
        case .glassRain: "Rain on a window at the hour outside. Your pointer wipes the pane clear."
        case .silkWaves: "Draped satin in a slow breeze. The cloth gathers toward your pointer and turns in the light."
        case .gradientMesh: "Soft fields of colour that fold into each other. Your pointer parts them like a fingertip in paint."
        case .starfield: "A deep sky drifting toward you, layer behind layer. Near stars shift further as your pointer moves."
        case .retroHorizon: "A neon grid rolls toward a striped sun. The lines glow brighter where your pointer rests."
        case .oceanCaustics: "Sunlight focused by moving water onto sand. Your pointer sends rings across the surface."
        case .northernLights: "Curtains of aurora over a still lake, mirrored in it. The view leans with your pointer."
        case .lavaLamp: "Warm wax rising and falling in glass. A bubble of it follows your pointer."
        case .inkInWater: "Ink blooming through clear water by day, glowing inks by night. Your pointer parts the water."
        case .fireflies: "A meadow at dusk, lit by drifting fireflies. They gather toward your pointer."
        case .liquidChrome: "A pool of mercury in a photo studio. Your pointer presses into it and rings run out."
        case .wallpaperRain: "Your own wallpaper behind a rainy window. Drops refract it; your pointer wipes the glass."
        case .wallpaperRipple: "Your own wallpaper under a still pond. Drops land now and then; your pointer stirs it."
        case .wallpaperDepth: "Your own wallpaper with depth: it breathes, leans with your pointer, and dust drifts in the light."
        }
    }

    var fragment: String { "\(rawValue)Fragment" }

    /// Fine detail needs more pixels; soft fields look the same at half and cost a quarter.
    var renderScale: CGFloat {
        switch self {
        case .topography, .wallpaperRain: 0.75
        case .glassRain, .starfield, .retroHorizon: 0.6
        // Soft light: four tenths look the same as half.
        case .northernLights: 0.4
        // Your picture must stay as sharp as the desktop shows it.
        case .wallpaperRipple, .wallpaperDepth: 1
        default: 0.5
        }
    }
}

/// Mirrors `Uniforms` in Living.metal. Keep the order and the padding: 128 bytes, the palette at 64.
struct LivingUniforms {
    var resolution = SIMD2<Float>(1, 1)
    var pointer = SIMD2<Float>(0.5, 0.5)
    var time: Float = 0
    var day: Float = 0
    var daylight: Float = 0
    var golden: Float = 0
    var presence: Float = 0
    var opacity: Float = 1
    var seed: Float = 0
    var contrast: Float = 0.5
    var grain: Float = 0
    var scale: Float = 1
    var dim: Float = 0
    var paletteMix: Float = 0
    var palette0 = SIMD4<Float>.zero
    var palette1 = SIMD4<Float>.zero
    var palette2 = SIMD4<Float>.zero
    var palette3 = SIMD4<Float>.zero
}

/// How a wallpaper follows the hour.
enum DayCycle: String, Codable, CaseIterable {
    case clock, day, dusk, night

    var title: String {
        switch self {
        case .clock: "Clock"
        case .day: "Day"
        case .dusk: "Dusk"
        case .night: "Night"
        }
    }

    /// The hour a held look shows. Nil follows the real one.
    var heldHour: Double? {
        switch self {
        case .clock: nil
        case .day: 13
        case .dusk: 19.2
        case .night: 23
        }
    }
}

/// The owner's settings for one shader. Defaults are the shader exactly as designed.
struct LivingTuning: Codable, Equatable {
    var palette = LivingPalette.natural
    var speed = 1.0        // 0.2 ... 2.5, scales the shader's own clock
    var intensity = 0.5    // contrast and colour, 0.5 as designed
    var grain = 0.0
    var scale = 1.0        // 0.6 ... 1.8
    var dim = 0.0          // 0 ... 0.7, for legibility
    var pointer = true
    var cycle = DayCycle.clock

    init() {}

    init(from decoder: Decoder) throws {
        // Every field is optional, so settings from an older build still load.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = LivingTuning()
        palette = try c.decodeIfPresent(String.self, forKey: .palette) ?? base.palette
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? base.speed
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? base.intensity
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? base.grain
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? base.scale
        dim = try c.decodeIfPresent(Double.self, forKey: .dim) ?? base.dim
        pointer = try c.decodeIfPresent(Bool.self, forKey: .pointer) ?? base.pointer
        cycle = (try? c.decodeIfPresent(DayCycle.self, forKey: .cycle)) ?? base.cycle
    }

    var isDefault: Bool { self == LivingTuning() }
}

/// The values one layer draws with. They ease toward the tuning, so every control changes the
/// desktop smoothly instead of in a cut.
struct LivingLook {
    var speed: Float = 1
    var contrast: Float = 0.5
    var grain: Float = 0
    var scale: Float = 1
    var dim: Float = 0
    var mix: Float = 0
    var palette = [SIMD3<Float>](repeating: .zero, count: 4)
    var daylight: Float = 0
    var golden: Float = 0
    var gate: Float = 1

    mutating func approach(_ target: LivingLook, _ k: Float) {
        speed += (target.speed - speed) * k
        contrast += (target.contrast - contrast) * k
        grain += (target.grain - grain) * k
        scale += (target.scale - scale) * k
        dim += (target.dim - dim) * k
        mix += (target.mix - mix) * k
        daylight += (target.daylight - daylight) * k
        golden += (target.golden - golden) * k
        gate += (target.gate - gate) * k
        // Fading out of a palette keeps its colours until it has gone.
        if target.mix > 0 {
            for index in 0..<4 { palette[index] += (target.palette[index] - palette[index]) * (mix < 0.01 ? 1 : k) }
        }
    }
}

/// Critically damped by default. The state is the motion, so any new target simply bends it.
struct LivingSpring {
    var value: Double
    var target: Double
    var velocity = 0.0
    var response: Double

    init(_ value: Double, response: Double) {
        self.value = value
        self.target = value
        self.response = response
    }

    mutating func step(_ dt: Double) {
        let omega = 2 * Double.pi / response
        // Exact solution of a critically damped spring, stable at any frame time.
        let offset = value - target
        let c = velocity + omega * offset
        let decay = exp(-omega * dt)
        value = target + (offset + c * dt) * decay
        velocity = (c - omega * (offset + c * dt)) * decay
    }

    var settled: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.001 }
}

enum DayLight {
    static var hourNow: Double {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        return Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
    }

    /// 0 at night, 1 at midday, soft shoulders around 06:30 and 19:30.
    static func daylight(hour: Double) -> Double {
        let raw = cos((hour - 13) / 24 * 2 * .pi)
        let t = min(max((raw + 0.32) / 0.72, 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func golden(hour: Double) -> Double {
        let dawn = exp(-pow(hour - 6.8, 2) / 1.6), dusk = exp(-pow(hour - 19.2, 2) / 1.6)
        return min(dawn + dusk, 1)
    }

    /// "07:30", always 24 hour.
    static func text(_ hour: Double) -> String {
        var parts = DateComponents()
        parts.hour = Int(hour) % 24
        parts.minute = Int(hour.truncatingRemainder(dividingBy: 1) * 60)
        let date = Calendar.current.date(from: parts) ?? Date()
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
    }
}

/// One Metal device, one library, pipelines built on demand. Nil when the shaders are missing.
@MainActor
final class LivingEngine {
    static let shared = LivingEngine()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [LivingShader: MTLRenderPipelineState] = [:]
    private var stillPipelines: [String: MTLRenderPipelineState] = [:]
    nonisolated static let pixelFormat = MTLPixelFormat.bgra8Unorm
    /// The owner's wallpaper, with a full mip chain for blur. Built on first use.
    private var wallpaper: MTLTexture?
    private var wallpaperSource: URL?
    private var fallback: MTLTexture?

    /// Why there is no engine, in a few words for the wallpaper chapters. Nil while it works.
    private(set) static var failure: String?

    /// Apple GPUs (Apple silicon, Intel builds under Rosetta included) share memory with the CPU
    /// and accept shared textures. Intel and AMD GPUs do not: on them a texture the CPU reads back
    /// is managed, and synchronised by a blit before it is read.
    let sharesMemory: Bool

    private init?() {
        guard MemoryLayout<LivingUniforms>.stride == 128 else { Self.failure = "This build's shader layout is wrong, so live wallpapers are off."; return nil }
        // The integrated GPU when there is a choice, so a dual-GPU Intel MacBook Pro is not switched
        // onto its discrete Radeon for a wallpaper.
        let all = MTLCopyAllDevices()
        let pick = all.count > 1 ? all.first(where: { $0.isLowPower && !$0.isRemovable && !$0.isHeadless }) : nil
        guard let device = pick ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            Self.failure = "This Mac offers no Metal graphics, so live wallpapers are off."
            return nil
        }
        // Built apps carry default.metallib. It must be compiled for the oldest macOS Atelier runs
        // on: a library stamped for a newer release is refused, and then the shader source, when
        // it is bundled, is compiled here instead, which works on every release.
        var library: MTLLibrary?
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib") {
            library = try? device.makeLibrary(URL: url)
        }
        if library == nil, let url = Bundle.main.url(forResource: "Living", withExtension: "metal"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            library = try? device.makeLibrary(source: source, options: nil)
        }
        guard let library else {
            Self.failure = "This build carries no shaders this macOS can load, so live wallpapers are off."
            return nil
        }
        self.device = device
        self.queue = queue
        self.library = library
        self.sharesMemory = device.supportsFamily(.apple7)
    }

    /// Makes a render target the CPU can read back on any Mac GPU.
    private func readableTarget(width: Int, height: Int, usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = sharesMemory ? .shared : .managed
        return device.makeTexture(descriptor: descriptor)
    }

    /// Brings a managed texture's GPU contents back to the CPU copy before `getBytes`. Shared
    /// textures need nothing.
    private func synchronise(_ texture: MTLTexture, in buffer: MTLCommandBuffer) {
        guard !sharesMemory, let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.synchronize(resource: texture)
        blit.endEncoding()
    }

    // MARK: The owner's wallpaper as a texture

    /// The texture the wallpaper* shaders read. Only the image is read, never the wallpaper setting.
    /// Falls back to a dark gradient when the picture can't be read, so the shaders still draw.
    /// Decoding a 4K picture takes a fifth of a second, far too long for a frame. It happens off
    /// the main thread; the shaders draw over the fallback until the picture is ready.
    private var wallpaperLoading = false
    private var wallpaperGeneration = 0

    func wallpaperTexture() -> MTLTexture? {
        if let wallpaper { return wallpaper }
        if !wallpaperLoading { loadWallpaperInBackground() }
        return fallbackTexture()
    }

    private func loadWallpaperInBackground() {
        wallpaperLoading = true
        wallpaperGeneration += 1
        let generation = wallpaperGeneration
        let largest = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3024
        let urls = Wallpaper.urls() + (NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.map { [$0] } ?? [])
        let maxPixels = Int(min(largest, 4096))
        Task.detached(priority: .userInitiated) {
            var found: (url: URL, pixels: LivingEngine.Pixels)?
            for url in urls {
                if let image = LivingEngine.loadImage(url, maxPixels: maxPixels), let pixels = LivingEngine.p3Pixels(image) {
                    found = (url, pixels)
                    break
                }
            }
            await MainActor.run {
                guard generation == self.wallpaperGeneration else { return }
                self.wallpaperLoading = false
                guard let found, let texture = self.makeTexture(found.pixels, mipmapped: true) else { return }
                self.wallpaper = texture
                self.wallpaperSource = found.url
            }
        }
    }

    private func fallbackTexture() -> MTLTexture? {
        if fallback == nil {
            // 4 x 256 vertical gradient, deep blue: a plausible night window when no picture is readable.
            let width = 4, height = 256
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                let t = Double(y) / Double(height - 1)
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    bytes[i] = UInt8(40 + 50 * t); bytes[i + 1] = UInt8(18 + 30 * t); bytes[i + 2] = UInt8(10 + 22 * t)
                }
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
            descriptor.usage = .shaderRead
            if let texture = device.makeTexture(descriptor: descriptor) {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
                generateMipmaps(texture)
                fallback = texture
            }
        }
        return fallback
    }

    /// Drops the texture when the wallpaper file changed, so the next frame reads the new one.
    /// Returns true when it did.
    @discardableResult func refreshWallpaperTexture() -> Bool {
        let current = Wallpaper.current().first
        guard wallpaper != nil, current != wallpaperSource else { return false }
        wallpaper = nil
        wallpaperSource = nil
        wallpaperLoading = false
        return true
    }

    nonisolated static func loadImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }

    /// Draws the image into Display P3 first: the shaders write P3 values, so the picture keeps its colour.
    struct Pixels: Sendable {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    /// The CPU half of a texture: the picture drawn into Display P3 bytes. Safe off the main thread.
    nonisolated static func p3Pixels(_ image: CGImage) -> Pixels? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(bytes: bytes, width: width, height: height) : nil
    }

    private func makeTexture(_ image: CGImage, mipmapped: Bool) -> MTLTexture? {
        guard let pixels = Self.p3Pixels(image) else { return nil }
        return makeTexture(pixels, mipmapped: mipmapped)
    }

    private func makeTexture(_ pixels: Pixels, mipmapped: Bool) -> MTLTexture? {
        let width = pixels.width, height = pixels.height, bytes = pixels.bytes
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: mipmapped)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        if mipmapped { generateMipmaps(texture) }
        return texture
    }

    private func generateMipmaps(_ texture: MTLTexture) {
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    func pipeline(for shader: LivingShader) -> MTLRenderPipelineState? {
        if let found = pipelines[shader] { return found }
        guard let descriptor = pipelineDescriptor(for: shader) else { return nil }
        let state = try? device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[shader] = state
        return state
    }

    /// Builds a shader's pipeline off the main thread ahead of its first frame, so a canvas that
    /// starts later does not compile it in the middle of an animation.
    func warm(_ shader: LivingShader) async {
        guard pipelines[shader] == nil, let descriptor = pipelineDescriptor(for: shader) else { return }
        nonisolated(unsafe) let unsafeDescriptor = descriptor
        let device = self.device
        nonisolated(unsafe) let state = try? await device.makeRenderPipelineState(descriptor: unsafeDescriptor)
        if pipelines[shader] == nil, let state { pipelines[shader] = state }
    }

    private func pipelineDescriptor(for shader: LivingShader) -> MTLRenderPipelineDescriptor? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "livingVertex")
        descriptor.fragmentFunction = library.makeFunction(name: shader.fragment)
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else { return nil }
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = Self.pixelFormat
        // Premultiplied, so shaders cross-fade over each other and over the real wallpaper.
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return descriptor
    }

    /// The look a tuning asks for at an hour, with nothing eased.
    static func look(_ tuning: LivingTuning, hour: Double, stops: [SIMD3<Float>]?) -> LivingLook {
        var look = LivingLook()
        look.speed = Float(tuning.speed)
        look.contrast = Float(tuning.intensity)
        look.grain = Float(tuning.grain)
        look.scale = Float(tuning.scale)
        look.dim = Float(tuning.dim)
        if let stops, stops.count == 4 { look.mix = 1; look.palette = stops }
        let shown = tuning.cycle.heldHour ?? hour
        look.daylight = Float(DayLight.daylight(hour: shown))
        look.golden = Float(DayLight.golden(hour: shown))
        look.gate = tuning.pointer ? 1 : 0
        return look
    }

    static func write(_ look: LivingLook, into uniforms: inout LivingUniforms, pointer: SIMD2<Float>, presence: Float) {
        uniforms.contrast = look.contrast
        uniforms.grain = look.grain
        uniforms.scale = max(look.scale, 0.2)
        uniforms.dim = look.dim
        uniforms.paletteMix = min(max(look.mix, 0), 1)
        uniforms.palette0 = SIMD4(look.palette[0], 0)
        uniforms.palette1 = SIMD4(look.palette[1], 0)
        uniforms.palette2 = SIMD4(look.palette[2], 0)
        uniforms.palette3 = SIMD4(look.palette[3], 0)
        uniforms.daylight = look.daylight
        uniforms.golden = look.golden
        // The shader paints a zoomed frame, so the pointer is zoomed the same way.
        uniforms.pointer = (pointer - 0.5) / uniforms.scale + 0.5
        uniforms.presence = presence * min(max(look.gate, 0), 1)
    }

    /// A single frame in memory: still backgrounds, and anything else that should not move.
    func snapshot(_ shader: LivingShader, width: Int, height: Int, hour: Double, time: Double = 40,
                  pointer: SIMD2<Float> = [0.5, 0.5], presence: Float = 0,
                  tuning: LivingTuning? = nil, seed: Float = 0) -> CGImage? {
        guard width > 0, height > 0, let pipeline = pipeline(for: shader) else { return nil }
        guard let texture = readableTarget(width: width, height: height, usage: [.renderTarget, .shaderRead]),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let tuning = tuning ?? LiveWallpaper.shared.tuning(for: shader)
        var uniforms = LivingUniforms()
        uniforms.resolution = [Float(width), Float(height)]
        uniforms.time = Float(time)
        uniforms.day = Float(hour / 24)
        uniforms.seed = seed
        let look = Self.look(tuning, hour: hour, stops: LiveWallpaper.shared.stops(for: tuning.palette))
        Self.write(look, into: &uniforms, pointer: pointer, presence: presence)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LivingUniforms>.stride, index: 0)
        if shader.usesWallpaper, let wall = wallpaperTexture() { encoder.setFragmentTexture(wall, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        synchronise(texture, in: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        return Self.image(from: texture, width: width, height: height)
    }

    /// One frame of a fragment that is not a live wallpaper: the generated stills. Opaque.
    func still(fragment: String, uniforms: LivingUniforms, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let pipeline: MTLRenderPipelineState
        if let found = stillPipelines[fragment] {
            pipeline = found
        } else {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "livingVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            guard descriptor.fragmentFunction != nil, let made = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            stillPipelines[fragment] = made
            pipeline = made
        }
        guard let texture = readableTarget(width: width, height: height, usage: [.renderTarget]),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var values = uniforms
        values.resolution = [Float(width), Float(height)]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&values, length: MemoryLayout<LivingUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        synchronise(texture, in: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        return Self.image(from: texture, width: width, height: height)
    }

    private static func image(from texture: MTLTexture, width: Int, height: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A Metal surface that draws shaders, cross-fading through a stack of layers.
/// Every value it animates is a spring or an ease, so a new choice mid-fade bends the motion.
@MainActor
final class LivingCanvas: MTKView, MTKViewDelegate {
    private struct Layer {
        let shader: LivingShader
        var alpha: LivingSpring
        /// Each layer keeps its own clock, so its speed can change without a jump.
        var phase: Double
        var look: LivingLook
    }

    var seed: Float = 0
    /// For previews in ordinary windows, where occlusion and clipping can be trusted to save the work.
    var followsOcclusion = false
    var hourOverride: () -> Double? = { nil }
    /// Where each shader's settings come from. Previews use the owner's, so they stay faithful.
    var tuning: (LivingShader) -> LivingTuning = { LiveWallpaper.shared.tuning(for: $0) }
    var onFaded: (() -> Void)?
    /// Frames a second. Gallery thumbnails run slower; the desktop runs at 30.
    /// Frames per second. The desktop and the stage run at the display's own rate (120 on
    /// ProMotion); gallery thumbnails ask for less.
    var fps = 120.0 { didSet { if running, fps != oldValue { run(false); run(true) } } }

    private var layers: [Layer] = []
    private var master = LivingSpring(0, response: 1.3)
    private var pointerX = LivingSpring(0.5, response: 0.9)
    private var pointerY = LivingSpring(0.5, response: 0.9)
    private var presence = LivingSpring(0, response: 0.8)
    private var daylight = LivingSpring(0.5, response: 1.1)
    private var golden = LivingSpring(0, response: 1.1)
    /// The hour this frame shows, read once per frame: the calendar is not free.
    private var hour = 12.0
    private var phase = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 3600)
    private var last = CACurrentMediaTime()
    private var pixelScale: CGFloat = 0.5
    private var fading = false
    private(set) var frames = 0
    private(set) var running = false
    private var beat: Timer?
    private var link: CADisplayLink?

    init(engine: LivingEngine, shader: LivingShader) {
        super.init(frame: .zero, device: engine.device)
        delegate = self
        colorPixelFormat = LivingEngine.pixelFormat
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        framebufferOnly = true
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        hour = DayLight.hourNow
        daylight = LivingSpring(DayLight.daylight(hour: hour), response: 1.1)
        golden = LivingSpring(DayLight.golden(hour: hour), response: 1.1)
        layers = [Layer(shader: shader, alpha: LivingSpring(1, response: 0.9), phase: phase, look: target(for: shader, hour: hour))]
        pixelScale = shader.renderScale
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitDrawable()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitDrawable()
        // The link belongs to a screen; a canvas made before it had a window starts it now.
        if running, link == nil, window != nil { running = false; run(true) }
    }

    private func fitDrawable() {
        let backing = window?.backingScaleFactor ?? 2
        let width = (bounds.width * backing * pixelScale).rounded(), height = (bounds.height * backing * pixelScale).rounded()
        guard width > 0, height > 0 else { return }
        let size = CGSize(width: width, height: height)
        if drawableSize != size { drawableSize = size }
    }

    /// What the tuning asks of a layer right now.
    private func target(for shader: LivingShader, hour: Double) -> LivingLook {
        let tuning = self.tuning(shader)
        var look = LivingEngine.look(tuning, hour: hour, stops: LiveWallpaper.shared.stops(for: tuning.palette))
        if tuning.cycle == .clock {
            // The clock look rides the canvas springs, so a dragged hour still glides.
            look.daylight = Float(daylight.value)
            look.golden = Float(golden.value)
        }
        return look
    }

    func show(_ shader: LivingShader) {
        guard layers.last?.shader != shader else { return }
        if let index = layers.firstIndex(where: { $0.shader == shader }) { layers.remove(at: index) }
        layers.append(Layer(shader: shader, alpha: { var s = LivingSpring(0, response: 1.3); s.target = 1; return s }(),
                            phase: phase, look: target(for: shader, hour: hour)))
        pixelScale = shader.renderScale
        fitDrawable()
        // Held still, there is no fade to watch: the new choice simply is the frame.
        if !running {
            layers = layers.suffix(1).map { var layer = $0; layer.alpha = LivingSpring(1, response: 0.9); return layer }
            redraw()
        }
    }

    func fadeIn(animated: Bool) {
        fading = false
        master.target = 1
        if !animated { master.value = 1; master.velocity = 0 }
    }

    func fadeOut(_ done: @escaping () -> Void) {
        fading = true
        master.target = 0
        onFaded = done
    }

    /// The screen's display link, not the window's: a window's link (and MTKView's loop) stops
    /// whenever the window server calls the window occluded, which desktop-level windows always
    /// are. A screen link keeps ticking, in step with the display, at up to 120 Hz.
    func run(_ on: Bool) {
        guard running != on else { return }
        running = on
        beat?.invalidate()
        beat = nil
        link?.invalidate()
        link = nil
        guard on else { return }
        last = CACurrentMediaTime()
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        let rate = Float(min(max(fps, 1), 120))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 30), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else { return }
        if followsOcclusion {
            // In a window: skip while the window is hidden, and while scrolled out of sight.
            if !window.occlusionState.contains(.visible) || isHiddenOrHasHiddenAncestor || visibleRect.isEmpty {
                last = CACurrentMediaTime()
                return
            }
        }
        draw()
    }

    /// One still frame: for Reduce Motion, and anything else that should not move.
    func still() {
        run(false)
        layers = layers.suffix(1).map { var layer = $0; layer.alpha = LivingSpring(1, response: 0.9); return layer }
        master.value = master.target
        master.velocity = 0
        redraw()
    }

    /// Draws one frame with every eased value at its target, without starting or stopping anything.
    /// Settings changed while the wallpaper is paused land on screen this way.
    func redraw() {
        hour = hourOverride() ?? DayLight.hourNow
        daylight = LivingSpring(DayLight.daylight(hour: hour), response: 1.1)
        golden = LivingSpring(DayLight.golden(hour: hour), response: 1.1)
        for index in layers.indices { layers[index].look = target(for: layers[index].shader, hour: hour) }
        last = CACurrentMediaTime()
        draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func advance(_ dt: Double) {
        phase += dt
        hour = hourOverride() ?? DayLight.hourNow
        daylight.target = DayLight.daylight(hour: hour)
        golden.target = DayLight.golden(hour: hour)
        daylight.step(dt)
        golden.step(dt)
        master.step(dt)
        let ease = Float(1 - exp(-dt / 0.22))
        for index in layers.indices {
            layers[index].alpha.step(dt)
            layers[index].look.approach(target(for: layers[index].shader, hour: hour), ease)
            layers[index].phase += dt * Double(layers[index].look.speed)
        }
        if layers.count > 1, let top = layers.last, top.alpha.value > 0.995 { layers = [top] }

        if let window {
            let rect = window.convertToScreen(convert(bounds, to: nil))
            let mouse = NSEvent.mouseLocation
            if rect.contains(mouse) {
                pointerX.target = (mouse.x - rect.minX) / rect.width
                pointerY.target = 1 - (mouse.y - rect.minY) / rect.height
                presence.target = 1
            } else {
                presence.target = 0
            }
        }
        pointerX.step(dt)
        pointerY.step(dt)
        presence.step(dt)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        advance(min(now - last, 0.1))
        last = now
        render()
        if fading, master.value < 0.004, master.target == 0 {
            fading = false
            let done = onFaded
            onFaded = nil
            done?()
        }
    }

    /// Frames rendered by every canvas, read by atelier://diag.
    static var rendered = 0

    private func render() {
        Self.rendered += 1
        guard let engine = LivingEngine.shared, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, let buffer = engine.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = LivingUniforms()
        uniforms.resolution = [Float(drawableSize.width), Float(drawableSize.height)]
        uniforms.day = Float(hour / 24)
        uniforms.seed = seed
        let pointer = SIMD2<Float>(Float(pointerX.value), Float(pointerY.value))
        let presence = Float(max(presence.value, 0))
        for (index, layer) in layers.enumerated() {
            guard let pipeline = engine.pipeline(for: layer.shader) else { continue }
            let alpha = index == 0 ? 1 : min(max(layer.alpha.value, 0), 1)
            uniforms.opacity = Float(alpha * min(max(master.value, 0), 1))
            uniforms.time = Float(layer.phase)
            LivingEngine.write(layer.look, into: &uniforms, pointer: pointer, presence: presence)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LivingUniforms>.stride, index: 0)
            if layer.shader.usesWallpaper, let wall = engine.wallpaperTexture() { encoder.setFragmentTexture(wall, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        frames += 1
    }
}

/// Real-time wallpapers in a click-through window directly above the system wallpaper.
/// The wallpaper setting itself is never read or written.
@MainActor
final class LiveWallpaper: ObservableObject {
    static let shared = LiveWallpaper()

    enum Pause: Equatable {
        case reduceMotion, battery, asleep, covered

        var note: String {
            switch self {
            case .reduceMotion: "Holding a still frame: Reduce Motion is on."
            case .battery: "Paused on battery."
            case .asleep: "Paused while the display sleeps."
            case .covered: "Paused: your desktop is fully covered."
            }
        }
    }

    private let store = UserDefaults.standard
    @Published var enabled: Bool {
        didSet {
            store.set(enabled, forKey: "liveWallpaper")
            if enabled, StillBackground.shared.enabled { StillBackground.shared.enabled = false }
            apply()
        }
    }
    /// The wallpaper showing now. With a schedule on, the schedule sets it at each change of light.
    @Published var shader: LivingShader {
        didSet { store.set(shader.rawValue, forKey: "liveShader"); showChoices() }
    }
    @Published var pauseOnBattery: Bool { didSet { store.set(pauseOnBattery, forKey: "livePauseOnBattery"); evaluate() } }
    /// While set, every surface shows this hour. Released, they spring back to the real one.
    @Published var previewHour: Double?
    /// Set only when it changes: this is decided every second, and an unchanged value republished
    /// every second redrew every view watching this object, the stage and its menu bar included.
    @Published private(set) var pause: Pause?
    private func setPause(_ value: Pause?) { if pause != value { pause = value } }

    /// Per-shader settings. Missing entries are the shader as designed.
    @Published private(set) var tunings: [LivingShader: LivingTuning]
    /// The current wallpaper's colours, read when the owner asks for them, kept across launches.
    @Published private(set) var wallpaperStops: [SIMD3<Float>]?

    /// One wallpaper by day, another by night.
    @Published var scheduled: Bool { didSet { store.set(scheduled, forKey: "liveScheduled"); scheduledLight = nil; followSchedule() } }
    @Published var dayShader: LivingShader { didSet { store.set(dayShader.rawValue, forKey: "liveDayShader"); scheduledLight = nil; followSchedule() } }
    @Published var nightShader: LivingShader { didSet { store.set(nightShader.rawValue, forKey: "liveNightShader"); scheduledLight = nil; followSchedule() } }
    @Published var dayBegins: Double { didSet { store.set(dayBegins, forKey: "liveDayBegins"); scheduledLight = nil; followSchedule() } }
    @Published var nightBegins: Double { didSet { store.set(nightBegins, forKey: "liveNightBegins"); scheduledLight = nil; followSchedule() } }

    /// Off, every display shows `shader`. On, a display with its own choice shows that instead.
    @Published var perDisplay: Bool { didSet { store.set(perDisplay, forKey: "livePerDisplay"); showChoices() } }
    /// Keyed by display UUID, which survives restarts and reconnection where a display ID does not.
    @Published private(set) var displayShaders: [String: LivingShader]

    var available: Bool { LivingEngine.shared != nil }
    /// Total frames presented on the desktop, for measuring the real rate.
    var framesDrawn: Int { surfaces.values.reduce(0) { $0 + $1.canvas.frames } }

    private struct Surface {
        let panel: FloatingPanel
        let canvas: LivingCanvas
        var covered = false
    }

    private var surfaces: [CGDirectDisplayID: Surface] = [:]
    private var watcher: Timer?
    private var started = false
    private var asleep = false
    private var heldStill = false
    /// The light the schedule last acted on. Nil makes it act on the next look.
    private var scheduledLight: Bool?

    private init() {
        enabled = store.bool(forKey: "liveWallpaper")
        shader = LivingShader(rawValue: store.string(forKey: "liveShader") ?? "") ?? .liquidLight
        pauseOnBattery = store.bool(forKey: "livePauseOnBattery")
        if let data = store.data(forKey: "liveTunings"),
           let saved = try? JSONDecoder().decode([String: LivingTuning].self, from: data) {
            tunings = Dictionary(saved.compactMap { key, value in LivingShader(rawValue: key).map { ($0, value) } },
                                 uniquingKeysWith: { first, _ in first })
        } else {
            tunings = [:]
        }
        if let flat = store.array(forKey: "liveWallpaperStops") as? [Double], flat.count == 12 {
            let values = flat.map(Float.init)
            wallpaperStops = (0..<4).map { index -> SIMD3<Float> in
                SIMD3<Float>(values[index * 3], values[index * 3 + 1], values[index * 3 + 2])
            }
        } else {
            wallpaperStops = nil
        }
        scheduled = store.bool(forKey: "liveScheduled")
        dayShader = LivingShader(rawValue: store.string(forKey: "liveDayShader") ?? "") ?? .gradientMesh
        nightShader = LivingShader(rawValue: store.string(forKey: "liveNightShader") ?? "") ?? .starfield
        dayBegins = store.object(forKey: "liveDayBegins") as? Double ?? 7
        nightBegins = store.object(forKey: "liveNightBegins") as? Double ?? 19
        perDisplay = store.bool(forKey: "livePerDisplay")
        displayShaders = (store.dictionary(forKey: "liveDisplayShaders") as? [String: String] ?? [:])
            .compactMapValues(LivingShader.init(rawValue:))
    }

    // MARK: Original wallpaper

    /// True while something from Atelier is drawn over, or set in place of, the owner's own wallpaper.
    var coversOriginal: Bool { enabled || StillBackground.shared.enabled || Effects.shared.living != nil }

    /// Everything off, the owner's own picture back. Live and still backgrounds only ever drew
    /// above it, so turning them off is enough; a generated wallpaper is swapped back for the
    /// saved original. No file is deleted.
    func showOriginal() {
        if enabled { enabled = false }
        if StillBackground.shared.enabled { StillBackground.shared.enabled = false }
        if WebWallpaper.shared.enabled { WebWallpaper.shared.enabled = false }
        Effects.shared.restoreOriginalWallpaper()
        objectWillChange.send()
    }

    // MARK: Settings

    func tuning(for shader: LivingShader) -> LivingTuning { tunings[shader] ?? LivingTuning() }

    func setTuning(_ tuning: LivingTuning, for shader: LivingShader) {
        guard tunings[shader] ?? LivingTuning() != tuning else { return }
        tunings[shader] = tuning.isDefault ? nil : tuning
        let flat = Dictionary(uniqueKeysWithValues: tunings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(flat) { store.set(data, forKey: "liveTunings") }
        if tuning.palette == LivingPalette.wallpaper, wallpaperStops == nil { sampleWallpaper() }
        refreshStill()
    }

    /// The four stops a palette maps onto. Nil means the shader's own colour.
    func stops(for palette: String) -> [SIMD3<Float>]? {
        switch palette {
        case LivingPalette.natural: nil
        case LivingPalette.wallpaper: wallpaperStops
        default: LivingPalette.preset(palette)?.stops ?? ThemePalettes.stops(for: palette)
        }
    }

    /// Reads the colours of the current wallpaper. Only the image is read, never the setting.
    func sampleWallpaper() {
        guard let image = Wallpaper.image(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let stops = PaletteSampler.stops(from: cgImage) else { return }
        wallpaperStops = stops
        store.set(stops.flatMap { [Double($0.x), Double($0.y), Double($0.z)] }, forKey: "liveWallpaperStops")
        refreshStill()
    }

    static func uuid(of display: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String? else { return "\(display)" }
        return text
    }

    func shader(forDisplay display: CGDirectDisplayID) -> LivingShader {
        guard perDisplay else { return shader }
        return displayShaders[Self.uuid(of: display)] ?? shader
    }

    func setShader(_ choice: LivingShader, forDisplay display: CGDirectDisplayID) {
        displayShaders[Self.uuid(of: display)] = choice
        store.set(displayShaders.mapValues(\.rawValue), forKey: "liveDisplayShaders")
        showChoices()
    }

    private func showChoices() {
        for (id, surface) in surfaces { surface.canvas.show(shader(forDisplay: id)) }
    }

    /// Paused or held surfaces do not draw on their own, so a changed setting is drawn once for them.
    /// Covered or asleep surfaces cannot be seen, so they wait until they run again.
    private func refreshStill() {
        guard pause == .reduceMotion || pause == .battery else { return }
        for surface in surfaces.values where !surface.canvas.running { surface.canvas.redraw() }
    }

    func isDay(at hour: Double) -> Bool {
        dayBegins <= nightBegins ? (hour >= dayBegins && hour < nightBegins) : (hour >= dayBegins || hour < nightBegins)
    }

    /// Acts only when the light changes, so a wallpaper picked by hand stays until the next change.
    private func followSchedule() {
        guard scheduled else { scheduledLight = nil; return }
        let day = isDay(at: DayLight.hourNow)
        guard day != scheduledLight else { return }
        scheduledLight = day
        let choice = day ? dayShader : nightShader
        if shader != choice { shader = choice }
    }

    // MARK: Surfaces

    func start() {
        guard !started else { return }
        started = true
        StillBackground.shared.start()
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveWallpaper.shared.apply() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveWallpaper.shared.evaluate() }
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveWallpaper.shared.evaluate() }
        }
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    LiveWallpaper.shared.asleep = sleeping
                    LiveWallpaper.shared.evaluate()
                }
            }
        }
        followSchedule()
        apply()
    }

    private func apply() {
        guard started else { return }
        guard enabled, let engine = LivingEngine.shared else {
            watcher?.invalidate()
            watcher = nil
            setPause(nil)
            heldStill = false
            for (id, surface) in surfaces {
                guard surface.canvas.running else {
                    surface.panel.orderOut(nil)
                    surfaces[id] = nil
                    continue
                }
                surface.canvas.fadeOut { LiveWallpaper.shared.remove(id) }
            }
            return
        }
        let screens = Dictionary(NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen) } },
                                 uniquingKeysWith: { first, _ in first })
        for (id, surface) in surfaces where screens[id] == nil {
            surface.panel.orderOut(nil)
            surfaces[id] = nil
        }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, (id, screen)) in screens.sorted(by: { $0.key < $1.key }).enumerated() {
            if let surface = surfaces[id] {
                surface.panel.setFrame(screen.frame, display: false)
                surface.canvas.fadeIn(animated: !still)
                continue
            }
            let canvas = LivingCanvas(engine: engine, shader: shader(forDisplay: id))
            canvas.seed = Float(index) * 17.3
            canvas.hourOverride = { LiveWallpaper.shared.previewHour }
            canvas.fadeIn(animated: !still)
            let panel = FloatingPanel(frame: screen.frame)
            // Exactly the desktop level: above the system wallpaper, below the Desktop Clock and Finder's icons.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            panel.contentView = canvas
            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            surfaces[id] = Surface(panel: panel, canvas: canvas)
        }
        heldStill = false
        if watcher == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { LiveWallpaper.shared.evaluate() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            watcher = timer
        }
        evaluate()
    }

    private func remove(_ id: CGDirectDisplayID) {
        guard !enabled, let surface = surfaces[id] else { return }
        surface.canvas.run(false)
        surface.panel.orderOut(nil)
        surfaces[id] = nil
    }

    private var ticks = 0

    /// Runs once a second. Everything that can stop the wallpaper lands here.
    private func evaluate() {
        guard enabled, !surfaces.isEmpty else { return }
        followSchedule()
        // Twice a minute, notice a new wallpaper picture for the shaders that paint with it.
        ticks += 1
        if ticks % 30 == 0, surfaces.keys.contains(where: { shader(forDisplay: $0).usesWallpaper }),
           LivingEngine.shared?.refreshWallpaperTexture() == true {
            for surface in surfaces.values where !surface.canvas.running { surface.canvas.redraw() }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setPause(.reduceMotion)
            if !heldStill {
                heldStill = true
                surfaces.values.forEach { $0.canvas.still() }
            }
            return
        }
        heldStill = false
        if asleep || Self.displaysAsleep { hold(.asleep); return }
        if pauseOnBattery, Self.onBattery { hold(.battery); return }

        let windows = Self.opaqueWindows()
        var covered = 0
        for (id, surface) in surfaces {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { continue }
            let hidden = Self.isCovered(screen, by: windows)
            surface.canvas.run(!hidden)
            if hidden { covered += 1 }
        }
        setPause(covered == surfaces.count ? .covered : nil)
    }

    private func hold(_ reason: Pause) {
        setPause(reason)
        for surface in surfaces.values {
            if surface.canvas.frames == 0 { surface.canvas.still() } else { surface.canvas.run(false) }
        }
    }

    /// Also true behind a locked screen with the display off, where no sleep notice may arrive.
    private static var displaysAsleep: Bool {
        NSScreen.screens.allSatisfy { $0.displayID.map { CGDisplayIsAsleep($0) != 0 } ?? false }
    }

    private static var onBattery: Bool {
        guard BatteryMeter.hasInternalBattery, let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPSBatteryPowerValue
    }

    /// Bounds of other apps' windows, in Core Graphics coordinates. No permission involved.
    private static func opaqueWindows() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) != own,
                  let layer = window[kCGWindowLayer as String] as? Int, (0..<20).contains(layer),
                  (window[kCGWindowAlpha as String] as? Double ?? 0) > 0.9,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return rect
        }
    }

    /// Samples the usable desktop on a coarse grid: all points under some window means nothing shows.
    static func isCovered(_ screen: NSScreen, by windows: [CGRect]) -> Bool {
        guard !windows.isEmpty, let primary = NSScreen.screens.first?.frame.height else { return false }
        let visible = screen.visibleFrame
        let area = CGRect(x: visible.minX, y: primary - visible.maxY, width: visible.width, height: visible.height)
        let columns = 24, rows = 15
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: area.minX + area.width * (CGFloat(column) + 0.5) / CGFloat(columns),
                                    y: area.minY + area.height * (CGFloat(row) + 0.5) / CGFloat(rows))
                if !windows.contains(where: { $0.contains(point) }) { return false }
            }
        }
        return true
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// MARK: - Chapter

/// A live surface for the app itself. It shares the desktop's shaders, the owner's settings for
/// them, and honours Reduce Motion. It skips frames while its window is hidden or it is scrolled away.
struct LivingPreview: NSViewRepresentable {
    let shader: LivingShader
    /// Frames a second. Thumbnails pass less.
    var fps: Double = 120
    /// Off, the canvas holds one composed frame and has no display link at all: plates and
    /// thumbnails rest still and come alive only under the pointer.
    var running = true

    func makeNSView(context: Context) -> NSView {
        guard let engine = LivingEngine.shared else { return NSView() }
        let canvas = LivingCanvas(engine: engine, shader: shader)
        canvas.followsOcclusion = true
        canvas.fps = fps
        canvas.fadeIn(animated: true)
        canvas.hourOverride = { LiveWallpaper.shared.previewHour }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !running {
            DispatchQueue.main.async { canvas.still() }
        } else {
            canvas.run(true)
        }
        return canvas
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let canvas = view as? LivingCanvas else { return }
        canvas.show(shader)
        canvas.fps = fps
        if running, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if !canvas.running { canvas.run(true) }
        } else {
            // Held still, it would not see a new setting or shader by itself.
            canvas.still()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? LivingCanvas)?.run(false)
    }
}

/// Still frames for the gallery cards, rendered once per shader, look and hour and kept in
/// memory and in Caches, so a card shows its picture at once, scrolled away and back or not.
@MainActor
enum LivingThumbnails {
    /// Points; rendered at twice that.
    static let size = CGSize(width: 220, height: 96)
    private static var memory: [String: NSImage] = [:]

    private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Atelier/LiveThumbnails", isDirectory: true)
    }

    /// Changes with the shader, its tuning, its palette's colours and the hour, so a stale picture is never shown.
    static func key(_ shader: LivingShader) -> String {
        let tuning = LiveWallpaper.shared.tuning(for: shader)
        let hour = Int(tuning.cycle.heldHour ?? Double(Calendar.current.component(.hour, from: Date())))
        var text = shader.rawValue + "|\(hour)|"
        if let data = try? JSONEncoder().encode(tuning) { text += String(decoding: data, as: UTF8.self) }
        if let stops = LiveWallpaper.shared.stops(for: tuning.palette) {
            text += stops.map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: ";")
        }
        // FNV-1a: a short, stable file name.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return shader.rawValue + "-" + String(hash, radix: 16)
    }

    /// Already in memory: what a card shows on its very first frame.
    static func cached(_ shader: LivingShader) -> NSImage? { memory[key(shader)] }

    /// From memory, then disk, then rendered. Shaders that paint with the owner's wallpaper are
    /// kept in memory only, since the picture under them can change.
    static func load(_ shader: LivingShader) async -> NSImage? {
        let key = key(shader)
        if let image = memory[key] { return image }
        let file = folder?.appendingPathComponent(key + ".png")
        if !shader.usesWallpaper, let file, let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            image.size = size
            memory[key] = image
            return image
        }
        guard let engine = LivingEngine.shared else { return nil }
        await engine.warm(shader)
        guard let still = engine.snapshot(shader, width: Int(size.width * 2), height: Int(size.height * 2),
                                          hour: Double(Calendar.current.component(.hour, from: Date())),
                                          tuning: LiveWallpaper.shared.tuning(for: shader)) else { return nil }
        let image = NSImage(cgImage: still, size: size)
        memory[key] = image
        if !shader.usesWallpaper, let file, let folder,
           let png = NSBitmapImageRep(cgImage: still).representation(using: .png, properties: [:]) {
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? png.write(to: file, options: .atomic)
            }
        }
        return image
    }
}

/// A gallery card. It always shows a still frame, and runs live only under the pointer.
struct LivingCard: View {
    let shader: LivingShader
    let selected: Bool
    /// Place in the gallery. Stills are rendered one after another, so ten shader builds at
    /// once never stall the panel's arrival.
    var order = 0
    let select: () -> Void
    let hover: (Bool) -> Void
    @ObservedObject private var wallpaper = LiveWallpaper.shared
    @State private var hovering = false
    @State private var still: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
        // A recycled card finds its picture in memory on the first frame, so it never blinks.
        let picture = still ?? LivingThumbnails.cached(shader)
        Button(action: select) {
            ZStack(alignment: .bottomLeading) {
                // The cell sets the size and the picture fills it: a filling image sized itself
                // would take its own wider width and push the card past its grid column.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .overlay {
                        ZStack {
                            if let picture {
                                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(DS.Ink.fill)
                            }
                            if hovering {
                                LivingPreview(shader: shader, fps: 30, running: true)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .clipped()
                    .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                // Hover is a tint, never a lift: the card holds a live Metal canvas.
                Color.white.opacity(hovering && !selected ? 0.06 : 0).allowsHitTesting(false)
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(shader.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if !wallpaper.tuning(for: shader).isDefault {
                        Circle().fill(DS.Spectrum.surfaces).frame(width: 5, height: 5)
                            .accessibilityLabel("Adjusted")
                    }
                }
                .padding(10)
            }
            .contentShape(Rectangle())
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(selected ? DS.Spectrum.surfaces : .white.opacity(hovering ? 0.24 : 0.1),
                                   lineWidth: selected ? 2 : 0.5)
            }
            .overlay {
                // The selection ring sits a hairline inside the hue, like a lit bezel.
                if selected { shape.inset(by: 2).strokeBorder(.black.opacity(0.35), lineWidth: 1) }
            }
            .animation(DS.Motion.settle, value: selected)
        }
        .buttonStyle(Pressable(scale: 0.97))
        .accessibilityLabel(shader.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { inside in
            hovering = inside && !ScrollActivity.scrolling
            hover(inside)
        }
        // Keyed by the look, so a changed tuning or palette brings a fresh still.
        .task(id: LivingThumbnails.key(shader)) {
            if let ready = LivingThumbnails.cached(shader) { still = ready; return }
            // Only the first pass staggers; later ones come from memory or disk.
            try? await Task.sleep(for: .milliseconds(40 * order))
            if let image = await LivingThumbnails.load(shader) { still = image }
        }
    }
}

/// A compact menu of every wallpaper, styled like the rest of the chapter.
struct ShaderMenu: View {
    let selection: LivingShader
    let choose: (LivingShader) -> Void

    var body: some View {
        Menu {
            ForEach(LivingShader.allCases) { shader in
                Button { choose(shader) } label: {
                    if shader == selection { Label(shader.title, systemImage: "checkmark") } else { Text(shader.title) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.primary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(Pressable(scale: 0.97))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Wallpaper")
        .accessibilityValue(selection.title)
    }
}

/// A labelled slider with its value beside the title.
struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tint: Color? = nil
    let text: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                Spacer()
                Text(text(value)).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
            }
            LuxSlider(value: $value, range: range, label: title, tint: tint)
        }
        .contentShape(Rectangle())
        .modifier(FallbackStagePreview(title: title, detail: text(value)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(text(value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

struct LiveWallpaperChapter: View {
    @ObservedObject private var wallpaper = LiveWallpaper.shared
    @State private var peek: LivingShader?
    @State private var hour = DayLight.hourNow
    @State private var screens = NSScreen.screens
    private let columns = [GridItem(.flexible(), spacing: DS.Space.m), GridItem(.flexible(), spacing: DS.Space.m),
                           GridItem(.flexible(), spacing: DS.Space.m)]
    private let hue = DS.Spectrum.surfaces

    private var shown: LivingShader { peek ?? wallpaper.shader }
    private var editing: LivingShader { wallpaper.shader }

    /// A binding into the selected shader's tuning.
    private func tune<Value>(_ key: WritableKeyPath<LivingTuning, Value>) -> Binding<Value> {
        let shader = editing
        return Binding(get: { LiveWallpaper.shared.tuning(for: shader)[keyPath: key] },
                       set: { value in
                           var tuning = LiveWallpaper.shared.tuning(for: shader)
                           tuning[keyPath: key] = value
                           LiveWallpaper.shared.setTuning(tuning, for: shader)
                       })
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    /// The main display's own rate: the wallpaper runs at it.
    private var rate: Int { NSScreen.main?.maximumFramesPerSecond ?? 60 }

    var body: some View {
        Text("Painted live by your GPU, above your wallpaper and below everything else. Your wallpaper setting is never touched.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)

        OriginalWallpaperCard()

        if wallpaper.available {
            hero

            SectionHeader("Gallery", symbol: "square.grid.3x3",
                          detail: "Point at one to see it above, at full speed. Click to wear it.", hue: hue)
            LazyVGrid(columns: columns, spacing: DS.Space.m) {
                ForEach(Array(LivingShader.allCases.enumerated()), id: \.element) { order, shader in
                    LivingCard(shader: shader, selected: wallpaper.shader == shader, order: order) {
                        wallpaper.shader = shader
                    } hover: { inside in
                        // The hero swaps its shader and title on hover; not for cards that
                        // merely pass under the pointer during a scroll.
                        if inside, ScrollActivity.scrolling { return }
                        withAnimation(DS.Motion.touch) {
                            if inside { peek = shader } else if peek == shader { peek = nil }
                        }
                    }
                }
            }

            ShaderPackGallery(hue: hue)

            SectionHeader("Adjust", symbol: "slider.horizontal.3", hue: hue)
            adjustCard
            RowGroup {
                SettingRow(title: "Follow Pointer", detail: "The wallpaper answers where your pointer rests.",
                           symbol: "cursorarrow.motionlines", density: .compact) {
                    LuxSwitch(isOn: tune(\.pointer), label: "Follow Pointer", tint: hue)
                }
                .stagePreview(.demo("live.pointer", "Follow Pointer", isOn: tune(\.pointer).wrappedValue, region: StageRegion.desktop, Demos.followPointer))
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    SettingRow(title: "Light", detail: wallpaper.tuning(for: editing).cycle == .clock
                               ? "Shifts with the hour, warm at sunrise and sunset."
                               : "Holds the look of \(wallpaper.tuning(for: editing).cycle.title.lowercased()) at every hour.",
                               symbol: "sun.horizon", density: .compact) { EmptyView() }
                    Segments(selection: tune(\.cycle), options: DayCycle.allCases.map { ($0, $0.title) })
                        .padding(.bottom, DS.Space.s)
                }
                timeRow
            }

            SectionHeader("When it runs", symbol: "clock", hue: hue)
            scheduleGroup
            if screens.count > 1 { displaysGroup }
        } else {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SettingRow(title: "Live Wallpapers Are Off", detail: "Still Background, Website Wallpaper and your own wallpaper still work.") { EmptyView() }
                    AvailabilityNote(availability: DesktopAvailability.metal)
                }
            }
        }

        SectionHeader("More ways to fill the desktop", symbol: "rectangle.on.rectangle",
                      detail: "Both draw above your wallpaper and never change it.", hue: hue)
        WebWallpaperCard()
        if wallpaper.available {
            StillBackgroundCard()
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                    screens = NSScreen.screens
                }
        }
    }

    // MARK: Hero

    private var hero: some View {
        HeroCard("Live Wallpaper",
                 pitch: wallpaper.pause?.note ?? "Shaders at your display's own rate. It sleeps when nothing shows.",
                 isOn: $wallpaper.enabled, hue: hue,
                 readout: "\(rate) Hz", readoutCaption: "Painted live",
                 preview: .toggle("live.on", "Live Wallpaper", isOn: wallpaper.enabled, region: StageRegion.desktop) { $0.livingOn.toggle() }) {
            LiveWallpaperPlate(shader: shown, peeking: peek != nil)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingRow(title: "Pause on Battery", detail: "Holds the last frame while you are unplugged.", density: .compact) {
                    LuxSwitch(isOn: $wallpaper.pauseOnBattery, label: "Pause on Battery", tint: hue)
                        .disabled(!DesktopAvailability.pauseOnBattery.isUsable)
                        .opacity(DesktopAvailability.pauseOnBattery.isUsable ? 1 : 0.4)
                }
                .stagePreview(.demo("live.battery", "Pause on Battery", isOn: wallpaper.pauseOnBattery, region: StageRegion.desktop, Demos.pauseOnBattery))
                AvailabilityNote(availability: DesktopAvailability.pauseOnBattery)
            }
        }
    }

    // MARK: Adjust

    private var adjustCard: some View {
        let tuning = wallpaper.tuning(for: editing)
        return Card {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text(editing.title).font(DS.title).foregroundStyle(DS.Ink.primary)
                        .contentTransition(.opacity)
                    Spacer()
                    Button {
                        withAnimation(DS.Motion.settle) { wallpaper.setTuning(LivingTuning(), for: editing) }
                    } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tuning.isDefault ? DS.Ink.tertiary : DS.Ink.primary)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(DS.Ink.fill, in: Capsule())
                    }
                    .buttonStyle(Pressable(scale: 0.95))
                    .disabled(tuning.isDefault)
                    .accessibilityLabel("Reset \(editing.title)")
                }

                if editing.usesWallpaper {
                    Text("Paints with your own wallpaper's colours, so it has no palette.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                } else {
                    PaletteRow(selection: tune(\.palette), wallpaperStops: wallpaper.wallpaperStops) {
                        wallpaper.sampleWallpaper()
                    }
                }

                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    TuningSlider(title: "Speed", value: tune(\.speed), range: 0.2...2.5, tint: hue) { String(format: "%.1f×", $0) }
                    TuningSlider(title: "Intensity", value: tune(\.intensity), range: 0...1, tint: hue, text: Self.percent)
                    TuningSlider(title: "Scale", value: tune(\.scale), range: 0.6...1.8, tint: hue) { String(format: "%.2f×", $0) }
                    TuningSlider(title: "Grain", value: tune(\.grain), range: 0...1, tint: hue, text: Self.percent)
                    TuningSlider(title: "Dim for Legibility", value: tune(\.dim), range: 0...0.7, tint: hue, text: Self.percent)
                }
            }
            .animation(DS.Motion.arrive, value: editing)
        }
    }

    private var timeRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SettingRow(title: "Time of Day", detail: "Drag to see other hours; let go to return.", symbol: "clock.arrow.circlepath",
                       density: .compact) {
                Text(DayLight.text(hour)).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
            }
            .help("Wallpapers set to Clock follow the hour.")
            LuxSlider(value: Binding(get: { hour }, set: { hour = $0; wallpaper.previewHour = $0 }), range: 0...23.98,
                      label: "Time of Day", tint: DS.Spectrum.light) {
                wallpaper.previewHour = nil
                withAnimation(DS.Motion.arrive) { hour = DayLight.hourNow }
            }
            .padding(.bottom, DS.Space.s)
        }
    }

    // MARK: Schedule and displays

    private var scheduleGroup: some View {
        RowGroup {
            SettingRow(title: "Change with the Day", detail: "One wallpaper by day, another by night.",
                       symbol: "sun.and.horizon", density: .compact) {
                LuxSwitch(isOn: $wallpaper.scheduled, label: "Change with the Day", tint: hue)
            }
            .help("Picking one by hand holds until the light next changes.")
            .stagePreview(.demo("live.day", "Change with the Day", isOn: wallpaper.scheduled, region: StageRegion.desktop, Demos.changeWithDay))
            if wallpaper.scheduled {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    SettingRow(title: "By Day", detail: "From \(DayLight.text(wallpaper.dayBegins))", symbol: "sun.max", density: .compact) {
                        ShaderMenu(selection: wallpaper.dayShader) { wallpaper.dayShader = $0 }
                    }
                    LuxSlider(value: hourBinding(\.dayBegins), range: 4...12, label: "Day begins", tint: DS.Spectrum.light)
                        .padding(.bottom, DS.Space.s)
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    SettingRow(title: "By Night", detail: "From \(DayLight.text(wallpaper.nightBegins))", symbol: "moon", density: .compact) {
                        ShaderMenu(selection: wallpaper.nightShader) { wallpaper.nightShader = $0 }
                    }
                    LuxSlider(value: hourBinding(\.nightBegins), range: 16...23.5, label: "Night begins", tint: DS.Spectrum.light)
                        .padding(.bottom, DS.Space.s)
                }
            }
        }
        .animation(DS.Motion.reveal, value: wallpaper.scheduled)
    }

    /// Hours on the quarter.
    private func hourBinding(_ key: ReferenceWritableKeyPath<LiveWallpaper, Double>) -> Binding<Double> {
        Binding(get: { LiveWallpaper.shared[keyPath: key] },
                set: { LiveWallpaper.shared[keyPath: key] = ($0 * 4).rounded() / 4 })
    }

    private var displaysGroup: some View {
        RowGroup {
            SettingRow(title: "Same on Every Display", detail: "Off, each display can show its own wallpaper.",
                       symbol: "display.2", density: .compact) {
                LuxSwitch(isOn: Binding(get: { !wallpaper.perDisplay }, set: { wallpaper.perDisplay = !$0 }),
                          label: "Same on Every Display", tint: hue)
            }
            .stagePreview(.demo("live.same", "Same on Every Display", isOn: !wallpaper.perDisplay, region: StageRegion.desktop, Demos.sameEveryDisplay))
            if wallpaper.perDisplay {
                ForEach(screens.compactMap { screen in screen.displayID.map { (screen, $0) } }, id: \.1) { screen, id in
                    SettingRow(title: screen.localizedName, symbol: "display", density: .compact) {
                        ShaderMenu(selection: wallpaper.shader(forDisplay: id)) { wallpaper.setShader($0, forDisplay: id) }
                    }
                }
            }
        }
        .animation(DS.Motion.reveal, value: wallpaper.perDisplay)
    }
}

/// The hero's plate: the wallpaper itself. One still frame at rest; it runs at full rate while the
/// pointer is on the plate or on a gallery card, so the peek is seen moving.
private struct LiveWallpaperPlate: View {
    let shader: LivingShader
    let peeking: Bool

    var body: some View {
        HeroLife { live in
            ZStack(alignment: .bottomLeading) {
                LivingPreview(shader: shader, running: live || peeking)
                    .allowsHitTesting(false)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shader.title).font(DS.title).foregroundStyle(.white)
                        .contentTransition(.opacity)
                    Text(shader.blurb).font(DS.caption).foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 330, alignment: .leading)
                .padding(DS.Space.m)
            }
        }
    }
}

/// The way back, at the top of both wallpaper chapters: one button that shows the owner's own picture.
struct OriginalWallpaperCard: View {
    @ObservedObject private var live = LiveWallpaper.shared
    @ObservedObject private var still = StillBackground.shared
    @ObservedObject private var effects = Effects.shared
    @ObservedObject private var web = WebWallpaper.shared
    @State private var thumbnail: NSImage?

    private var covering: String? {
        if web.enabled { return "Website Wallpaper is showing above it." }
        if live.enabled { return "Live Wallpaper is showing above it." }
        if still.enabled { return "Still Background is showing above it." }
        if effects.living != nil { return "A generated wallpaper is set in its place. Yours is kept." }
        // A photo from the Wallpaper library counts too: it replaced the owner's own.
        if effects.replacedWallpaper { return "A picture from Atelier is set in its place. Yours is kept." }
        return nil
    }

    var body: some View {
        Card(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.m) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                        }
                    }
                    .frame(width: 72, height: 46)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Wallpaper").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        Text(covering ?? "Showing now.")
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        withAnimation(DS.Motion.settle) { live.showOriginal() }
                    } label: {
                        Label("Restore Original", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(covering == nil ? DS.Ink.tertiary : DS.Ink.primary)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(covering == nil ? DS.Ink.fill : DS.Ink.fillStrong, in: Capsule())
                            .fixedSize()
                    }
                    .buttonStyle(Pressable(scale: 0.95))
                    .disabled(covering == nil)
                    .accessibilityLabel("Restore Original Wallpaper")
                }
                if let notice = effects.notice {
                    Text(notice).font(DS.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { if thumbnail == nil { thumbnail = Self.original() } }
        .onChange(of: covering) { thumbnail = Self.original() }
    }

    /// The owner's own picture, the one Restore puts back; the current one when nothing replaced it.
    private static func original() -> NSImage? {
        if Effects.shared.replacedWallpaper, let url = Effects.shared.originalWallpaperURL,
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240,
           ] as CFDictionary) {
            return NSImage(cgImage: image, size: .zero)
        }
        return Wallpaper.image()
    }
}
