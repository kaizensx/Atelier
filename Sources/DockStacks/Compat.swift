import AppKit
import DockCore
import SwiftUI

// MARK: - One app, every Mac from Sonoma on
//
// Atelier is open source and runs on macOS 14 Sonoma through the latest release, on Apple
// silicon and Intel. The newest look (Liquid Glass, mesh gradients) arrived in later releases,
// so every surface asks for it through these wrappers: on macOS 26 and later they are the real
// thing, on earlier systems a vibrant material with the same tint and outline stands in, so the
// layout and hierarchy are the same everywhere.

/// Atelier's description of a glass surface, mirroring SwiftUI's `Glass` so call sites read the
/// same (`.regular.tint(…)`, `.clear`, `.interactive()`), without naming a macOS 26 type.
struct AGlass: Equatable {
    enum Base: Equatable { case regular, clear, identity }
    var base: Base
    var tintColor: Color?
    var isInteractive = false

    static let regular = AGlass(base: .regular)
    static let clear = AGlass(base: .clear)
    static let identity = AGlass(base: .identity)

    func tint(_ color: Color?) -> AGlass { var copy = self; copy.tintColor = color; return copy }
    func interactive(_ on: Bool = true) -> AGlass { var copy = self; copy.isInteractive = on; return copy }

    @available(macOS 26, *)
    var native: Glass {
        var glass: Glass = switch base {
        case .regular: .regular
        case .clear: .clear
        case .identity: .identity
        }
        if let tintColor { glass = glass.tint(tintColor) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a tinted vibrant material before it (see `AtelierGlassFallback`).
    @ViewBuilder
    func atelierGlass<S: Shape>(_ glass: AGlass = .regular, in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(glass.native, in: shape)
        } else if glass.base == .identity {
            self
        } else {
            modifier(AtelierGlassFallback(glass: glass, shape: shape))
        }
    }

    /// The default capsule, as `glassEffect()` with no arguments draws.
    func atelierGlass(_ glass: AGlass = .regular) -> some View { atelierGlass(glass, in: Capsule()) }

    /// `.buttonStyle(.glass)` where it exists; before it a bordered capsule, the same silhouette
    /// the glass button has, so a row of them keeps its rhythm on macOS 14 and 15.
    @ViewBuilder
    func atelierGlassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered).buttonBorderShape(.capsule) }
    }
}

/// The stand-in for Liquid Glass on macOS 14 and 15, built to read as a deliberate surface of
/// its own rather than a missing effect:
/// - a SwiftUI material, so the content behind still blurs through (Reduce Transparency turns it
///   opaque by itself);
/// - the tint laid over it, capped in strength: `Glass.tint` on macOS 26 colours the glass but
///   never paints it solid, and a caller's opaque tint must not turn a panel into a flat slab;
/// - a lit top edge fading down the sides, the cue that makes glass read as a raised pane, with a
///   faint dark rim in Light so a pale panel keeps its outline on a pale wallpaper;
/// - for interactive glass, a gentle lift under the pointer in place of the glass's own response.
private struct AtelierGlassFallback<S: Shape>: ViewModifier {
    let glass: AGlass
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    /// The strongest a tint may get over the material.
    private static var tintCeiling: CGFloat { 0.55 }

    private var tint: Color? {
        guard let color = glass.tintColor else { return nil }
        let alpha = NSColor(color).usingColorSpace(.sRGB)?.alphaComponent ?? 1
        return alpha > Self.tintCeiling ? color.opacity(Double(Self.tintCeiling / alpha)) : color
    }

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background {
                ZStack {
                    shape.fill(glass.base == .clear ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))
                    if let tint { shape.fill(tint) }
                    if glass.isInteractive, hover { shape.fill(Color.white.opacity(dark ? 0.06 : 0.12)) }
                }
            }
            .overlay {
                shape.stroke(LinearGradient(colors: [Color.white.opacity(dark ? 0.24 : 0.7), Color.white.opacity(dark ? 0.06 : 0.25)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    .overlay { if !dark { shape.stroke(Color.black.opacity(0.08), lineWidth: 0.5) } }
                    .allowsHitTesting(false)
            }
            .onHover { inside in if glass.isInteractive { hover = inside } }
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Groups glass shapes so they blend on macOS 26+; earlier, the content as it is.
struct AtelierGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// What this Mac is, for features that depend on the release or the chip.
enum MacPlatform {
    static let version = ProcessInfo.processInfo.operatingSystemVersion
    static var major: Int { version.majorVersion }
    static func atLeast(_ major: Int, _ minor: Int = 0) -> Bool {
        version.majorVersion > major || (version.majorVersion == major && version.minorVersion >= minor)
    }

    /// Apple silicon, including an Intel build running under Rosetta.
    static let appleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 { return value == 1 }
        return false
    }()

    /// An Intel build running on Apple silicon through Rosetta 2: Apple-silicon-only private
    /// frameworks are there, but their arm64e-only entry points are not callable from x86_64.
    static let translated: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }()

    /// How the stage should draw the menu bar and Dock for the running release.
    @MainActor static var stageChrome: ShellStageChrome {
        ShellStageChrome.forRelease(major: major, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }

    /// A notch at the top of the built-in display.
    @MainActor static var hasNotch: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }
}

/// A mesh gradient on macOS 15+; before it, a diagonal blend through the mesh's corner and
/// centre colours, which keeps the same mood.
struct AtelierMesh: View {
    let width: Int
    let height: Int
    let points: [SIMD2<Float>]
    let colors: [Color]

    var body: some View {
        if #available(macOS 15, *) {
            MeshGradient(width: width, height: height, points: points, colors: colors)
        } else {
            let picks = [colors.first, colors.indices.contains(colors.count / 2) ? colors[colors.count / 2] : nil, colors.last]
            LinearGradient(colors: picks.compactMap { $0 }, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

extension Color {
    /// `Color.mix` on macOS 15+, AppKit's blend before it.
    func atelierMix(with other: Color, by fraction: Double) -> Color {
        if #available(macOS 15, *) { return mix(with: other, by: fraction) }
        let blended = NSColor(self).usingColorSpace(.sRGB)?.blended(withFraction: fraction, of: NSColor(other).usingColorSpace(.sRGB) ?? .black)
        return blended.map(Color.init(nsColor:)) ?? self
    }
}

/// The pointer shapes Atelier asks for, mapped to SwiftUI's on macOS 15+ and to AppKit cursors
/// pushed on hover before it.
enum APointer: Equatable {
    case `default`, grabIdle, grabActive
    case resize(UnitPoint)

    static func frameResize(position: UnitPoint) -> APointer { .resize(position) }

    var cursor: NSCursor {
        switch self {
        case .default: .arrow
        case .grabIdle: .openHand
        case .grabActive: .closedHand
        case .resize(let point): Self.diagonal(point) ?? .crosshair
        }
    }

    /// AppKit's own diagonal window-resize cursors are not public before macOS 15, but the class
    /// methods behind them have shipped on every release since 10.x. Asked for by name and only
    /// when the class answers, so a release that drops them gets the crosshair instead of a crash.
    private static func diagonal(_ point: UnitPoint) -> NSCursor? {
        let falling = point == .topLeading || point == .bottomTrailing
        let selector = NSSelectorFromString(falling ? "_windowResizeNorthWestSouthEastCursor" : "_windowResizeNorthEastSouthWestCursor")
        guard NSCursor.responds(to: selector) else { return nil }
        return (NSCursor.perform(selector)?.takeUnretainedValue()) as? NSCursor
    }

    @available(macOS 15, *)
    var native: PointerStyle {
        switch self {
        case .default: .default
        case .grabIdle: .grabIdle
        case .grabActive: .grabActive
        case .resize(let point):
            .frameResize(position: point == .bottomTrailing ? .bottomTrailing : point == .topLeading ? .topLeading
                         : point == .topTrailing ? .topTrailing : .bottomLeading)
        }
    }
}

extension View {
    @ViewBuilder
    func atelierPointer(_ pointer: APointer) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(pointer.native)
        } else {
            modifier(AtelierCursorFallback(pointer: pointer))
        }
    }

    /// A little wiggle to say "look here"; a bounce where wiggle does not exist yet.
    @ViewBuilder
    func atelierWiggle() -> some View {
        if #available(macOS 15, *) {
            symbolEffect(.wiggle, options: .repeat(3))
        } else {
            modifier(AtelierBounceFallback())
        }
    }
}

/// AppKit cursors keep a stack: every push needs exactly one pop. A plain `onHover` pops on exit
/// only, so a view that disappears under the pointer (a sheet closing, a row scrolling away) would
/// leave its cursor stuck for the rest of the session. This remembers its own push and pops it
/// however the hover ends.
private struct AtelierCursorFallback: ViewModifier {
    let pointer: APointer
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed { pointer.cursor.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

/// A discrete symbol effect plays when its value changes, so the bounce needs a value that
/// changes once the symbol is on screen; a constant would never play.
private struct AtelierBounceFallback: ViewModifier {
    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, options: .repeat(3), value: trigger)
            .onAppear { trigger += 1 }
    }
}

// MARK: - Whether a feature works on this Mac

/// Every feature answers this before it shows its controls, so a Mac that cannot do something
/// says so plainly ("Needs macOS 15", "Needs a Force Touch trackpad") instead of failing quietly.
enum FeatureAvailability: Equatable, Sendable {
    case available
    /// Works, with a limit worth knowing ("Brightness keys keep Apple's overlay on this Mac").
    case limited(String)
    /// Cannot work here; the reason is shown to the person, in a few words.
    case unavailable(String)

    var isUsable: Bool { if case .unavailable = self { return false } else { return true } }
    var note: String? {
        switch self {
        case .available: nil
        case .limited(let text), .unavailable(let text): text
        }
    }

    static func needsMacOS(_ major: Int, _ minor: Int = 0) -> FeatureAvailability {
        MacPlatform.atLeast(major, minor) ? .available
            : .unavailable("Needs macOS \(major)\(minor > 0 ? ".\(minor)" : "") or later")
    }

    static var needsAppleSilicon: FeatureAvailability {
        MacPlatform.appleSilicon ? .available : .unavailable("Needs a Mac with Apple silicon")
    }
}

/// A one-line badge for a card that is limited or unavailable on this Mac.
struct AvailabilityNote: View {
    let availability: FeatureAvailability

    var body: some View {
        if let note = availability.note {
            HStack(spacing: 6) {
                Image(systemName: availability.isUsable ? "info.circle" : "nosign")
                    .font(.system(size: 11, weight: .semibold))
                Text(note).font(DS.caption)
            }
            .foregroundStyle(availability.isUsable ? DS.Ink.secondary : Color.orange.opacity(0.95))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((availability.isUsable ? DS.Ink.fill : Color.orange.opacity(0.12)), in: .capsule)
            .accessibilityElement(children: .combine)
        }
    }
}
