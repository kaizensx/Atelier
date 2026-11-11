import CoreGraphics
import DockCore
import Foundation
import IOKit
import IOKit.i2c

// MARK: - DDC/CI transport
//
// The IOKit half of External Monitor Control. No AppKit, no app state: it finds the monitors'
// I²C channels, matches them to CGDirectDisplayIDs and moves bytes, one serial queue per
// monitor, so a slow scaler never blocks the main thread or another monitor.
//
// Apple silicon: every display pipe has a DCPAVServiceProxy in the IORegistry, right after
// its framebuffer (IOMobileFramebufferShim on macOS 15+, AppleCLCD2 before). Its "Location"
// says "Embedded" for the built-in panel and "External" for a monitor; Atelier only ever
// opens an IOAVService on an External one, so the built-in panel is never addressed at all.
// IOAVServiceReadI2C / WriteI2C (IOKit, private but exported, the calls MonitorControl, m1ddc
// and Lunar make) carry the DDC/CI packets to chip 0x37, sub-address 0x51.
//
// Intel: IOFramebuffer's I²C interface (IOFBCopyI2CInterfaceForBus + IOI2CSendRequest), the
// way MonitorControl's IntelDDC does it. Chosen at runtime, not by architecture: the x86_64
// slice running under Rosetta on Apple silicon still finds DCPAVServiceProxy and uses it.
//
// Every private symbol is looked up with dlsym once; a missing one means no DDC, never a crash.

enum DDCPrivate {
    typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias WriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias InfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    typealias ServiceForDisplay = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<io_service_t>) -> Void

    nonisolated(unsafe) private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    nonisolated(unsafe) private static let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
    nonisolated(unsafe) private static let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

    static let createWithService = iokit.flatMap { dlsym($0, "IOAVServiceCreateWithService") }.map { unsafeBitCast($0, to: CreateWithService.self) }
    static let readI2C = iokit.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: ReadI2C.self) }
    static let writeI2C = iokit.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: WriteI2C.self) }
    static let infoDictionary = coreDisplay.flatMap { dlsym($0, "CoreDisplay_DisplayCreateInfoDictionary") }.map { unsafeBitCast($0, to: InfoDictionary.self) }
    static let serviceForDisplay = coreGraphics.flatMap { dlsym($0, "CGSServiceForDisplayNumber") }.map { unsafeBitCast($0, to: ServiceForDisplay.self) }

    static var avAvailable: Bool { createWithService != nil && readI2C != nil && writeI2C != nil }
}

/// Bytes on one monitor's DDC channel. Used only on its link's queue.
protocol DDCChannel: AnyObject {
    var kind: String { get }
    /// One Set VCP exchange, following the plan; true when the bus took it.
    func write(_ packet: [UInt8], policy: DDCRetryPolicy) -> Bool
    /// One Get VCP exchange; `request` builds the packet for a seed.
    func read(code: UInt8, policy: DDCRetryPolicy) -> DDCPacket.Reply
}

/// Apple silicon: an IOAVService on an External DCPAVServiceProxy.
final class AVServiceChannel: DDCChannel {
    let kind = "IOAVService"
    private let service: CFTypeRef

    init(service: CFTypeRef) { self.service = service }

    private func send(_ packet: [UInt8]) -> Bool {
        guard let writeI2C = DDCPrivate.writeI2C else { return false }
        var bytes = packet
        return bytes.withUnsafeMutableBytes { buffer in
            writeI2C(service, UInt32(DDCPacket.chipAddress), UInt32(DDCPacket.dataAddress), buffer.baseAddress!, UInt32(buffer.count))
        } == kIOReturnSuccess
    }

    private func receive() -> [UInt8]? {
        guard let readI2C = DDCPrivate.readI2C else { return nil }
        var reply = [UInt8](repeating: 0, count: DDCPacket.replyLength)
        let ok = reply.withUnsafeMutableBytes { buffer in
            readI2C(service, UInt32(DDCPacket.chipAddress), 0, buffer.baseAddress!, UInt32(buffer.count))
        } == kIOReturnSuccess
        return ok ? reply : nil
    }

    func write(_ packet: [UInt8], policy: DDCRetryPolicy) -> Bool {
        var sent = false
        for step in policy.plan(read: false) {
            switch step {
            case .wait(let us): usleep(us)
            case .write: sent = send(packet) || sent
            case .read: break
            case .check: if sent { return true }
            }
        }
        return sent
    }

    func read(code: UInt8, policy: DDCRetryPolicy) -> DDCPacket.Reply {
        var last = DDCPacket.Reply.invalid("no answer")
        var seed = DDCPacket.Seed.standard
        for step in policy.plan(read: true) {
            switch step {
            case .wait(let us): usleep(us)
            case .write(let s): seed = s; _ = send(DDCPacket.getRequest(code, seed: seed))
            case .read: last = receive().map { DDCPacket.parseReply($0, code: code) } ?? .invalid("read failed")
            case .check:
                switch last {
                case .value, .unsupported: return last
                case .invalid: continue
                }
            }
        }
        return last
    }
}

/// Intel: the framebuffer's I²C buses, one combined write-and-read request per attempt.
final class FramebufferChannel: DDCChannel {
    let kind = "IOFramebuffer I2C"
    private let framebuffer: io_service_t
    private let replyType: IOOptionBits

    init?(framebuffer: io_service_t) {
        guard let type = FramebufferChannel.replyTransactionType() else { return nil }
        self.framebuffer = framebuffer
        self.replyType = type
    }

    deinit { IOObjectRelease(framebuffer) }

    private static func replyTransactionType() -> IOOptionBits? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("IOFramebufferI2CInterface"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let types = IORegistryEntryCreateCFProperty(service, kIOI2CTransactionTypesKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? UInt64 else { continue }
            if (1 << kIOI2CDDCciReplyTransactionType) & types != 0 { return IOOptionBits(kIOI2CDDCciReplyTransactionType) }
            if (1 << kIOI2CSimpleTransactionType) & types != 0 { return IOOptionBits(kIOI2CSimpleTransactionType) }
        }
        return nil
    }

    private func send(_ request: inout IOI2CRequest) -> Bool {
        var buses: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &buses) == KERN_SUCCESS else { return false }
        for bus in 0..<buses {
            var interface = io_service_t()
            guard IOFBCopyI2CInterfaceForBus(framebuffer, IOOptionBits(bus), &interface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(interface) }
            var connect: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connect else { continue }
            defer { IOI2CInterfaceClose(connect, 0) }
            if IOI2CSendRequest(connect, 0, &request) == KERN_SUCCESS, request.result == KERN_SUCCESS { return true }
        }
        return false
    }

    func write(_ packet: [UInt8], policy: DDCRetryPolicy) -> Bool {
        var data = DDCPacket.framed(packet)
        var sent = false
        for _ in 0..<policy.writeCycles {
            usleep(policy.writeDelay)
            let ok = data.withUnsafeMutableBytes { buffer -> Bool in
                var request = IOI2CRequest()
                request.sendAddress = UInt32(DDCPacket.destination)
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = vm_address_t(bitPattern: buffer.baseAddress)
                request.sendBytes = UInt32(buffer.count)
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                return send(&request)
            }
            sent = ok || sent
        }
        return sent
    }

    func read(code: UInt8, policy: DDCRetryPolicy) -> DDCPacket.Reply {
        var last = DDCPacket.Reply.invalid("no answer")
        for attempt in 0..<policy.attempts {
            usleep(policy.writeDelay)
            var data = DDCPacket.framed(DDCPacket.getRequest(code, seed: policy.seed(attempt: attempt)))
            var reply = [UInt8](repeating: 0, count: DDCPacket.replyLength)
            let ok = data.withUnsafeMutableBytes { send in
                reply.withUnsafeMutableBytes { answer -> Bool in
                    var request = IOI2CRequest()
                    request.sendAddress = UInt32(DDCPacket.destination)
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendBuffer = vm_address_t(bitPattern: send.baseAddress)
                    request.sendBytes = UInt32(send.count)
                    request.minReplyDelay = UInt64(policy.readDelay / 1000)
                    request.replyAddress = UInt32(DDCPacket.destination | 1)
                    request.replySubAddress = DDCPacket.dataAddress
                    request.replyTransactionType = replyType
                    request.replyBuffer = vm_address_t(bitPattern: answer.baseAddress)
                    request.replyBytes = UInt32(answer.count)
                    return self.send(&request)
                }
            }
            if ok {
                last = DDCPacket.parseReply(reply, code: code)
                if case .invalid = last {} else { return last }
            }
            usleep(policy.retryDelay)
        }
        return last
    }
}

/// Counts every byte Atelier puts on a DDC bus, for diagnostics and the tests that prove the
/// built-in panel is never addressed.
final class DDCCounters: @unchecked Sendable {
    static let shared = DDCCounters()
    private let lock = NSLock()
    private var _reads = 0, _writes = 0, _refused = 0
    /// How many external displays have a channel right now; writes are refused while 0.
    private var _external = 0

    var reads: Int { lock.withLock { _reads } }
    var writes: Int { lock.withLock { _writes } }
    var refused: Int { lock.withLock { _refused } }
    var external: Int {
        get { lock.withLock { _external } }
        set { lock.withLock { _external = newValue } }
    }
    func read() { lock.withLock { _reads += 1 } }
    func wrote() { lock.withLock { _writes += 1 } }
    func refuse() { lock.withLock { _refused += 1 } }
}

/// One monitor's channel and its queue. Everything that touches the bus runs on `queue`.
final class DDCLink: @unchecked Sendable {
    let display: CGDirectDisplayID
    let kind: String
    private let channel: DDCChannel
    private let queue: DispatchQueue
    private var coalescer = DDCCoalescer()
    private var draining = false
    /// Slow monitors get the patient timings after their first failure.
    private var policy = DDCRetryPolicy.standard

    init(display: CGDirectDisplayID, channel: DDCChannel) {
        self.display = display
        self.channel = channel
        self.kind = channel.kind
        self.queue = DispatchQueue(label: "atelier.ddc.\(display)", qos: .userInitiated)
    }

    /// Reads a code off the main thread; `done` is called on the main queue.
    func read(_ code: VCPCode, probe: Bool = false, done: @escaping @Sendable (DDCPacket.Reply) -> Void) {
        queue.async { [self] in
            DDCCounters.shared.read()
            let reply = channel.read(code: code.rawValue, policy: probe ? .probe : policy)
            if case .value(let current, _) = reply { coalescer.record(code.rawValue, current) }
            if case .invalid = reply, !probe { policy = .patient }
            DispatchQueue.main.async { done(reply) }
        }
    }

    /// Queues a value; only the newest per code is sent. `done` reports whether the bus took it.
    func push(_ code: VCPCode, _ value: UInt16, done: (@Sendable (Bool) -> Void)? = nil) {
        queue.async { [self] in
            coalescer.push(code.rawValue, value)
            drain(done)
        }
    }

    func forgetWritten() { queue.async { [self] in coalescer.forget() } }

    private func drain(_ done: (@Sendable (Bool) -> Void)?) {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        var ok = true
        while let next = coalescer.next() {
            // The last gate: an allowed code, a packet that could be built, an external display.
            guard DDCSafety.mayWrite(next.code, externalDisplays: DDCCounters.shared.external),
                  let packet = DDCPacket.setRequest(next.code, value: next.value) else {
                DDCCounters.shared.refuse()
                ok = false
                continue
            }
            DDCCounters.shared.wrote()
            let sent = channel.write(packet, policy: policy)
            if sent { coalescer.record(next.code, next.value) }
            ok = ok && sent
        }
        if let done { DispatchQueue.main.async { done(ok) } }
    }
}

// MARK: - Finding the monitors

enum DDCDiscovery {
    /// What the registry walk saw, for diagnostics.
    struct Survey {
        var services: [DDCServiceFacts] = []
        /// AV services by registry index, External ones only.
        var avServices: [Int: CFTypeRef] = [:]
    }

    /// MonitorControl's walk: each framebuffer's properties, then the DCPAVServiceProxy that
    /// follows it. An IOAVService is created only for "Location" = "External".
    static func survey() -> Survey {
        var survey = Survey()
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return survey }
        defer { IOObjectRelease(iterator) }
        let framebuffers = ["AppleCLCD2", "IOMobileFramebufferShim"]
        var current: DDCServiceFacts?
        var index = 0
        var name = [CChar](repeating: 0, count: 128)
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            let entryName = cString(name)
            if framebuffers.contains(entryName) {
                index += 1
                current = framebufferFacts(entry, index: index)
            } else if entryName == "DCPAVServiceProxy", var facts = current {
                facts.location = property(entry, "Location") as? String ?? ""
                survey.services.append(facts)
                if facts.external, DDCPrivate.avAvailable,
                   let service = DDCPrivate.createWithService?(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    survey.avServices[facts.index] = service
                }
                current = nil
            }
        }
        return survey
    }

    private static func cString(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func framebufferFacts(_ entry: io_registry_entry_t, index: Int) -> DDCServiceFacts {
        var facts = DDCServiceFacts(index: index)
        facts.edidUUID = property(entry, "EDID UUID") as? String ?? ""
        var path = [CChar](repeating: 0, count: 1024)
        if IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS { facts.path = cString(path) }
        if let attributes = property(entry, "DisplayAttributes") as? [String: Any],
           let product = attributes["ProductAttributes"] as? [String: Any] {
            facts.productName = product["ProductName"] as? String ?? ""
            facts.manufacturer = product["ManufacturerID"] as? String ?? ""
            facts.serial = (product["SerialNumber"] as? NSNumber)?.int64Value ?? 0
        }
        return facts
    }

    /// CoreDisplay's facts for a display, in the shape DDCMatch scores.
    static func displayFacts(_ display: CGDirectDisplayID) -> DDCDisplayFacts {
        var facts = DDCDisplayFacts(vendor: Int64(CGDisplayVendorNumber(display)), product: Int64(CGDisplayModelNumber(display)),
                                    serial: Int64(CGDisplaySerialNumber(display)))
        guard let info = DDCPrivate.infoDictionary?(display)?.takeRetainedValue() as? [String: Any] else { return facts }
        func number(_ key: String) -> Int64 { (info[key] as? NSNumber)?.int64Value ?? 0 }
        facts.vendor = number("DisplayVendorID")
        facts.product = number("DisplayProductID")
        facts.serial = number("DisplaySerialNumber")
        facts.week = number("DisplayWeekManufacture")
        facts.year = number("DisplayYearManufacture")
        facts.horizontalMM = number("DisplayHorizontalImageSize")
        facts.verticalMM = number("DisplayVerticalImageSize")
        facts.location = info["IODisplayLocation"] as? String ?? ""
        if let names = info["DisplayProductName"] as? [String: String] {
            facts.name = names["en_US"] ?? names.values.first ?? ""
        }
        return facts
    }

    /// The Intel route: the framebuffer CoreGraphics drives the display through.
    static func framebuffer(for display: CGDirectDisplayID) -> io_service_t? {
        guard CGDisplayIsBuiltin(display) == 0, let lookup = DDCPrivate.serviceForDisplay else { return nil }
        var service: io_service_t = 0
        lookup(display, &service)
        guard service != 0 else { return nil }
        var buses: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(service, &buses) == KERN_SUCCESS, buses > 0 else { return nil }
        IOObjectRetain(service)
        return service
    }
}
