import Foundation
import CoreGraphics

// MARK: - Dock Bridge: the contract
//
// Some of what people want from their windows only the Dock can do, because the Dock holds
// the window server's privileged connection: fading another app's window, keeping one above
// all others, pinning it to every Space, shrinking it to a picture-in-picture, creating and
// removing Spaces. Atelier reaches that power the way yabai does, with a small scripting
// addition loaded into the Dock. macOS only allows that with System Integrity Protection
// partly off, so every feature built on the bridge first asks `status`, and explains, rather
// than failing, when the Mac is not set up for it.
//
// This file is the shared contract between the bridge (the loader, the payload inside the
// Dock, the client talking to it) and the UI built on top. The implementation lives in
// DockBridge.swift.

/// Where the Mac stands, from "cannot ever work" to "ready", in the order a person fixes it.
enum BridgeStatus: Equatable, Sendable {
    /// System Integrity Protection is fully on. The owner must partly disable it in Recovery.
    case sipEnabled
    /// SIP is partly off, but Apple silicon also needs the arm64e preview ABI boot argument.
    case needsBootArgument
    /// The Mac is ready; the scripting addition is not installed in /Library/ScriptingAdditions.
    case notInstalled
    /// Installed but not loaded into the running Dock (after a Dock restart, a login, an update).
    case notLoaded
    /// Loaded, and answering.
    case ready(version: String)
    /// Something failed; the message says what, in plain words.
    case failed(String)

    var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// A window, as the window server numbers it.
typealias BridgeWindow = CGWindowID

/// Everything a feature can ask the Dock to do. Calls are asynchronous and cheap; each returns
/// whether the Dock accepted it. Nothing here is attempted unless `status.isReady`.
@MainActor
protocol DockBridging: AnyObject {
    var status: BridgeStatus { get }

    /// Re-reads SIP, the boot arguments, the installed bundle and the payload's heartbeat.
    func refresh() async

    /// Installs the scripting addition (asks for an administrator password), or removes it.
    func install() async throws
    func uninstall() async throws
    /// Loads the installed scripting addition into the running Dock (administrator password).
    func load() async throws

    // Windows
    func setOpacity(_ window: BridgeWindow, _ alpha: Double, duration: Double) async -> Bool
    func setOnTop(_ window: BridgeWindow, _ onTop: Bool) async -> Bool
    func setSticky(_ window: BridgeWindow, _ sticky: Bool) async -> Bool
    func setShadow(_ window: BridgeWindow, _ shadow: Bool) async -> Bool
    /// Scales a window about an anchor point in screen coordinates; 1 restores it. Used for
    /// picture-in-picture of any window.
    func setScale(_ window: BridgeWindow, _ scale: Double, anchor: CGPoint) async -> Bool
    func move(_ window: BridgeWindow, toSpace space: UInt64) async -> Bool

    // Spaces
    func createSpace(onDisplay display: CGDirectDisplayID) async -> UInt64?
    func destroySpace(_ space: UInt64) async -> Bool
    func focusSpace(_ space: UInt64) async -> Bool
    func moveSpace(_ space: UInt64, after other: UInt64) async -> Bool
}
