import AppKit
import CryptoKit
import DockCore
import SwiftUI

// MARK: - Updates from GitHub Releases
//
// Checks github.com/kaizensx/Atelier for a newer release on the chosen channel, downloads it,
// and installs it only when its Ed25519 signature matches the key built into this app: a
// release that was tampered with, or uploaded by anyone without the maintainer's key, is
// refused. The running app is kept as a backup for "Roll back". Requests carry a generic
// User-Agent and nothing about the person.
//
// Test hook: atelier://update?check=1 | channel=stable|beta | auto=0|1 | install=1 |
//            feed=<url of a releases.json> | feed=default | rollback=1 | report=1
// The report goes to $TMPDIR/atelier-update.txt.

enum UpdateConfig {
    static let repository = "kaizensx/Atelier"
    static var releasesURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")! }
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }
    /// Public half of the release signing key. The private half never leaves the maintainer's Mac.
    static let publicKey = "y1GKXZIFsjhQfyC6AEWw5IpQ2kJ1io990yZS83bWjXc="
}

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle, checking, upToDate, available(ReleaseInfo), downloading(Double), ready(ReleaseInfo), installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheck: Date?
    @Published var channel: UpdateChannel { didSet { store.set(channel.rawValue, forKey: Keys.channel); if oldValue != channel { check() } } }
    @Published var automatic: Bool { didSet { store.set(automatic, forKey: Keys.auto); schedule() } }

    let current: AppVersion
    private let store = UserDefaults.standard
    private var timer: Timer?
    private var staged: URL?
    private var feedOverride: URL?
    private var log: [String] = []

    private enum Keys {
        static let channel = "updates.channel", auto = "updates.automatic", last = "updates.lastCheck", skipped = "updates.skipped"
    }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let text = (info["AtelierVersion"] as? String) ?? (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        current = AppVersion(text) ?? AppVersion("0.0.0")!
        channel = UpdateChannel(rawValue: store.string(forKey: Keys.channel) ?? "") ?? (current.isPrerelease ? .beta : .stable)
        automatic = store.object(forKey: Keys.auto) as? Bool ?? true
        lastCheck = store.object(forKey: Keys.last) as? Date
    }

    // MARK: Lifecycle

    func resume() {
        schedule()
        // a first look a little after launch, once the rest of Atelier has settled
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    func restoreOnQuit() { timer?.invalidate() }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard automatic else { return }
        let t = Timer(timeInterval: 3600, repeats: true) { _ in MainActor.assumeIsolated { Updater.shared.checkIfDue() } }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        guard automatic, UpdatePolicy.checkDue(last: lastCheck, now: Date()) else { return }
        check()
    }

    var previousInstalled: Bool { FileManager.default.fileExists(atPath: Self.previousURL.path) }

    // MARK: Check

    func check() {
        if case .downloading = phase { return }
        if case .installing = phase { return }
        phase = .checking
        note("check \(channel.rawValue) from \(feedOverride?.absoluteString ?? "github")")
        var request = URLRequest(url: feedOverride ?? UpdateConfig.releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Atelier-Updater", forHTTPHeaderField: "User-Agent")
        let channel = self.channel, current = self.current
        let skipped = Set(store.stringArray(forKey: Keys.skipped) ?? [])
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let result: Result<ReleaseInfo?, Error> = Result {
                if let error { throw error }
                guard (200..<300).contains(status), let data else { throw UpdateError.http(status) }
                return UpdatePolicy.pick(try UpdatePolicy.parseReleases(data), current: current, channel: channel, skipped: skipped)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = Updater.shared
                    me.lastCheck = Date(); me.store.set(me.lastCheck, forKey: Keys.last)
                    switch result {
                    case .success(let found?):
                        me.phase = .available(found); me.note("found \(found.version.value)")
                    case .success(nil):
                        me.phase = .upToDate; me.note("up to date at \(current)")
                    case .failure(let e):
                        me.phase = .failed(me.describe(e)); me.note("check failed: \(e)")
                    }
                    me.writeReport()
                }
            }
        }.resume()
    }

    func skip(_ release: ReleaseInfo) {
        var s = store.stringArray(forKey: Keys.skipped) ?? []
        s.append(release.version.value.description)
        store.set(s, forKey: Keys.skipped)
        phase = .upToDate
    }

    // MARK: Download and verify

    func download(_ release: ReleaseInfo) {
        guard let archive = release.archive, let sigAsset = release.signature else { return }
        phase = .downloading(0)
        note("download \(archive.name)")
        Task.detached(priority: .userInitiated) {
            do {
                let sigData = try await Self.fetch(sigAsset.url)
                let zip = try await Self.fetch(archive.url) { p in
                    Task { @MainActor in if case .downloading = Updater.shared.phase { Updater.shared.phase = .downloading(p) } }
                }
                guard UpdatePolicy.plausibleArchive(bytes: zip.count, announced: archive.size) else { throw UpdateError.size }
                guard let sig = Data(base64Encoded: String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                      let keyData = Data(base64Encoded: UpdateConfig.publicKey),
                      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                      key.isValidSignature(sig, for: zip) else { throw UpdateError.signature }
                let app = try Self.unpack(zip, version: release.version.value)
                await MainActor.run {
                    let me = Updater.shared
                    me.staged = app
                    me.phase = .ready(release)
                    me.note("verified and staged \(app.path)")
                    me.writeReport()
                }
            } catch {
                await MainActor.run {
                    let me = Updater.shared
                    me.phase = .failed(me.describe(error)); me.note("download failed: \(error)"); me.writeReport()
                }
            }
        }
    }

    nonisolated private static func fetch(_ url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Atelier-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw UpdateError.http(status) }
        let total = max(response.expectedContentLength, 1)
        var data = Data(); data.reserveCapacity(Int(max(total, 0)))
        var lastReport = 0
        for try await byte in bytes {
            data.append(byte)
            if let progress, data.count - lastReport > 262_144 { lastReport = data.count; progress(min(Double(data.count) / Double(total), 1)) }
        }
        return data
    }

    /// Unzips into the caches folder and checks it is really a newer Atelier, signed and whole.
    nonisolated private static func unpack(_ zip: Data, version: AppVersion) throws -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("net.dasantos.dockstacks/Updates/\(version)", isDirectory: true)
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let zipURL = root.appendingPathComponent("Atelier.zip")
        try zip.write(to: zipURL)
        guard run("/usr/bin/ditto", ["-x", "-k", zipURL.path, root.path]) == 0 else { throw UpdateError.unpack }
        let app = root.appendingPathComponent("Atelier.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let text = (info["AtelierVersion"] as? String), AppVersion(text) == version else { throw UpdateError.notAtelier }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { throw UpdateError.codesign }
        try? fm.removeItem(at: zipURL)
        return app
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    // MARK: Install

    static var previousURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Previous/Atelier.app", isDirectory: true)
    }

    /// Hands the swap to a small script that waits for Atelier to end, keeps the running copy as
    /// the backup, moves the new one into place and opens it.
    func installAndRelaunch() {
        guard case .ready(let release) = phase, let staged else { return }
        installSwap(from: staged, label: "update to \(release.version.value)")
    }

    func rollBack() {
        guard previousInstalled else { return }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AtelierRollback/Atelier.app")
        try? fm.removeItem(at: tmp.deletingLastPathComponent())
        try? fm.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard Self.run("/usr/bin/ditto", [Self.previousURL.path, tmp.path]) == 0 else { phase = .failed("The previous version could not be read."); return }
        installSwap(from: tmp, label: "roll back")
    }

    private func installSwap(from newApp: URL, label: String) {
        let dest = Bundle.main.bundleURL
        let prev = Self.previousURL
        let script = """
        #!/bin/bash
        # Atelier \(label): wait, back up, swap, relaunch.
        PID=\(ProcessInfo.processInfo.processIdentifier)
        for i in $(seq 1 150); do kill -0 $PID 2>/dev/null || break; sleep 0.2; done
        DEST="\(dest.path)"; NEW="\(newApp.path)"; PREV="\(prev.path)"
        mkdir -p "$(dirname "$PREV")"
        rm -rf "$PREV.tmp" && /usr/bin/ditto "$DEST" "$PREV.tmp" && rm -rf "$PREV" && mv "$PREV.tmp" "$PREV"
        rm -rf "$DEST.new" && /usr/bin/ditto "$NEW" "$DEST.new" || { open "$DEST"; exit 1; }
        [ -f "$DEST.new/Contents/Info.plist" ] || { rm -rf "$DEST.new"; open "$DEST"; exit 1; }
        rm -rf "$DEST" && mv "$DEST.new" "$DEST"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
        open "$DEST"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch { phase = .failed("The installer could not be written."); return }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup and a background job: the script outlives Atelier, which it is waiting for.
        launcher.arguments = ["-c", "nohup /bin/bash '\(scriptURL.path)' >'\(scriptURL.path).log' 2>&1 &"]
        do { try launcher.run(); launcher.waitUntilExit() } catch { phase = .failed("The installer could not start."); return }
        phase = .installing
        note("\(label): handing over to \(scriptURL.lastPathComponent)")
        writeReport()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AppDelegate.quitForReal = true
            NSApp.terminate(nil)
        }
    }

    // MARK: Errors, diagnostics, hook

    enum UpdateError: Error { case http(Int), size, signature, unpack, notAtelier, codesign }

    private func describe(_ e: Error) -> String {
        switch e {
        case UpdateError.http(404): "No releases were found."
        case UpdateError.http(403): "GitHub is limiting requests. Atelier tries again later."
        case UpdateError.http(let c): "GitHub answered \(c)."
        case UpdateError.size: "The download was incomplete."
        case UpdateError.signature: "The download's signature did not match, so it was not installed."
        case UpdateError.unpack: "The download could not be opened."
        case UpdateError.notAtelier: "The download was not the expected Atelier version."
        case UpdateError.codesign: "The downloaded app's code signature is broken, so it was not installed."
        default: (e as NSError).localizedDescription
        }
    }

    private func note(_ s: String) {
        log.append("\(ISO8601DateFormatter().string(from: Date())) \(s)")
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }

    var diagnostics: String {
        let p: String = switch phase {
        case .idle: "idle"; case .checking: "checking"; case .upToDate: "upToDate"
        case .available(let r): "available:\(r.version.value)"; case .downloading(let x): String(format: "downloading:%.2f", x)
        case .ready(let r): "ready:\(r.version.value)"; case .installing: "installing"; case .failed(let m): "failed:\(m.replacingOccurrences(of: " ", with: "_"))"
        }
        return "update=\(p) updateCurrent=\(current) updateChannel=\(channel.rawValue) updateAuto=\(automatic) updatePrevious=\(previousInstalled)"
    }

    private func writeReport() {
        let path = NSTemporaryDirectory() + "atelier-update.txt"
        try? ([diagnostics, "feed=\(feedOverride?.absoluteString ?? "github")"] + log).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func handleTest(_ items: [URLQueryItem]) {
        let value = { (n: String) in items.first { $0.name == n }?.value }
        if let f = value("feed") { feedOverride = f == "default" ? nil : URL(string: f) }
        if let c = value("channel").flatMap(UpdateChannel.init(rawValue:)) { channel = c }
        if let a = value("auto") { automatic = a == "1" }
        if value("check") != nil { check() }
        if value("download") != nil, case .available(let r) = phase { download(r) }
        if value("install") != nil {
            if case .ready = phase { installAndRelaunch() }
            else if case .available(let r) = phase { download(r) }
        }
        if value("rollback") != nil { rollBack() }
        writeReport()
    }
}

// MARK: - Card

struct UpdatesCard: View {
    @ObservedObject private var updater = Updater.shared
    private let hue = Color(red: 0.37, green: 0.83, blue: 1.0)

    var body: some View {
        HeroCard("Updates", pitch: "New versions arrive straight from GitHub, checked against Atelier's signature before anything is installed.",
                 isOn: $updater.automatic, hue: hue, badge: nil,
                 readout: updater.current.description, readoutCaption: updater.current.isPrerelease ? "beta" : "version") {
            plate
        } controls: {
            VStack(spacing: 0) {
                SettingRow(title: "Channel", detail: updater.channel == .beta
                           ? "Every new build first. Beta builds have been tested on the maintainer's Mac, but are newer and less proven."
                           : "Finished releases only, after they have run as betas.", symbol: "point.3.connected.trianglepath.dotted") {
                    Segments(selection: $updater.channel, options: [(.stable, "Stable"), (.beta, "Beta")]).frame(width: 170)
                }
                SettingRow(title: status, detail: statusDetail, symbol: statusSymbol) { actions }
                if updater.previousInstalled {
                    SettingRow(title: "Previous version", detail: "Kept from the last update, in case you want it back.", symbol: "clock.arrow.circlepath") {
                        Button("Roll Back") { updater.rollBack() }.buttonStyle(UpdatePill(prominent: false, hue: hue))
                    }
                }
            }
        }
    }

    private var plate: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.18), Color(red: 0.02, green: 0.03, blue: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 18) {
                FacetMark().frame(width: 54, height: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Atelier \(updater.current.description)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    Text(plateLine).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                }
                Spacer()
                if case .downloading(let p) = updater.phase {
                    ProgressRing(progress: p, hue: hue).frame(width: 34, height: 34)
                }
            }
            .padding(.horizontal, 22)
        }
        .frame(height: 112)
    }

    private var plateLine: String {
        switch updater.phase {
        case .available(let r), .ready(let r): "Atelier \(r.version.value) is ready for you"
        case .downloading: "Downloading and checking…"
        case .installing: "Installing, Atelier reopens in a moment"
        default:
            if let d = updater.lastCheck { "Checked " + d.formatted(.relative(presentation: .named)) } else { "Not checked yet" }
        }
    }

    private var status: String {
        switch updater.phase {
        case .idle, .upToDate: "Atelier is up to date"
        case .checking: "Checking GitHub…"
        case .available(let r): "Atelier \(r.version.value) is available"
        case .downloading: "Downloading…"
        case .ready(let r): "Atelier \(r.version.value) is verified and ready"
        case .installing: "Installing…"
        case .failed: "The last check did not finish"
        }
    }

    private var statusDetail: String? {
        switch updater.phase {
        case .failed(let m): m
        case .available(let r), .ready(let r): r.notes.split(separator: "\n").first.map(String.init)
        default: updater.automatic ? "Atelier looks every few hours." : "Automatic checks are off."
        }
    }

    private var statusSymbol: String {
        switch updater.phase {
        case .available, .ready: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        default: "checkmark.seal"
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch updater.phase {
            case .available(let r):
                Button("Release Notes") { NSWorkspace.shared.open(r.page ?? UpdateConfig.releasesPage) }.buttonStyle(UpdatePill(prominent: false, hue: hue))
                Button("Download") { updater.download(r) }.buttonStyle(UpdatePill(prominent: true, hue: hue))
            case .ready:
                Button("Install and Relaunch") { updater.installAndRelaunch() }.buttonStyle(UpdatePill(prominent: true, hue: hue))
            case .checking, .downloading, .installing:
                ProgressView().controlSize(.small)
            default:
                Button("Check Now") { updater.check() }.buttonStyle(UpdatePill(prominent: false, hue: hue))
            }
        }
    }
}

/// The Atelier mark, drawn natively: two facets and the glacier tip.
struct FacetMark: View {
    var body: some View {
        Canvas { ctx, size in
            func pt(_ x: Double, _ y: Double) -> CGPoint {   // mark box 0.08...0.92 x 0.10...0.88, y up
                CGPoint(x: (x - 0.08) / 0.84 * size.width, y: (0.88 - y) / 0.78 * size.height)
            }
            func poly(_ p: [(Double, Double)]) -> Path { var path = Path(); path.addLines(p.map { pt($0.0, $0.1) }); path.closeSubpath(); return path }
            let cap = 0.715, t = (0.88 - cap) / 0.78
            let lc = (0.5 - 0.42 * t, cap), rc = (0.5 + 0.42 * t, cap), mid = (0.5, cap)
            ctx.fill(poly([mid, lc, (0.08, 0.10), (0.34, 0.10), (0.5, 0.52)]), with: .color(Color(red: 0.86, green: 0.89, blue: 0.94)))
            ctx.fill(poly([mid, (0.5, 0.52), (0.66, 0.10), (0.92, 0.10), rc]), with: .color(Color(red: 0.49, green: 0.54, blue: 0.63)))
            ctx.fill(poly([(0.5, 0.88), lc, mid]), with: .color(Color(red: 0.37, green: 0.83, blue: 1.0)))
            ctx.fill(poly([(0.5, 0.88), mid, rc]), with: .color(Color(red: 0.18, green: 0.66, blue: 0.88)))
        }
    }
}

private struct ProgressRing: View {
    var progress: Double
    var hue: Color
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 3)
            Circle().trim(from: 0, to: progress).stroke(hue, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}

private struct UpdatePill: ButtonStyle {
    var prominent: Bool
    var hue: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(prominent ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fill), in: .capsule)
            .overlay { Capsule().strokeBorder(prominent ? Color.white.opacity(0.2) : DS.Ink.edge, lineWidth: 0.5) }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DS.Motion.touch, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
