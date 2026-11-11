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

@MainActor
final class DockPermissions: ObservableObject {
    static let shared = DockPermissions()

    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var screen = ScreenRecordingFlag.allowed

    private var timer: Timer?

    func start() {
        // The first check comes with the first tick, after the dock's own start-up (which
        // turns the minimise tap on two seconds in).
        guard timer == nil else { return }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let interval = trusted && screen ? 10.0 : 2.0
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { DockPermissions.shared.check() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reads both flags now; anything that changed is passed on at once.
    func check() {
        defer { if trusted { MinimizeRedirect.shared.ensureTap() } }
        let nowTrusted = AXIsProcessTrusted()
        let nowScreen = ScreenRecordingFlag.allowed
        let changed = nowTrusted != trusted || nowScreen != screen
        let trustChanged = nowTrusted != trusted
        if nowTrusted != trusted { trusted = nowTrusted }
        if nowScreen != screen { screen = nowScreen }
        guard changed else { return }
        if trustChanged {
            // The tap and the readers start (or stop) with the grant.
            MinimizeRedirect.shared.update()
        }
        OwnDock.shared.refresh()
        schedule()
    }

    /// Shows the system prompt the first time, and the Accessibility list in System Settings.
    func askAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { open("Privacy_Accessibility") }
        check()
    }

    /// Shows the system prompt the first time, and the Screen Recording list in System Settings.
    func askScreenRecording() {
        if !CGRequestScreenCaptureAccess() { open("Privacy_ScreenCapture") }
        check()
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) {
            NSWorkspace.shared.open(url)
        }
    }
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
