import AppKit
import CoreText
import SwiftUI

// Every picture Orbit shows, drawn once into bitmaps so a frame only moves them.

/// Icons are drawn once off the main thread so the entrance never waits on the disk.
@MainActor
final class OrbitIconStore {
    static let shared = OrbitIconStore()
    /// Pixels on a side. Large enough for the biggest icon size at 2x.
    nonisolated static let side = 192
    private var images: [String: CGImage] = [:]
    private(set) var hues: [String: OrbitRGB] = [:]
    private var pending = Set<String>()
    /// Called on the main actor when icons that were missing arrive.
    var arrived: (() -> Void)?

    private init() {
        // An icon chosen in Atelier (Orbit's app list, the Launcher, Folder & App Icons) replaces
        // the drawn one: forget it and draw it again, off the main thread like the rest.
        // Posted on the main thread, and handled there at once (no queue), before views redraw.
        NotificationCenter.default.addObserver(forName: .atelierIconChanged, object: nil, queue: nil) { note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated { OrbitIconStore.shared.forget(path) }
        }
    }

    func forget(_ path: String) {
        guard images[path] != nil || hues[path] != nil else { return }
        images[path] = nil
        hues[path] = nil
        request([path])
    }

    /// For SwiftUI surfaces. Draws synchronously on a miss, as before.
    func image(_ path: String) -> Image {
        if let cached = images[path] { return Image(decorative: cached, scale: 2) }
        guard let drawn = Self.render(path) else { return Image(nsImage: NSWorkspace.shared.icon(forFile: path)) }
        images[path] = drawn.image
        hues[path] = drawn.hue
        return Image(decorative: drawn.image, scale: 2)
    }

    /// A bitmap for drawing, drawn now on a miss.
    func picture(_ path: String) -> CGImage? {
        if let cached = images[path] { return cached }
        guard let drawn = Self.render(path) else { return nil }
        images[path] = drawn.image
        hues[path] = drawn.hue
        return drawn.image
    }

    /// For layers. Never blocks: a miss is fetched in the background and announced through `arrived`.
    func cached(_ path: String) -> CGImage? {
        if let cached = images[path] { return cached }
        request([path])
        return nil
    }

    func store(_ drawn: [String: (image: CGImage, hue: OrbitRGB)]) {
        for (path, value) in drawn {
            images[path] = value.image
            hues[path] = value.hue
        }
    }

    func missing(_ paths: [String]) -> [String] { paths.filter { images[$0] == nil } }

    func request(_ paths: [String]) {
        let fresh = paths.filter { images[$0] == nil && !pending.contains($0) && !$0.isEmpty }
        guard !fresh.isEmpty else { return }
        pending.formUnion(fresh)
        Task.detached(priority: .userInitiated) {
            var drawn: [String: (image: CGImage, hue: OrbitRGB)] = [:]
            for path in fresh { if let value = OrbitIconStore.render(path) { drawn[path] = value } }
            await MainActor.run { [drawn] in
                let store = OrbitIconStore.shared
                store.store(drawn)
                store.pending.subtract(fresh)
                store.arrived?()
            }
        }
    }

    nonisolated static func render(_ path: String) -> (image: CGImage, hue: OrbitRGB)? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // The icon chosen for it in Atelier, else its own.
        (AtelierIcons.override(for: path) ?? NSWorkspace.shared.icon(forFile: path)).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.current = previous
        guard let image = context.makeImage() else { return nil }
        return (image, averageColour(image))
    }

    /// The icon squeezed to 4x4 and averaged, weighted towards saturated pixels.
    nonisolated static func averageColour(_ image: CGImage) -> OrbitRGB {
        var pixels = [UInt8](repeating: 0, count: 64)
        let made = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            return true
        }
        guard made else { return OrbitRGB(0.5, 0.5, 0.5) }
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for index in stride(from: 0, to: 64, by: 4) {
            let a = Double(pixels[index + 3]) / 255
            guard a > 0.1 else { continue }
            let pr = Double(pixels[index]) / 255 / a, pg = Double(pixels[index + 1]) / 255 / a, pb = Double(pixels[index + 2]) / 255 / a
            let w = a * (0.2 + (max(pr, pg, pb) - min(pr, pg, pb)))
            r += pr * w
            g += pg * w
            b += pb * w
            weight += w
        }
        guard weight > 0 else { return OrbitRGB(0.5, 0.5, 0.5) }
        return OrbitRGB(min(r / weight, 1), min(g / weight, 1), min(b / weight, 1))
    }
}

struct OrbitLabelStyle: Hashable, Sendable {
    var font = OrbitLabelFont.system
    var ink = OrbitInk.light
    var width = 108.0

    init(font: OrbitLabelFont = .system, ink: OrbitInk = .light, width: Double = 108) {
        self.font = font
        self.ink = ink
        self.width = width
    }

    init(_ options: OrbitOptions) {
        self.init(font: options.labelFont, ink: options.ink, width: options.iconSize + 46)
    }
}

/// Bitmaps for labels, titles, folders and shadows, kept until the style changes.
@MainActor
enum OrbitArt {
    nonisolated static let scale = 2.0
    private static var labels: [String: CGImage] = [:]
    private static var titles: [String: CGImage] = [:]
    private static var folders: [String: CGImage] = [:]
    private static var cachedShadow: CGImage?

    nonisolated static func font(_ choice: OrbitLabelFont, size: Double, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        switch choice {
        case .system: return base
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .rounded, .serif:
            let design: NSFontDescriptor.SystemDesign = choice == .rounded ? .rounded : .serif
            guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
    }

    nonisolated static func context(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// One line of text, truncated to the style's width, its shadow baked in. Thread safe.
    nonisolated static func renderLabel(_ text: String, style: OrbitLabelStyle) -> CGImage? {
        let font = font(style.font, size: 11.5, weight: .medium)
        let colour = style.ink == .light ? CGColor(gray: 1, alpha: 0.96) : CGColor(gray: 0.08, alpha: 0.9)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let limit = style.width
        var shown = line
        if CTLineGetTypographicBounds(line, nil, nil, nil) > limit {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            shown = CTLineCreateTruncatedLine(line, limit, .end, ellipsis) ?? line
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = min(CTLineGetTypographicBounds(shown, &ascent, &descent, nil), limit)
        let pad = 4.0, height = 18.0
        guard let context = context(Int((width + pad * 2) * scale), Int(height * scale)) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if style.ink == .light {
            context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.55))
        } else {
            context.setShadow(offset: .zero, blur: 2, color: CGColor(gray: 1, alpha: 0.5))
        }
        context.textPosition = CGPoint(x: pad, y: (height - ascent - descent) / 2 + descent)
        CTLineDraw(shown, context)
        return context.makeImage()
    }

    static func label(_ text: String, style: OrbitLabelStyle) -> CGImage? {
        let key = "\(style.font.rawValue)|\(style.ink.rawValue)|\(Int(style.width))|\(text)"
        if let cached = labels[key] { return cached }
        let drawn = renderLabel(text, style: style)
        labels[key] = drawn
        return drawn
    }

    static func store(labels drawn: [String: CGImage], style: OrbitLabelStyle) {
        for (text, image) in drawn { labels["\(style.font.rawValue)|\(style.ink.rawValue)|\(Int(style.width))|\(text)"] = image }
    }

    static func missingLabels(_ texts: [String], style: OrbitLabelStyle) -> [String] {
        texts.filter { labels["\(style.font.rawValue)|\(style.ink.rawValue)|\(Int(style.width))|\($0)"] == nil }
    }

    /// A page title: the constellation's symbol, its name and a count.
    static func title(_ title: String, symbol: String?, hue: OrbitRGB, count: String, large: Bool, ink: OrbitInk,
                      font choice: OrbitLabelFont) -> CGImage? {
        let key = "\(title)|\(symbol ?? "")|\(hue.r),\(hue.g),\(hue.b)|\(count)|\(large)|\(ink.rawValue)|\(choice.rawValue)"
        if let cached = titles[key] { return cached }
        let size = large ? 34.0 : 26.0
        let main = ink == .light ? CGColor(gray: 1, alpha: 0.96) : CGColor(gray: 0.08, alpha: 0.92)
        let soft = ink == .light ? CGColor(gray: 1, alpha: 0.4) : CGColor(gray: 0.08, alpha: 0.5)
        let titleFont = font(choice, size: size, weight: .semibold)
        let titleLine = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
            .font: titleFont, .foregroundColor: main, .kern: -size * 0.028,
        ]))
        let countLine = CTLineCreateWithAttributedString(NSAttributedString(string: count.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: soft, .kern: 1.4,
        ]))
        let titleWidth = CTLineGetTypographicBounds(titleLine, nil, nil, nil)
        let countWidth = CTLineGetTypographicBounds(countLine, nil, nil, nil)
        let symbolHeight = symbol == nil ? 0.0 : 30.0
        let width = max(titleWidth, countWidth, 40) + 24
        let height = symbolHeight + size * 1.2 + 18 + 8
        guard let context = context(Int(width * scale), Int(height * scale)) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Core Graphics counts up from the bottom.
        var y = 4.0
        context.textPosition = CGPoint(x: (width - countWidth) / 2, y: y)
        CTLineDraw(countLine, context)
        y += 18
        context.textPosition = CGPoint(x: (width - titleWidth) / 2, y: y + size * 0.22)
        CTLineDraw(titleLine, context)
        y += size * 1.2
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .medium).applying(.init(paletteColors: [
                NSColor(srgbRed: hue.r, green: hue.g, blue: hue.b, alpha: 1),
            ]))) {
            let rect = CGRect(x: (width - image.size.width) / 2, y: y + (symbolHeight - image.size.height) / 2,
                              width: image.size.width, height: image.size.height)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 14, color: CGColor(srgbRed: hue.r, green: hue.g, blue: hue.b, alpha: 0.7))
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: rect)
            NSGraphicsContext.current = previous
            context.restoreGState()
        }
        let drawn = context.makeImage()
        if titles.count > 64 { titles.removeAll() }
        titles[key] = drawn
        return drawn
    }

    /// A folder: a pane of glass holding the first few icons.
    static func folder(_ paths: [String], size: Double, highlighted: Bool) -> CGImage? {
        let key = "\(Int(size))|\(highlighted)|" + paths.prefix(9).joined(separator: "|")
        if let cached = folders[key] { return cached }
        let columns = paths.count <= 4 ? 2 : 3
        let gap = size * (columns == 2 ? 0.11 : 0.07)
        let mini = (size - gap * Double(columns + 1)) / Double(columns)
        guard let context = context(Int(size * scale), Int(size * scale)) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let shape = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1),
                           cornerWidth: size * 0.26, cornerHeight: size * 0.26, transform: nil)
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 1, alpha: highlighted ? 0.3 : 0.16))
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
        context.setLineWidth(1)
        context.strokePath()
        context.interpolationQuality = .high
        var complete = true
        for (index, path) in paths.prefix(columns * columns).enumerated() {
            guard let icon = OrbitIconStore.shared.cached(path) else {
                complete = false
                continue
            }
            let x = gap + Double(index % columns) * (mini + gap)
            let top = gap + Double(index / columns) * (mini + gap)
            context.draw(icon, in: CGRect(x: x, y: size - top - mini, width: mini, height: mini))
        }
        let drawn = context.makeImage()
        if folders.count > 64 { folders.removeAll() }
        // A folder still waiting on an icon is drawn again when it arrives.
        if complete { folders[key] = drawn }
        return drawn
    }

    /// A soft shadow shaped like an app icon, shared by every icon on the field.
    static var shadow: CGImage? {
        if let cachedShadow { return cachedShadow }
        let side = 96.0, inset = 18.0
        guard let context = context(Int(side * scale), Int(side * scale)) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        // Draw the shape far off the canvas and keep only its shadow.
        context.setShadow(offset: CGSize(width: 1000, height: -3), blur: 12, color: CGColor(gray: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: rect.offsetBy(dx: -1000, dy: 0), cornerWidth: 14, cornerHeight: 14, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        cachedShadow = context.makeImage()
        return cachedShadow
    }

    static func flush() {
        labels.removeAll()
        titles.removeAll()
        folders.removeAll()
    }
}

extension OrbitRGB {
    var color: Color { Color(red: r, green: g, blue: b) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent))
    }
}
