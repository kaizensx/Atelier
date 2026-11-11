import AppKit
import ApplicationServices
import DockCore
import SwiftUI

// MARK: - Every permission, read in one place
//
// Accessibility, Screen Recording and the optional three are read here and nowhere else. The
// older watchers (AccessWatch, DockPermissions, ScreenCaptureAccess) stay as thin wrappers over
// this, so their call sites did not change: each is told on every read and acts only on a change
// it cares about. One timer: every 2 s while the Permissions sheet is open or an essential
// permission is missing, every 10 s otherwise (to notice a revoke), plus macOS's "the
// Accessibility list changed" notification and Atelier coming back to the front.
//
// What a row shows is pure logic, in DockCore (PermissionFlow), so it is tested without a Mac's
// real permissions. Nothing here ever prompts except the row's own button.

@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    /// One identity for both pages, so Set Up turns the page in place instead of closing the
    /// sheet and opening another.
    enum Sheet: String, Identifiable { case welcome, permissions; var id: String { "permissions" } }

    @Published private(set) var accessibility = AXIsProcessTrusted()
    /// CGPreflightScreenCaptureAccess, which can stay false until a relaunch.
    @Published private(set) var screenPreflight = CGPreflightScreenCaptureAccess()
    /// Preflight, or other apps' window names visible: the grant is there even before a relaunch.
    @Published private(set) var screenAllowed = ScreenRecordingFlag.allowed
    @Published private(set) var systemAudio: PermissionReading = .unknown
    @Published private(set) var fullDiskAccess: PermissionReading = .unknown
    @Published private(set) var appManagement: PermissionReading = .unknown
    @Published private(set) var tracks: [PermissionKind: PermissionTrack]
    /// Moves on with each read while the sheet is open, so a waiting row turns into the fix.
    @Published private(set) var now = Date()
    @Published var sheet: Sheet? {
        didSet {
            guard (sheet == nil) != (oldValue == nil) else { return }
            if sheet == nil { UserDefaults.standard.set(true, forKey: Self.welcomedKey) }
            // Not inside the view update that may have set it (the sheet's own dismissal).
            DispatchQueue.main.async { MainActor.assumeIsolated { PermissionCenter.shared.check() } }
        }
    }

    static let welcomedKey = "permissions.welcomed"
    /// Passed to the relaunched Atelier, which opens the sheet again at the permissions.
    static let reopenArgument = "--reopen-permissions"

    private var timer: Timer?
    private var interval = 0.0
    private var observers: [NSObjectProtocol] = []
    private var offeredAtLaunch = false

    private init() {
        let screen = CGPreflightScreenCaptureAccess() || ScreenRecordingFlag.allowed
        tracks = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map {
            ($0, PermissionTrack(grantedAtLaunch: $0 == .screenRecording ? screen : true))
        })
    }

    // MARK: Reading

    var readings: [PermissionKind: PermissionReading] {
        [.accessibility: accessibility ? .granted : .missing,
         .screenRecording: screenAllowed || screenPreflight ? .granted : .missing,
         .systemAudio: systemAudio, .fullDiskAccess: fullDiskAccess, .appManagement: appManagement]
    }

    var snapshot: PermissionSnapshot {
        PermissionSnapshot(readings: readings, tracks: tracks, now: now,
                           folder: Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent)
    }

    /// Idempotent. Never prompts.
    func start() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            // The list changes a moment before the process's trust does, and the flag can lag
            // further on a revoke: read it a few times over the next seconds.
            MainActor.assumeIsolated { PermissionCenter.shared.recheckSoon() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            // Coming back from System Settings.
            MainActor.assumeIsolated { PermissionCenter.shared.check() }
        })
        retime()
    }

    private var burst: [DispatchWorkItem] = []
    private var lastBurst = Date.distantPast

    /// A sign that Accessibility may have changed (the list changed, an event tap was turned off,
    /// a tap could not be made): read now, then again over the next seconds, since the flag can
    /// lag the change. Several signs at once make one burst.
    func recheckSoon() {
        check()
        guard Date().timeIntervalSince(lastBurst) > 1 else { return }
        lastBurst = Date()
        burst.forEach { $0.cancel() }
        burst = [0.6, 2, 5].map { delay in
            let item = DispatchWorkItem { MainActor.assumeIsolated { PermissionCenter.shared.check() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    /// Reads everything now and tells the wrappers. Each acts only on its own change.
    func check() {
        // AXIsProcessTrusted can keep answering yes for a while after a revoke; an AX request
        // that macOS refuses outright settles it (AccessWatch.swift).
        let ax = AXIsProcessTrusted() && !AXLiveProbe.refused()
        let preflight = CGPreflightScreenCaptureAccess()
        let allowed = preflight || ScreenRecordingFlag.allowed
        if ax != accessibility { accessibility = ax }
        if preflight != screenPreflight { screenPreflight = preflight }
        if allowed != screenAllowed { screenAllowed = allowed }
        AccessWatch.shared.sync(ax)
        ScreenCaptureAccess.shared.sync(preflight)
        DockPermissions.shared.sync(trusted: ax, screen: allowed)
        if sheet != nil {
            readOptional()
            now = Date()
        }
        retime()
    }

    /// The three that only the sheet shows, read only while it is open.
    private func readOptional() {
        let mixer = SoundMixer.shared
        mixer.recheckPermission()
        let audio: PermissionReading = switch mixer.permission {
        case .granted: .granted
        case .denied: .missing
        case .unknown: .unknown
        }
        if audio != systemAudio { systemAudio = audio }
        let disk: PermissionReading = Self.hasFullDiskAccess() ? .granted : .missing
        if disk != fullDiskAccess { fullDiskAccess = disk }
        // macOS offers no way to read App Management; a refused icon change is the one sign.
        let apps: PermissionReading = CustomIcons.shared.needsAppManagement ? .missing : .unknown
        if apps != appManagement { appManagement = apps }
    }

    /// The TCC database opens only with Full Disk Access. Opened and closed, never read.
    /// Without access macOS refuses quietly; there is no prompt.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    private func retime() {
        let wanted = PermissionFlow.pollInterval(sheetOpen: sheet != nil, readings: readings)
        guard wanted != interval || timer == nil, !observers.isEmpty else { return }
        interval = wanted
        timer?.invalidate()
        let next = Timer(timeInterval: wanted, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.check() }
        }
        next.tolerance = wanted * 0.1
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    // MARK: Acting

    /// A row's button.
    func perform(_ kind: PermissionKind, _ action: PermissionAction) {
        switch action {
        case .requestThenOpen: request(kind)
        case .openSettings: openPane(kind)
        case .relaunch: AtelierRelaunch.run()
        case .none: break
        }
    }

    /// The system call that puts Atelier in the right list (once a session, since macOS shows
    /// its prompt only once), then the exact pane, unless the call already says it is granted.
    func request(_ kind: PermissionKind) {
        start()
        var track = tracks[kind] ?? PermissionTrack(grantedAtLaunch: true)
        let first = track.requestedAt == nil
        track.requestedAt = track.requestedAt ?? Date()
        tracks[kind] = track
        var granted = false
        if first {
            switch kind {
            case .accessibility:
                AccessWatch.shared.markAsked()
                granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            case .screenRecording:
                // Files Atelier under Screen & System Audio Recording, the top list. Opening the
                // pane without this left it only under System Audio Recording Only.
                granted = CGRequestScreenCaptureAccess()
            default: break
            }
        }
        check()
        guard !granted else { return }
        // A beat for the system prompt to come up first; System Settings opens behind it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (first && kind.addsItselfToList ? 0.6 : 0)) {
            MainActor.assumeIsolated { PermissionCenter.shared.openPane(kind) }
        }
    }

    /// Recorded when something else showed the prompt (the Window Engine's own button).
    func noteRequested(_ kind: PermissionKind) {
        guard tracks[kind]?.requestedAt == nil else { return }
        tracks[kind]?.requestedAt = Date()
    }

    func openPane(_ kind: PermissionKind) {
        start()
        tracks[kind]?.paneOpenedAt = Date()
        if kind == .accessibility { AccessWatch.shared.markAsked() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + kind.settingsAnchor) {
            NSWorkspace.shared.open(url)
        }
        check()
    }

    /// "It's on but not working": the fix shows at once.
    func saysOn(_ kind: PermissionKind) {
        tracks[kind]?.userSaysOn = true
        check()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: The sheet

    func present(_ sheet: Sheet = .permissions) {
        start()
        ManagerWindow.shared.show()
        self.sheet = sheet
    }

    /// Once, when the Studio first appears: the Welcome on a first launch, or the permissions
    /// again after a relaunch made for one.
    func offerAtLaunchIfNeeded() {
        guard !offeredAtLaunch else { return }
        offeredAtLaunch = true
        switch PermissionFlow.launchSheet(welcomed: UserDefaults.standard.bool(forKey: Self.welcomedKey),
                                          reopenAfterRelaunch: CommandLine.arguments.contains(Self.reopenArgument)) {
        case .none: break
        case .welcome: sheet = .welcome
        case .permissions: sheet = .permissions
        }
    }
}

/// What the views draw from: the center's live state, or a fixed one for offline renders.
struct PermissionSnapshot {
    var readings: [PermissionKind: PermissionReading]
    var tracks: [PermissionKind: PermissionTrack]
    var now: Date
    /// The folder Atelier is installed in, named in the fix's "choose Atelier in …" step.
    var folder: String

    func reading(_ kind: PermissionKind) -> PermissionReading { readings[kind] ?? .unknown }
    func track(_ kind: PermissionKind) -> PermissionTrack { tracks[kind] ?? PermissionTrack(grantedAtLaunch: true) }
    func phase(_ kind: PermissionKind) -> PermissionPhase {
        PermissionFlow.phase(kind, reading: reading(kind), track: track(kind), now: now)
    }
    func action(_ kind: PermissionKind) -> PermissionAction {
        PermissionFlow.action(kind, phase: phase(kind), track: track(kind))
    }
    var essentialGranted: Bool { PermissionFlow.essentialMissing(readings).isEmpty }
    var grantedCount: Int { PermissionKind.allCases.filter { phase($0).isGranted }.count }
    /// The ones Atelier can read at all (App Management it cannot).
    var readableCount: Int { PermissionKind.allCases.filter { reading($0) != .unknown }.count }
}

/// What the views can ask for. The live sheet routes these to the center; renders pass nothing.
struct PermissionHandlers {
    var perform: (PermissionKind, PermissionAction) -> Void = { _, _ in }
    var openPane: (PermissionKind) -> Void = { _ in }
    var saysOn: (PermissionKind) -> Void = { _ in }
    var reveal: () -> Void = {}
    var relaunch: () -> Void = {}
    var close: () -> Void = {}
    var setUp: () -> Void = {}

    @MainActor static func live(close: @escaping () -> Void) -> PermissionHandlers {
        let center = PermissionCenter.shared
        return PermissionHandlers(perform: { center.perform($0, $1) }, openPane: { center.openPane($0) },
                                  saysOn: { center.saysOn($0) }, reveal: { center.revealInFinder() },
                                  relaunch: { AtelierRelaunch.run() }, close: close,
                                  setUp: { center.sheet = .permissions })
    }
}

// MARK: - A clean relaunch

/// Quits Atelier the normal way and opens it again. A small detached shell waits for this
/// process to end, then runs `open -n`. The quit is a real one (`quitForReal`), so
/// applicationWillTerminate puts the macOS Dock and everything else back and writes the
/// clean-exit marker: AtelierGuard reads a clean end and does nothing, and the new Atelier only
/// starts (and clears that marker) 0.6 s after the old one is gone, once the guard has seen it.
@MainActor
enum AtelierRelaunch {
    private static var running = false

    static func run(arguments: [String] = [PermissionCenter.reopenArgument]) {
        guard !running else { return }
        running = true
        // $1 the PID to wait for, $2 the bundle, the rest for the new Atelier. Passed as
        // arguments, never pasted into the script, so no path can break the quoting.
        let script = """
        for i in $(seq 1 150); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$1" 2>/dev/null && exit 1
        sleep 0.6
        app="$2"; shift 2
        /usr/bin/open -n "$app" --args "$@"
        """
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup and a background job: the waiter outlives Atelier, as the updater's does.
        launcher.arguments = ["-c", "nohup /bin/sh -c \"$ATELIER_RELAUNCH\" relaunch \"$@\" >/dev/null 2>&1 &", "sh",
                              String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ATELIER_RELAUNCH"] = script
        launcher.environment = environment
        do {
            try launcher.run()
            launcher.waitUntilExit()
        } catch {
            running = false
            Effects.shared.notice = "Atelier could not relaunch itself. Quit it from the menu bar and open it again."
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AppDelegate.quitForReal = true
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Look

private extension PermissionKind {
    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .systemAudio: "waveform"
        case .fullDiskAccess: "internaldrive"
        case .appManagement: "app.badge"
        }
    }

    var hue: Color {
        switch self {
        case .accessibility: DS.Spectrum.windows
        case .screenRecording: DS.Spectrum.surfaces
        case .systemAudio: DS.Spectrum.sound
        case .fullDiskAccess: DS.Spectrum.light
        case .appManagement: DS.Spectrum.input
        }
    }
}

enum PermissionInk {
    static let granted = Color(red: 0.42, green: 0.9, blue: 0.62)
    static let missing = Color(red: 1, green: 0.7, blue: 0.4)
    static let sheet = LinearGradient(colors: [Color(red: 0.055, green: 0.07, blue: 0.11), Color(red: 0.02, green: 0.025, blue: 0.04)],
                                      startPoint: .top, endPoint: .bottom)
}

/// A pill button: the prominent one in the row's hue, the quiet one in glass.
struct PermissionPill: ButtonStyle {
    var prominent = false
    var hue: Color = DS.Ink.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(prominent ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fillStrong), in: .capsule)
            .overlay { Capsule().strokeBorder(prominent ? Color.white.opacity(0.25) : DS.Ink.edge, lineWidth: 0.5) }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DS.Motion.touch, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Granted ✓, Not Yet, or why there is nothing to read.
struct PermissionBadge: View {
    let phase: PermissionPhase

    var body: some View {
        let (text, symbol, tint): (String, String?, Color) = switch phase {
        case .granted: ("Granted", "checkmark", PermissionInk.granted)
        case .grantedRelaunchSuggested: ("On · Relaunch", "arrow.clockwise", DS.Ink.accent)
        case .missing: ("Not Yet", nil, PermissionInk.missing)
        case .waiting: ("Waiting", nil, PermissionInk.missing)
        case .stale: ("Not Working", "exclamationmark", PermissionInk.missing)
        case .unknown: ("Asked When Needed", nil, DS.Ink.tertiary)
        }
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .heavy)) }
            Text(text.uppercased()).font(DS.Typo.badge).tracking(0.6)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).frame(height: 18)
        .background(tint.opacity(0.14), in: .capsule)
        .overlay { Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5) }
        .fixedSize()
        .contentTransition(.opacity)
        .accessibilityLabel(text)
    }
}

// MARK: - The sheet

/// Presents the Welcome and Permissions sheet over the Studio. Hung once on StudioView.
struct PermissionsSheetHost: ViewModifier {
    @ObservedObject private var center = PermissionCenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $center.sheet) { sheet in
                PermissionsSheet(start: sheet)
            }
            .onAppear {
                center.start()
                // After the Studio's own arrival, so the sheet does not land on an empty window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    MainActor.assumeIsolated { PermissionCenter.shared.offerAtLaunchIfNeeded() }
                }
            }
    }
}

/// The live sheet: the center's state, its actions.
struct PermissionsSheet: View {
    let start: PermissionCenter.Sheet
    @ObservedObject private var center = PermissionCenter.shared

    var body: some View {
        let handlers = PermissionHandlers.live(close: { center.sheet = nil })
        Group {
            switch center.sheet ?? start {
            case .welcome: WelcomePage(handlers: handlers)
            case .permissions: PermissionsPage(snapshot: center.snapshot, handlers: handlers)
            }
        }
        .onAppear { center.check() }
    }
}

/// First launch: who Atelier is, and the two switches that matter.
struct WelcomePage: View {
    var handlers = PermissionHandlers()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PermissionInk.sheet
                RadialGradient(colors: [Color(red: 0.3, green: 0.7, blue: 1).opacity(0.28), .clear],
                               center: .init(x: 0.5, y: 0.18), startRadius: 0, endRadius: 260)
                VStack(spacing: 16) {
                    FacetMark().frame(width: 74, height: 68)
                        .shadow(color: Color(red: 0.3, green: 0.75, blue: 1).opacity(0.45), radius: 22, y: 4)
                    VStack(spacing: 8) {
                        DisplayTitle(text: "Welcome to Atelier", size: 30)
                        Text("Your Dock, windows, menu bar and desktop, made yours.")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                    }
                }
                .padding(.top, 14)
            }
            .frame(height: 250)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.Ink.hairline).frame(height: 0.5) }

            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Most of Atelier works with two switches in System Settings. Atelier asks for each one only when you press its button, and starts using it the moment you allow it.")
                    .font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    point(.accessibility)
                    point(.screenRecording)
                    HStack(alignment: .top, spacing: DS.Space.m) {
                        tile("sparkles", DS.Ink.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Everything else").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                            Text("Themes, widgets, wallpapers and most settings need nothing at all.")
                                .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)

            footer
        }
        .frame(width: 600)
        .background(PermissionInk.sheet)
        .environment(\.colorScheme, .dark)
    }

    private func point(_ kind: PermissionKind) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            tile(kind.symbol, kind.hue)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                Text(kind.unlocks).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ symbol: String, _ hue: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(hue)
            .frame(width: 32, height: 32)
            .background(hue.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hue.opacity(0.3), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Text("You can always find this in Settings › Permissions.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            Spacer(minLength: DS.Space.s)
            Button("Later") { handlers.close() }.buttonStyle(PermissionPill()).keyboardShortcut(.cancelAction)
            Button("Set Up Permissions") { handlers.setUp() }
                .buttonStyle(PermissionPill(prominent: true, hue: DS.Ink.accent)).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(DS.Ink.hairline).frame(height: 0.5) }
    }
}

/// One row per permission, live, each with the one button that does the right thing.
struct PermissionsPage: View {
    let snapshot: PermissionSnapshot
    var handlers = PermissionHandlers()
    /// The rows scroll past this height. Renders pass nil to draw everything.
    var maxListHeight: CGFloat? = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                FacetMark().frame(width: 34, height: 31)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Permissions").font(DS.Typo.hero).foregroundStyle(DS.Ink.primary)
                    Text(subtitle).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)

            Group {
                if let maxListHeight { ScrollView { list }.frame(maxHeight: maxListHeight).fixedSize(horizontal: false, vertical: true) }
                else { list }
            }

            footer
        }
        .frame(width: 600)
        .background(PermissionInk.sheet)
        .environment(\.colorScheme, .dark)
        .animation(DS.Motion.gentle(DS.Motion.reveal), value: PermissionKind.allCases.map { snapshot.phase($0) })
    }

    private var subtitle: String {
        if snapshot.essentialGranted { return "Atelier has what it needs. The optional ones can wait until you use their feature." }
        return "Allow what you want, skip the rest. Each one works the moment you allow it."
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            group("Needed for most features")
            ForEach(PermissionKind.allCases.filter(\.essential)) { PermissionRow(kind: $0, snapshot: snapshot, handlers: handlers) }
            group("Optional").padding(.top, DS.Space.s)
            ForEach(PermissionKind.allCases.filter { !$0.essential }) { PermissionRow(kind: $0, snapshot: snapshot, handlers: handlers) }
        }
        .padding(.horizontal, 20).padding(.bottom, 18)
    }

    private func group(_ text: String) -> some View {
        Eyebrow(text: text).padding(.leading, 4).padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Text("\(snapshot.grantedCount) of \(snapshot.readableCount) allowed · Find this again in Settings.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary).monospacedDigit()
            Spacer(minLength: DS.Space.s)
            if snapshot.essentialGranted {
                Button("Done") { handlers.close() }
                    .buttonStyle(PermissionPill(prominent: true, hue: DS.Ink.accent)).keyboardShortcut(.defaultAction)
            } else {
                Button("Later") { handlers.close() }.buttonStyle(PermissionPill()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(DS.Ink.hairline).frame(height: 0.5) }
    }
}

struct PermissionRow: View {
    let kind: PermissionKind
    let snapshot: PermissionSnapshot
    var handlers = PermissionHandlers()

    var body: some View {
        let phase = snapshot.phase(kind)
        let action = snapshot.action(kind)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: kind.symbol).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(phase.isGranted ? kind.hue : kind.hue.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(kind.hue.opacity(0.14), in: .rect(cornerRadius: 9, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(kind.hue.opacity(0.3), lineWidth: 0.5) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DS.Space.s) {
                        Text(kind.title).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        PermissionBadge(phase: phase)
                    }
                    Text(kind.unlocks).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    note(phase)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if phase == .stale {
                    // The fix below carries the buttons.
                    EmptyView()
                } else if let title = PermissionFlow.actionTitle(action) {
                    Button(title) { handlers.perform(kind, action) }
                        .buttonStyle(PermissionPill(prominent: kind.essential || action == .relaunch, hue: kind.essential ? kind.hue : DS.Ink.accent))
                        .accessibilityHint(kind.title)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                        .foregroundStyle(PermissionInk.granted).frame(height: 28)
                        .accessibilityHidden(true)
                }
            }
            if phase == .stale {
                StaleFixPanel(kind: kind, folder: snapshot.folder, handlers: handlers)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(14)
        .background { CardSurface(style: phase == .stale ? .lit(PermissionInk.missing) : .standard, radius: DS.Radius.card - 4) }
        .accessibilityElement(children: .contain)
    }

    /// The line under the sentence: what is happening, or the way into the fix.
    @ViewBuilder private func note(_ phase: PermissionPhase) -> some View {
        switch phase {
        case .waiting where kind.canGoStale:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(PermissionInk.missing).frame(width: 6, height: 6)
                    Text("Turn on Atelier in \(kind.listName).").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                staleLink
            }
            .padding(.top, 2)
        case .missing where kind.canGoStale:
            staleLink.padding(.top, 2)
        case .waiting:
            Text("Turn on Atelier in \(kind.listName).").font(DS.caption).foregroundStyle(DS.Ink.tertiary).padding(.top, 2)
        case .grantedRelaunchSuggested:
            Text("It's on. Relaunch Atelier so window pictures and recording can use it too.")
                .font(DS.caption).foregroundStyle(DS.Ink.accent).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        default:
            EmptyView()
        }
    }

    private var staleLink: some View {
        Button { handlers.saysOn(kind) } label: {
            Text("It's on but not working").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.accent)
                .underline(true, color: DS.Ink.accent.opacity(0.4))
        }
        .buttonStyle(.plain)
    }
}

/// A stale entry after a re-sign: the switch shows on, macOS trusts an older Atelier. The
/// cure is to remove the entry and add Atelier again, so the steps say exactly that.
struct StaleFixPanel: View {
    let kind: PermissionKind
    let folder: String
    var handlers = PermissionHandlers()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text("macOS is holding an old entry").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                Text("After an update the switch can look on while macOS still trusts the previous Atelier. Add it again:")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: DS.Space.l) {
                SettingsListSketch(kind: kind)
                    .frame(width: 214)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(PermissionFlow.fixSteps(kind, folder: folder).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            StepNumber(index + 1)
                            Text(step).font(DS.caption).foregroundStyle(DS.Ink.primary.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let warning = PermissionFlow.listWarning(kind) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(PermissionInk.missing)
                    Text(warning).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            WrapStack(spacing: DS.Space.s, lineSpacing: DS.Space.s) {
                Button("Open Settings…") { handlers.openPane(kind) }
                    .buttonStyle(PermissionPill(prominent: true, hue: kind.hue))
                Button("Reveal Atelier in Finder") { handlers.reveal() }.buttonStyle(PermissionPill())
                if kind.mayNeedRelaunch {
                    Button("Relaunch Atelier") { handlers.relaunch() }.buttonStyle(PermissionPill())
                }
            }
        }
        .padding(DS.Space.m)
        .background(Color.black.opacity(0.22), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
    }
}

private struct StepNumber: View {
    let number: Int
    init(_ number: Int) { self.number = number }
    var body: some View {
        Text("\(number)").font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(width: 16, height: 16)
            .background(PermissionInk.missing, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A drawing of the System Settings list, with the three places to press numbered.
private struct SettingsListSketch: View {
    let kind: PermissionKind

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.18)).frame(width: 6, height: 6) }
                Spacer()
                Text("Privacy & Security").font(.system(size: 8, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                Color.clear.frame(width: 26, height: 1)
            }
            .padding(.horizontal, 8).frame(height: 18)
            .background(Color.white.opacity(0.04))

            VStack(alignment: .leading, spacing: 6) {
                Text(kind.listName).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                VStack(spacing: 0) {
                    appRow("Atelier", selected: true, badge: 1)
                    Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                    appRow("Another app", selected: false, badge: nil)
                    Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                    HStack(spacing: 0) {
                        bar("plus", badge: 3)
                        Rectangle().fill(DS.Ink.hairline).frame(width: 0.5, height: 12)
                        bar("minus", badge: 2)
                        Spacer()
                    }
                    .frame(height: 20)
                }
                .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 6, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }

                if kind == .screenRecording {
                    // The look-alike list below, struck out.
                    HStack(spacing: 4) {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(PermissionInk.missing)
                        Text("System Audio Recording Only").font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(DS.Ink.tertiary).strikethrough(true, color: DS.Ink.tertiary)
                    }
                    .padding(.top, 2)
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.025))
                        .frame(height: 16)
                        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
                }
            }
            .padding(8)
        }
        .background(Color(red: 0.11, green: 0.115, blue: 0.13), in: .rect(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(DS.Ink.edge, lineWidth: 0.5) }
        .clipShape(.rect(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The \(kind.listName) list in System Settings, with Atelier selected and the plus and minus buttons under it.")
    }

    private func appRow(_ name: String, selected: Bool, badge: Int?) -> some View {
        HStack(spacing: 6) {
            Group {
                if selected { FacetMark().padding(2) } else { RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.2)) }
            }
            .frame(width: 13, height: 12)
            Text(name).font(.system(size: 9, weight: .medium)).foregroundStyle(selected ? .white : DS.Ink.tertiary)
            Spacer(minLength: 4)
            if let badge { StepNumber(badge).scaleEffect(0.85) }
            // The switch, drawn on: it looks right, which is the trap.
            Capsule().fill(selected ? DS.Ink.accent : Color.white.opacity(0.18)).frame(width: 20, height: 11)
                .overlay(alignment: selected ? .trailing : .leading) { Circle().fill(.white).frame(width: 9, height: 9).padding(1) }
        }
        .padding(.horizontal, 7).frame(height: 22)
        .background(selected ? DS.Ink.accent.opacity(0.22) : .clear)
    }

    private func bar(_ symbol: String, badge: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(DS.Ink.primary)
                .frame(width: 18, height: 20)
            StepNumber(badge).scaleEffect(0.75).padding(.trailing, 2)
        }
    }
}

// MARK: - Settings and Home

/// Settings › Permissions: where each one stands, and the sheet one press away.
struct PermissionsCard: View {
    @ObservedObject private var center = PermissionCenter.shared
    /// Set by offline renders.
    var preview: PermissionSnapshot?

    var body: some View {
        let snapshot = preview ?? center.snapshot
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SettingRow(title: "Permissions",
                           detail: snapshot.essentialGranted ? "Atelier has what it needs." : "Some features wait for a switch in System Settings.",
                           symbol: "lock.shield", density: .compact) {
                    Chip("Review…") { PermissionCenter.shared.present(.permissions) }
                }
                WrapStack(spacing: DS.Space.s, lineSpacing: DS.Space.s) {
                    ForEach(PermissionKind.allCases) { kind in
                        HStack(spacing: 6) {
                            Text(kind.title).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            PermissionBadge(phase: snapshot.phase(kind))
                        }
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(DS.Ink.fill, in: .capsule)
                    }
                }
            }
        }
        .onAppear { center.start(); center.check() }
    }
}

/// Home's reminder while an essential permission is missing. Gone the moment it is granted.
struct PermissionsReminder: View {
    @ObservedObject private var center = PermissionCenter.shared
    var preview: [PermissionKind: PermissionReading]?

    var body: some View {
        if let text = PermissionFlow.homeReminder(preview ?? center.readings) {
            Button { PermissionCenter.shared.present(.permissions) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").font(.system(size: 12, weight: .semibold)).foregroundStyle(PermissionInk.missing)
                    Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                    Text("Review").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.accent)
                }
                .padding(.horizontal, 12).frame(height: 30)
                // A plain surface, not glass: it sits on the stage's wallpaper and must read on any.
                .background(Color.black.opacity(0.55), in: .capsule)
                .overlay { Capsule().strokeBorder(DS.Ink.edge, lineWidth: 0.5) }
                .contentShape(Capsule())
            }
            .buttonStyle(Pressable(scale: 0.96))
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .accessibilityLabel("\(text). Review permissions")
        }
    }
}
