import Foundation
import Testing
@testable import DockCore

// The bridge's platform gating: precondition order, the per-CPU boot-argument rule, and how much
// of the Spaces command set each macOS/CPU supports. Pure, so every branch is checked here.

// MARK: - Precondition stage order

@Test func sipOffIsTheFirstGate() {
    // Nothing else matters while SIP is fully on.
    let s = BridgeGate.stage(sipCapable: false, cpu: .appleSilicon, bootArgPresent: false,
                             installedMatches: false, loaded: false)
    #expect(s == .sipEnabled)
}

@Test func appleSiliconNeedsBootArgumentAfterSIP() {
    let s = BridgeGate.stage(sipCapable: true, cpu: .appleSilicon, bootArgPresent: false,
                             installedMatches: true, loaded: true)
    #expect(s == .needsBootArgument)
}

@Test func intelSkipsBootArgument() {
    // Intel never needs the arm64e boot argument, so an SIP-capable Intel Mac with the addition
    // installed and loaded is ready even with bootArgPresent false.
    let s = BridgeGate.stage(sipCapable: true, cpu: .intel, bootArgPresent: false,
                             installedMatches: true, loaded: true)
    #expect(s == .ready)
}

@Test func intelMissingInstallIsNotInstalled() {
    let s = BridgeGate.stage(sipCapable: true, cpu: .intel, bootArgPresent: false,
                             installedMatches: false, loaded: false)
    #expect(s == .notInstalled)
}

@Test func appleSiliconInstalledButNotLoaded() {
    let s = BridgeGate.stage(sipCapable: true, cpu: .appleSilicon, bootArgPresent: true,
                             installedMatches: true, loaded: false)
    #expect(s == .notLoaded)
}

@Test func appleSiliconFullyReady() {
    let s = BridgeGate.stage(sipCapable: true, cpu: .appleSilicon, bootArgPresent: true,
                             installedMatches: true, loaded: true)
    #expect(s == .ready)
}

@Test func bootArgumentGateComesBeforeInstall() {
    // Even with nothing installed, Apple silicon is asked for the boot argument first.
    let s = BridgeGate.stage(sipCapable: true, cpu: .appleSilicon, bootArgPresent: false,
                             installedMatches: false, loaded: false)
    #expect(s == .needsBootArgument)
}

// MARK: - Finish-setup restart rule

@Test func finishNeedsRestartOnlyWhenAppleSiliconLacksBootArg() {
    #expect(BridgeGate.finishNeedsRestart(cpu: .appleSilicon, bootArgPresent: false))
    #expect(!BridgeGate.finishNeedsRestart(cpu: .appleSilicon, bootArgPresent: true))
    #expect(!BridgeGate.finishNeedsRestart(cpu: .intel, bootArgPresent: false))
    #expect(!BridgeGate.finishNeedsRestart(cpu: .intel, bootArgPresent: true))
}

// MARK: - Spaces support per OS / CPU

@Test func spacesFullOnFourteenFifteenTwentySix() {
    for major in [14, 15, 26] {
        #expect(BridgeGate.spacesSupport(osMajor: major, cpu: .appleSilicon) == .full)
        #expect(BridgeGate.spacesSupport(osMajor: major, cpu: .intel) == .full)
    }
}

@Test func spacesFocusOnlyOnTwentySevenAppleSilicon() {
    #expect(BridgeGate.spacesSupport(osMajor: 27, cpu: .appleSilicon) == .focusOnly)
}

@Test func spacesNoneOnTwentySevenIntelAndUnknown() {
    // macOS 27 is Apple-silicon only, so the Intel case is defensive; older/newer untested.
    #expect(BridgeGate.spacesSupport(osMajor: 27, cpu: .intel) == .none)
    #expect(BridgeGate.spacesSupport(osMajor: 13, cpu: .appleSilicon) == .none)
    #expect(BridgeGate.spacesSupport(osMajor: 99, cpu: .intel) == .none)
}
