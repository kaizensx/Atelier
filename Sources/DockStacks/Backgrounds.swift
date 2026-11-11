import AppKit
import CoreGraphics
import simd
import SwiftUI

// MARK: - Palettes

/// Four stops a shader's light is mapped onto: deep, shadow, body, crest. Display P3 values,
/// written to the drawable as they are, like every colour in Living.metal.
struct LivingPalette: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let stops: [SIMD3<Float>]

    static let natural = "natural"
    static let wallpaper = "wallpaper"

    static let presets: [LivingPalette] = [
        LivingPalette(id: "midnight", title: "Midnight", stops: [[0.010, 0.012, 0.040], [0.060, 0.080, 0.260], [0.220, 0.380, 0.850], [0.800, 0.900, 1.000]]),
        LivingPalette(id: "ember", title: "Ember", stops: [[0.030, 0.008, 0.004], [0.320, 0.050, 0.020], [0.950, 0.360, 0.080], [1.000, 0.860, 0.550]]),
        LivingPalette(id: "lagoon", title: "Lagoon", stops: [[0.004, 0.030, 0.040], [0.020, 0.200, 0.260], [0.100, 0.660, 0.700], [0.780, 1.000, 0.920]]),
        LivingPalette(id: "orchid", title: "Orchid", stops: [[0.030, 0.005, 0.040], [0.280, 0.050, 0.360], [0.860, 0.300, 0.780], [1.000, 0.840, 0.960]]),
        LivingPalette(id: "glacier", title: "Glacier", stops: [[0.030, 0.040, 0.060], [0.220, 0.300, 0.400], [0.620, 0.760, 0.880], [0.970, 0.990, 1.000]]),
        LivingPalette(id: "forest", title: "Forest", stops: [[0.008, 0.025, 0.012], [0.060, 0.200, 0.100], [0.360, 0.620, 0.300], [0.900, 0.960, 0.700]]),
        LivingPalette(id: "dune", title: "Dune", stops: [[0.050, 0.030, 0.020], [0.360, 0.200, 0.120], [0.820, 0.580, 0.380], [1.000, 0.930, 0.800]]),
        LivingPalette(id: "graphite", title: "Graphite", stops: [[0.010, 0.010, 0.012], [0.140, 0.140, 0.150], [0.520, 0.520, 0.540], [0.960, 0.960, 0.970]]),
    ]

    static func preset(_ id: String) -> LivingPalette? { presets.first { $0.id == id } }

    static func title(_ id: String) -> String {
        switch id {
        case natural: "Original"
        case wallpaper: "From Wallpaper"
        default: preset(id)?.title ?? "Original"
        }
    }

    static func color(_ stop: SIMD3<Float>) -> Color {
        Color(.displayP3, red: Double(stop.x), green: Double(stop.y), blue: Double(stop.z))
    }
}

/// Reads a palette out of a picture: four clusters of colour, ordered dark to light, then
/// pushed apart so they make a ramp a shader can live on. Pure CoreGraphics, any thread.
enum PaletteSampler {
    static func stops(from image: CGImage) -> [SIMD3<Float>]? {
        let width = 48, height = 30
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            pixels.append(SIMD3(Float(bytes[index]), Float(bytes[index + 1]), Float(bytes[index + 2])) / 255)
        }
        return stops(from: pixels)
    }

    static func luma(_ c: SIMD3<Float>) -> Float { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }

    static func chroma(_ c: SIMD3<Float>) -> Float { c.max() - c.min() }

    static func stops(from pixels: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        guard pixels.count >= 12 else { return nil }
        // k-means with six clusters, seeded along the luminance range so the result is the same every time.
        let k = 6
        let sorted = pixels.sorted { luma($0) < luma($1) }
        var centres = (0..<k).map { sorted[min(sorted.count - 1, sorted.count * (2 * $0 + 1) / (2 * k))] }
        var counts = [Int](repeating: 0, count: k)
        for _ in 0..<8 {
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            counts = [Int](repeating: 0, count: k)
            for pixel in pixels {
                var best = 0, bestDistance = Float.greatestFiniteMagnitude
                for (index, centre) in centres.enumerated() {
                    let d = pixel - centre
                    let distance = (d * d).sum()
                    if distance < bestDistance { bestDistance = distance; best = index }
                }
                sums[best] += pixel
                counts[best] += 1
            }
            for index in 0..<k where counts[index] > 0 { centres[index] = sums[index] / Float(counts[index]) }
        }
        // The darkest and the lightest frame the ramp. Between them, the two most colourful clusters
        // that cover at least a few percent of the picture: a small vivid accent beats a large grey.
        let used = (0..<k).filter { counts[$0] > 0 }.sorted { luma(centres[$0]) < luma(centres[$1]) }
        guard used.count >= 2 else { return nil }
        let middle = used.dropFirst().dropLast()
            .filter { counts[$0] * 25 >= pixels.count }
            .sorted { chroma(centres[$0]) > chroma(centres[$1]) }
            .prefix(2)
        var picked = [used.first!] + middle.sorted { luma(centres[$0]) < luma(centres[$1]) } + [used.last!]
        while picked.count < 4 { picked.insert(picked[picked.count / 2], at: picked.count / 2) }
        let chosen = picked.map { centres[$0] }

        // Keep each colour's hue, make it richer than the photo, give it the light its place in the ramp needs.
        // Each stop keeps the photo's own light within a band, so a bright orange stays orange, not brown.
        let bands: [ClosedRange<Float>] = [0.015...0.03, 0.09...0.20, 0.30...0.52, 0.72...0.88]
        return zip(chosen, bands).map { colour, band in
            let l = max(luma(colour), 0.004)
            let target = min(max(l, band.lowerBound), band.upperBound)
            let grey = SIMD3<Float>(repeating: l)
            let c0 = chroma(colour)
            let richer: Float = c0 > 0.03 ? min(max(0.36 / c0, 1.4), 2.4) : 1
            var c = simd_max(grey + (colour - grey) * richer, .zero)
            c *= target / max(luma(c), 0.004)
            let peak = c.max()
            if peak > 1 {
                // Too bright to hold the hue: lean toward white instead of clipping one channel.
                let t = min((peak - 1) / peak, 1)
                c = c / peak + (SIMD3<Float>(repeating: 1) - c / peak) * t
            }
            return simd_min(simd_max(c, .zero), SIMD3<Float>(repeating: 1))
        }
    }
}

// MARK: - Still background

/// A gradient mesh painted once by the GPU and held in the desktop layer: the look of a live
/// wallpaper at no running cost. Like the live one, it never reads or writes the wallpaper setting.
@MainActor
final class StillBackground: ObservableObject {
    static let shared = StillBackground()

    enum Mood: String, CaseIterable {
        case day, dusk, night
        var title: String {
            switch self {
            case .day: "Day"
            case .dusk: "Dusk"
            case .night: "Night"
            }
        }
        var hour: Double {
            switch self {
            case .day: 13
            case .dusk: 19.2
            case .night: 23
            }
        }
    }

    private let store = UserDefaults.standard
    @Published var enabled: Bool {
        didSet {
            store.set(enabled, forKey: "stillBackground")
            if enabled, LiveWallpaper.shared.enabled { LiveWallpaper.shared.enabled = false }
            apply()
        }
    }
    @Published var palette: String { didSet { store.set(palette, forKey: "stillPalette"); repaint() } }
    @Published var mood: Mood { didSet { store.set(mood.rawValue, forKey: "stillMood"); repaint() } }
    @Published var seed: Double { didSet { store.set(seed, forKey: "stillSeed"); repaint() } }
    @Published var grain: Double { didSet { store.set(grain, forKey: "stillGrain"); repaint() } }
    /// The painting for the main display, for previews.
    @Published private(set) var image: CGImage?

    private var panels: [CGDirectDisplayID: FloatingPanel] = [:]
    private var started = false
    private var pending = false

    private init() {
        enabled = store.bool(forKey: "stillBackground")
        palette = store.string(forKey: "stillPalette") ?? "orchid"
        mood = Mood(rawValue: store.string(forKey: "stillMood") ?? "") ?? .night
        seed = store.object(forKey: "stillSeed") as? Double ?? 3.7
        grain = store.object(forKey: "stillGrain") as? Double ?? 0.3
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StillBackground.shared.apply() }
        }
        apply()
    }

    func shuffle() { seed = Double.random(in: 0..<400).rounded(toPlaces: 2) }

    /// Paints the preview if nothing has been painted yet.
    func prepare() { if image == nil { repaint() } }

    /// The tuning the painting is made with: Gradient Mesh, frozen.
    private var tuning: LivingTuning {
        var tuning = LivingTuning()
        tuning.palette = palette
        tuning.grain = grain
        tuning.cycle = .clock
        return tuning
    }

    /// Renders at half the backing scale: the mesh has no detail finer than that, and it stays a quarter of the memory.
    func render(width: Int, height: Int) -> CGImage? {
        LivingEngine.shared?.snapshot(.gradientMesh, width: width, height: height, hour: mood.hour,
                                      time: seed * 37, tuning: tuning, seed: Float(seed))
    }

    /// Several changes in one turn of the run loop paint once.
    private func repaint() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let still = StillBackground.shared
                still.pending = false
                still.paint()
            }
        }
    }

    private func paint() {
        let main = NSScreen.screens.first
        if let main {
            let scale = main.backingScaleFactor * 0.5
            image = render(width: Int(main.frame.width * scale), height: Int(main.frame.height * scale))
        }
        guard enabled else { return }
        for (id, panel) in panels {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { continue }
            let picture = screen == main ? image : render(width: Int(screen.frame.width * screen.backingScaleFactor * 0.5),
                                                        height: Int(screen.frame.height * screen.backingScaleFactor * 0.5))
            let layer = panel.contentView?.layer
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            layer?.contents = picture
            CATransaction.commit()
        }
    }

    private func apply() {
        guard started else { return }
        guard enabled, LivingEngine.shared != nil else {
            for panel in panels.values {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.5
                    panel.animator().alphaValue = 0
                }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
            }
            panels = [:]
            return
        }
        let screens = Dictionary(NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen) } },
                                 uniquingKeysWith: { first, _ in first })
        for (id, panel) in panels where screens[id] == nil {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for (id, screen) in screens {
            if let panel = panels[id] {
                panel.setFrame(screen.frame, display: false)
                continue
            }
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspectFill
            view.layer?.backgroundColor = NSColor.black.cgColor
            let panel = FloatingPanel(frame: screen.frame)
            // The same level as the live wallpaper: above the system wallpaper, below Finder's icons.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.8
                panel.animator().alphaValue = 1
            }
            panels[id] = panel
        }
        repaint()
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

// MARK: - Controls

/// One swatch per palette, plus the shader's own colour and the wallpaper's.
struct PaletteRow: View {
    @Binding var selection: String
    let wallpaperStops: [SIMD3<Float>]?
    var natural: [Color] = [Color(white: 0.12), Color(white: 0.4), Color(white: 0.85)]
    let sampleWallpaper: () -> Void
    @State private var hovered: String?

    private let columns = [GridItem(.adaptive(minimum: 32, maximum: 36), spacing: DS.Space.s)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("Palette").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                Spacer()
                Text(LivingPalette.title(hovered ?? selection)).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .contentTransition(.opacity)
                    .animation(DS.Motion.hover, value: hovered)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Space.s) {
                swatch(LivingPalette.natural, colors: natural, symbol: "sparkles")
                ForEach(LivingPalette.presets) { palette in
                    swatch(palette.id, colors: palette.stops.dropFirst().map(LivingPalette.color))
                }
                swatch(LivingPalette.wallpaper,
                       colors: (wallpaperStops ?? []).dropFirst().map(LivingPalette.color),
                       symbol: wallpaperStops == nil ? "photo" : nil)
            }
        }
    }

    private func swatch(_ id: String, colors: [Color], symbol: String? = nil) -> some View {
        let selected = selection == id
        return Button {
            if id == LivingPalette.wallpaper { sampleWallpaper() }
            withAnimation(DS.Motion.settle) { selection = id }
        } label: {
            ZStack {
                Circle().fill(colors.count > 1
                              ? AnyShapeStyle(LinearGradient(colors: colors, startPoint: .bottomLeading, endPoint: .topTrailing))
                              : AnyShapeStyle(DS.Ink.fillStrong))
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 26, height: 26)
            .padding(3)
            // Selection rings in the desktop's light; hover is only a faint ring, nothing grows.
            .overlay {
                Circle().strokeBorder(selected ? DS.Spectrum.surfaces : .white.opacity(hovered == id ? 0.3 : 0),
                                      lineWidth: selected ? 2 : 1)
            }
            .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5).padding(3) }
            .animation(DS.Motion.hover, value: hovered)
        }
        .buttonStyle(Pressable(scale: 0.9))
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .accessibilityLabel(LivingPalette.title(id))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Still Background, as a hero: the painting itself is the plate.
struct StillBackgroundCard: View {
    @ObservedObject private var still = StillBackground.shared
    @ObservedObject private var live = LiveWallpaper.shared
    private let hue = DS.Spectrum.surfaces

    /// Without Metal nothing can be painted: the switch only turns it off.
    private var enabled: Binding<Bool> {
        Binding(get: { still.enabled },
                set: { on in if !on || DesktopAvailability.metal.isUsable { still.enabled = on } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HeroCard("Still Background",
                     pitch: "A gradient painted once and held above your wallpaper. It costs nothing while it shows.",
                     isOn: enabled, hue: hue, readout: "0 fps", readoutCaption: "Running cost",
                     preview: .toggle("still.on", "Still Background", isOn: still.enabled, region: StageRegion.desktop) { $0.stillOn.toggle() }) {
                StillBackgroundPlate(image: still.image, mood: still.mood.title)
            } controls: {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(spacing: DS.Space.m) {
                        Segments(selection: $still.mood, options: StillBackground.Mood.allCases.map { ($0, $0.title) })
                        Button {
                            withAnimation(DS.Motion.arrive) { still.shuffle() }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Ink.primary)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(DS.Ink.fillStrong, in: Capsule())
                                .fixedSize()
                        }
                        .buttonStyle(Pressable(scale: 0.95))
                    }
                    PaletteRow(selection: $still.palette, wallpaperStops: live.wallpaperStops,
                               natural: [Color(red: 0.36, green: 0.1, blue: 0.62), Color(red: 0.0, green: 0.38, blue: 0.5),
                                         Color(red: 0.86, green: 0.1, blue: 0.46)]) {
                        live.sampleWallpaper()
                    }
                    TuningSlider(title: "Grain", value: $still.grain, range: 0...1, tint: hue) { "\(Int(($0 * 100).rounded()))%" }
                        .stagePreview(.demo("bg.grain", "Grain", isOn: false, region: StageRegion.desktop, Demos.grain))
                }
            }
            AvailabilityNote(availability: DesktopAvailability.metal)
        }
        .onAppear { still.prepare() }
    }
}

/// The painting at plate size. It is a still by nature, so under the pointer it only drifts,
/// slowly, as a camera would over a print: a transform, never a repaint.
private struct StillBackgroundPlate: View {
    let image: CGImage?
    let mood: String

    var body: some View {
        HeroLife { live in
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        DS.Ink.fill
                    }
                }
                .scaleEffect(live ? 1.08 : 1)
                .animation(live ? .easeOut(duration: 6) : DS.Motion.arrive, value: live)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                Text(mood).font(DS.title).foregroundStyle(.white).padding(DS.Space.m)
            }
        }
    }
}
