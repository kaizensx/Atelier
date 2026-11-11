import ApplicationServices
import CoreGraphics
import Foundation
import MachO
import ObjectiveC

// MARK: - Instant Spaces: talking to the window server
//
// Kept in DockCore, beside the pure logic, so the app and the command-line test tool
// (test/spacetest.swift) run exactly the same code. Everything is called from our own
// process: no injection, no SIP change. Each private entry point is looked up at run time and
// its absence is reported, never assumed.

/// Finds a symbol in a loaded image by walking its symbol table, the way yabai does. dlsym only
/// sees exported symbols; the window-management bridge in SkyLight is a file-local C++
/// function, present in the table but not exported.
public enum MachOSymbols {
    public static func find(image path: String, symbol: String) -> UnsafeRawPointer? {
        _ = dlopen(path, RTLD_LAZY | RTLD_NOLOAD)
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i), String(cString: name) == path,
                  let header = _dyld_get_image_header(i) else { continue }
            return find(header: header, slide: _dyld_get_image_vmaddr_slide(i), symbol: symbol)
        }
        return nil
    }

    static func find(header: UnsafePointer<mach_header>, slide: Int, symbol: String) -> UnsafeRawPointer? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        let base = UnsafeRawPointer(header)
        var offset = MemoryLayout<mach_header_64>.size
        var linkedit: segment_command_64?
        var symtab: symtab_command?
        for _ in 0..<header.pointee.ncmds {
            let command = base.advanced(by: offset).loadUnaligned(as: load_command.self)
            if command.cmd == LC_SEGMENT_64 {
                let segment = base.advanced(by: offset).loadUnaligned(as: segment_command_64.self)
                if segmentName(segment) == SEG_LINKEDIT { linkedit = segment }
            } else if command.cmd == LC_SYMTAB {
                symtab = base.advanced(by: offset).loadUnaligned(as: symtab_command.self)
            }
            offset += Int(command.cmdsize)
        }
        guard let linkedit, let symtab else { return nil }
        // __LINKEDIT's file offsets map to memory through its own vmaddr, plus the slide.
        let start = Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide
        guard let strings = UnsafeRawPointer(bitPattern: start + Int(symtab.stroff)),
              let table = UnsafeRawPointer(bitPattern: start + Int(symtab.symoff)) else { return nil }
        return symbol.withCString { wanted in
            for k in 0..<Int(symtab.nsyms) {
                let entry = table.advanced(by: k * MemoryLayout<nlist_64>.stride).loadUnaligned(as: nlist_64.self)
                guard entry.n_value != 0 else { continue }
                if strcmp(strings.advanced(by: Int(entry.n_un.n_strx)).assumingMemoryBound(to: CChar.self), wanted) == 0 {
                    return UnsafeRawPointer(bitPattern: Int(entry.n_value) + slide)
                }
            }
            return nil
        }
    }

    private static func segmentName(_ segment: segment_command_64) -> String {
        withUnsafeBytes(of: segment.segname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

public enum SpacesEngine {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias PerformBridged = @convention(c) (UnsafeRawPointer) -> Void
    private typealias InitMove = @convention(c) (AnyObject, Selector, CFArray, UInt64) -> Unmanaged<AnyObject>?
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    private typealias MoveToManagedSpace = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias SetCompatID = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SetWindowListWorkspace = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32

    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    private static let bridgedSymbol =
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"

    private static func lookup(_ name: String) -> UnsafeMutableRawPointer? { dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) }

    private static var connection: Int32? {
        lookup("CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self)() }
    }

    // MARK: Reading

    public static func displays() -> [ManagedDisplay] {
        guard let cid = connection, let copy = lookup("CGSCopyManagedDisplaySpaces"),
              let raw = unsafeBitCast(copy, to: CopyDisplaySpaces.self)(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return ManagedDisplay.parse(raw)
    }

    /// The first display's (Mission Control's main) list, the one the menu bar indicator shows.
    public static func mainDisplay() -> ManagedDisplay? { displays().first }

    /// The UUID of the display under the pointer, in the form the window server uses for
    /// "Display Identifier". Public CoreGraphics and ColorSync only, so it works on every release.
    public static func cursorDisplayIdentifier() -> String? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Mission Control's Control-Arrow shortcuts, as the user has them (see SpaceArrowShortcuts).
    public static var arrowShortcuts: (left: Bool, right: Bool) {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        let table = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        return SpaceArrowShortcuts.enabled(table as? [String: Any])
    }

    /// Spaces a window is on: an empty list for a window that is nowhere (or unknown).
    public static func spaces(ofWindow id: UInt32) -> [Int] {
        guard let cid = connection, let fn = lookup("SLSCopySpacesForWindows") ?? lookup("CGSCopySpacesForWindows") else { return [] }
        // Mask 7: current, other and full-screen spaces.
        return unsafeBitCast(fn, to: CopySpacesForWindows.self)(cid, 0x7, [NSNumber(value: id)] as CFArray)?
            .takeRetainedValue() as? [Int] ?? []
    }

    // MARK: Instant switch

    /// The user's natural-scrolling choice; the Dock reads the swipe's sign through it. Unset means on.
    public static var naturalScrolling: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var valid: DarwinBoolean = false
        let value = CFPreferencesGetAppBooleanValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication, &valid)
        return !valid.boolValue || value
    }

    /// Posting synthetic events needs Accessibility; without it the Dock never sees them.
    public static var canPost: Bool { AXIsProcessTrusted() }

    private static var major: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// macOS 27 ignores a synthetic swipe unless it carries the raw IOHID payload too.
    public static var needsPayload: Bool { DockSwipe.usesPayload(major: major) }

    /// One whole swipe, one desktop over: began, changed, ended. On 27 each phase carries the
    /// IOHID payload and is followed by its companion gesture event; before 27 the bare
    /// Dock-control event is what the Dock expects, as InstantSpaceSwitcher and yabai post it.
    /// Returns false when an event could not be built (the caller then uses Control-Arrow).
    @discardableResult
    public static func swipe(right: Bool) -> Bool {
        let payload = needsPayload
        let sign = DockSwipe.sign(right: right, naturalScrolling: payload ? naturalScrolling : false, major: major)
        for phase in [DockSwipe.Phase.began, .changed, .ended] {
            guard let event = swipeEvent(phase: phase, sign: sign) else { return false }
            guard payload else {
                event.post(tap: .cgSessionEventTap)
                continue
            }
            guard let companion = CGEvent(source: nil) else { return false }
            companion.setIntegerValueField(field(DockSwipe.Field.cgsType), value: DockSwipe.gesture)
            event.post(tap: .cgSessionEventTap)
            companion.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// Posts `steps` swipes back to back (positive is right). The Dock queues them, so a jump of
    /// three desktops is three swipes with no animation in between.
    @discardableResult
    public static func jump(steps: Int) -> Bool {
        guard steps != 0 else { return true }
        for _ in 0..<abs(steps) where !swipe(right: steps > 0) { return false }
        return true
    }

    private static func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

    private static func swipeEvent(phase: DockSwipe.Phase, sign: Double) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let progress = sign * DockSwipe.progress
        let velocity = phase == .ended ? sign * DockSwipe.fling : 0
        event.setIntegerValueField(field(DockSwipe.Field.cgsType), value: DockSwipe.dockControl)
        event.setIntegerValueField(field(DockSwipe.Field.hidType), value: DockSwipe.dockSwipe)
        event.setIntegerValueField(field(DockSwipe.Field.phase), value: phase.rawValue)
        event.setIntegerValueField(field(DockSwipe.Field.swipeMotion), value: DockSwipe.horizontal)
        event.setDoubleValueField(field(DockSwipe.Field.progress), value: progress)
        guard needsPayload else {
            // Before 27: velocity on every phase, both axes, as the older Dock expects.
            event.setDoubleValueField(field(DockSwipe.Field.velocityX), value: sign * DockSwipe.fling)
            event.setDoubleValueField(field(DockSwipe.Field.velocityY), value: sign * DockSwipe.fling)
            return event
        }
        // Fields a real trackpad swipe carries on 27, then the raw payload appended to the event.
        event.setIntegerValueField(field(DockSwipe.Field.phaseAlias), value: phase.rawValue)
        event.setDoubleValueField(field(DockSwipe.Field.zoomDeltaY), value: 3)
        event.setDoubleValueField(field(DockSwipe.Field.timestampAlias), value: Double(mach_absolute_time()))
        event.setDoubleValueField(field(DockSwipe.Field.positionX), value: 0.1)
        if phase == .ended { event.setDoubleValueField(field(DockSwipe.Field.velocityX), value: velocity) }
        guard let data = event.data as Data? else { return nil }
        let payload = DockSwipe.payload(phase: phase, progress: progress, positionX: 0.1, velocityX: velocity,
                                        timestamp: event.timestamp == 0 ? mach_absolute_time() : event.timestamp)
        guard let bytes = DockSwipe.augment(eventData: [UInt8](data), payload: payload) else { return nil }
        return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
    }

    /// macOS's own Control-Arrow, the slow, animated way. The Dock matches it only with Control
    /// really held, and the arrow carrying the flags a keyboard gives it.
    public static func controlArrow(right: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        let arrow: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        let key: CGKeyCode = right ? 124 : 123
        post(59, true, .maskControl)
        post(key, true, arrow)
        post(key, false, arrow)
        post(59, false, [])
    }

    // MARK: Sending windows

    /// The bridge entry point, found once. Nil on systems where SkyLight does not have it
    /// (it is known on 26.4 and later; older releases may lack it).
    nonisolated(unsafe) private static let bridged: UnsafeRawPointer? = MachOSymbols.find(image: skyLight, symbol: bridgedSymbol)

    private static var bridgeAvailable: Bool {
        bridged != nil && NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") != nil
    }

    /// The ways this Mac may move a window to another desktop, best first, each one present
    /// in SkyLight right now. Empty means sending is not possible here with SIP on.
    public static var sendMethods: [SpaceSendMethod] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SpaceSendMethod.candidates(major: version.majorVersion, minor: version.minorVersion,
                                          bridgeAvailable: bridgeAvailable).filter { method in
            switch method {
            case .bridged: true
            case .direct: lookup("SLSMoveWindowsToManagedSpace") != nil
            case .compatID: lookup("SLSSpaceSetCompatID") != nil && lookup("SLSSetWindowListWorkspace") != nil
            }
        }
    }

    /// Whether this Mac can move a window to another desktop at all.
    public static var canMoveWindows: Bool { !sendMethods.isEmpty }

    /// Asks the window server to move windows to a desktop with one method. Every method is
    /// asynchronous or silently ignored when refused, so the caller checks where the window
    /// went (`spaces(ofWindow:)`) and tries the next method if it did not move.
    @discardableResult
    public static func move(windows: [UInt32], toSpace space: Int, using method: SpaceSendMethod) -> Bool {
        guard !windows.isEmpty, let cid = connection else { return false }
        switch method {
        case .bridged:
            return move(windows: windows, toSpace: space)
        case .direct:
            guard let fn = lookup("SLSMoveWindowsToManagedSpace") else { return false }
            unsafeBitCast(fn, to: MoveToManagedSpace.self)(cid, windows.map { NSNumber(value: $0) } as CFArray, UInt64(space))
            return true
        case .compatID:
            guard let setID = lookup("SLSSpaceSetCompatID"), let setList = lookup("SLSSetWindowListWorkspace") else { return false }
            // yabai's tag: the space borrows a legacy workspace number for an instant, the
            // windows are put in that workspace, and the space gives the number back.
            let tag: Int32 = 0x79616265
            let setCompat = unsafeBitCast(setID, to: SetCompatID.self)
            var list = windows
            _ = setCompat(cid, UInt64(space), tag)
            let status = list.withUnsafeMutableBufferPointer { buffer in
                unsafeBitCast(setList, to: SetWindowListWorkspace.self)(cid, buffer.baseAddress!, Int32(buffer.count), tag)
            }
            _ = setCompat(cid, UInt64(space), 0)
            return status == 0
        }
    }

    /// Asks the window server to move windows to a desktop through the bridge, as yabai does
    /// with SIP on. The operation is asynchronous: the move lands a few milliseconds later.
    @discardableResult
    public static func move(windows: [UInt32], toSpace space: Int) -> Bool {
        guard !windows.isEmpty, let bridged, let send = lookup("objc_msgSend"),
              let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") as? NSObject.Type,
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return false }
        let list = windows.map { NSNumber(value: $0) } as CFArray
        guard let operation = unsafeBitCast(send, to: InitMove.self)(allocated, NSSelectorFromString("initWithWindows:spaceID:"),
                                                                      list, UInt64(space))?.takeRetainedValue() else { return false }
        unsafeBitCast(bridged, to: PerformBridged.self)(Unmanaged.passUnretained(operation).toOpaque())
        return true
    }

    /// The window the user is working in: that app's focused window, through Accessibility,
    /// then its window-server number. The caller names the app (NSWorkspace's frontmost).
    public static func focusedWindow(of pid: pid_t) -> UInt32? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID(), let fn = lookup("_AXUIElementGetWindow") {
            var id: UInt32 = 0
            if unsafeBitCast(fn, to: GetWindow.self)(value as! AXUIElement, &id) == .success, id != 0 { return id }
        }
        // No Accessibility answer: the app's front-most ordinary window on screen.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .flatMap { $0[kCGWindowNumber as String] as? UInt32 }
    }
}
