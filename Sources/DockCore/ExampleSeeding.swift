import Foundation

/// The example themes and plugins that ship inside the app and are copied into the owner's
/// folders. Each is copied once: never over a folder of the same name (the owner's edits stay),
/// and never again after the owner deletes it.
public enum ExampleSeeding {
    /// Bundle folder names to copy now. `bundled` ships in this build, `offered` was copied
    /// before (by name), `present` is in the owner's folder right now.
    public static func toCopy(bundled: [String], offered: Set<String>, present: Set<String>) -> [String] {
        bundled.filter { !offered.contains($0) && !present.contains($0) }.sorted()
    }

    /// Copies the examples in `source` with extension `pathExtension` into `destination`, and
    /// returns the names now offered (copied this time, or found already there).
    @discardableResult
    public static func seed(from source: URL, into destination: URL, pathExtension: String,
                            offered: Set<String>, fileManager: FileManager = .default) -> Set<String> {
        guard let bundled = try? fileManager.contentsOfDirectory(atPath: source.path)
            .filter({ ($0 as NSString).pathExtension == pathExtension }), !bundled.isEmpty else { return offered }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let present = Set((try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? [])
        var result = offered
        for name in bundled where present.contains(name) { result.insert(name) }
        for name in toCopy(bundled: bundled, offered: offered, present: present) {
            let target = destination.appendingPathComponent(name)
            // Copied beside, then moved in, so a half-copied example is never loaded.
            let staging = destination.appendingPathComponent("." + name + ".partial")
            try? fileManager.removeItem(at: staging)
            do {
                try fileManager.copyItem(at: source.appendingPathComponent(name), to: staging)
                try fileManager.moveItem(at: staging, to: target)
                result.insert(name)
            } catch {
                try? fileManager.removeItem(at: staging)
            }
        }
        return result
    }
}
