import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// Pins a live copy of any window above everything, picture-in-picture style.
///
/// macOS has no public way to make another app's window float or turn translucent:
/// Accessibility exposes position and size, never level or alpha. A ScreenCaptureKit
/// stream of the one window, shown in our own floating panel, is the honest substitute.
/// Each pin streams only while it exists; closing it stops the capture.
@MainActor
final class WindowPin: ObservableObject {
    static let shared = WindowPin()
    private let store = UserDefaults.standard

    @Published var fps: Int { didSet { store.set(fps, forKey: "tools.pinFPS") } }
    @Published var opacity: Double { didSet { store.set(opacity, forKey: "tools.pinOpacity"); sessions.forEach { $0.panel.alphaValue = opacity } } }
    @Published private(set) var count = 0
    @Published private(set) var message: String?
    /// From the press to the first frame. A second press meanwhile is ignored, so a double
    /// press never opens two pins of one window.
    @Published private(set) var starting = false

    private var sessions: [PinSession] = []
    static let limit = 3

    private init() {
        fps = store.object(forKey: "tools.pinFPS") as? Int ?? 60
        opacity = store.object(forKey: "tools.pinOpacity") as? Double ?? 1
    }

    func pinFrontWindow() {
        guard !starting else { return }
        let access = ScreenCaptureAccess.shared
        guard access.refresh() else {
            message = "Needs Screen Recording. Grant it, then pin again."
            access.request()
            return
        }
        guard sessions.count < Self.limit else { message = "Up to \(Self.limit) pins at once."; return }
        guard let app = WindowEngine.shared.toolsTargetApp, let target = Self.frontWindow(of: app.processIdentifier) else {
            message = "There is no window to pin."
            return
        }
        guard !sessions.contains(where: { $0.windowID == target.id }) else { message = "That window is already pinned."; return }
        message = nil
        let rate = fps
        starting = true
        Task { await self.start(windowID: target.id, frame: target.bounds, pid: app.processIdentifier, fps: rate) }
    }

    func unpinAll() {
        for session in sessions { session.stop() }
        sessions = []
        count = 0
    }

    fileprivate func ended(_ session: PinSession) {
        session.panel.orderOut(nil)
        sessions.removeAll { $0 === session }
        count = sessions.count
    }

    /// The front-most normal window of an app, from the window list. Needs no Accessibility.
    private static func frontWindow(of pid: pid_t) -> (id: CGWindowID, bounds: CGRect)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? Int, let raw = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary), bounds.width > 60, bounds.height > 40 else { continue }
            return (CGWindowID(id), bounds)
        }
        return nil
    }

    private func start(windowID: CGWindowID, frame: CGRect, pid: pid_t, fps: Int) async {
        defer { starting = false }
        do {
            let content = try await ToolsCapture.content()
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                message = "That window can’t be captured."
                return
            }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            // A pin is small; capturing at most 1600 px wide keeps the cost down.
            let shrink = min(1, 1600 / (frame.width * scale))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(frame.width * scale * shrink)
            configuration.height = Int(frame.height * scale * shrink)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.queueDepth = 4
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let session = PinSession(windowID: windowID, pid: pid, size: Self.pinSize(for: frame.size), opacity: opacity)
            try await session.begin(filter: filter, configuration: configuration)
            sessions.append(session)
            count = sessions.count
        } catch {
            ScreenCaptureAccess.shared.refresh()
            message = "Could not pin that window: \(error.localizedDescription)"
        }
    }

    private static func pinSize(for size: CGSize) -> CGSize {
        let width = min(max(size.width * 0.32, 240), 520)
        return CGSize(width: width, height: (width * size.height / max(size.width, 1)).rounded())
    }
}

/// One pinned window: a stream, a display layer, and the panel that holds them.
final class PinSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    // Written once on the main actor before the stream starts, read from the capture queue.
    private let layer = AVSampleBufferDisplayLayer()
    /// Taken once on the main actor. The video renderer accepts buffers from any queue.
    nonisolated(unsafe) private let renderer: AVSampleBufferVideoRenderer
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "atelier.pin", qos: .userInteractive)
    @MainActor private(set) var panel: NSPanel!

    @MainActor init(windowID: CGWindowID, pid: pid_t, size: CGSize, opacity: Double) {
        self.windowID = windowID
        self.pid = pid
        renderer = layer.sampleBufferRenderer
        super.init()
        layer.videoGravity = .resizeAspect
        layer.preventsDisplaySleepDuringVideoPlayback = false
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let origin = CGPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
        let panel = PinPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentAspectRatio = size
        panel.alphaValue = opacity
        panel.contentView = NSHostingView(rootView: PinChrome(layer: layer, close: { [weak self] in
            MainActor.assumeIsolated { self?.closeTapped() }
        }, focus: { [pid] in
            NSRunningApplication(processIdentifier: pid)?.activate()
        }))
        self.panel = panel
    }

    @MainActor func begin(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
        panel.orderFrontRegardless()
    }

    @MainActor func stop() {
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
        panel.orderOut(nil)
    }

    @MainActor private func closeTapped() {
        stop()
        WindowPin.shared.ended(self)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
              let first = attachments.first else { return }
        // Idle and blank frames carry no new picture.
        if let raw = first[SCStreamFrameInfo.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        first[kCMSampleAttachmentKey_DisplayImmediately] = true
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // The window closed, or capture was revoked.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                self.panel.orderOut(nil)
                WindowPin.shared.ended(self)
            }
        }
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class LayerHost: NSView {
    let hosted: CALayer
    init(_ hosted: CALayer) {
        self.hosted = hosted
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(hosted)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}

private struct PinLayer: NSViewRepresentable {
    let layer: CALayer
    func makeNSView(context: Context) -> LayerHost { LayerHost(layer) }
    func updateNSView(_ view: LayerHost, context: Context) {}
}

private struct PinChrome: View {
    let layer: CALayer
    let close: () -> Void
    let focus: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.35)
            PinLayer(layer: layer)
            if hovering {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .atelierGlass(.regular, in: .circle)
                }
                .buttonStyle(Pressable(scale: 0.9))
                .padding(8)
                .transition(.opacity)
                .accessibilityLabel("Unpin")
            }
        }
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        // A lit top edge, as on every Atelier surface; brighter under the pointer, nothing moves.
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(hovering ? 0.32 : 0.22), .white.opacity(0.08)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
        }
        .onHover { inside in withAnimation(inside ? DS.Motion.hover : DS.Motion.exit) { hovering = inside } }
        .onTapGesture(count: 2, perform: focus)
        .help("Drag to move. Double-click to go to the window.")
    }
}
