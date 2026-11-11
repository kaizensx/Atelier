import Foundation

// MARK: - Which Atelier Dock tile bounces, the pure part
//
// The Atelier Dock learns that an app asks for attention by reading the hidden macOS Dock's
// tiles through Accessibility: a tile off the line the others rest on is being bounced. Two
// things made that fan out to several tiles:
//
// - With auto-hide on, the macOS Dock slides in when an app asks for attention. A read made
//   while it moves catches each tile at a different point of the slide, so many tiles look
//   "off the line". A real bounce lifts one tile, two at the most, and only away from the edge.
// - Launches bounce in the macOS Dock too, and are not a request for attention.

public enum OwnDockBounce {
    /// Whether attention requests can be seen at all on this macOS. From macOS 27 the Dock draws
    /// every tile in one full-screen window: a bouncing tile's Accessibility frame no longer
    /// moves, and LaunchServices carries no sign of the request either. So on 27 and later the
    /// Atelier Dock cannot bounce for attention, and says so; badges still read.
    public static func attentionReadable(osMajor: Int) -> Bool { osMajor < 27 }

    /// The most tiles that can be bouncing at once before a reading is taken for the whole Dock
    /// moving (sliding in or out, or still settling) rather than for bounces.
    public static func most(of count: Int) -> Int { max(2, count / 6) }

    /// Tiles lifted more than `threshold` points off the line most tiles rest on, away from the
    /// screen edge. `base` is the side of each tile that rests on the edge, in Accessibility
    /// coordinates (top-left origin): maxY at the bottom, minX on the left, maxX on the right.
    /// Empty when too many tiles are off the line: the Dock itself is moving.
    public static func bouncing(_ bases: [(path: String, base: Double)], orientation: String,
                                threshold: Double = 3) -> Set<String> {
        guard bases.count >= 3 else { return [] }
        let sorted = bases.map(\.base).sorted()
        let rest = sorted[sorted.count / 2]
        let lifted = bases.filter { tile in
            // How far the tile is from the edge it rests on, past the rest line.
            let lift: Double = switch orientation {
            case "left": tile.base - rest
            case "right": rest - tile.base
            default: rest - tile.base
            }
            return lift > threshold
        }
        guard lifted.count <= most(of: bases.count) else { return [] }
        return Set(lifted.map(\.path))
    }

    /// The apps that ask for attention after a new reading. `previous` maps each to when it was
    /// last seen bouncing. An app in front has its answer; one launched in the last `launchGrace`
    /// seconds, or still opening from the Atelier Dock, bounces for its launch, not for attention.
    /// A request not seen for `linger` seconds is over.
    public static func attention(previous: [String: Date], bouncing: Set<String>, front: String?,
                                 launched: [String: Date], opening: Set<String>, now: Date,
                                 launchGrace: Double = 8, linger: Double = 12) -> [String: Date] {
        var next = previous
        for path in bouncing where path != front {
            if let at = launched[path], now.timeIntervalSince(at) < launchGrace { continue }
            if opening.contains(path) { continue }
            next[path] = now
        }
        return next.filter { now.timeIntervalSince($0.value) < linger && $0.key != front }
    }

    /// Paths in `keys` that name the same app as `path` once both are resolved, for clearing
    /// a launch that was keyed by the tile's own path (a symlink, or /Applications/Safari.app
    /// for the Cryptex copy macOS really runs).
    public static func sameApp(_ keys: some Sequence<String>, as path: String, resolve: (String) -> String) -> [String] {
        let target = resolve(path)
        return keys.filter { $0 == path || resolve($0) == target }
    }
}
