#if DEBUG
import AppKit
import AVFoundation
import DockCore
import SwiftUI

/// `DockStacks --render-packs <packs folder> <out folder>` (debug builds): every pack in the
/// folder read and checked by the same rules as an install, then its preview drawn to a PNG, plus
/// the Browse filter chips and a frame sheet of each effect's mesh. Nothing is installed, chosen
/// or written outside the out folder.
@MainActor
enum ModPacksRenders {
    static func run(packs: URL, into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: packs, includingPropertiesForKeys: nil)) ?? [])
            .filter { ModPackKind.of(extension: $0.pathExtension) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var kind: ModKind? = .icons
        save(AnyView(PackKindFilter(kind: Binding(get: { kind }, set: { kind = $0 })).frame(width: 640, alignment: .leading)),
             name: "filter", into: folder)
        for url in urls {
            switch ModPackDisk.load(url) {
            case .failure(let error):
                print("invalid \(url.lastPathComponent): \(error.description)")
            case .success(let (pack, report)):
                let installed = InstalledPack(pack: pack, bundle: url, warnings: report.warnings)
                let view = VStack(alignment: .leading, spacing: 12) {
                    Text("\(pack.header.name) · \(pack.kind.title)").font(DS.title).foregroundStyle(DS.Ink.primary)
                    PackPreview(pack: installed)
                }
                save(AnyView(view.frame(width: 640, alignment: .leading)), name: pack.kind.rawValue, into: folder)
                if case .effects(let effects) = pack {
                    for effect in effects.effects { sheet(effect, into: folder) }
                }
                if case .sounds(let sounds) = pack, let format = AVAudioFormat(standardFormatWithSampleRate: TypingSynth.sampleRate, channels: 1) {
                    // Typing Sounds' path: each key sound decoded into the engine's format.
                    for slot in TypingSlot.allCases {
                        let frames = sounds.variants(slot).map { SoundPackRuntime.decode(url.appendingPathComponent($0), into: format)?.frameLength ?? 0 }
                        print("typing \(slot.rawValue): \(frames.map(String.init).joined(separator: ", ")) frames at 48 kHz mono")
                    }
                }
                if case .shader(let shader) = pack {
                    if let still = ShaderPackRuntime.still(shader, width: 640, height: 400, time: 30) {
                        write(NSImage(cgImage: still, size: NSSize(width: 640, height: 400)), to: folder.appendingPathComponent("packs-shader-still.png"))
                    } else {
                        print("no Metal engine for the shader still")
                    }
                }
            }
        }
    }

    private static func save(_ view: AnyView, name: String, into folder: URL) {
        let content = view.padding(20).background(Color(red: 0.07, green: 0.075, blue: 0.1)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage else { print("failed: \(name)"); return }
        write(image, to: folder.appendingPathComponent("packs-\(name).png"))
    }

    /// Five frames of an effect's mesh, as triangles, window to tile.
    private static func sheet(_ effect: PackMinimizeEffect, into folder: URL) {
        let frame = CGSize(width: 260, height: 200), count = 5
        let image = NSImage(size: NSSize(width: frame.width * Double(count), height: frame.height), flipped: false) { _ in
            NSColor(red: 0.07, green: 0.075, blue: 0.1, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: frame.width * Double(count), height: frame.height).fill()
            for i in 0..<count {
                let p = Double(i) / Double(count - 1), dx = frame.width * Double(i)
                let g = MinimizeGeometry(window: CGRect(x: dx + 40, y: 70, width: 170, height: 110),
                                         tile: CGRect(x: dx + 200, y: 8, width: 30, height: 30), edge: .bottom)
                NSColor.white.withAlphaComponent(0.25).setStroke()
                NSBezierPath(roundedRect: g.tile, xRadius: 6, yRadius: 6).stroke()
                let mesh = effect.mesh(progress: p, geometry: g)
                for t in stride(from: 0, to: mesh.indices.count, by: 3) {
                    let a = mesh.vertices[Int(mesh.indices[t])], b = mesh.vertices[Int(mesh.indices[t + 1])], c = mesh.vertices[Int(mesh.indices[t + 2])]
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: Double(a.x), y: Double(a.y)))
                    path.line(to: NSPoint(x: Double(b.x), y: Double(b.y)))
                    path.line(to: NSPoint(x: Double(c.x), y: Double(c.y)))
                    path.close()
                    let alpha = Double(a.alpha + b.alpha + c.alpha) / 3
                    NSColor(red: 0.46, green: 0.86, blue: 0.95, alpha: 0.12 + 0.6 * alpha).setFill()
                    path.fill()
                }
                let label = "\(effect.name) \(Int(p * 100))% blur \(String(format: "%.1f", mesh.blur))" as NSString
                label.draw(at: NSPoint(x: dx + 8, y: frame.height - 18), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)])
            }
            return true
        }
        write(image, to: folder.appendingPathComponent("packs-effect-\(effect.id).png"))
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print(url.path)
    }
}
#endif
