import AppKit
import ApplicationServices

// MARK: - The window you are working in
//
// Window Borders and Dim Inactive Windows both need to know which window has focus and where
// it is. One Accessibility observer on the front app answers for both: it hears focus changes,
// moves, resizes and minimising, and tells whoever has joined. It runs only while someone has.

@MainActor
final class FocusTracker {
    static let shared = FocusTracker()

    struct Focus: Equatable {
        /// Screen points, top-left origin, as Accessibility gives them.
        let frame: CGRect
        let windowID: CGWindowID?
    }

    /// The focused window, or nil when there is none worth marking: the desktop, a minimised
    /// or full-screen window, or something too small to be a document (a panel, a popover).
    private(set) var focus: Focus?

    private var listeners: [String: @MainActor () -> Void] = [:]
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var window: AXUIElement?
    private var activation: NSObjectProtocol?
    private var spaceChange: NSObjectProtocol?

    var running: Bool { activation != nil }

    func join(_ name: String, _ changed: @escaping @MainActor () -> Void) {
        listeners[name] = changed
        if running { changed() } else { start() }
    }

    func leave(_ name: String) {
        listeners[name] = nil
        if listeners.isEmpty { stop() }
    }

    private func start() {
        guard AXIsProcessTrusted() else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { FocusTracker.shared.follow(app) }
        }
        spaceChange = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FocusTracker.shared.retarget() }
        }
        follow(NSWorkspace.shared.frontmostApplication)
    }

    private func stop() {
        [activation, spaceChange].compactMap { $0 }.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        activation = nil
        spaceChange = nil
        detach()
        focus = nil
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
        window = nil
    }

    private static let appEvents = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                                    kAXWindowCreatedNotification, kAXApplicationHiddenNotification]
    private static let windowEvents = [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                                       kAXWindowMiniaturizedNotification]

    private func follow(_ app: NSRunningApplication?) {
        guard running, let app else { return }
        let pid = app.processIdentifier
        if pid != observedPID {
            detach()
            var created: AXObserver?
            let callback: AXObserverCallback = { _, _, _, _ in
                MainActor.assumeIsolated { FocusTracker.shared.retarget() }
            }
            guard AXObserverCreate(pid, callback, &created) == .success, let created else { publish(nil); return }
            observer = created
            observedPID = pid
            let element = AXUIElementCreateApplication(pid)
            for name in Self.appEvents { AXObserverAddNotification(created, element, name as CFString, nil) }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        }
        retarget()
        // An app that is coming forward raises its windows a moment after it says so; ask again
        // once they have landed, or whatever is ordered against them ends up in the wrong place.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { FocusTracker.shared.retarget() }
    }

    /// Reads the front app's focused window again and tells everyone where it is.
    func retarget() {
        guard running, let pid = observedPID else { return }
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { publish(nil); return }
        let focused = raw as! AXUIElement
        if window.map({ !CFEqual($0, focused) }) ?? true {
            if let observer, let old = window {
                for name in Self.windowEvents { AXObserverRemoveNotification(observer, old, name as CFString) }
            }
            window = focused
            if let observer {
                for name in Self.windowEvents { AXObserverAddNotification(observer, focused, name as CFString, nil) }
            }
        }
        guard let rect = frame(of: focused), rect.width > 80, rect.height > 60,
              !flag(focused, "AXFullScreen"), !flag(focused, kAXMinimizedAttribute) else { publish(nil); return }
        publish(Focus(frame: rect, windowID: DockAX.windowID(AXRef(element: focused))))
    }

    private func publish(_ focus: Focus?) {
        self.focus = focus
        for listener in listeners.values { listener() }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        var place: CFTypeRef?, extent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &place) == .success, let place,
              CFGetTypeID(place) == AXValueGetTypeID(), AXValueGetValue(place as! AXValue, .cgPoint, &position),
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &extent) == .success, let extent,
              CFGetTypeID(extent) == AXValueGetTypeID(), AXValueGetValue(extent as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func flag(_ element: AXUIElement, _ name: String) -> Bool {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success && (raw as? Bool) == true
    }
}
