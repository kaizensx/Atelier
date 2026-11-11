import AppKit
// usage: svg2png in.svg out.png width [bg hex]
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!
let w = CGFloat(Double(a[3])!), h = w * img.size.height / img.size.width
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
if a.count > 4, let v = UInt32(a[4], radix: 16) { NSColor(srgbRed: CGFloat(v >> 16) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill() }
img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
