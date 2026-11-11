import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Beyond SIP: what only the Dock can do
//
// Six window powers that macOS keeps for the Dock: fading another app's windows, keeping one above
// all others, showing one on every Space, shrinking one to a picture-in-picture, taking shadows away,
// and making or reordering Spaces. Atelier asks the Dock for them through the Dock Bridge
// (DockBridgeAPI.swift), which needs System Integrity Protection partly off.
//
// Rules this engine keeps:
// - Nothing is sent to the Dock unless `DockBridge.shared.status.isReady`. Settings are remembered
//   either way (UserDefaults, "bridge." prefix), so a Mac set up later picks them up.
// - Every effect is undone when its switch goes off: opacity 1, normal level, not sticky,
//   shadow back, scale 1. When the bridge stops answering (the Dock restarted) the Dock has
//   already dropped them, so the bookkeeping is simply cleared.
// - One poller, about once a second, and only while something needs it: new windows get the
//   opacity and the missing shadow; closed windows leave the pinned, sticky and PiP lists.
// - Shortcuts are Carbon hot keys ('BSIP'), registered only while their feature is on and the
//   bridge is ready.

/// A window on screen, as the window server lists it.
struct BridgeLiveWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    /// Global screen points, top-left origin.
    let bounds: CGRect
}

/// One window Atelier changed: pinned, sticky or shrunk. Window numbers do not survive a restart
/// of the app that owns them, so these lists live in memory only.
struct BridgeMarkedWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    var label: String { title.isEmpty ? app : "\(app) · \(title)" }
}

enum BridgeOpacityMode: String, CaseIterable, Identifiable {
    case inactive, all
    var id: String { rawValue }
    var title: String { self == .inactive ? "Inactive windows" : "All windows" }
}

enum BridgeCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        }
    }
    var unit: UnitPoint {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

/// The shortcut-driven features, in the order their hot key ids are numbered.
enum BridgeAction: Int, CaseIterable, Identifiable {
    case pin, sticky, pip
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .pin: "Pin on Top"
        case .sticky: "Sticky Window"
        case .pip: "Picture in Picture"
        }
    }
    fileprivate var storeKey: String {
        switch self {
        case .pin: "bridge.pin.key"
        case .sticky: "bridge.sticky.key"
        case .pip: "bridge.pip.key"
        }
    }
    /// ⌃⌥P, ⌃⌥S, ⌃⌥I.
    var defaultCombo: KeyCombo {
        let mods = controlKey | optionKey
        switch self {
        case .pin: return KeyCombo(keyCode: kVK_ANSI_P, modifiers: mods)
        case .sticky: return KeyCombo(keyCode: kVK_ANSI_S, modifiers: mods)
        case .pip: return KeyCombo(keyCode: kVK_ANSI_I, modifiers: mods)
        }
    }
}

/// 'BSIP'. Tools use 'ATol', Window Engine 'WEng', Command 'DSTK'.
private let bridgeHotKeySignature = OSType(0x42534950)

/// The PiP shrink factor.
let bridgePiPScale = 0.35

@MainActor
final class BeyondSIP: ObservableObject {
    static let shared = BeyondSIP()

    private let store = UserDefaults.standard
    private let bridge = DockBridge.shared

    // MARK: Settings (persisted)

    @Published var opacityEnabled: Bool { didSet { save(opacityEnabled, "bridge.opacity.enabled"); opacityChanged(wasOn: oldValue) } }
    @Published var opacityMode: BridgeOpacityMode { didSet { save(opacityMode.rawValue, "bridge.opacity.mode"); kick() } }
    /// Bundle id → alpha. 1 (or absent) leaves the app alone.
    @Published private(set) var opacityApps: [String: Double]
    @Published var pinEnabled: Bool { didSet { save(pinEnabled, "bridge.pin.enabled"); if !pinEnabled { unpinAll() }; reconcile() } }
    @Published var stickyEnabled: Bool { didSet { save(stickyEnabled, "bridge.sticky.enabled"); if !stickyEnabled { unstickAll() }; reconcile() } }
    @Published var pipEnabled: Bool { didSet { save(pipEnabled, "bridge.pip.enabled"); if !pipEnabled { restoreAllPiP() }; reconcile() } }
    @Published var pipCorner: BridgeCorner { didSet { save(pipCorner.rawValue, "bridge.pip.corner") } }
    @Published var noShadowEnabled: Bool { didSet { save(noShadowEnabled, "bridge.noShadow.enabled"); shadowChanged() } }
    @Published private(set) var combos: [BridgeAction: KeyCombo] = [:]
    @Published private(set) var conflicts: Set<BridgeAction> = []

    // MARK: Live state

    @Published private(set) var pinned: [BridgeMarkedWindow] = []
    @Published private(set) var sticky: [BridgeMarkedWindow] = []
    @Published private(set) var pipped: [CGWindowID: BridgeCorner] = [:]
    /// Windows whose alpha Atelier set, and to what.
    private var faded: [CGWindowID: Double] = [:]
    /// Windows whose shadow Atelier took away.
    private var shadowless: Set<CGWindowID> = []
    /// The last thing a shortcut did, for the chapter to show briefly.
    @Published private(set) var lastAction: String?

    private var poller: Task<Void, Never>?
    private var statusWatch: AnyCancellable?
    private var activation: NSObjectProtocol?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var started = false
    private var keysSuspended = false

    var ready: Bool { bridge.status.isReady }

    private init() {
        let d = UserDefaults.standard
        opacityEnabled = d.bool(forKey: "bridge.opacity.enabled")
        opacityMode = BridgeOpacityMode(rawValue: d.string(forKey: "bridge.opacity.mode") ?? "") ?? .inactive
        opacityApps = d.dictionary(forKey: "bridge.opacity.apps") as? [String: Double] ?? [:]
        pinEnabled = d.bool(forKey: "bridge.pin.enabled")
        stickyEnabled = d.bool(forKey: "bridge.sticky.enabled")
        pipEnabled = d.bool(forKey: "bridge.pip.enabled")
        pipCorner = BridgeCorner(rawValue: d.string(forKey: "bridge.pip.corner") ?? "") ?? .bottomRight
        noShadowEnabled = d.bool(forKey: "bridge.noShadow.enabled")
        for action in BridgeAction.allCases {
            if let data = d.data(forKey: action.storeKey) {
                // An empty record means the owner cleared it on purpose.
                combos[action] = try? JSONDecoder().decode(KeyCombo.self, from: data)
            } else {
                combos[action] = action.defaultCombo
            }
        }
    }

    // MARK: Lifetime

    /// Call once at launch. Follows the bridge: everything starts when it is ready, stops when not.
    func resume() {
        guard !started else { return }
        started = true
        statusWatch = bridge.$status.removeDuplicates().receive(on: RunLoop.main).sink { status in
            MainActor.assumeIsolated { BeyondSIP.shared.statusChanged(status) }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BeyondSIP.shared.kick() }
        }
        // A later turn of the run loop puts the hot key handler in front of Command's, which claims every key.
        DispatchQueue.main.async { MainActor.assumeIsolated { BeyondSIP.shared.reconcile() } }
    }

    private func statusChanged(_ status: BridgeStatus) {
        if !status.isReady {
            // The Dock has forgotten everything it did for us (it restarted, or the bridge went away).
            faded = [:]
            shadowless = []
            pinned = []
            sticky = []
            pipped = [:]
        }
        reconcile()
    }

    /// Starts or stops the hot keys and the poller to match the settings and the bridge.
    func reconcile() {
        guard started else { return }
        registerKeys()
        let needsPolling = ready && (opacityEnabled || noShadowEnabled || !pinned.isEmpty || !sticky.isEmpty || !pipped.isEmpty)
        if needsPolling, poller == nil {
            poller = Task { @MainActor in
                while !Task.isCancelled {
                    await BeyondSIP.shared.tick()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else if !needsPolling, let poller {
            poller.cancel()
            self.poller = nil
        }
    }

    /// Runs one pass now, between ticks: an app came forward, a setting changed.
    func kick() {
        guard ready else { return }
        Task { @MainActor in await BeyondSIP.shared.tick() }
    }

    // MARK: Reading the window server

    /// Ordinary windows on screen, front to back.
    nonisolated static func liveWindows() -> [BridgeLiveWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let own = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 80, bounds.height >= 60 else { return nil }
            return BridgeLiveWindow(id: CGWindowID(number), pid: pid,
                                    owner: info[kCGWindowOwnerName as String] as? String ?? "",
                                    title: info[kCGWindowName as String] as? String ?? "",
                                    bounds: bounds)
        }
    }

    /// The window you are working in: the front app's frontmost ordinary window.
    static func focusedWindow(in windows: [BridgeLiveWindow]? = nil) -> BridgeLiveWindow? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let list = windows ?? liveWindows()
        if let id = FocusTracker.shared.focus?.windowID, let match = list.first(where: { $0.id == id && $0.pid == front }) {
            return match
        }
        return list.first { $0.pid == front }
    }

    private static func exists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == Int(id) }
    }

    // MARK: The poller

    private func tick() async {
        guard ready else { return }
        let windows = Self.liveWindows()
        if opacityEnabled { await applyOpacity(windows) }
        if noShadowEnabled {
            for window in windows where !shadowless.contains(window.id) {
                if await bridge.setShadow(window.id, false) { shadowless.insert(window.id) }
            }
        }
        // Forget windows that closed.
        let onScreen = Set(windows.map(\.id))
        faded = faded.filter { onScreen.contains($0.key) || Self.exists($0.key) }
        shadowless = shadowless.filter { onScreen.contains($0) || Self.exists($0) }
        let pinnedLeft = pinned.filter { onScreen.contains($0.id) || Self.exists($0.id) }
        if pinnedLeft != pinned { pinned = pinnedLeft }
        let stickyLeft = sticky.filter { onScreen.contains($0.id) || Self.exists($0.id) }
        if stickyLeft != sticky { sticky = stickyLeft }
        let pipLeft = pipped.filter { onScreen.contains($0.key) || Self.exists($0.key) }
        if pipLeft != pipped { pipped = pipLeft }
        reconcile()
    }

    // MARK: Window Opacity

    func alpha(for bundleID: String) -> Double { opacityApps[bundleID] ?? 1 }

    func setAlpha(_ alpha: Double, for bundleID: String) {
        let value = min(max(alpha, 0.15), 1)
        if value >= 0.995 { opacityApps[bundleID] = nil } else { opacityApps[bundleID] = value }
        store.set(opacityApps, forKey: "bridge.opacity.apps")
    }

    /// Called when a slider is let go: apply at once rather than on the next tick.
    func opacityCommitted() { kick() }

    private func applyOpacity(_ windows: [BridgeLiveWindow]) async {
        let focused = Self.focusedWindow(in: windows)?.id
        var bundles: [pid_t: String] = [:]
        for window in windows {
            let bundle = bundles[window.pid] ?? NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? ""
            bundles[window.pid] = bundle
            let chosen = opacityApps[bundle] ?? 1
            let target = (opacityMode == .inactive && window.id == focused) ? 1 : chosen
            let current = faded[window.id] ?? 1
            guard abs(current - target) > 0.005 else { continue }
            if await bridge.setOpacity(window.id, target, duration: 0.2) {
                faded[window.id] = target >= 0.995 ? nil : target
            }
        }
    }

    private func opacityChanged(wasOn: Bool) {
        if !opacityEnabled && wasOn { restoreOpacity() }
        reconcile()
        kick()
    }

    private func restoreOpacity() {
        let windows = faded.keys
        faded = [:]
        guard ready else { return }
        Task { @MainActor in
            for id in windows { _ = await DockBridge.shared.setOpacity(id, 1, duration: 0.2) }
        }
    }

    // MARK: No Shadows

    private func shadowChanged() {
        if !noShadowEnabled {
            let windows = shadowless
            shadowless = []
            if ready {
                Task { @MainActor in for id in windows { _ = await DockBridge.shared.setShadow(id, true) } }
            }
        }
        reconcile()
        kick()
    }

    // MARK: Pin on Top, Sticky, Picture in Picture

    func perform(_ action: BridgeAction) {
        guard ready else { return }
        guard let window = Self.focusedWindow() else { note("No window to \(action == .pip ? "shrink" : "change")"); return }
        Task { @MainActor in
            let model = BeyondSIP.shared
            switch action {
            case .pin: await model.togglePin(window)
            case .sticky: await model.toggleSticky(window)
            case .pip: await model.togglePiP(window)
            }
            model.reconcile()
        }
    }

    private static func mark(_ window: BridgeLiveWindow) -> BridgeMarkedWindow {
        let app = NSRunningApplication(processIdentifier: window.pid)?.localizedName ?? window.owner
        return BridgeMarkedWindow(id: window.id, pid: window.pid, app: app, title: window.title)
    }

    private func togglePin(_ window: BridgeLiveWindow) async {
        if pinned.contains(where: { $0.id == window.id }) {
            await unpin(window.id)
        } else if await bridge.setOnTop(window.id, true) {
            pinned.append(Self.mark(window))
            note("Pinned \(Self.mark(window).app)")
        }
    }

    func unpin(_ id: CGWindowID) async {
        _ = await bridge.setOnTop(id, false)
        pinned.removeAll { $0.id == id }
        note("Unpinned")
        reconcile()
    }

    private func unpinAll() {
        let ids = pinned.map(\.id)
        pinned = []
        guard ready else { return }
        Task { @MainActor in for id in ids { _ = await DockBridge.shared.setOnTop(id, false) } }
    }

    private func toggleSticky(_ window: BridgeLiveWindow) async {
        if sticky.contains(where: { $0.id == window.id }) {
            await unstick(window.id)
        } else if await bridge.setSticky(window.id, true) {
            sticky.append(Self.mark(window))
            note("\(Self.mark(window).app) is on every desktop")
        }
    }

    func unstick(_ id: CGWindowID) async {
        _ = await bridge.setSticky(id, false)
        sticky.removeAll { $0.id == id }
        note("Back on one desktop")
        reconcile()
    }

    private func unstickAll() {
        let ids = sticky.map(\.id)
        sticky = []
        guard ready else { return }
        Task { @MainActor in for id in ids { _ = await DockBridge.shared.setSticky(id, false) } }
    }

    private func togglePiP(_ window: BridgeLiveWindow) async {
        if let corner = pipped[window.id] {
            _ = await bridge.setScale(window.id, 1, anchor: Self.anchor(for: window.bounds, corner: corner))
            pipped[window.id] = nil
            note("Restored")
        } else {
            let corner = pipCorner
            if await bridge.setScale(window.id, bridgePiPScale, anchor: Self.anchor(for: window.bounds, corner: corner)) {
                pipped[window.id] = corner
                note("Picture in picture, \(corner.title.lowercased())")
            }
        }
    }

    func restoreAllPiP() {
        let entries = pipped
        pipped = [:]
        guard ready else { return }
        let windows = Self.liveWindows()
        Task { @MainActor in
            for (id, corner) in entries {
                let bounds = windows.first { $0.id == id }?.bounds ?? .zero
                _ = await DockBridge.shared.setScale(id, 1, anchor: Self.anchor(for: bounds, corner: corner))
            }
        }
    }

    /// The point to scale about so the shrunk window lands in the screen's corner, 16 pt in.
    /// Scaling about P maps x to P + s(x − P); solving for the window's corner reaching the screen's
    /// corner gives P = (T − s·C) / (1 − s). Global points, top-left origin, like the window list.
    static func anchor(for bounds: CGRect, corner: BridgeCorner, scale: Double = bridgePiPScale) -> CGPoint {
        let screen = visibleFrame(containing: bounds)
        let margin = 16.0
        let windowCorner: CGPoint
        let target: CGPoint
        switch corner {
        case .topLeft:
            windowCorner = CGPoint(x: bounds.minX, y: bounds.minY)
            target = CGPoint(x: screen.minX + margin, y: screen.minY + margin)
        case .topRight:
            windowCorner = CGPoint(x: bounds.maxX, y: bounds.minY)
            target = CGPoint(x: screen.maxX - margin, y: screen.minY + margin)
        case .bottomLeft:
            windowCorner = CGPoint(x: bounds.minX, y: bounds.maxY)
            target = CGPoint(x: screen.minX + margin, y: screen.maxY - margin)
        case .bottomRight:
            windowCorner = CGPoint(x: bounds.maxX, y: bounds.maxY)
            target = CGPoint(x: screen.maxX - margin, y: screen.maxY - margin)
        }
        let s = min(max(scale, 0.05), 0.95)
        return CGPoint(x: (target.x - s * windowCorner.x) / (1 - s), y: (target.y - s * windowCorner.y) / (1 - s))
    }

    /// The visible frame (no menu bar, no Dock) of the screen holding most of `bounds`, top-left origin.
    static func visibleFrame(containing bounds: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return bounds }
        let flip = { (rect: CGRect) in
            CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        let best = NSScreen.screens.max { a, b in
            flip(a.frame).intersection(bounds).area < flip(b.frame).intersection(bounds).area
        } ?? primary
        return flip(best.visibleFrame)
    }

    private func note(_ text: String) {
        lastAction = text
        let stamp = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            MainActor.assumeIsolated { if BeyondSIP.shared.lastAction == stamp { BeyondSIP.shared.lastAction = nil } }
        }
    }

    // MARK: Spaces Studio

    func createSpace() async {
        guard ready else { return }
        _ = await bridge.createSpace(onDisplay: CGMainDisplayID())
        SpacesIndicator.shared.refresh()
    }

    func destroySpace(_ sid: Int) async {
        guard ready, SpacesIndicator.shared.spaces.count > 1 else { return }
        _ = await bridge.destroySpace(UInt64(sid))
        SpacesIndicator.shared.refresh()
    }

    func focusSpace(_ sid: Int) async {
        guard ready else { return }
        _ = await bridge.focusSpace(UInt64(sid))
        SpacesIndicator.shared.refresh()
    }

    /// Puts the desktops in `order` (space ids). The bridge only moves "after", so chain every
    /// one after the one before it: correct from any starting order, n − 1 calls.
    func reorder(_ order: [Int]) async {
        guard ready, order.count > 1 else { return }
        for index in 1..<order.count {
            _ = await bridge.moveSpace(UInt64(order[index]), after: UInt64(order[index - 1]))
        }
        SpacesIndicator.shared.refresh()
    }

    // MARK: Shortcuts

    func combo(for action: BridgeAction) -> KeyCombo? { combos[action] }

    func setCombo(_ combo: KeyCombo?, for action: BridgeAction) {
        if let combo { for (other, existing) in combos where existing == combo && other != action { combos[other] = nil; persist(other) } }
        combos[action] = combo
        persist(action)
        registerKeys()
    }

    private func persist(_ action: BridgeAction) {
        let data = combos[action].flatMap { try? JSONEncoder().encode($0) } ?? Data()
        store.set(data, forKey: action.storeKey)
    }

    /// While a recorder listens, our own keys must not swallow the combo being typed.
    func suspendKeys(_ on: Bool) {
        keysSuspended = on
        registerKeys()
    }

    private func enabled(_ action: BridgeAction) -> Bool {
        switch action {
        case .pin: pinEnabled
        case .sticky: stickyEnabled
        case .pip: pipEnabled
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == bridgeHotKeySignature,
                  let action = BridgeAction(rawValue: Int(id.id)) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { BeyondSIP.shared.perform(action) }
            return noErr
        }, 1, &type, nil, &handler)
    }

    private func registerKeys() {
        references.forEach { UnregisterEventHotKey($0) }
        references = []
        var refused: Set<BridgeAction> = []
        if started, ready, !keysSuspended {
            for action in BridgeAction.allCases where enabled(action) {
                guard let combo = combo(for: action) else { continue }
                installHandler()
                var reference: EventHotKeyRef?
                let id = EventHotKeyID(signature: bridgeHotKeySignature, id: UInt32(action.rawValue))
                let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &reference)
                if status == noErr, let reference { references.append(reference) } else { refused.insert(action) }
            }
        }
        if refused != conflicts { conflicts = refused }
    }

    private func save(_ value: Any, _ key: String) { store.set(value, forKey: key) }

    // MARK: Diagnostics

    static var diagnostics: String {
        let model = shared
        return "bsipStatus=\(DockBridge.shared.status.diagnosticName) bsipOpacityApps=\(model.opacityApps.count) " +
            "bsipOpacityOn=\(model.opacityEnabled) bsipFaded=\(model.faded.count) " +
            "bsipPinned=\(model.pinned.count) bsipSticky=\(model.sticky.count) " +
            "bsipPip=\(model.pipEnabled ? "on" : "off"):\(model.pipped.count) " +
            "bsipNoShadow=\(model.noShadowEnabled ? "on" : "off"):\(model.shadowless.count) " +
            "bsipKeys=\(model.references.count) bsipPolling=\(model.poller != nil)"
    }
}

extension BridgeStatus {
    /// One word for logs and diagnostics.
    var diagnosticName: String {
        switch self {
        case .sipEnabled: "sipEnabled"
        case .needsBootArgument: "needsBootArgument"
        case .notInstalled: "notInstalled"
        case .notLoaded: "notLoaded"
        case .ready(let version): "ready(\(version))"
        case .failed: "failed"
        }
    }
}

private extension CGRect {
    var area: Double { isNull || isEmpty ? 0 : width * height }
}
