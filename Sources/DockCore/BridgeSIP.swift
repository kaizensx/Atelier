import Foundation

// MARK: - System Integrity Protection, decoded
//
// The Dock bridge needs two SIP protections off: Filesystem Protections (so the scripting
// addition can be written into /Library) and Debugging Restrictions (so the loader can call
// task_for_pid on the Dock). Setting the arm64e boot argument from macOS also needs NVRAM
// Protections off; it can instead be set from Recovery.
//
// Two ways to read SIP, both pure and unit-tested here:
//   * `BridgeSIP(config:)` decodes the raw uint32 from csr_get_active_config (the precise one;
//     the client resolves that symbol via dlsym at runtime).
//   * `BridgeSIP.parse(csrutil:)` reads the text of `csrutil status`, the fallback when the
//     symbol is unavailable or the config reads as 0.
//
// Flag values are Apple's csr.h constants.

public struct BridgeSIP: Equatable, Sendable {
    // csr_config_t flags (a set bit means that protection is ALLOWED, i.e. OFF).
    public static let allowUnrestrictedFS: UInt32    = 0x02   // Filesystem Protections
    public static let allowTaskForPID: UInt32        = 0x04   // Debugging Restrictions
    public static let allowUnrestrictedNVRAM: UInt32 = 0x40   // NVRAM Protections

    /// True when that protection is DISABLED (the bridge wants these true).
    public let filesystemProtectionsOff: Bool
    public let debuggingRestrictionsOff: Bool
    public let nvramProtectionsOff: Bool
    /// The raw config word when known (from csr_get_active_config), else nil (parsed from text).
    public let rawConfig: UInt32?

    public init(filesystemProtectionsOff: Bool,
                debuggingRestrictionsOff: Bool,
                nvramProtectionsOff: Bool,
                rawConfig: UInt32?) {
        self.filesystemProtectionsOff = filesystemProtectionsOff
        self.debuggingRestrictionsOff = debuggingRestrictionsOff
        self.nvramProtectionsOff = nvramProtectionsOff
        self.rawConfig = rawConfig
    }

    /// Decode the raw csr_get_active_config word.
    public init(config: UInt32) {
        self.init(
            filesystemProtectionsOff: config & Self.allowUnrestrictedFS != 0,
            debuggingRestrictionsOff: config & Self.allowTaskForPID != 0,
            nvramProtectionsOff: config & Self.allowUnrestrictedNVRAM != 0,
            rawConfig: config)
    }

    /// The two protections injection requires are both off. (NVRAM is only needed to set the
    /// boot-arg from macOS, so it is reported but not required here.)
    public var isBridgeCapable: Bool { filesystemProtectionsOff && debuggingRestrictionsOff }

    /// Fully enabled SIP: nothing is allowed.
    public var isFullyEnabled: Bool {
        !filesystemProtectionsOff && !debuggingRestrictionsOff && !nvramProtectionsOff
    }

    /// Compact one-line form for `diagnostics`, e.g. "fs=off tfp=off nvram=on config=0x06".
    public var flags: String {
        var parts = [
            "fs=\(filesystemProtectionsOff ? "off" : "on")",
            "tfp=\(debuggingRestrictionsOff ? "off" : "on")",
            "nvram=\(nvramProtectionsOff ? "off" : "on")",
        ]
        if let raw = rawConfig {
            parts.append(String(format: "config=0x%02X", raw))
        } else {
            parts.append("config=text")
        }
        return parts.joined(separator: " ")
    }

    /// Parse the human-readable output of `csrutil status`.
    ///
    /// Two shapes are handled:
    ///   "System Integrity Protection status: enabled."   → everything on
    ///   "System Integrity Protection status: disabled."  → everything off
    ///   a "Configuration:" block listing each protection  → per-line enabled/disabled
    public static func parse(csrutil text: String) -> BridgeSIP {
        let lower = text.lowercased()

        // Whole-state lines win when there is no per-protection breakdown.
        let hasBreakdown = lower.contains("filesystem protections")
        if !hasBreakdown {
            if lower.contains("status: disabled") {
                return BridgeSIP(filesystemProtectionsOff: true, debuggingRestrictionsOff: true,
                                 nvramProtectionsOff: true, rawConfig: nil)
            }
            // Default (including "status: enabled"): all protections on.
            return BridgeSIP(filesystemProtectionsOff: false, debuggingRestrictionsOff: false,
                             nvramProtectionsOff: false, rawConfig: nil)
        }

        func off(_ label: String) -> Bool {
            // Find the line mentioning the protection and check whether it says "disabled".
            for line in lower.split(whereSeparator: { $0 == "\n" }) {
                if line.contains(label) { return line.contains("disabled") }
            }
            return false
        }

        return BridgeSIP(
            filesystemProtectionsOff: off("filesystem protections"),
            debuggingRestrictionsOff: off("debugging restrictions"),
            nvramProtectionsOff: off("nvram protections"),
            rawConfig: nil)
    }
}

// MARK: - Bridge gating, as pure platform logic
//
// The order in which a Mac becomes bridge-ready, and the per-platform differences, decided from
// plain inputs so the decisions can be unit-tested without a Mac in any particular state. The
// MainActor client (DockBridge) reads the live SIP word, boot arguments, installed version and CPU
// and feeds them here; the ObjC payload carries the same Spaces-support facts in its own tables.

public enum BridgeGateCPU: Equatable, Sendable { case appleSilicon, intel }

/// The first unmet precondition, in the order a person fixes it. Mirrors BridgeStatus.
public enum BridgeGateStage: Equatable, Sendable {
    case sipEnabled, needsBootArgument, notInstalled, notLoaded, ready
}

/// What the scripting addition on disk amounts to. Pure, so a stale or broken bridge is tested.
public enum BridgeInstall {
    /// This build's bridge, whole: on disk, the expected version, both binaries in place. Anything
    /// else on disk is stale: still installed (Remove shows), but Update replaces it before a load.
    public static func isCurrent(onDisk: Bool, version: String?, expected: String, binaries: Bool) -> Bool {
        onDisk && binaries && version == expected
    }
}

public enum BridgeGate {
    /// The stage this Mac is at. `loaded` is only consulted once every earlier precondition is met
    /// (the caller learns it from the payload's handshake), so pass it as the final tiebreak.
    public static func stage(sipCapable: Bool,
                             cpu: BridgeGateCPU,
                             bootArgPresent: Bool,
                             installedMatches: Bool,
                             loaded: Bool) -> BridgeGateStage {
        if !sipCapable { return .sipEnabled }
        // Only Apple silicon needs the arm64e preview ABI boot argument; Intel injects with SIP
        // partly off alone.
        if cpu == .appleSilicon && !bootArgPresent { return .needsBootArgument }
        if !installedMatches { return .notInstalled }
        return loaded ? .ready : .notLoaded
    }

    /// Whether the Recovery Assistant's one-tap finish must set the boot argument first (after which
    /// a restart is required before the bridge can load). True only on Apple silicon still missing it.
    public static func finishNeedsRestart(cpu: BridgeGateCPU, bootArgPresent: Bool) -> Bool {
        cpu == .appleSilicon && !bootArgPresent
    }

    /// How much of the Spaces command set the payload can drive on a given macOS/CPU, matching the
    /// pattern tables in Native/arm64_payload.m and Native/x64_payload.m.
    ///   * full      — focus plus create/destroy/move (macOS 14, 15, 26 on both CPUs)
    ///   * focusOnly — focus only; create/destroy/move stay disabled (macOS 27, Apple silicon)
    ///   * none      — no Spaces commands; window commands still work (anything else, e.g. 27 Intel,
    ///                 which does not exist, or an untested future release)
    public enum SpacesSupport: Equatable, Sendable { case full, focusOnly, none }

    public static func spacesSupport(osMajor: Int, cpu: BridgeGateCPU) -> SpacesSupport {
        switch osMajor {
        case 14, 15, 26: return .full
        case 27: return cpu == .appleSilicon ? .focusOnly : .none
        default: return .none
        }
    }
}
