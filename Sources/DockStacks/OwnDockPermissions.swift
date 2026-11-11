import AppKit
import ApplicationServices
import SwiftUI

// MARK: - The Atelier Dock's two permissions, kept current
//
// Badges, Attention Bounce, minimised windows and Minimise into this Dock read and move other
// apps' windows through Accessibility; window pictures need Screen Recording. Both can be
// granted (or taken away, by a re-sign) while Atelier runs. This polls the two flags every two
// seconds while either is missing, every ten once both are there, and turns the dock's readers
// and the minimise tap on the moment a grant lands, with no relaunch. Neither read ever asks.
// The reading is PermissionCenter's (Permissions.swift); this keeps the published flags.

@MainActor
final class DockPermissions: ObservableObject {
    static let shared = DockPermissions()

    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var screen = ScreenRecordingFlag.allowed

    /// The dock is running: changes reach its readers and the minimise tap.
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        PermissionCenter.shared.start()
        // The first check comes two seconds in, after the dock's own start-up (which turns the
        // minimise tap on two seconds in). Then every PermissionCenter read.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { PermissionCenter.shared.check() }
        }
    }

    /// Reads both flags now; anything that changed is passed on at once.
    func check() { PermissionCenter.shared.check() }

    /// From PermissionCenter on every read.
    func sync(trusted nowTrusted: Bool, screen nowScreen: Bool) {
        defer { if started && trusted { MinimizeRedirect.shared.ensureTap() } }
        let trustChanged = nowTrusted != trusted
        let changed = trustChanged || nowScreen != screen
        if trustChanged { trusted = nowTrusted }
        if nowScreen != screen { screen = nowScreen }
        guard changed, started else { return }
        if trustChanged {
            // The tap and the readers start (or stop) with the grant.
            MinimizeRedirect.shared.update()
        }
        OwnDock.shared.refresh()
    }

    /// Shows the system prompt the first time, and the Accessibility list in System Settings.
    func askAccessibility() { PermissionCenter.shared.request(.accessibility) }

    /// Shows the system prompt the first time, and the Screen Recording list in System Settings.
    func askScreenRecording() { PermissionCenter.shared.request(.screenRecording) }
}

/// "Needs Screen Recording" or "Needs Accessibility", with the button that asks. Goes away by
/// itself the moment the permission is there.
struct DockPermissionNote: View {
    enum Kind { case accessibility, screen }
    let kind: Kind
    /// What the feature cannot do without it, in a few words.
    let sentence: String
    @ObservedObject private var permissions = DockPermissions.shared

    var body: some View {
        if !(kind == .accessibility ? permissions.trusted : permissions.screen) {
            HStack(spacing: 10) {
                Text(sentence)
                    .font(DS.caption).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                DockPillButton(title: "Grant…") {
                    kind == .accessibility ? permissions.askAccessibility() : permissions.askScreenRecording()
                }
            }
        }
    }
}
