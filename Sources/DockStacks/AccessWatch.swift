import AppKit
import ApplicationServices
import DockCore
import SwiftUI

// MARK: - Accessibility, watched in one place
//
// Every window feature, and the keyboard taps of Hyper Key, Hold ⌘Q and friends, need
// Accessibility. Each used to read `AXIsProcessTrusted()` once, when it started, so a grant
// made later (or a re-signed build granted again) left them off until a relaunch, and their
// cards greyed out with no word why. Now one watcher reads the flag every two seconds while it
// is missing (and every ten while it is there, to notice it going away), also on macOS's own
// "the list changed" notification, and when it turns on it starts everything that was waiting.
// The reading is PermissionCenter's (Permissions.swift); this keeps the published flag and the
// fan-out, so every card that observes it is unchanged.
// The switches stay usable without it: turning a feature on records the wish, and it starts
// the moment the grant lands.

extension Notification.Name {
    /// Posted on the main thread when Accessibility trust changes either way.
    static let atelierAccessibilityChanged = Notification.Name("net.dasantos.atelier.accessibilityChanged")
}

@MainActor
final class AccessWatch: ObservableObject {
    static let shared = AccessWatch()

    @Published private(set) var trusted = AXIsProcessTrusted()
    /// The system prompt was shown once this session: the next press opens System Settings,
    /// since macOS does not show the prompt again for an app it already lists.
    @Published private(set) var asked = false

    /// Seconds between reads while missing, and while granted. The reading itself is
    /// PermissionCenter's, which this follows.
    static let waitingInterval = PermissionFlow.activeInterval
    static let grantedInterval = PermissionFlow.idleInterval

    private init() {}

    /// Idempotent. Never prompts.
    func start() { PermissionCenter.shared.start() }

    /// Reads the flag now; on a change, tells every feature.
    func check() { PermissionCenter.shared.check() }

    /// From PermissionCenter on every read.
    func sync(_ now: Bool) {
        guard now != trusted else { return }
        trusted = now
        fanOut(granted: now)
    }

    /// The Grant button: the system prompt (which puts Atelier in the list) and the
    /// Accessibility pane; the pane alone after that.
    func grant() {
        if asked || trusted { openSettings() } else { PermissionCenter.shared.request(.accessibility) }
    }

    /// For the Window Engine's own button, which prompts itself.
    func noteAsked() {
        asked = true
        PermissionCenter.shared.noteRequested(.accessibility)
    }

    /// From PermissionCenter, when it shows the prompt or the pane.
    func markAsked() { if !asked { asked = true } }

    func openSettings() { PermissionCenter.shared.openPane(.accessibility) }

    /// Each feature starts what it holds back without access. Taps made before a revoke are
    /// made again, since macOS may leave them in place but deaf.
    private func fanOut(granted: Bool) {
        WindowEngine.shared.refreshTrust()
        // Either way: it idles its multitouch stream while access is missing.
        TitleBarGestures.shared.refreshTrust()
        if granted {
            WindowGrab.shared.rearm()
            WindowSwitcher.shared.rearm()
            RadialMenu.shared.resume()
            FocusFollowsMouse.shared.resume()
            WindowBorders.shared.resume()
            InactiveDim.shared.resume()
            QuitGuard.shared.rearm()
            InputTrust.granted()
            InstantSpaces.shared.resume()
            AtelierHUD.shared.retryIfTrusted()
        }
        NotificationCenter.default.post(name: .atelierAccessibilityChanged, object: nil)
    }
}

// MARK: - The one state a card shows without access

/// "Needs Accessibility · Grant…": shown inside a feature's card while access is missing,
/// in place of greyed-out controls. The button shows the system prompt, then System Settings.
struct NeedsAccessRow: View {
    /// What the feature does with it, in a few words.
    var reason: String?
    /// Set by offline renders, which cannot hold the permission.
    var previewTrusted: Bool?
    @ObservedObject private var access = AccessWatch.shared

    var body: some View {
        if !(previewTrusted ?? access.trusted) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange.opacity(0.95))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Needs Accessibility").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    if let reason {
                        Text(reason).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Chip(access.asked ? "Open Settings…" : "Grant…") { access.grant() }
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            .accessibilityElement(children: .contain)
            .onAppear { access.start(); access.check() }
        }
    }
}
