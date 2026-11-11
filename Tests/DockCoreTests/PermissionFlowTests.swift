import Foundation
import Testing
@testable import DockCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func phase(_ kind: PermissionKind, _ reading: PermissionReading, _ track: PermissionTrack, at seconds: Double = 0) -> PermissionPhase {
    PermissionFlow.phase(kind, reading: reading, track: track, now: t0.addingTimeInterval(seconds))
}

@Test func grantedIsGrantedAndHasNoButton() {
    let track = PermissionTrack(grantedAtLaunch: true)
    #expect(phase(.accessibility, .granted, track) == .granted)
    #expect(PermissionFlow.action(.accessibility, phase: .granted, track: track) == .none)
    #expect(PermissionFlow.actionTitle(.none) == nil)
}

@Test func neverAskedPromptsFirstThenOpensThePane() {
    var track = PermissionTrack(grantedAtLaunch: false)
    for kind in [PermissionKind.accessibility, .screenRecording] {
        #expect(phase(kind, .missing, track) == .missing)
        #expect(PermissionFlow.action(kind, phase: .missing, track: track) == .requestThenOpen)
    }
    // macOS shows its prompt once: after that the button goes straight to the pane.
    track.requestedAt = t0
    #expect(phase(.accessibility, .missing, track) == .waiting)
    #expect(PermissionFlow.action(.accessibility, phase: .waiting, track: track) == .openSettings)
}

@Test func optionalOnesOnlyOpenTheirPane() {
    let track = PermissionTrack(grantedAtLaunch: true)
    for kind in [PermissionKind.systemAudio, .fullDiskAccess, .appManagement] {
        #expect(!kind.addsItselfToList)
        #expect(PermissionFlow.action(kind, phase: phase(kind, .missing, track), track: track) == .openSettings)
    }
    #expect(phase(.appManagement, .unknown, track) == .unknown)
    #expect(PermissionFlow.action(.appManagement, phase: .unknown, track: track) == .openSettings)
}

@Test func paneOpenWithoutTrustTurnsStaleAfterTwentySeconds() {
    let track = PermissionTrack(grantedAtLaunch: false, requestedAt: t0, paneOpenedAt: t0)
    #expect(phase(.accessibility, .missing, track, at: 5) == .waiting)
    #expect(phase(.accessibility, .missing, track, at: 19.9) == .waiting)
    #expect(phase(.accessibility, .missing, track, at: 20) == .stale)
    #expect(phase(.screenRecording, .missing, track, at: 45) == .stale)
    #expect(PermissionFlow.staleDeadline(track: track) == t0.addingTimeInterval(PermissionFlow.staleAfter))
    // A grant while the pane is open is a grant, however long it took.
    #expect(phase(.accessibility, .granted, PermissionTrack(grantedAtLaunch: true, paneOpenedAt: t0), at: 60) == .granted)
}

@Test func optionalOnesNeverShowTheStaleFix() {
    let track = PermissionTrack(grantedAtLaunch: true, requestedAt: t0, paneOpenedAt: t0, userSaysOn: true)
    #expect(phase(.fullDiskAccess, .missing, track, at: 60) == .waiting)
    #expect(phase(.systemAudio, .missing, track, at: 60) == .waiting)
}

@Test func itsOnButNotWorkingShowsTheFixAtOnce() {
    let track = PermissionTrack(grantedAtLaunch: true, userSaysOn: true)
    #expect(phase(.accessibility, .missing, track) == .stale)
    #expect(PermissionFlow.action(.accessibility, phase: .stale, track: track) == .openSettings)
}

@Test func screenRecordingGrantedLaterSuggestsARelaunch() {
    let fresh = PermissionTrack(grantedAtLaunch: false, requestedAt: t0)
    #expect(phase(.screenRecording, .granted, fresh) == .grantedRelaunchSuggested)
    #expect(PermissionFlow.action(.screenRecording, phase: .grantedRelaunchSuggested, track: fresh) == .relaunch)
    #expect(PermissionFlow.actionTitle(.relaunch) == "Relaunch Atelier")
    // After the relaunch it was there at launch: plain granted.
    #expect(phase(.screenRecording, .granted, PermissionTrack(grantedAtLaunch: true)) == .granted)
    // "It's on but not working" with the flag on: a relaunch is the cure.
    #expect(phase(.screenRecording, .granted, PermissionTrack(grantedAtLaunch: true, userSaysOn: true)) == .grantedRelaunchSuggested)
    // Accessibility never needs one.
    #expect(phase(.accessibility, .granted, fresh) == .granted)
    #expect(PermissionPhase.grantedRelaunchSuggested.isGranted)
}

@Test func pollFastOnlyWhileSheetOpenOrEssentialMissing() {
    let allGranted: [PermissionKind: PermissionReading] = [.accessibility: .granted, .screenRecording: .granted,
                                                           .systemAudio: .missing, .fullDiskAccess: .missing, .appManagement: .unknown]
    #expect(PermissionFlow.pollInterval(sheetOpen: false, readings: allGranted) == 10)
    #expect(PermissionFlow.pollInterval(sheetOpen: true, readings: allGranted) == 2)
    var missing = allGranted
    missing[.screenRecording] = .missing
    #expect(PermissionFlow.pollInterval(sheetOpen: false, readings: missing) == 2)
    #expect(PermissionFlow.essentialMissing(missing) == [.screenRecording])
}

@Test func homeReminderNamesWhatIsMissing() {
    #expect(PermissionFlow.homeReminder([.accessibility: .granted, .screenRecording: .granted, .fullDiskAccess: .missing]) == nil)
    #expect(PermissionFlow.homeReminder([.accessibility: .missing, .screenRecording: .granted]) == "Needs Accessibility")
    #expect(PermissionFlow.homeReminder([.accessibility: .missing, .screenRecording: .missing]) == "Needs 2 permissions")
}

@Test func welcomeShowsOnceAndARelaunchReopensThePermissions() {
    #expect(PermissionFlow.launchSheet(welcomed: false, reopenAfterRelaunch: false) == .welcome)
    #expect(PermissionFlow.launchSheet(welcomed: true, reopenAfterRelaunch: false) == PermissionFlow.LaunchSheet.none)
    #expect(PermissionFlow.launchSheet(welcomed: true, reopenAfterRelaunch: true) == .permissions)
    #expect(PermissionFlow.launchSheet(welcomed: false, reopenAfterRelaunch: true) == .permissions)
}

@Test func fixNamesTheRightListAndFolder() {
    #expect(PermissionKind.screenRecording.listName == "Screen & System Audio Recording")
    #expect(PermissionKind.screenRecording.settingsAnchor == "Privacy_ScreenCapture")
    #expect(PermissionKind.accessibility.settingsAnchor == "Privacy_Accessibility")
    #expect(PermissionKind.systemAudio.settingsAnchor == "Privacy_AudioCapture")
    #expect(PermissionKind.fullDiskAccess.settingsAnchor == "Privacy_AllFiles")
    #expect(PermissionKind.appManagement.settingsAnchor == "Privacy_AppBundles")
    let steps = PermissionFlow.fixSteps(.screenRecording, folder: "Applications")
    #expect(steps.first == "Select Atelier in the list.")
    #expect(steps.contains("Press +, then choose Atelier in Applications."))
    #expect(steps.last == "Relaunch Atelier.")
    #expect(!PermissionFlow.fixSteps(.accessibility, folder: "Applications").contains("Relaunch Atelier."))
    #expect(PermissionFlow.listWarning(.screenRecording)?.contains("Not System Audio Recording Only") == true)
}

@Test func onlyAccessibilityAndScreenRecordingAreEssential() {
    #expect(PermissionKind.allCases.filter(\.essential) == [.accessibility, .screenRecording])
    #expect(PermissionKind.allCases.filter(\.canGoStale) == [.accessibility, .screenRecording])
}
