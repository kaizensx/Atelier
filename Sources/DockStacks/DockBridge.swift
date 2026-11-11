import Foundation
import Combine
import CoreGraphics
import DockCore

// MARK: - DockBridge: the implementation of the Dock Bridge contract (DockBridgeAPI.swift)
//
// The client half of the scripting addition. It:
//   * detects where the Mac stands (SIP flags, boot-arg, installed bundle, loaded payload);
//   * installs / uninstalls / loads the addition through an administrator-password prompt;
//   * speaks the little binary protocol (DockCore/BridgeWire) to the payload over a per-uid
//     unix socket, with connect/send/recv timeouts and no retained connection (each command
//     opens, sends, reads an ack, closes — matching the payload's one-shot handler).
//
// Nothing privileged ever runs on its own. install(), uninstall() and load() are the only
// methods that touch /Library or task_for_pid, and each one goes through the system password
// prompt. Auto-load at login happens only when the owner turned it on, and it still prompts
// unless they added a sudoers rule themselves (see sudoersInstructions).
//
// The injection itself cannot run while SIP is on, so on this Mac status resolves to
// .sipEnabled and every command short-circuits. The detection, the wire protocol and the build
// artefacts are all exercised with SIP on.

// csr_get_active_config lives in libsystem_kernel; resolve it at runtime so the app links
// cleanly even where the private symbol is unavailable.
private typealias CSRGetActiveConfig = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32

enum BridgeError: LocalizedError {
    case notReady(BridgeStatus)
    case privilegedStepFailed(String)
    case resourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let s): return "Dock bridge is not ready (\(s))."
        case .privilegedStepFailed(let m): return m
        case .resourceMissing(let r): return "Missing bundled resource: \(r)."
        }
    }
}

@MainActor
final class DockBridge: ObservableObject, DockBridging {
    static let shared = DockBridge()

    @Published private(set) var status: BridgeStatus = .failed("not yet checked")

    /// Detected SIP state, kept for diagnostics.
    private(set) var sip: BridgeSIP = BridgeSIP(filesystemProtectionsOff: false,
                                                debuggingRestrictionsOff: false,
                                                nvramProtectionsOff: false, rawConfig: nil)
    private(set) var bootArgPresent = false
    private(set) var installedVersion: String?
    /// The addition is on disk, whatever its version and whatever SIP says. Removing it needs no
    /// SIP change (/Library/ScriptingAdditions is not SIP-protected), so Remove shows on this.
    @Published private(set) var installed = false
    /// What an administrator step is doing right now, for a progress line. The prompt runs off
    /// the main thread, so the Studio keeps drawing while it waits for the password.
    @Published private(set) var working: String?

    /// The version this build ships; must match Native/common.h OSAX_VERSION and the osax
    /// Info.plist written by build.sh. An installed addition of a different version counts as
    /// not installed, so the UI offers to reinstall.
    let expectedVersion = "1.0.0"

    /// UserDefaults key gating automatic re-load at login. Default false.
    static let autoloadDefaultsKey = "bridge.autoload"

    private let io = DispatchQueue(label: "net.dasantos.atelier.bridge.io")

    private init() {}

    // MARK: Paths

    private var socketPath: String { "/tmp/atelier-sa_\(getuid()).socket" }
    private let osaxDir = "/Library/ScriptingAdditions/Atelier.osax"
    private var installedInfoPlist: String { "\(osaxDir)/Contents/Info.plist" }

    /// The staged scripting addition and loader shipped inside Atelier.app/Contents/Resources,
    /// placed there by build.sh.
    private var stagedOSAX: String? { Bundle.main.path(forResource: "Atelier", ofType: "osax") }
    private var stagedLoader: String? { Bundle.main.path(forResource: "atelier-loader", ofType: nil) }

    // MARK: - Status detection

    func refresh() async {
        sip = Self.detectSIP()
        bootArgPresent = Self.detectBootArg()
        installedVersion = readInstalledVersion()
        installed = FileManager.default.fileExists(atPath: osaxDir)

        // The precondition order lives in DockCore.BridgeGate (pure, unit-tested). The CPU is read
        // at runtime (sysctl via MacPlatform), not by build slice, so the Intel slice under Rosetta
        // on an Apple silicon Mac still asks for the boot argument the arm64e Dock requires. `loaded`
        // is settled by the handshake below, so pass true here and let it decide the final step.
        let stage = BridgeGate.stage(sipCapable: sip.isBridgeCapable,
                                     cpu: Self.gateCPU,
                                     bootArgPresent: bootArgPresent,
                                     installedMatches: installedVersion == expectedVersion,
                                     loaded: true)
        switch stage {
        case .sipEnabled:
            status = .sipEnabled; autoLoadIfEnabled(); return
        case .needsBootArgument:
            status = .needsBootArgument; autoLoadIfEnabled(); return
        case .notInstalled:
            status = .notInstalled; autoLoadIfEnabled(); return
        case .notLoaded, .ready:
            if let loaded = await handshakeVersion() {
                status = .ready(version: loaded)
            } else {
                status = .notLoaded
                autoLoadIfEnabled()
            }
        }
    }

    /// This Mac's CPU as the pure gate sees it, decided at runtime so Rosetta is handled correctly.
    static var gateCPU: BridgeGateCPU { MacPlatform.appleSilicon ? .appleSilicon : .intel }

    /// Decode SIP precisely via csr_get_active_config; fall back to parsing `csrutil status`.
    static func detectSIP() -> BridgeSIP {
        if let handle = dlopen("/usr/lib/libSystem.dylib", RTLD_LAZY),
           let sym = dlsym(handle, "csr_get_active_config") {
            let fn = unsafeBitCast(sym, to: CSRGetActiveConfig.self)
            var config: UInt32 = 0
            if fn(&config) == 0 {
                let decoded = BridgeSIP(config: config)
                // config == 0 with SIP truly on is correct; but a 0 from a failed read would
                // masquerade as "all on", which is the safe default, so accept it.
                return decoded
            }
        }
        return BridgeSIP.parse(csrutil: runReadOnly("/usr/bin/csrutil", ["status"]) ?? "")
    }

    static func detectBootArg() -> Bool {
        // Intel never needs the arm64e boot-arg, so it is treated as always present there. The
        // check is by the running machine (sysctl), not the compiled slice.
        guard MacPlatform.appleSilicon else { return true }
        var size = 0
        if sysctlbyname("kern.bootargs", nil, &size, nil, 0) == 0, size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.bootargs", &buf, &size, nil, 0) == 0 {
                return String(cString: buf).contains("-arm64e_preview_abi")
            }
        }
        return false
    }

    private func readInstalledVersion() -> String? {
        guard FileManager.default.fileExists(atPath: osaxDir),
              let data = FileManager.default.contents(atPath: installedInfoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let v = plist["CFBundleVersion"] as? String
        else { return nil }
        return v
    }

    // MARK: - Privileged lifecycle (each prompts for the administrator password)

    func install() async throws {
        guard sip.isBridgeCapable else { throw BridgeError.notReady(.sipEnabled) }
        guard let osax = stagedOSAX else { throw BridgeError.resourceMissing("Atelier.osax") }

        let q = Self.shellQuote
        let script = """
        /bin/rm -rf \(q(osaxDir)); \
        /bin/mkdir -p /Library/ScriptingAdditions; \
        /bin/cp -R \(q(osax)) \(q(osaxDir)); \
        /bin/chmod -R 755 \(q(osaxDir)); \
        /usr/bin/codesign -f -s - \(q("\(osaxDir)/Contents/MacOS/loader")) 2>/dev/null; \
        /usr/bin/codesign -f -s - \(q("\(osaxDir)/Contents/Resources/payload.bundle/Contents/MacOS/payload")) 2>/dev/null; \
        /usr/bin/killall Dock
        """
        try await runPrivileged(script, describing: "install the Dock bridge")
        await refresh()
    }

    /// The shell step that takes the addition out, for Remove Everything's single prompt.
    var uninstallScript: String { "/bin/rm -rf \(Self.shellQuote(osaxDir)); /usr/bin/killall Dock 2>/dev/null; true" }

    /// Deleting /Library/ScriptingAdditions/Atelier.osax needs an administrator, not SIP: it works
    /// with SIP fully back on, which is exactly when someone wants it gone.
    func uninstall() async throws {
        try await runPrivileged(uninstallScript, describing: "remove the Dock bridge")
        await refresh()
    }

    func load() async throws {
        guard sip.isBridgeCapable else { throw BridgeError.notReady(.sipEnabled) }
        if MacPlatform.appleSilicon {
            guard bootArgPresent else { throw BridgeError.notReady(.needsBootArgument) }
        }
        if installedVersion != expectedVersion { try await install() }

        let loader = "\(osaxDir)/Contents/MacOS/loader"
        let script = "\(Self.shellQuote(loader))"
        try await runPrivileged(script, describing: "load the Dock bridge into the Dock")
        await refresh()
    }

    /// The outcome of the Recovery Assistant's one-tap finish step.
    enum SetupOutcome: Sendable {
        /// Installed and loaded; the Dock is answering (or will be after `refresh`).
        case loaded
        /// The arm64e boot argument was just set, so a restart is needed before loading.
        case needsRestart
    }

    /// The Recovery Assistant's "Finish setup": one administrator prompt that, on Apple silicon
    /// still missing the boot argument, sets it (a restart is then required) and installs the
    /// addition; otherwise installs the addition and loads it into the Dock. It never runs on its
    /// own — only from the assistant's explicit button, after the Mac already has SIP partly off.
    func finishSetup() async throws -> SetupOutcome {
        guard sip.isBridgeCapable else { throw BridgeError.notReady(.sipEnabled) }
        guard let osax = stagedOSAX else { throw BridgeError.resourceMissing("Atelier.osax") }
        let q = Self.shellQuote
        let needsBootArg = BridgeGate.finishNeedsRestart(cpu: Self.gateCPU, bootArgPresent: bootArgPresent)

        var steps: [String] = []
        if needsBootArg { steps.append("/usr/sbin/nvram boot-args=-arm64e_preview_abi") }
        steps.append("/bin/rm -rf \(q(osaxDir))")
        steps.append("/bin/mkdir -p /Library/ScriptingAdditions")
        steps.append("/bin/cp -R \(q(osax)) \(q(osaxDir))")
        steps.append("/bin/chmod -R 755 \(q(osaxDir))")
        steps.append("/usr/bin/codesign -f -s - \(q("\(osaxDir)/Contents/MacOS/loader")) 2>/dev/null")
        steps.append("/usr/bin/codesign -f -s - \(q("\(osaxDir)/Contents/Resources/payload.bundle/Contents/MacOS/payload")) 2>/dev/null")
        // Loading needs the arm64e Dock, which only exists after the reboot that applies the boot
        // argument. So load now only when no boot argument is pending.
        if !needsBootArg {
            steps.append("/usr/bin/killall Dock")
            steps.append("/bin/sleep 1")
            steps.append(q("\(osaxDir)/Contents/MacOS/loader"))
        }

        try await runPrivileged(steps.joined(separator: "; "),
                          describing: needsBootArg ? "set the boot argument and install the Dock bridge"
                                                   : "install and load the Dock bridge")
        await refresh()
        return needsBootArg ? .needsRestart : .loaded
    }

    /// Intel only: set the next boot to Recovery, then restart now. One administrator prompt, and
    /// only ever from the Recovery Assistant's explicit, separately confirmed button. On Apple
    /// silicon there is no programmatic path into Recovery, so the assistant gives instructions
    /// instead and never calls this.
    func restartIntoRecovery() async throws {
        let script = "/usr/sbin/nvram recovery-boot-mode=unused; /sbin/shutdown -r now"
        try await runPrivileged(script, describing: "restart into Recovery")
    }

    /// Re-load at login, but only if the owner enabled it. Still prompts for the password
    /// unless they added a sudoers rule (sudoersInstructions explains how; we never write it).
    private func autoLoadIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.autoloadDefaultsKey) else { return }
        guard sip.isBridgeCapable, installedVersion == expectedVersion else { return }
        if MacPlatform.appleSilicon, !bootArgPresent { return }
        Task { try? await self.load() }
    }

    // MARK: - Commands (no-ops unless ready)

    func setOpacity(_ window: BridgeWindow, _ alpha: Double, duration: Double) async -> Bool {
        await sendAck(BridgeWire.setOpacity(UInt32(window), alpha: alpha, duration: duration))
    }
    func setOnTop(_ window: BridgeWindow, _ onTop: Bool) async -> Bool {
        await sendAck(BridgeWire.setLayer(UInt32(window), onTop ? .onTop : .normal))
    }
    func setSticky(_ window: BridgeWindow, _ sticky: Bool) async -> Bool {
        await sendAck(BridgeWire.setSticky(UInt32(window), sticky))
    }
    func setShadow(_ window: BridgeWindow, _ shadow: Bool) async -> Bool {
        await sendAck(BridgeWire.setShadow(UInt32(window), shadow))
    }
    func setScale(_ window: BridgeWindow, _ scale: Double, anchor: CGPoint) async -> Bool {
        await sendAck(BridgeWire.setScale(UInt32(window), scale: scale,
                                          anchorX: Double(anchor.x), anchorY: Double(anchor.y)))
    }
    func move(_ window: BridgeWindow, toSpace space: UInt64) async -> Bool {
        await sendAck(BridgeWire.moveWindowToSpace(UInt32(window), space: space))
    }

    func createSpace(onDisplay display: CGDirectDisplayID) async -> UInt64? {
        guard status.isReady else { return nil }
        guard let reply = await send(BridgeWire.createSpace(onDisplay: UInt32(display)), expect: 9),
              reply.count == 9, reply[0] == 1 else { return nil }
        var sid: UInt64 = 0
        for i in 0..<8 { sid |= UInt64(reply[1 + i]) << (8 * i) }
        return sid == 0 ? nil : sid
    }
    func destroySpace(_ space: UInt64) async -> Bool {
        await sendAck(BridgeWire.destroySpace(space))
    }
    func focusSpace(_ space: UInt64) async -> Bool {
        await sendAck(BridgeWire.focusSpace(space))
    }
    func moveSpace(_ space: UInt64, after other: UInt64) async -> Bool {
        await sendAck(BridgeWire.moveSpace(space, after: other, focus: false))
    }

    // MARK: - Diagnostics

    var diagnostics: String {
        let installed = installedVersion ?? "no"
        let version: String
        if case .ready(let v) = status { version = v } else { version = installedVersion ?? "none" }
        return "bridgeStatus=\(statusWord) bridgeSIP=<\(sip.flags)> "
             + "bridgeBootArg=\(bootArgPresent) bridgeInstalled=\(installed) bridgeVersion=\(version)"
    }

    private var statusWord: String {
        switch status {
        case .sipEnabled: return "sipEnabled"
        case .needsBootArgument: return "needsBootArgument"
        case .notInstalled: return "notInstalled"
        case .notLoaded: return "notLoaded"
        case .ready(let v): return "ready(\(v))"
        case .failed(let m): return "failed(\(m))"
        }
    }

    /// Instructions text for a passwordless auto-load, shown in the UI. We never write sudoers.
    static var sudoersInstructions: String {
        let loader = "/Library/ScriptingAdditions/Atelier.osax/Contents/MacOS/loader"
        return """
        To let "Load at Login" run without the password prompt, add a sudoers rule yourself:

          sudo visudo -f /private/etc/sudoers.d/atelier

        then add one line (replace USERNAME with your short user name):

          USERNAME ALL=(root) NOPASSWD: \(loader)

        Atelier never writes this file for you. Remove it to require the password again.
        """
    }

    // MARK: - Socket I/O (connect/send/recv with timeouts)

    private func handshakeVersion() async -> String? {
        guard let reply = await send(BridgeWire.handshake(), expect: 64) else { return nil }
        return BridgeWire.decodeHandshake(reply)?.version
    }

    /// Send a frame; return true when the payload replied with a 0x01 ack.
    private func sendAck(_ bytes: [UInt8]) async -> Bool {
        guard status.isReady else { return false }
        guard let reply = await send(bytes, expect: 1) else { return false }
        return reply.first == 1
    }

    /// Open the socket, send `bytes`, read up to `expect` bytes, close. Returns nil on any
    /// failure or timeout. Runs off the main actor on the io queue.
    private func send(_ bytes: [UInt8], expect: Int, timeoutMs: Int32 = 400) async -> [UInt8]? {
        let path = socketPath
        return await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            io.async {
                cont.resume(returning: Self.roundtrip(path: path, bytes: bytes, expect: expect, timeoutMs: timeoutMs))
            }
        }
    }

    /// Blocking one-shot request/response on a unix socket, with a non-blocking connect guarded
    /// by select() and SO_SND/RCVTIMEO on the transfer. Not main-actor isolated.
    nonisolated static func roundtrip(path: String, bytes: [UInt8], expect: Int, timeoutMs: Int32) -> [UInt8]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer { close(fd) }

        // Non-blocking connect so a dead socket cannot hang us.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)   // includes trailing NUL
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let n = min(pathBytes.count, raw.count)
            pathBytes.withUnsafeBytes { src in
                raw.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: n)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let crc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if crc != 0 && errno != EINPROGRESS { return nil }

        if crc != 0 {
            var wset = fd_set(); fdZero(&wset); fdSet(fd, &wset)
            var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: (timeoutMs % 1000) * 1000)
            if select(fd + 1, nil, &wset, nil, &tv) <= 0 { return nil }
            var soErr: Int32 = 0; var l = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &l) != 0 || soErr != 0 { return nil }
        }

        // Back to blocking with timeouts for the transfer.
        _ = fcntl(fd, F_SETFL, flags)
        var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: (timeoutMs % 1000) * 1000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var sent = 0
        bytes.withUnsafeBytes { raw in
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
        if sent != bytes.count { return nil }
        if expect == 0 { return [] }

        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: expect)
        while out.count < expect {
            let n = read(fd, &buf, expect - out.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Running helpers

    /// Run a read-only diagnostic command, capturing stdout. Never privileged.
    nonisolated static func runReadOnly(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Run a shell script with administrator privileges (the system password prompt), off the
    /// main thread: the script may `killall Dock; sleep 1`, and the prompt waits on the person.
    /// Throws on failure or cancel.
    private func runPrivileged(_ shellScript: String, describing what: String) async throws {
        working = what
        defer { working = nil }
        if let failure = await AdminPrompt.run(shellScript, reason: what) {
            throw BridgeError.privilegedStepFailed("Could not \(what): \(failure)")
        }
    }

    /// POSIX single-quote a path for embedding in a /bin/sh command.
    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for inclusion inside an AppleScript double-quoted literal.
    nonisolated static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// The system's administrator prompt for one shell script, run by an explicit click and never on
/// its own. It runs `osascript` as a child process on a background queue, so the main thread
/// (the Studio, the Dock, every panel) keeps going while the prompt waits and while the script
/// runs. NSAppleScript did this on the main actor before, freezing Atelier for the whole step.
enum AdminPrompt {
    private static let queue = DispatchQueue(label: "net.dasantos.atelier.admin", qos: .userInitiated)

    /// nil on success, otherwise what went wrong, in a short sentence ("User canceled.").
    nonisolated static func run(_ shellScript: String, reason: String) async -> String? {
        let source = "do shell script \"\(DockBridge.appleScriptEscape(shellScript))\" "
            + "with prompt \"Atelier needs an administrator to \(DockBridge.appleScriptEscape(reason)).\" "
            + "with administrator privileges"
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: runNow(source)) }
        }
    }

    nonisolated private static func runNow(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return message(String(decoding: data, as: UTF8.self))
    }

    /// "0:120: execution error: User canceled. (-128)" becomes "User canceled."
    nonisolated static func message(_ stderr: String) -> String {
        var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "execution error: ") { text = String(text[range.upperBound...]) }
        if let open = text.range(of: " (", options: .backwards), text.hasSuffix(")") { text = String(text[..<open.lowerBound]) }
        return text.isEmpty ? "The administrator step did not finish." : text
    }
}

// fd_set helpers: Swift imports fd_set as an opaque tuple, so set/zero by hand.
private func fdZero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set.fds_bits) { $0.initializeMemory(as: Int32.self, repeating: 0) }
}
private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let i = Int(fd) / 32, bit = Int32(1) << (Int32(fd) % 32)
    withUnsafeMutablePointer(to: &set.fds_bits) {
        $0.withMemoryRebound(to: Int32.self, capacity: 32) { $0[i] |= bit }
    }
}
