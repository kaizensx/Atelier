import AppKit
import Darwin

// Atelier's crash guard: a tiny launchd agent, separate from the app, so it outlives it.
//
// The app's own /bin/sh guardian is a child process. When the app dies, launchd tears down
// the app's whole job, child included, and the macOS Dock stayed hidden. This agent is its
// own job. It sleeps on NSWorkspace notifications (no polling) and, when Atelier ends:
//
//   * not cleanly (crash, kill, force quit): runs the Dock restore script the app keeps
//     while it hides the macOS Dock, so the Dock is back at once and clicks work again;
//   * by crashing (the app's signal handler left a `crashed` marker): relaunches Atelier
//     after 0.3 s, at most 3 times a minute, so a crash loop cannot spin.
//
// A plain quit writes `clean-exit` first, so nothing happens. Nothing here writes to the
// system beyond running the app's own restore script.

let appID = "net.dasantos.dockstacks"
let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Atelier/Guard", isDirectory: true)
let restoreScript = folder.appendingPathComponent("restore-dock.sh")
let crashedMarker = folder.appendingPathComponent("crashed")
let cleanMarker = folder.appendingPathComponent("clean-exit")

/// This binary lives in Atelier.app/Contents/MacOS, so the main bundle is Atelier itself.
/// launchd starts it with a relative argv[0], so the path is not read from there.
var appURL: URL {
    Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL
        : NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) ?? URL(fileURLWithPath: "/Applications/Atelier.app")
}

/// One line per event, for diagnosis. Kept short: the newest 200 lines.
func log(_ text: String) {
    let url = folder.appendingPathComponent("guard.log")
    var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    lines.append("\(Date()) \(text)")
    try? (lines.suffix(200).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Atelier's process, found by its executable path through libproc. NSWorkspace's lists and
/// notifications are not reliable in a process with no NSApplication.
func atelierPID() -> pid_t? {
    var pids = [pid_t](repeating: 0, count: 4096)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return nil }
    var path = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(Int(count)) where pid > 0 {
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0,
           String(cString: path).hasSuffix(".app/Contents/MacOS/DockStacks") { return pid }
    }
    return nil
}

@MainActor func atelierRunning() -> Bool { atelierPID() != nil }

@MainActor func restoreDock() {
    guard exists(restoreScript) else { return }
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = [restoreScript.path]
    shell.standardOutput = FileHandle.nullDevice
    shell.standardError = FileHandle.nullDevice
    try? shell.run()
    shell.waitUntilExit()
    try? FileManager.default.removeItem(at: restoreScript)
}

var relaunches: [Date] = []

@MainActor func relaunch() {
    relaunches = relaunches.filter { Date().timeIntervalSince($0) < 60 }
    guard relaunches.count < 3 else { return }
    relaunches.append(Date())
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard !atelierRunning() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--relaunched-after-crash"]
        log("relaunching \(appURL.path)")
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error { log("relaunch failed: \(error.localizedDescription)") }
        }
    }
}

log("guard started")
// A restore left over from a run this agent did not see end.
if !atelierRunning() { restoreDock() }

@MainActor func ended() {
    let clean = exists(cleanMarker)
    let crashed = exists(crashedMarker)
    log("Atelier ended clean=\(clean) crashed=\(crashed)")
    if !clean { restoreDock() }
    // Atelier is meant to stay running like part of the system: any end that was not the
    // person's own "Quit Atelier Completely" (crash, kill, force quit, jetsam) brings it back,
    // at most three times a minute so a crash loop cannot spin.
    if !clean { relaunch() }
    _ = crashed
}

/// The exit of the process being watched arrives through kqueue, the moment it happens.
nonisolated(unsafe) var watched: (pid: pid_t, source: DispatchSourceProcess)?  // main queue only

@MainActor func watch() {
    if let watched, kill(watched.pid, 0) == 0 { return }
    guard let pid = atelierPID(), pid != watched?.pid else { return }
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated {
            source.cancel()
            ended()
            watched = nil
        }
    }
    watched = (pid, source)
    source.resume()
}

// Picks up each new Atelier process. Two seconds is cheap and only matters after a launch.
let finder = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { watch() } }
RunLoop.main.add(finder, forMode: .common)
MainActor.assumeIsolated { watch() }

RunLoop.main.run()
