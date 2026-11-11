import Foundation
import Testing
@testable import DockCore

@Test func examplesAreCopiedOnceAndNeverOverEdits() {
    let bundled = ["a.ateliertheme", "b.ateliertheme", "c.ateliertheme"]
    #expect(ExampleSeeding.toCopy(bundled: bundled, offered: [], present: []) == bundled)
    // b was edited in place, c was deleted after its first copy.
    #expect(ExampleSeeding.toCopy(bundled: bundled, offered: ["c.ateliertheme"], present: ["b.ateliertheme"]) == ["a.ateliertheme"])
}

@Test func seedingCopiesIntoAnEmptyFolderAndRespectsTheOwner() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("Examples/themes"), destination = root.appendingPathComponent("Themes")
    for name in ["one", "two"] {
        let bundle = source.appendingPathComponent("\(name).ateliertheme")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{\"name\":\"\(name)\"}".utf8).write(to: bundle.appendingPathComponent("atelier-theme.json"))
    }
    try Data().write(to: source.appendingPathComponent("README.md"))

    let first = ExampleSeeding.seed(from: source, into: destination, pathExtension: "ateliertheme", offered: [])
    #expect(first == ["one.ateliertheme", "two.ateliertheme"])
    #expect(Set(try fm.contentsOfDirectory(atPath: destination.path)) == first)

    // The owner edits one and deletes the other: neither is touched again.
    let edited = destination.appendingPathComponent("one.ateliertheme/atelier-theme.json")
    try Data("mine".utf8).write(to: edited)
    try fm.removeItem(at: destination.appendingPathComponent("two.ateliertheme"))
    let second = ExampleSeeding.seed(from: source, into: destination, pathExtension: "ateliertheme", offered: first)
    #expect(second == first)
    #expect(try String(contentsOf: edited, encoding: .utf8) == "mine")
    #expect(!fm.fileExists(atPath: destination.appendingPathComponent("two.ateliertheme").path))
}

@Test func seedingWithNoBundledExamplesChangesNothing() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(ExampleSeeding.seed(from: missing, into: missing, pathExtension: "ateliertheme", offered: ["x"]) == ["x"])
}
