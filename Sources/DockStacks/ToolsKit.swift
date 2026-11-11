import AppKit
import CoreAudio
import DockCore
import ImageIO
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Shell

enum ToolsShell {
    /// Runs a system tool off the main thread and returns its status and output.
    @discardableResult
    nonisolated static func run(_ path: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return (-1, "") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    static var scratch: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AtelierTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Text Grab

/// One-shot OCR: you drag a region with the system's own capture UI, Vision reads it,
/// the text goes to the clipboard. Nothing is kept.
@MainActor
final class TextGrab: ObservableObject {
    static let shared = TextGrab()
    @Published private(set) var lastText = ""
    @Published private(set) var working = false
    @Published var notice: String?

    func grab() {
        guard !working else { return }
        working = true
        notice = nil
        let file = ToolsShell.scratch.appendingPathComponent("grab-\(UUID().uuidString).png")
        Task {
            await ToolsShell.run("/usr/sbin/screencapture", ["-i", "-x", "-o", file.path])
            defer { try? FileManager.default.removeItem(at: file) }
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                working = false
                notice = "Cancelled."
                return
            }
            let text = await Self.recognise(image)
            working = false
            if text.isEmpty { notice = "No text found in that area."; return }
            lastText = text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notice = "Copied \(text.count) characters."
        }
    }

    nonisolated static func recognise(_ image: CGImage) async -> String {
        await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

// MARK: - Clipboard

@MainActor
final class ClipboardTools: ObservableObject {
    static let shared = ClipboardTools()
    @Published var notice: String?

    var preview: String {
        String((NSPasteboard.general.string(forType: .string) ?? "").prefix(140))
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
enum QuickLookTool {
    static func preview(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { await ToolsShell.run("/usr/bin/qlmanage", ["-p"] + urls.map(\.path)) }
    }

    /// Returns false when the clipboard holds nothing previewable.
    @MainActor static func previewClipboard() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            preview(urls); return true
        }
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = ToolsShell.scratch.appendingPathComponent("Clipboard.png")
            if (try? png.write(to: url)) != nil { preview([url]); return true }
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            let url = ToolsShell.scratch.appendingPathComponent("Clipboard.txt")
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { preview([url]); return true }
        }
        return false
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

    private var stream: SCStream?
    /// An SCRecordingOutput on macOS 15+, which is when ScreenCaptureKit learnt to write files.
    private var output: AnyObject?
    private var keysWereOn = false

    func toggle() { recording ? stop() : start() }

    func start() {
        notice = nil
        guard #available(macOS 15, *) else {
            notice = "Recording needs macOS 15 or later, where ScreenCaptureKit can write the file itself."
            return
        }
        startRecording()
    }

    @available(macOS 15, *)
    private func startRecording() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
                notice = "Recording could not start: \(error.localizedDescription) Screen Recording permission is needed."
            }
        }
    }

    func stop() {
        guard let stream else { return }
        Task {
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

/// Default input and output through CoreAudio's public HAL properties.
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

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        var address = address(selector)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(_ id: AudioObjectID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "Device \(id)" }
        return name.takeRetainedValue() as String
    }

    func refresh() {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        devices = ids.map {
            Device(id: $0, name: Self.name($0),
                   output: Self.hasStreams($0, scope: kAudioObjectPropertyScopeOutput),
                   input: Self.hasStreams($0, scope: kAudioObjectPropertyScopeInput))
        }
        defaultOutput = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        defaultInput = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    func use(_ device: Device, asOutput: Bool) {
        var id = device.id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(asOutput ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectSetPropertyData(system, &address, 0, nil, size, &id)
        if asOutput, alertsFollow {
            var alerts = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(system, &alerts, 0, nil, size, &id)
        }
        refresh()
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
            NSSound(named: "Glass")?.play()
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
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !blocked.contains(id), id != Bundle.main.bundleIdentifier { blocked.append(id) }
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
    @Published var files: [URL] = []
    @Published var plan = RenamePlan()
    @Published var notice: String?
    /// The last batch, new name to old, for Undo.
    @Published private(set) var undo: [(URL, URL)] = []

    var items: [RenamePlan.Item] {
        files.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return RenamePlan.Item(name: url.lastPathComponent, date: date)
        }
    }

    var preview: [String] { plan.names(for: items) }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        files = panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
