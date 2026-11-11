import AppKit
// Banner / social preview with measured alignment.
// usage: banner <icon.png> <wordmark-dark.svg> <metrics.json> <out.png> <width> <height> <tagline>
// Layout rules:
// - icon and text block form one group, centred on the canvas both ways;
// - text block = wordmark (ascender..baseline) + tagline; its vertical centre = the icon's centre;
// - tagline's left edge on the wordmark's left ink edge; gap icon->text = 0.16 of the icon.
let a = CommandLine.arguments
let W = CGFloat(Double(a[5])!), H = CGFloat(Double(a[6])!)
let metrics = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[3]))) as! [String: Double]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func c(_ h: UInt32, _ al: CGFloat = 1) -> CGColor { CGColor(srgbRed: CGFloat(h >> 16) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: al) }
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// sizes
let iconSide = H * 0.60
let iconInk = iconSide * (824.0 / 1024.0)          // the squircle inside the icon's canvas
let wmH = iconInk * 0.30                            // wordmark ascender..baseline
let wmScale = wmH / metrics["baseline"]!
let wmW = metrics["width"]! * wmScale
let font = NSFont(name: "Avenir Next Medium", size: wmH * 0.24) ?? NSFont.systemFont(ofSize: wmH * 0.24, weight: .medium)
let tagGap = wmH * 0.42                             // baseline of wordmark -> cap top of tagline
let blockH = wmH + tagGap + font.capHeight
let gap = iconInk * 0.20
let groupW = iconInk + gap + wmW
let gx = (W - groupW) / 2, cy = H / 2

// background
ctx.setFillColor(c(0x05080F)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let iconCX = gx + iconInk / 2
let g = CGGradient(colorsSpace: cs, colors: [c(0x163A66, 0.85), c(0x05080F, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(g, startCenter: CGPoint(x: iconCX, y: cy), startRadius: 0, endCenter: CGPoint(x: iconCX, y: cy), endRadius: H * 0.95, options: [])
ctx.setStrokeColor(c(0xFFFFFF, 0.022)); ctx.setLineWidth(1)
let step = H / 16
var x = (W / 2).truncatingRemainder(dividingBy: step); while x < W { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)); x += step }
var y = (H / 2).truncatingRemainder(dividingBy: step); while y < H { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += step }
ctx.strokePath()

// icon: its squircle (not its transparent canvas) is what aligns
NSImage(contentsOfFile: a[1])!.draw(in: NSRect(x: iconCX - iconSide / 2, y: cy - iconSide / 2, width: iconSide, height: iconSide))

// text block, centred on the icon's centre line
let blockTop = cy + blockH / 2
let tx = gx + iconInk + gap
let wm = NSImage(contentsOfFile: a[2])!
let wmTotalH = metrics["height"]! * wmScale      // includes the bowl overshoot below the baseline
wm.draw(in: NSRect(x: tx, y: blockTop - wmTotalH, width: wmW, height: wmTotalH))
let baseline = blockTop - wmH
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.49, green: 0.54, blue: 0.63, alpha: 1), .kern: font.pointSize * 0.02]
let tag = NSAttributedString(string: a[7], attributes: attrs)
// draw(at:) puts the line's origin at the bottom of its box: lift by the descender so the baseline lands exactly
let tagBaseline = baseline - tagGap - font.capHeight
tag.draw(at: NSPoint(x: tx + metrics["stroke"]! * 0 * wmScale, y: tagBaseline + font.descender))
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[4]))
print("group \(Int(gx))..\(Int(gx + groupW)) of \(Int(W)); block \(Int(blockTop - blockH))..\(Int(blockTop)) centre \(Int(cy))")
