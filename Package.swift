// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DockStacks",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DockCore"),
        .executableTarget(name: "DockStacks", dependencies: ["DockCore"]),
        .executableTarget(name: "AtelierGuard"),
        .executableTarget(name: "AtelierFans", dependencies: ["DockCore"]),
        .testTarget(name: "DockCoreTests", dependencies: ["DockCore"]),
    ]
)
