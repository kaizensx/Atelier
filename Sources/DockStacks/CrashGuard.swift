import AppKit
import Darwin
import ServiceManagement

/// The app's half of crash recovery. The other half is AtelierGuard, a launchd agent in the
/// bundle that outlives the app (see Sources/AtelierGuard/main.swift).
///
/// - While the macOS Dock is hidden, `restore-dock.sh` holds the commands that bring it back.
/// - A crash signal leaves a `crashed` marker, so the agent relaunches the app.
/// - A normal quit leaves `clean-exit`, so the agent does nothing.
/// - SIGTERM (`kill`, `pkill`, launchd) is a request to quit, not a crash: it runs the normal
///   quit, restores and all, so the agent sees a clean end. SIGKILL and crashes still relaunch.
enum CrashGuard {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Atelier/Guard", isDirectory: true)
    static let restoreScript = folder.appendingPathComponent("restore-dock.sh")
    static let crashedMarker = folder.appendingPathComponent("crashed")
    static let cleanMarker = folder.appendingPathComponent("clean-exit")
    // SMAppService shipped in macOS 13, so it is always present at Atelier's macOS 14 deployment
    // target — no #available gate is needed, and it is architecture-neutral (same on Intel and
    // Apple silicon). The one behavioural wrinkle across 14→27 is that macOS may hold the agent in
    // "requires approval" until the owner enables it in System Settings › Login Items; until then
    // `agent.status != .enabled` and crash recovery is simply off, which `register()` tolerates.
    @MainActor static let agent = SMAppService.agent(plistName: "net.dasantos.atelier.guard.plist")

    /// The marker's path, kept as C bytes: a signal handler may not allocate.
    nonisolated(unsafe) private static var crashedPath: UnsafeMutablePointer<CChar>?
    /// Kept alive for the life of the process.
    @MainActor private static var terminateSource: DispatchSourceSignal?
    @MainActor private static var terminating = false

    /// Whether the run before this launch ended in a crash. Read by plugin safe mode.
    @MainActor private(set) static var lastRunCrashed = false

    /// At launch, before anything can crash.
    @MainActor static func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        lastRunCrashed = FileManager.default.fileExists(atPath: crashedMarker.path)
        try? FileManager.default.removeItem(at: crashedMarker)
        try? FileManager.default.removeItem(at: cleanMarker)
        installSignalHandlers()
        installTerminateHandler()
        register()
    }

    /// SIGTERM becomes "Quit Atelier Completely". A no-op handler, not SIG_IGN, keeps the default
    /// from killing the process: a handler is reset to the default across exec, so the helpers
    /// Atelier starts (hidutil, the relaunch and update shells) still die on SIGTERM.
    @MainActor private static func installTerminateHandler() {
        guard terminateSource == nil else { return }
        signal(SIGTERM, { _ in })
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { CrashGuard.quitOnSignal() }
        }
        source.resume()
        terminateSource = source
    }

    @MainActor private static func quitOnSignal() {
        // A second SIGTERM, or a quit a sheet holds up: do what terminate would, then go.
        if terminating { forceCleanExit(); return }
        terminating = true
        AppDelegate.quitForReal = true
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { forceCleanExit() }
    }

    @MainActor private static func forceCleanExit() {
        NSApp.delegate?.applicationWillTerminate?(Notification(name: NSApplication.willTerminateNotification, object: NSApp))
        exit(0)
    }

    /// For `applicationWillTerminate`.
    static func noteCleanExit() {
        FileManager.default.createFile(atPath: cleanMarker.path, contents: nil)
    }

    /// The agent is registered with launchd once. macOS may ask the owner to allow it in
    /// Login Items; until then crash recovery is simply off.
    ///
    /// launchd keeps the registration pointing at the bundle it first saw. When the app is
    /// replaced (an update, a reinstall), the agent fails to spawn with EX_CONFIG until it is
    /// registered again, so a new build registers afresh once.
    @MainActor static func register() {
        let executable = Bundle.main.executableURL?.path ?? ""
        let modified = (try? FileManager.default.attributesOfItem(atPath: executable))?[.modificationDate] as? Date
        let stamp = "\(executable)|\(modified?.timeIntervalSince1970 ?? 0)"
        let key = "crashGuard.registeredBuild"
        if agent.status == .enabled, UserDefaults.standard.string(forKey: key) == stamp { return }
        Task { @MainActor in
            if agent.status == .enabled { try? await agent.unregister() }
            do {
                try agent.register()
                UserDefaults.standard.set(stamp, forKey: key)
            } catch {}
        }
    }

    @MainActor static var agentStatus: SMAppService.Status { agent.status }

    /// Remove Everything: the agent leaves launchd, and its folder goes. Without this the
    /// AtelierGuard launch agent stayed registered after Atelier's data was gone.
    @MainActor static func unregister() async {
        if agent.status != .notRegistered { try? await agent.unregister() }
        UserDefaults.standard.removeObject(forKey: "crashGuard.registeredBuild")
        try? FileManager.default.removeItem(at: folder)
    }

    /// Kept in step with the Dock guardian: written when the macOS Dock is hidden, removed
    /// when it is back.
    static func writeRestoreScript(_ script: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(script.utf8).write(to: restoreScript, options: .atomic)
    }

    static func removeRestoreScript() {
        try? FileManager.default.removeItem(at: restoreScript)
    }

    private static func installSignalHandlers() {
        crashedPath = strdup(crashedMarker.path)
        let handler: @convention(c) (Int32) -> Void = { signal in
            if let path = CrashGuard.crashedPath {
                let fd = open(path, O_CREAT | O_WRONLY, 0o644)
                if fd >= 0 { close(fd) }
            }
            // Let the crash go on as normal, so macOS still writes its report.
            Darwin.signal(signal, SIG_DFL)
            raise(signal)
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] { signal(sig, handler) }
    }
}
