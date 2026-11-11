#if DEBUG
import AppKit
import DockCore
import SwiftUI

/// `DockStacks --render-permissions <folder>` (debug builds): every state of the Welcome and
/// Permissions sheet as a PNG, light and dark, from fixed snapshots. Reads nothing from macOS
/// and asks for nothing, so it is safe on any Mac.
@MainActor
enum PermissionRenders {
    static func run(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func snap(_ ax: PermissionReading, _ screen: PermissionReading, audio: PermissionReading = .missing,
                  disk: PermissionReading = .missing, apps: PermissionReading = .unknown,
                  tracks: [PermissionKind: PermissionTrack] = [:]) -> PermissionSnapshot {
            var all = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionTrack(grantedAtLaunch: true)) })
            all.merge(tracks) { $1 }
            return PermissionSnapshot(readings: [.accessibility: ax, .screenRecording: screen, .systemAudio: audio,
                                                 .fullDiskAccess: disk, .appManagement: apps],
                                      tracks: all, now: now, folder: "Applications")
        }
        let opened = { (seconds: Double) in PermissionTrack(grantedAtLaunch: false, requestedAt: now.addingTimeInterval(-seconds),
                                                            paneOpenedAt: now.addingTimeInterval(-seconds)) }
        let states: [(String, AnyView)] = [
            ("welcome", AnyView(WelcomePage())),
            ("all-missing", AnyView(PermissionsPage(snapshot: snap(.missing, .missing,
                tracks: [.screenRecording: PermissionTrack(grantedAtLaunch: false)]), maxListHeight: nil))),
            ("partial", AnyView(PermissionsPage(snapshot: snap(.granted, .missing, audio: .granted,
                tracks: [.screenRecording: opened(6)]), maxListHeight: nil))),
            ("all-granted", AnyView(PermissionsPage(snapshot: snap(.granted, .granted, audio: .granted, disk: .granted), maxListHeight: nil))),
            ("stale-accessibility", AnyView(PermissionsPage(snapshot: snap(.missing, .granted,
                tracks: [.accessibility: PermissionTrack(grantedAtLaunch: true, requestedAt: now, userSaysOn: true)]), maxListHeight: nil))),
            ("stale-screen", AnyView(PermissionsPage(snapshot: snap(.granted, .missing,
                tracks: [.screenRecording: opened(25)]), maxListHeight: nil))),
            ("screen-relaunch", AnyView(PermissionsPage(snapshot: snap(.granted, .granted, audio: .granted,
                tracks: [.screenRecording: PermissionTrack(grantedAtLaunch: false, requestedAt: now)]), maxListHeight: nil))),
            ("settings-card", AnyView(PermissionsCard(preview: snap(.granted, .missing)).frame(width: 368).padding(16).background(Color.black))),
            ("home-reminder", AnyView(PermissionsReminder(preview: [.accessibility: .missing, .screenRecording: .missing])
                .padding(24).background(Color(red: 0.1, green: 0.14, blue: 0.24)))),
        ]
        for (name, view) in states {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    print("failed: \(name)"); continue
                }
                let url = folder.appendingPathComponent("permissions-\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
        }
    }
}
#endif
