import AppKit
import CoreAudio
import DockCore
import ImageIO
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Shell

/// What a system tool returned. `timedOut` and `cancelled` say why it was stopped early.
struct ShellResult: Sendable {
    var status: Int32
    var output: String
    var timedOut = false
    var cancelled = false
}

enum ToolsShell {
    /// Runs a system tool and waits for it without holding any thread: the exit arrives through
    /// its termination handler. Cancelling the calling task, or passing `timeout`, terminates it.
    @discardableResult
    nonisolated static func run(_ path: String, _ arguments: [String], timeout: TimeInterval? = nil) async -> ShellResult {
        let job = ShellJob(path: path, arguments: arguments)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                job.start(continuation, timeout: timeout)
            }
        } onCancel: {
            job.stop(timedOut: false)
        }
    }

    static var scratch: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AtelierTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One running tool. Every field is touched under the lock; the continuation resumes once.
private final class ShellJob: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private var output = Data()
    private var continuation: CheckedContinuation<ShellResult, Never>?
    private var finished = false
    private var timedOut = false
    private var cancelled = false

    init(path: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
    }

    func start(_ continuation: CheckedContinuation<ShellResult, Never>, timeout: TimeInterval?) {
        let early = lock.withLock { () -> Bool in
            self.continuation = continuation
            return cancelled
        }
        if early { finish(status: -1); return }
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { lock.withLock { output.append(data) } }
        }
        process.terminationHandler = { [self] process in
            // What the tool wrote just before it exited is still in the pipe.
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = (try? pipe.fileHandleForReading.readToEnd()) ?? nil
            if let rest { lock.withLock { output.append(rest) } }
            finish(status: process.terminationStatus)
        }
        do { try process.run() } catch { finish(status: -1); return }
        // A cancel that landed between the check above and the launch.
        if lock.withLock({ cancelled }) { stop(timedOut: false) }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in stop(timedOut: true) }
        }
    }

    func stop(timedOut: Bool) {
        let running = lock.withLock { () -> Bool in
            guard !finished else { return false }
            if timedOut { self.timedOut = true } else { cancelled = true }
            return process.isRunning
        }
        guard running else { return }
        process.terminate()
        // Anything that ignores SIGTERM gets SIGKILL a moment later.
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            if lock.withLock({ !finished }) { kill(pid, SIGKILL) }
        }
    }

    private func finish(status: Int32) {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<ShellResult, Never>?, ShellResult) in
            guard !finished else { return (nil, ShellResult(status: status, output: "")) }
            finished = true
            let result = ShellResult(status: status, output: String(decoding: output, as: UTF8.self), timedOut: timedOut, cancelled: cancelled)
            let pending = self.continuation
            self.continuation = nil
            return (pending, result)
        }
        continuation?.resume(returning: result)
    }
}

// MARK: - Screen Recording access

/// Whether Atelier may read the screen. Text Grab, the Screen Recorder and Pin Window ask here
/// first, so a missing permission shows as "Needs Screen Recording" instead of a blank capture
/// or a hang. While it is missing the answer is re-read every 2 s, so a grant in System
/// Settings lights the tools up without a relaunch.
@MainActor
final class ScreenCaptureAccess: ObservableObject {
    static let shared = ScreenCaptureAccess()
    @Published private(set) var granted = CGPreflightScreenCaptureAccess()

    @discardableResult
    func refresh() -> Bool {
        let now = CGPreflightScreenCaptureAccess()
        sync(now)
        return now
    }

    /// The 2 s re-check while access is missing is PermissionCenter's.
    func watch() {
        refresh()
        PermissionCenter.shared.start()
    }

    /// From PermissionCenter on every read.
    func sync(_ now: Bool) { if now != granted { granted = now } }

    /// The system prompt the first time, which files Atelier under Screen & System Audio
    /// Recording; then the Screen Recording pane.
    func request() {
        watch()
        PermissionCenter.shared.request(.screenRecording)
    }

    func openSettings() { PermissionCenter.shared.openPane(.screenRecording) }
}

/// "Needs Screen Recording · Grant…", shown under a tool for as long as access is missing.
struct ScreenRecordingNeeded: View {
    var detail = "Allow Atelier in System Settings, Privacy & Security, Screen Recording. It works as soon as you do."
    @ObservedObject private var access = ScreenCaptureAccess.shared

    var body: some View {
        Group {
            if !access.granted {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    Image(systemName: "lock.shield").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.orange.opacity(0.95))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Needs Screen Recording").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        Text(detail).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Chip("Grant…") { access.request() }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { access.watch() }
        .animation(DS.Motion.reveal, value: access.granted)
    }
}

/// ScreenCaptureKit's window and display list, with a deadline. Without a deadline the call
/// can wait on a permission prompt indefinitely.
enum ToolsCapture {
    struct TimedOut: LocalizedError {
        var errorDescription: String? { "Screen capture did not answer in time." }
    }

    nonisolated static func content(timeout: TimeInterval = 8) async throws -> SCShareableContent {
        let once = OnceResume<SCShareableContent>()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let content { once.resume(.success(content)) } else { once.resume(.failure(error ?? TimedOut())) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { once.resume(.failure(TimedOut())) }
        }
    }
}

/// Resumes a continuation exactly once, whichever of a result and a deadline comes first.
final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    func set(_ continuation: CheckedContinuation<T, any Error>) { lock.withLock { self.continuation = continuation } }

    func resume(_ result: sending Result<T, any Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<T, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

// MARK: - Text Grab

/// One-shot OCR: you drag a region with the system's own capture UI, Vision reads it,
/// the text goes to the clipboard. Nothing is kept.
///
/// Nothing here runs on the main thread but the bookkeeping: the capture UI is its own
/// process, decoding and Vision run on a background queue, and each step has a deadline.
/// Escape in the capture UI cancels it; pressing Grab (or its shortcut) again does too.
@MainActor
final class TextGrab: ObservableObject {
    static let shared = TextGrab()
    @Published private(set) var lastText = ""
    @Published private(set) var working = false
    @Published var notice: String?
    private var job: Task<Void, Never>?
    private var generation = 0

    func grab() {
        if working { cancel(); return }
        let access = ScreenCaptureAccess.shared
        guard access.refresh() else {
            // Without access, screencapture returns only the wallpaper: no text, and no reason why.
            notice = "Needs Screen Recording. Grant it, then grab again."
            access.request()
            return
        }
        working = true
        notice = nil
        generation += 1
        let current = generation
        let file = ToolsShell.scratch.appendingPathComponent("grab-\(UUID().uuidString).png")
        job = Task {
            // Two minutes to drag a region; the capture UI is the system's, Escape leaves it.
            let capture = await ToolsShell.run("/usr/sbin/screencapture", ["-i", "-x", "-o", file.path], timeout: 120)
            defer { try? FileManager.default.removeItem(at: file) }
            // A cancel or a newer grab owns the state now.
            guard current == generation, !Task.isCancelled else { return }
            if capture.timedOut { done("Timed out. Nothing was copied."); return }
            if capture.cancelled { done("Cancelled."); return }
            let text = await Self.read(file)
            guard current == generation, !Task.isCancelled else { return }
            guard let text else { done("Cancelled. Nothing was captured."); return }
            if text.isEmpty { done("No text found in that area."); return }
            lastText = text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            done("Copied \(text.count) characters.")
        }
    }

    func cancel() {
        generation += 1
        job?.cancel()
        job = nil
        working = false
        notice = "Cancelled."
    }

    private func done(_ message: String) {
        working = false
        job = nil
        notice = message
    }

    /// Decodes the capture and reads it. Nil when there was no capture (Escape, or a click
    /// without a drag).
    nonisolated static func read(_ file: URL, timeout: TimeInterval = 20) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: recogniseNow(image, timeout: timeout))
            }
        }
    }

    nonisolated static func recognise(_ image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: recogniseNow(image, timeout: 20)) }
        }
    }

    /// Blocking; call it off the main thread. Vision is told to stop if it runs past `timeout`.
    nonisolated private static func recogniseNow(_ image: CGImage, timeout: TimeInterval) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let box = RequestBox(request)
        let deadline = DispatchWorkItem { box.request.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        try? VNImageRequestHandler(cgImage: image).perform([request])
        deadline.cancel()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// Lets the deadline reach the request from another queue; cancel() is thread-safe.
private final class RequestBox: @unchecked Sendable {
    let request: VNRequest
    init(_ request: VNRequest) { self.request = request }
}

// MARK: - Clipboard

@MainActor
final class ClipboardTools: ObservableObject {
    static let shared = ClipboardTools()
    @Published var notice: String?
    private var previewCount = -1
    private var previewText = ""

    /// Read again only when the clipboard changes: the card redraws often, and a large copied
    /// text is not worth decoding on every frame.
    var preview: String {
        let board = NSPasteboard.general
        if board.changeCount != previewCount {
            previewCount = board.changeCount
            previewText = String((board.string(forType: .string) ?? "").prefix(140))
        }
        return previewText
    }

    func run(_ transform: TextTransform) {
        guard let text = NSPasteboard.general.string(forType: .string) else { notice = "The clipboard has no text."; return }
        guard let result = transform.apply(text) else { notice = "\(transform.title) does not apply to this text."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        notice = "\(transform.title): done. Formatting removed."
        objectWillChange.send()
    }
}

// MARK: - Quick Look

/// Quick Look anything: files, or whatever is on the clipboard, through Apple's qlmanage.
/// One preview at a time: a new one closes the last, so repeated presses never pile up.
@MainActor
enum QuickLookTool {
    private static var current: Task<Void, Never>?

    static func preview(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        current?.cancel()
        current = Task { await ToolsShell.run("/usr/bin/qlmanage", ["-p"] + urls.map(\.path)) }
    }

    /// Returns false when the clipboard holds nothing previewable. Images are written out
    /// off the main thread; a big screenshot on the clipboard is many megabytes.
    static func previewClipboard() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            preview(urls); return true
        }
        if let png = board.data(forType: .png) {
            write(png, as: "Clipboard.png"); return true
        }
        if let tiff = board.data(forType: .tiff) {
            write(tiff, as: "Clipboard.tiff"); return true
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            write(Data(text.utf8), as: "Clipboard.txt"); return true
        }
        return false
    }

    private static func write(_ data: Data, as name: String) {
        let url = ToolsShell.scratch.appendingPathComponent(name)
        Task {
            let written = await Task.detached(priority: .userInitiated) { (try? data.write(to: url, options: .atomic)) != nil }.value
            if written { preview([url]) }
        }
    }
}

// MARK: - Screen recorder

/// Records the main display to ~/Movies with ScreenCaptureKit's own recording output.
/// Clicks are drawn by macOS (showMouseClicks); keystrokes reuse Show Keystrokes.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()
    @Published private(set) var recording = false
    @Published private(set) var startedAt: Date?
    @Published var showClicks = true
    @Published var showKeys = false
    @Published var notice: String?
    @Published private(set) var lastFile: URL?
    /// Between the press and the first frame, or the stop and the file closing. Presses in
    /// between are ignored, so a double press never starts two streams.
    @Published private(set) var busy = false

    private var stream: SCStream?
    /// An SCRecordingOutput on macOS 15+, which is when ScreenCaptureKit learnt to write files.
    private var output: AnyObject?
    private var keysWereOn = false

    func toggle() {
        guard !busy else { return }
        recording ? stop() : start()
    }

    func start() {
        guard !busy, !recording else { return }
        notice = nil
        guard #available(macOS 15, *) else {
            notice = "Recording needs macOS 15 or later, where ScreenCaptureKit can write the file itself."
            return
        }
        let access = ScreenCaptureAccess.shared
        guard access.refresh() else {
            notice = "Needs Screen Recording. Grant it, then press Record again."
            access.request()
            return
        }
        startRecording()
    }

    @available(macOS 15, *)
    private func startRecording() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let content = try await ToolsCapture.content()
                let mainID = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                    notice = "No display to record."; return
                }
                let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainID }?.backingScaleFactor ?? 2
                configuration.width = Int(Double(display.width) * scale)
                configuration.height = Int(Double(display.height) * scale)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.showsCursor = true
                configuration.showMouseClicks = showClicks
                let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
                let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
                let file = folder.appendingPathComponent("Atelier Recording \(stamp).mov")
                let recordingConfiguration = SCRecordingOutputConfiguration()
                recordingConfiguration.outputURL = file
                recordingConfiguration.outputFileType = .mov
                let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addRecordingOutput(output)
                try await stream.startCapture()
                self.stream = stream
                self.output = output
                lastFile = file
                recording = true
                startedAt = Date()
                if showKeys {
                    keysWereOn = DesktopPlus.shared.keystrokes
                    DesktopPlus.shared.keystrokes = true
                }
            } catch {
                ScreenCaptureAccess.shared.refresh()
                notice = "Recording could not start: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        guard let stream, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            try? await stream.stopCapture()
            if #available(macOS 15, *), let output = output as? SCRecordingOutput { try? stream.removeRecordingOutput(output) }
            self.stream = nil
            self.output = nil
            recording = false
            startedAt = nil
            if showKeys, !keysWereOn { DesktopPlus.shared.keystrokes = false }
            if let lastFile { NSWorkspace.shared.activateFileViewerSelecting([lastFile]) }
        }
    }
}

@available(macOS 15, *)
extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            ScreenRecorder.shared.notice = "Recording stopped: \(message)"
            ScreenRecorder.shared.stop()
        }
    }
}

// MARK: - Display modes

/// Resolution presets through the public CGDisplay mode API. The original mode is kept
/// per display so one click puts it back. Brightness has no public API on Apple silicon.
@MainActor
final class DisplayModes: ObservableObject {
    static let shared = DisplayModes()

    struct Mode: Identifiable, Hashable {
        let id: Int32
        let width: Int
        let height: Int
        let pixelWidth: Int
        let refresh: Double
        var hiDPI: Bool { pixelWidth > width }
        var label: String { "\(width) × \(height)" + (hiDPI ? "" : " (low resolution)") + (refresh > 0 ? " · \(Int(refresh.rounded())) Hz" : "") }
    }

    struct Screen: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let modes: [Mode]
        let current: Int32
    }

    @Published private(set) var screens: [Screen] = []
    @Published var notice: String?
    private var originals: [CGDirectDisplayID: Int32] = [:]

    func refresh() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        screens = ids.map { id in
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let all = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            var seen = Set<String>()
            let modes = all.filter { $0.isUsableForDesktopGUI() }.map {
                Mode(id: $0.ioDisplayModeID, width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth, refresh: $0.refreshRate)
            }
            .sorted { ($0.width, $0.hiDPI ? 1 : 0, $0.refresh) > ($1.width, $1.hiDPI ? 1 : 0, $1.refresh) }
            .filter { seen.insert("\($0.width)x\($0.height)-\($0.hiDPI)-\(Int($0.refresh))").inserted }
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?
                .localizedName ?? "Display \(id)"
            return Screen(id: id, name: name, modes: modes, current: CGDisplayCopyDisplayMode(id)?.ioDisplayModeID ?? 0)
        }
    }

    func set(_ mode: Mode, on display: CGDirectDisplayID) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let target = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode])?.first(where: { $0.ioDisplayModeID == mode.id }) else { return }
        if originals[display] == nil { originals[display] = CGDisplayCopyDisplayMode(display)?.ioDisplayModeID }
        let result = CGDisplaySetDisplayMode(display, target, nil)
        notice = result == .success ? nil : "macOS refused that mode."
        refresh()
    }

    func canRestore(_ display: CGDirectDisplayID) -> Bool { originals[display] != nil }

    func restore(_ display: CGDirectDisplayID) {
        guard let original = originals[display], let screen = screens.first(where: { $0.id == display }),
              let mode = screen.modes.first(where: { $0.id == original }) else { originals[display] = nil; return }
        set(mode, on: display)
        originals[display] = nil
    }
}

// MARK: - Audio devices

/// Default input and output through CoreAudio's public HAL properties. The HAL can take a
/// long moment to answer (a Bluetooth headset waking, an AirPlay device), so every call runs
/// off the main thread and only the result is published here.
@MainActor
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    struct Device: Identifiable, Hashable {
        let id: AudioObjectID
        let name: String
        let output: Bool
        let input: Bool
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var defaultOutput: AudioObjectID = 0
    @Published private(set) var defaultInput: AudioObjectID = 0
    @Published var alertsFollow = true

    nonisolated private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = address(selector)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    nonisolated private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    nonisolated private static func name(_ id: AudioObjectID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "Device \(id)" }
        return name.takeRetainedValue() as String
    }

    private struct Snapshot: Sendable {
        let devices: [Device]
        let output: AudioObjectID
        let input: AudioObjectID
    }

    nonisolated private static func snapshot() -> Snapshot? {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        let devices = ids.map {
            Device(id: $0, name: name($0),
                   output: hasStreams($0, scope: kAudioObjectPropertyScopeOutput),
                   input: hasStreams($0, scope: kAudioObjectPropertyScopeInput))
        }
        return Snapshot(devices: devices, output: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
                        input: defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
    }

    func refresh() {
        Task {
            guard let snapshot = await Task.detached(priority: .userInitiated, operation: { Self.snapshot() }).value else { return }
            publish(snapshot)
        }
    }

    private func publish(_ snapshot: Snapshot) {
        if devices != snapshot.devices { devices = snapshot.devices }
        defaultOutput = snapshot.output
        defaultInput = snapshot.input
    }

    func use(_ device: Device, asOutput: Bool) {
        // Shown at once; the HAL catches up off the main thread.
        if asOutput { defaultOutput = device.id } else { defaultInput = device.id }
        let follow = alertsFollow, target = device.id
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) { () -> Snapshot? in
                var id = target
                let size = UInt32(MemoryLayout<AudioObjectID>.size)
                let system = AudioObjectID(kAudioObjectSystemObject)
                var address = Self.address(asOutput ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
                AudioObjectSetPropertyData(system, &address, 0, nil, size, &id)
                if asOutput, follow {
                    var alerts = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
                    AudioObjectSetPropertyData(system, &alerts, 0, nil, size, &id)
                }
                return Self.snapshot()
            }.value
            if let snapshot { publish(snapshot) }
        }
    }
}

// MARK: - Timers

@MainActor
final class TimerShelf: ObservableObject {
    static let shared = TimerShelf()

    struct Item: Identifiable, Codable, Equatable {
        var id = UUID()
        var label: String
        var end: Date
        var isAlarm: Bool
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var ringing: Item?
    private var tick: Timer?

    func add(minutes: Double, label: String? = nil) {
        items.append(Item(label: label ?? "\(Int(minutes)) min", end: Date().addingTimeInterval(minutes * 60), isAlarm: false))
        schedule()
    }

    func addAlarm(at date: Date) {
        var end = date
        if end < Date() { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
        items.append(Item(label: "Alarm \(end.formatted(date: .omitted, time: .shortened))", end: end, isAlarm: true))
        schedule()
    }

    func remove(_ item: Item) { items.removeAll { $0.id == item.id }; schedule() }

    func dismiss() { ringing = nil; TimerHUD.shared.hide() }

    private func schedule() {
        items.sort { $0.end < $1.end }
        tick?.invalidate()
        guard let next = items.first else { tick = nil; return }
        // One timer for the next deadline, not a tick per second.
        tick = Timer.scheduledTimer(withTimeInterval: max(0.05, next.end.timeIntervalSinceNow), repeats: false) { _ in
            Task { @MainActor in TimerShelf.shared.fire() }
        }
    }

    private func fire() {
        let now = Date()
        let due = items.filter { $0.end <= now.addingTimeInterval(0.2) }
        items.removeAll { due.contains($0) }
        if let last = due.last {
            ringing = last
            SoundPackRuntime.timerDone()
            TimerHUD.shared.show(last.label)
        }
        schedule()
    }
}

/// A small glass card at the top of the screen. Does not take focus.
@MainActor
final class TimerHUD {
    static let shared = TimerHUD()
    private var panel: NSPanel?

    func show(_ label: String) {
        hide()
        guard let screen = NSScreen.main else { return }
        let size = CGSize(width: 300, height: 74)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TimerHUDView(label: label))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() { panel?.orderOut(nil); panel = nil }
}

private struct TimerHUDView: View {
    let label: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "alarm.waves.left.and.right.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(DS.Ink.accent)
                .atelierWiggle()
            VStack(alignment: .leading, spacing: 2) {
                Text("Time’s up").font(DS.title)
                Text(label).font(DS.caption).foregroundStyle(DS.Ink.secondary)
            }
            Spacer()
            Button("Done") { TimerShelf.shared.dismiss() }.atelierGlassButton()
        }
        .padding(.horizontal, 16)
        .frame(width: 300, height: 74)
        .atelierGlass(.regular, in: .rect(cornerRadius: 22))
    }
}

// MARK: - Focus session

/// While a session runs, the listed apps are hidden (or asked to quit) whenever they come
/// forward. It cannot stop you reopening them, and says so.
@MainActor
final class FocusSession: ObservableObject {
    static let shared = FocusSession()

    @Published var blocked: [String] { didSet { UserDefaults.standard.set(blocked, forKey: "focus.blocked") } }
    @Published var quitInstead = false
    @Published private(set) var endsAt: Date?
    @Published private(set) var deflected = 0
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    private init() { blocked = UserDefaults.standard.stringArray(forKey: "focus.blocked") ?? [] }

    var running: Bool { endsAt != nil }

    func start(minutes: Double) {
        endsAt = Date().addingTimeInterval(minutes * 60)
        deflected = 0
        for app in NSWorkspace.shared.runningApplications where blocked.contains(app.bundleIdentifier ?? "") { deflect(app) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.processIdentifier
            Task { @MainActor in
                guard let id, let app = NSRunningApplication(processIdentifier: id) else { return }
                FocusSession.shared.consider(app)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { _ in
            Task { @MainActor in FocusSession.shared.stop() }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        endsAt = nil
    }

    private func consider(_ app: NSRunningApplication) {
        guard running, let id = app.bundleIdentifier, blocked.contains(id) else { return }
        deflect(app)
    }

    private func deflect(_ app: NSRunningApplication) {
        deflected += 1
        if quitInstead { app.terminate() } else { app.hide() }
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        // Not runModal: a modal loop stops every timer and animation in the app until it closes.
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                let session = FocusSession.shared
                for url in urls {
                    if let id = Bundle(url: url)?.bundleIdentifier, !session.blocked.contains(id), id != Bundle.main.bundleIdentifier {
                        session.blocked.append(id)
                    }
                }
            }
        }
    }

    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Batch rename

@MainActor
final class BatchRenamer: ObservableObject {
    static let shared = BatchRenamer()
    /// Dates are read once when the list changes, not on every redraw of the preview.
    @Published var files: [URL] = [] { didSet { dates = files.map(Self.date) } }
    @Published var plan = RenamePlan()
    private var dates: [Date] = []
    @Published var notice: String?
    /// The last batch, new name to old, for Undo.
    @Published private(set) var undo: [(URL, URL)] = []

    private static func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }

    var items: [RenamePlan.Item] {
        zip(files, dates).map { RenamePlan.Item(name: $0.lastPathComponent, date: $1) }
    }

    var preview: [String] { plan.names(for: items) }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            MainActor.assumeIsolated { BatchRenamer.shared.files = urls }
        }
    }

    func apply() {
        let names = preview
        let manager = FileManager.default
        var staged: [(temp: URL, original: URL, target: URL)] = [], failed = 0
        // Through temporary names first, so swapping two names never collides.
        for (url, name) in zip(files, names) where url.lastPathComponent != name {
            let folder = url.deletingLastPathComponent()
            let temp = folder.appendingPathComponent(".atelier-rename-\(UUID().uuidString)")
            do { try manager.moveItem(at: url, to: temp); staged.append((temp, url, folder.appendingPathComponent(name))) }
            catch { failed += 1 }
        }
        var done: [(URL, URL)] = []
        for item in staged {
            if !manager.fileExists(atPath: item.target.path), (try? manager.moveItem(at: item.temp, to: item.target)) != nil {
                done.append((item.target, item.original))
            } else {
                try? manager.moveItem(at: item.temp, to: item.original)
                failed += 1
            }
        }
        undo = done
        let renamed = Dictionary(done.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })
        files = files.map { renamed[$0] ?? $0 }
        notice = failed == 0 ? "Renamed \(done.count) items." : "Renamed \(done.count). \(failed) could not be renamed and kept their names."
    }

    func revert() {
        var restored = 0
        for (current, original) in undo where !FileManager.default.fileExists(atPath: original.path) {
            if (try? FileManager.default.moveItem(at: current, to: original)) != nil { restored += 1 }
        }
        files = undo.map(\.1)
        undo = []
        notice = "Put back \(restored) names."
    }
}

// MARK: - Image converter

enum ImageConverter {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case png, jpeg, heic
        var id: String { rawValue }
        var type: UTType { switch self { case .png: .png; case .jpeg: .jpeg; case .heic: .heic } }
        var ext: String { switch self { case .png: "png"; case .jpeg: "jpg"; case .heic: "heic" } }
    }

    /// Writes "name (converted).ext" beside each original. Originals are never touched.
    nonisolated static func convert(_ urls: [URL], to format: Format, maxPixels: Int, quality: Double) async -> (done: Int, failed: Int) {
        await Task.detached {
            var done = 0, failed = 0
            for url in urls {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { failed += 1; continue }
                var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true]
                if maxPixels > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels }
                else if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                        let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
                    options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height)
                }
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { failed += 1; continue }
                let base = url.deletingPathExtension().lastPathComponent + " (converted)"
                var target = url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(format.ext)
                var copy = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    target = url.deletingLastPathComponent().appendingPathComponent("\(base) \(copy)").appendingPathExtension(format.ext)
                    copy += 1
                }
                guard let destination = CGImageDestinationCreateWithURL(target as CFURL, format.type.identifier as CFString, 1, nil) else { failed += 1; continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination) { done += 1 } else { failed += 1 }
            }
            return (done, failed)
        }.value
    }
}

// MARK: - Finder toolbar scripts

/// Small AppleScript applets you ⌘-drag into Finder's toolbar. Built with Apple's osacompile
/// into ~/Applications/Atelier Finder Scripts. The first run asks to control Finder.
enum FinderScripts {
    struct Script: Identifiable, Sendable {
        let name: String
        let symbol: String
        let source: String
        var id: String { name }
    }

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Atelier Finder Scripts", isDirectory: true)

    private static let target = "tell application \"Finder\" to set here to (target of front window) as alias"

    static let all: [Script] = [
        Script(name: "Open Terminal Here", symbol: "terminal",
               source: "\(target)\ndo shell script \"open -a Terminal \" & quoted form of POSIX path of here"),
        Script(name: "New Text File", symbol: "doc.badge.plus",
               source: "tell application \"Finder\"\nset here to target of front window\nset i to 1\nset n to \"Untitled.txt\"\nrepeat while exists item n of here\nset i to i + 1\nset n to \"Untitled \" & i & \".txt\"\nend repeat\nmake new file at here with properties {name:n}\nend tell"),
        Script(name: "Copy Path", symbol: "doc.on.clipboard",
               source: "tell application \"Finder\"\nset s to selection\nif s is {} then set s to {target of front window}\nset p to POSIX path of (item 1 of s as alias)\nend tell\nset the clipboard to p"),
    ]

    static func isInstalled(_ script: Script) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(script.name + ".app").path)
    }

    /// Returns an error message, or nil.
    static func install(_ script: Script) async -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent(script.name + ".app")
        let result = await ToolsShell.run("/usr/bin/osacompile", ["-o", app.path, "-e", script.source])
        guard result.status == 0 else { return "osacompile could not build \(script.name)." }
        if let symbol = NSImage(systemSymbolName: script.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 256, weight: .regular)) {
            await MainActor.run { _ = NSWorkspace.shared.setIcon(symbol, forFile: app.path, options: []) }
        }
        return nil
    }

    static func remove(_ script: Script) {
        try? FileManager.default.trashItem(at: folder.appendingPathComponent(script.name + ".app"), resultingItemURL: nil)
    }
}
