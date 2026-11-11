import Accelerate
import AppKit
import CoreAudio
import DockCore
import os

// MARK: - Sound Mixer
//
// Per-app volume (0–150 %), mute and output routing, and a 10-band EQ for everything, with its
// own curve per output device. Built on Core Audio process taps (public API, macOS 14.2+):
//
//   app processes ──tap (muted when tapped)──▶ private aggregate (main sub-device = output)
//                                              └─ IOProc: gain ramp → biquads → soft limiter
//
// - An app with its own setting (not 100 %, muted, or routed elsewhere) gets one tap of its
//   processes, a private aggregate on its output device, and an IOProc applying its gain and
//   that device's EQ.
// - With the EQ on, one global tap takes everything else (every process except ours and the
//   apps with their own tap) and plays it, EQ'd, to the default output.
// - An app at 100 % with no EQ is never tapped (SoundMixerPlanner): zero cost, zero latency.
//
// Lifecycle: nothing runs, listens or polls while the mixer is off and its card is not on
// screen. Turning it off, or quitting, stops every IOProc and destroys every aggregate and tap
// at once, so the Mac sounds exactly as before. Taps and private aggregates belong to this
// process: if it crashes, coreaudiod drops them and every app plays normally again.
//
// Real-time rule: the IOProc never allocates, locks or calls into Swift runtime machinery that
// might. Parameters arrive through a mailbox the IO thread only *tries* to lock (it keeps the
// previous parameters when the writer holds it), and all its state lives in raw memory set up
// before the IOProc starts.
//
// Structural Core Audio work (creating and destroying taps and aggregates, which can take tens
// of milliseconds) runs on one serial queue, never on the main thread.

// MARK: Core Audio property helpers

private enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var address = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBufferPointer { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// The process object for a PID, or nil when it has never touched audio.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func deviceUID(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    static var defaultOutputDevice: AudioObjectID? {
        read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }
}

/// The UID prefix of the aggregates this engine creates, so the output picker never lists them.
private let mixerAggregatePrefix = "app.atelier.soundmixer."

// MARK: Private helpers, resolved once

private typealias ResponsibleForPID = @convention(c) (pid_t) -> pid_t
/// libsystem's "which app is responsible for this helper" (WebKit's WebContent → Safari).
/// Optional: without it, helpers are matched to their app by bundle identifier.
private let responsiblePID: ResponsibleForPID? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: ResponsibleForPID.self)
}()

private typealias TCCPreflight = @convention(c) (CFString, CFDictionary?) -> Int32
private typealias TCCRequest = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) @Sendable (Bool) -> Void) -> Void
/// TCC's preflight and request for "System Audio Recording Only", read-only use: it lets the
/// card say what is missing before a tap would play silence. Without TCC, creating the first
/// tap shows the same prompt.
private let tcc: (preflight: TCCPreflight, request: TCCRequest)? = {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
          let preflight = dlsym(handle, "TCCAccessPreflight"), let request = dlsym(handle, "TCCAccessRequest") else { return nil }
    return (unsafeBitCast(preflight, to: TCCPreflight.self), unsafeBitCast(request, to: TCCRequest.self))
}()
private var audioCaptureService: CFString { "kTCCServiceAudioCapture" as CFString }

enum MixerPermission: String, Sendable {
    case granted, denied, unknown
}

// MARK: Real-time DSP

/// The state one IOProc renders with. Everything the IO thread touches is raw memory allocated
/// here, so rendering never allocates and Swift's exclusivity checks never run on that thread.
final class MixerDSP: @unchecked Sendable {
    static let sections = SoundEQ.bandCount
    static let chunk = 4096
    private static let delayStride = 2 * sections + 2

    /// What the writer hands over. Copied as a whole under the lock.
    private struct Mailbox {
        var serial = 0
        var gain: Float = 1
        var eq = false
        var limiter = false
        var coefficientsSerial = 0
    }

    /// What only the IO thread reads and writes.
    private struct Live {
        var serial = 0
        var coefficientsSerial = 0
        var gain: Float = 1
        var target: Float = 1
        var eq = false
        var limiter = false
        var cleared = true
    }

    struct Stats {
        var callbacks: UInt64 = 0
        var audible: UInt64 = 0
        var peak: Float = 0
    }

    /// Input buffers that belong to the output device itself (the AirPods microphone, an
    /// interface's inputs). The aggregate lists its sub-device's input streams first and the
    /// tap's last, so the tap starts after these. Written once before the IOProc starts.
    var inputSkip = 0

    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let mailbox = UnsafeMutablePointer<Mailbox>.allocate(capacity: 1)
    private let mailboxCoefficients = UnsafeMutablePointer<Double>.allocate(capacity: 5 * sections)
    private let live = UnsafeMutablePointer<Live>.allocate(capacity: 1)
    private let delays = UnsafeMutablePointer<Float>.allocate(capacity: 2 * delayStride)
    private let scratchA = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
    private let scratchB = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
    /// Loose counters for diagnostics: written by the IO thread, read without a lock. A torn
    /// read of a counter only ever shows a stale number.
    let stats = UnsafeMutablePointer<Stats>.allocate(capacity: 1)
    private let setup: vDSP_biquad_Setup

    /// `startGain` is what the listener hears before the tap: an untapped app plays at 1, so a
    /// new pipeline glides from there to its target instead of jumping.
    init?(startGain: Float = 1) {
        let identity = [Double](repeating: 0, count: 5 * Self.sections).enumerated().map { $0.offset % 5 == 0 ? 1 : $0.element }
        guard let setup = vDSP_biquad_CreateSetup(identity, vDSP_Length(Self.sections)) else { return nil }
        self.setup = setup
        lock.initialize(to: os_unfair_lock())
        mailbox.initialize(to: Mailbox(gain: startGain))
        mailboxCoefficients.initialize(from: identity, count: identity.count)
        live.initialize(to: Live(gain: startGain, target: startGain))
        delays.initialize(repeating: 0, count: 2 * Self.delayStride)
        scratchA.initialize(repeating: 0, count: Self.chunk)
        scratchB.initialize(repeating: 0, count: Self.chunk)
        stats.initialize(to: Stats())
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
        lock.deallocate(); mailbox.deallocate(); mailboxCoefficients.deallocate(); live.deallocate()
        delays.deallocate(); scratchA.deallocate(); scratchB.deallocate(); stats.deallocate()
    }

    /// From the graph queue: the next gain and curve. The coefficients are worked out here, off
    /// the IO thread, and copied into the mailbox.
    func update(gain: Double, eq: [Double]?, limiter: Bool, sampleRate: Double) {
        let coefficients = eq.map { SoundEQ.vDSPCoefficients(gains: $0, sampleRate: sampleRate) }
        let preamp = eq.map { pow(10, SoundEQ.preampDB(gains: $0, sampleRate: sampleRate) / 20) } ?? 1
        os_unfair_lock_lock(lock)
        mailbox.pointee.gain = Float(gain * preamp)
        mailbox.pointee.eq = coefficients != nil
        mailbox.pointee.limiter = limiter
        if let coefficients {
            coefficients.withUnsafeBufferPointer { mailboxCoefficients.update(from: $0.baseAddress!, count: min($0.count, 5 * Self.sections)) }
            mailbox.pointee.coefficientsSerial &+= 1
        }
        mailbox.pointee.serial &+= 1
        os_unfair_lock_unlock(lock)
    }

    var currentGain: Float { live.pointee.gain }

    // MARK: IO thread

    /// The IOProc body. Input: the tap (stereo float). Output: the aggregate's output streams.
    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        stats.pointee.callbacks &+= 1
        pullMailbox()

        let outList = UnsafeMutableAudioBufferListPointer(output)
        var outL: UnsafeMutablePointer<Float>?, outR: UnsafeMutablePointer<Float>?
        var outStrideL = 1, outStrideR = 1, outFrames = Int.max
        for buffer in outList {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let base = data.assumingMemoryBound(to: Float.self)
            for c in 0..<channels {
                if outL == nil { outL = base + c; outStrideL = channels }
                else if outR == nil { outR = base + c; outStrideR = channels }
            }
            outFrames = min(outFrames, Int(buffer.mDataByteSize) / (4 * channels))
        }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var inL: UnsafePointer<Float>?, inR: UnsafePointer<Float>?
        var inStrideL = 1, inStrideR = 1, inFrames = Int.max
        // Only the tap's buffers: never the device's own microphone.
        let skip = inList.count > inputSkip ? inputSkip : 0
        for buffer in inList.dropFirst(skip) {
            guard let data = buffer.mData else { continue }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let base = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            for c in 0..<channels {
                if inL == nil { inL = base + c; inStrideL = channels }
                else if inR == nil { inR = base + c; inStrideR = channels }
            }
            inFrames = min(inFrames, Int(buffer.mDataByteSize) / (4 * channels))
        }

        guard let inL, let outL, inFrames != Int.max, outFrames != Int.max else { return }
        if inR == nil { inR = inL; inStrideR = inStrideL }
        let frames = min(inFrames, outFrames)
        guard frames > 0 else { return }

        var peakL: Float = 0, peakR: Float = 0
        vDSP_maxmgv(inL, vDSP_Stride(inStrideL), &peakL, vDSP_Length(frames))
        vDSP_maxmgv(inR!, vDSP_Stride(inStrideR), &peakR, vDSP_Length(frames))
        let state = live
        // Silence in, settled gain: leave the zeroed output and rest the filters, so their
        // state never decays into denormals (which cost a lot of CPU on Intel).
        if peakL == 0 && peakR == 0 && state.pointee.gain == state.pointee.target {
            if !state.pointee.cleared {
                vDSP_vclr(delays, 1, vDSP_Length(2 * Self.delayStride))
                state.pointee.cleared = true
            }
            stats.pointee.peak = 0
            return
        }
        state.pointee.cleared = false
        stats.pointee.audible &+= 1

        let start = state.pointee.gain, target = state.pointee.target
        let step = SoundMixerGain.rampStep(current: start, target: target, frames: frames)
        let eqOn = state.pointee.eq, limiter = state.pointee.limiter
        var gain = start
        var offset = 0
        while offset < frames {
            let n = min(Self.chunk, frames - offset)
            for channel in 0..<(outR == nil ? 1 : 2) {
                let source = channel == 0 ? inL + offset * inStrideL : inR! + offset * inStrideR
                let sourceStride = channel == 0 ? inStrideL : inStrideR
                let destination = channel == 0 ? outL + offset * outStrideL : outR! + offset * outStrideR
                let destinationStride = channel == 0 ? outStrideL : outStrideR
                var rampStart = gain, rampStep = step
                vDSP_vrampmul(source, vDSP_Stride(sourceStride), &rampStart, &rampStep, scratchA, 1, vDSP_Length(n))
                var processed = scratchA
                if eqOn {
                    vDSP_biquad(setup, delays + channel * Self.delayStride, scratchA, 1, scratchB, 1, vDSP_Length(n))
                    processed = scratchB
                }
                if limiter {
                    for i in 0..<n { destination[i * destinationStride] = SoundMixerGain.softLimit(processed[i]) }
                } else {
                    for i in 0..<n { destination[i * destinationStride] = processed[i] }
                }
            }
            gain += step * Float(n)
            offset += n
        }
        // Land exactly on the target once the ramp passes it.
        if (step >= 0 && gain >= target) || (step < 0 && gain <= target) { gain = target }
        state.pointee.gain = gain
        stats.pointee.peak = max(peakL, peakR) * gain
    }

    /// Takes new parameters if the writer is not mid-update; otherwise keeps the current ones
    /// for this buffer. Never waits.
    @inline(__always)
    private func pullMailbox() {
        guard os_unfair_lock_trylock(lock) else { return }
        let box = mailbox.pointee
        if box.serial != live.pointee.serial {
            live.pointee.serial = box.serial
            live.pointee.target = box.gain
            live.pointee.limiter = box.limiter
            if box.eq && !live.pointee.eq { vDSP_vclr(delays, 1, vDSP_Length(2 * Self.delayStride)) }
            live.pointee.eq = box.eq
            if box.coefficientsSerial != live.pointee.coefficientsSerial {
                vDSP_biquad_SetCoefficientsDouble(setup, mailboxCoefficients, 0, vDSP_Length(Self.sections))
                live.pointee.coefficientsSerial = box.coefficientsSerial
            }
        }
        os_unfair_lock_unlock(lock)
    }
}

// MARK: One pipeline: tap → private aggregate → IOProc

struct MixerFailure: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? " '" + String(decoding: bytes, as: UTF8.self) + "'" : ""
        return "\(step) failed (\(status)\(fourCC))"
    }
}

/// A snapshot of one running pipeline, for diagnostics and the card.
struct MixerPipelineStatus: Sendable, Equatable {
    var id: String
    var outputUID: String
    var processes: Int
    var gain: Double
    var eq: Bool
    var sampleRate: Double
    var callbacks: UInt64
    var audible: UInt64
    var retiring: Bool

    /// Everything but the counters: what the cards redraw for.
    var shape: String { "\(id)|\(outputUID)|\(processes)|\(gain)|\(eq)|\(sampleRate)|\(retiring)" }
}

@available(macOS 14.2, *)
private final class MixerPipeline {
    private(set) var plan: MixerPipelinePlan
    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let queue: DispatchQueue
    let dsp: MixerDSP
    private(set) var sampleRate = 48000.0
    /// Set when the plan no longer wants it; it is destroyed then unless wanted again.
    var retireAt: DispatchTime?

    init(plan: MixerPipelinePlan, queue: DispatchQueue, onRateChange: @escaping @Sendable () -> Void) throws {
        self.plan = plan
        self.queue = queue
        guard let dsp = MixerDSP() else { throw MixerFailure(step: "vDSP setup", status: -1) }
        self.dsp = dsp

        switch plan.kind {
        case .app: description = CATapDescription(stereoMixdownOfProcesses: plan.processes)
        case .global: description = CATapDescription(stereoGlobalTapButExcludeProcesses: plan.processes)
        }
        description.name = "Atelier Sound Mixer"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        do {
            try build(onRateChange: onRateChange)
        } catch {
            destroy()
            throw error
        }
    }

    private func build(onRateChange: @escaping @Sendable () -> Void) throws {
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw MixerFailure(step: "Create tap", status: status) }

        let output = plan.outputUID
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Atelier Sound Mixer",
            kAudioAggregateDeviceUIDKey: mixerAggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID)
        guard status == noErr else { throw MixerFailure(step: "Create aggregate", status: status) }

        sampleRate = CA.read(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)).flatMap { $0 > 0 ? $0 : nil } ?? 48000
        apply(plan)

        let dsp = dsp
        // The tap is one stream, listed after the sub-device's own inputs.
        let inputStreams = CA.objects(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
        dsp.inputSkip = max(0, inputStreams - 1)
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            dsp.render(input, output)
        }
        guard status == noErr, procID != nil else { throw MixerFailure(step: "Create IOProc", status: status) }

        var address = CA.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onRateChange() }
        if AudioObjectAddPropertyListenerBlock(aggregateID, &address, queue, listener) == noErr { rateListener = listener }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw MixerFailure(step: "Start IOProc", status: status) }
    }

    /// Gain and curve, from a plan with the same structure.
    func apply(_ plan: MixerPipelinePlan) {
        self.plan = plan
        dsp.update(gain: plan.gain, eq: plan.eq, limiter: plan.needsLimiter, sampleRate: sampleRate)
    }

    /// Plays straight through while it waits to be retired, so lingering never keeps a mute or
    /// a volume the person has already undone.
    func neutralise() {
        dsp.update(gain: 1, eq: nil, limiter: false, sampleRate: sampleRate)
    }

    func sampleRateChanged() {
        sampleRate = CA.read(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)).flatMap { $0 > 0 ? $0 : nil } ?? sampleRate
        if retireAt == nil { apply(plan) } else { neutralise() }
    }

    /// Changes which processes the tap takes (or leaves out) without rebuilding anything.
    /// False when Core Audio refuses; the caller rebuilds then.
    func setProcesses(_ processes: [AudioObjectID]) -> Bool {
        description.processes = processes
        var address = CA.address(kAudioTapPropertyDescription)
        var reference = Unmanaged.passUnretained(description).toOpaque()
        let status = AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference)
        guard status == noErr else { return false }
        plan.processes = processes
        return true
    }

    /// Stop, then destroy in reverse order of creation. Safe to call on a half-built pipeline.
    func destroy() {
        if let rateListener, aggregateID != kAudioObjectUnknown {
            var address = CA.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &address, queue, rateListener)
        }
        rateListener = nil
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    var status: MixerPipelineStatus {
        MixerPipelineStatus(id: plan.id, outputUID: plan.outputUID, processes: plan.processes.count, gain: plan.gain,
                            eq: plan.eq != nil, sampleRate: sampleRate, callbacks: dsp.stats.pointee.callbacks,
                            audible: dsp.stats.pointee.audible, retiring: retireAt != nil)
    }
}

// MARK: The graph: reconciles plans with running pipelines, on its own queue

@available(macOS 14.2, *)
private final class MixerGraph: @unchecked Sendable {
    /// How long an unneeded pipeline lingers (playing straight through) before it is destroyed,
    /// so dragging a slider across 100 % does not tear down and rebuild a tap each time.
    static let retireDelay = 1.2

    let queue = DispatchQueue(label: "app.atelier.soundMixer", qos: .userInitiated)
    /// Only touched on `queue`.
    private var pipelines: [String: MixerPipeline] = [:]
    private let report: @Sendable ([MixerPipelineStatus], [String]) -> Void

    init(report: @escaping @Sendable ([MixerPipelineStatus], [String]) -> Void) {
        self.report = report
    }

    func reconcile(_ plans: [MixerPipelinePlan], immediate: Bool) {
        queue.async { self.reconcileNow(plans, immediate: immediate) }
    }

    private func reconcileNow(_ requested: [MixerPipelinePlan], immediate: Bool) {
        var errors: [String] = []
        // The global tap must leave this process out, or it would take in its own output and
        // feed back. Our process object exists once we have talked to the HAL; if it does not
        // yet, the global tap waits for the next pass rather than risk it.
        let own = CA.processObject(for: getpid())
        let plans: [MixerPipelinePlan] = requested.compactMap { plan in
            guard plan.kind == .global else { return plan }
            guard let own else {
                errors.append("global: Atelier's own audio process is not known yet")
                return nil
            }
            var plan = plan
            if !plan.processes.contains(own) { plan.processes = (plan.processes + [own]).sorted() }
            return plan
        }
        let wanted = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Unwanted, or wanted on another output: retire or destroy.
        for (id, pipeline) in pipelines {
            if let plan = wanted[id], plan.structureKey == pipeline.plan.structureKey { continue }
            if wanted[id] == nil && !immediate {
                if pipeline.retireAt == nil {
                    pipeline.retireAt = .now() + Self.retireDelay
                    pipeline.neutralise()
                    queue.asyncAfter(deadline: .now() + Self.retireDelay + 0.05) { self.sweep() }
                }
                continue
            }
            pipeline.destroy()
            pipelines[id] = nil
        }

        // Existing ones first (a global tap starts leaving an app out before the app's own tap
        // takes it, so for a moment it is never in both), then new ones.
        for plan in plans {
            guard let pipeline = pipelines[plan.id] else { continue }
            pipeline.retireAt = nil
            if pipeline.plan.processes != plan.processes && !pipeline.setProcesses(plan.processes) {
                pipeline.destroy()
                pipelines[plan.id] = nil
                continue
            }
            pipeline.apply(plan)
        }
        for plan in plans where pipelines[plan.id] == nil {
            do {
                let id = plan.id
                pipelines[id] = try MixerPipeline(plan: plan, queue: queue) { [weak self] in
                    self?.pipelines[id]?.sampleRateChanged()
                }
            } catch {
                errors.append("\(plan.id): \(error)")
            }
        }
        report(statuses, errors)
    }

    private func sweep() {
        let now = DispatchTime.now()
        var changed = false
        for (id, pipeline) in pipelines {
            if let at = pipeline.retireAt, at <= now {
                pipeline.destroy()
                pipelines[id] = nil
                changed = true
            }
        }
        if changed { report(statuses, []) }
    }

    private var statuses: [MixerPipelineStatus] { pipelines.values.map(\.status).sorted { $0.id < $1.id } }

    /// For quitting and diagnostics: runs on the queue and waits. The queue never waits on the
    /// main thread, so this cannot deadlock.
    func teardownAll() {
        queue.sync {
            for pipeline in pipelines.values { pipeline.destroy() }
            pipelines = [:]
        }
    }

    func currentStatuses() -> [MixerPipelineStatus] { queue.sync { statuses } }
}

// MARK: The model the cards use

struct MixerApp: Identifiable, Equatable {
    let id: String              // owner bundle identifier
    var name: String
    var icon: NSImage?
    var playing: Bool
    var processes: [AudioObjectID]

    static func == (a: MixerApp, b: MixerApp) -> Bool {
        a.id == b.id && a.name == b.name && a.playing == b.playing && a.processes == b.processes && a.icon === b.icon
    }
}

struct MixerOutput: Identifiable, Equatable {
    let id: String              // device UID
    var name: String
    var transport: UInt32

    var symbol: String {
        let lower = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            if lower.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return lower.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "hifispeaker"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual: return "square.stack.3d.up"
        default: return "speaker.wave.2"
        }
    }
}

@MainActor
final class SoundMixer: ObservableObject {
    static let shared = SoundMixer()

    enum Keys {
        static let enabled = "soundMixer.enabled"
        static let settings = "soundMixer.settings"
    }

    /// Process taps are macOS 14.2's.
    static var availability: FeatureAvailability {
        if #available(macOS 14.2, *) { return .available }
        return .unavailable("Needs macOS 14.2")
    }

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            if enabled && !Self.availability.isUsable { enabled = false; return }
            store.set(enabled, forKey: Keys.enabled)
            enabledChanged()
        }
    }
    @Published var settings: SoundMixerSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = settings.encoded() { store.set(data, forKey: Keys.settings) }
            apply()
        }
    }
    /// Apps playing now, and running apps with a setting of their own.
    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var outputs: [MixerOutput] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var permission: MixerPermission = .unknown
    /// One line for the card when something did not work.
    @Published private(set) var problem: String?
    @Published private(set) var pipelines: [MixerPipelineStatus] = []

    private let store = UserDefaults.standard
    private var processes: [MixerProcessInfo] = []
    private var ownProcesses: [AudioObjectID] = []
    private var graphBox: AnyObject?
    private var watchers = 0
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var refreshQueued = false
    private var requestingPermission = false
    /// NSRunningApplication may hand back a new image each time; one per app keeps the rows equal.
    private var icons: [String: NSImage] = [:]

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Keys.enabled) && Self.availability.isUsable
        settings = SoundMixerSettings.decoded(UserDefaults.standard.data(forKey: Keys.settings))
    }

    // MARK: Lifecycle

    /// At launch, including the relaunch after a crash (coreaudiod already dropped the old
    /// process's taps and aggregates): rebuilds what the settings ask for. Off: does nothing.
    func resume() {
        guard enabled else { return }
        enabledChanged()
    }

    /// For `applicationWillTerminate`: every IOProc stopped, every aggregate and tap destroyed,
    /// before the process goes, so no app is left muted for a moment.
    func restoreOnQuit() {
        pollTimer?.invalidate(); pollTimer = nil
        healthTimer?.invalidate(); healthTimer = nil
        removeListeners()
        if #available(macOS 14.2, *), let graph = graphBox as? MixerGraph { graph.teardownAll() }
        pipelines = []
    }

    /// The card is on screen: keep the list of playing apps live.
    func startWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        updateListening()
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { SoundMixer.shared.refresh() } }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopWatching() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        pollTimer?.invalidate(); pollTimer = nil
        updateListening()
    }

    private func enabledChanged() {
        updateListening()
        if enabled {
            checkPermission()
            refresh()
        } else {
            problem = nil
            if #available(macOS 14.2, *), let graph = graphBox as? MixerGraph { graph.reconcile([], immediate: true) }
            healthTimer?.invalidate(); healthTimer = nil
        }
    }

    private func updateListening() {
        let want = enabled || watchers > 0
        if want && listeners.isEmpty { addListeners() } else if !want && !listeners.isEmpty { removeListeners() }
    }

    private func addListeners() {
        guard #available(macOS 14.2, *) else { return }
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = CA.address(selector)
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { SoundMixer.shared.queueRefresh() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                listeners.append((selector, block))
            }
        }
    }

    private func removeListeners() {
        for (selector, block) in listeners {
            var address = CA.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listeners = []
    }

    /// Core Audio sends a burst of notifications for one change; refresh once for the burst.
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                SoundMixer.shared.refreshQueued = false
                SoundMixer.shared.refresh()
            }
        }
    }

    // MARK: Permission

    private func checkPermission() {
        guard let tcc else { permission = .unknown; return }
        switch tcc.preflight(audioCaptureService, nil) {
        case 0: permission = .granted
        case 1: permission = .denied
        default: permission = .unknown
        }
        if permission == .denied {
            problem = "Allow Atelier under Privacy & Security › Screen & System Audio Recording."
        } else if problem?.hasPrefix("Allow Atelier") == true {
            problem = nil
        }
    }

    /// Asks before the first tap, so no app is muted while the prompt is up.
    private func requestPermission() {
        guard let tcc, !requestingPermission else { return }
        requestingPermission = true
        tcc.request(audioCaptureService, nil) { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let mixer = SoundMixer.shared
                    mixer.requestingPermission = false
                    mixer.permission = granted ? .granted : .denied
                    mixer.checkPermission()
                    mixer.apply()
                }
            }
        }
    }

    /// Re-reads the permission while the "Needs Screen & System Audio Recording" note is up,
    /// so a grant in System Settings starts the mixer without a relaunch.
    func recheckPermission() {
        let before = permission
        checkPermission()
        if before != permission { apply() }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reading the system

    func refresh() {
        guard #available(macOS 14.2, *) else { return }
        // Allowed in System Settings since: pick it up without a relaunch.
        if enabled && permission == .denied { checkPermission() }
        readDevices()
        readProcesses()
        apply()
    }

    private func readDevices() {
        var found: [MixerOutput] = []
        for device in CA.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
            guard let uid = CA.deviceUID(device), !uid.hasPrefix(mixerAggregatePrefix),
                  !CA.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty,
                  CA.read(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) != 0
            else { continue }
            found.append(MixerOutput(id: uid, name: CA.string(device, kAudioObjectPropertyName) ?? uid,
                                     transport: CA.read(device, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0))
        }
        found.sort { ($0.transport == kAudioDeviceTransportTypeBuiltIn ? 0 : 1, $0.name) < ($1.transport == kAudioDeviceTransportTypeBuiltIn ? 0 : 1, $1.name) }
        if found != outputs { outputs = found }
        let uid = CA.defaultOutputDevice.flatMap(CA.deviceUID)
        if uid != defaultOutputUID { defaultOutputUID = uid }
    }

    @available(macOS 14.2, *)
    private func readProcesses() {
        let running = NSWorkspace.shared.runningApplications
        var byPID: [pid_t: NSRunningApplication] = [:]
        var byBundle: [String: NSRunningApplication] = [:]
        for app in running {
            byPID[app.processIdentifier] = app
            if let id = app.bundleIdentifier, app.activationPolicy != .prohibited, byBundle[id] == nil { byBundle[id] = app }
        }
        let regular = Set(byBundle.keys)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        ownProcesses = CA.processObject(for: ownPID).map { [$0] } ?? []
        let ownBundle = Bundle.main.bundleIdentifier

        var list: [MixerProcessInfo] = []
        for object in CA.objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard let pid = CA.read(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0, pid != ownPID else { continue }
            let bundleID = CA.string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
                ?? byPID[pid]?.bundleIdentifier
            let responsible = responsiblePID.map { $0(pid) }.flatMap { $0 > 0 && $0 != pid ? byPID[$0]?.bundleIdentifier : nil }
            var owner = MixerOwner.owner(bundleID: bundleID, responsibleBundleID: responsible, regularApps: regular)
            if owner == ownBundle { owner = nil }
            let playing = (CA.read(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            list.append(MixerProcessInfo(objectID: object, pid: pid, bundleID: bundleID, owner: owner, isRunningOutput: playing))
        }
        processes = list

        // The card's rows: apps that are playing, and running apps with a setting of their own.
        var rows: [String: MixerApp] = [:]
        for process in list {
            guard let owner = process.owner, let app = byBundle[owner] else { continue }
            if icons[owner] == nil { icons[owner] = app.icon }
            var row = rows[owner] ?? MixerApp(id: owner, name: app.localizedName ?? owner, icon: icons[owner], playing: false, processes: [])
            row.playing = row.playing || process.isRunningOutput
            row.processes.append(process.objectID)
            rows[owner] = row
        }
        let shown = rows.values.filter { $0.playing || settings.apps[$0.id] != nil }
            .sorted { ($0.playing ? 0 : 1, $0.name.localizedLowercase) < ($1.playing ? 0 : 1, $1.name.localizedLowercase) }
        if shown != apps { apps = shown }
    }

    // MARK: Applying

    private func apply() {
        guard #available(macOS 14.2, *) else { return }
        guard enabled, permission != .denied else {
            if let graph = graphBox as? MixerGraph { graph.reconcile([], immediate: true) }
            return
        }
        let plans = SoundMixerPlanner.plan(enabled: true, settings: settings, processes: processes, ownProcesses: ownProcesses,
                                           defaultOutputUID: defaultOutputUID, outputUIDs: Set(outputs.map(\.id)))
        if plans.isEmpty && graphBox == nil { return }
        if !plans.isEmpty && permission == .unknown && tcc != nil {
            requestPermission()
            return
        }
        graph().reconcile(plans, immediate: false)
        updateHealthTimer(running: !plans.isEmpty)
    }

    @available(macOS 14.2, *)
    private func graph() -> MixerGraph {
        if let graph = graphBox as? MixerGraph { return graph }
        let graph = MixerGraph { statuses, errors in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let mixer = SoundMixer.shared
                    if mixer.pipelines.map(\.shape) != statuses.map(\.shape) { mixer.pipelines = statuses }
                    if !errors.isEmpty { mixer.problem = "Could not take over " + errors.joined(separator: "; ") }
                    else if mixer.problem?.hasPrefix("Could not") == true { mixer.problem = nil }
                    mixer.updateHealthTimer(running: !statuses.isEmpty)
                }
            }
        }
        graphBox = graph
        return graph
    }

    /// While taps run: notices permission being taken away in System Settings, which would
    /// otherwise leave tapped apps playing silence.
    private func updateHealthTimer(running: Bool) {
        if running && healthTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let mixer = SoundMixer.shared
                    let before = mixer.permission
                    mixer.checkPermission()
                    if before != .denied && mixer.permission == .denied { mixer.apply() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            healthTimer = timer
        } else if !running, let timer = healthTimer {
            timer.invalidate()
            healthTimer = nil
        }
    }

    // MARK: What the cards change

    func rule(for app: String) -> MixerAppRule { settings.rule(for: app) }

    /// Touching a control is a clear wish to use the mixer, so it turns it on. Turning a
    /// part off (`wakes: false`) is not: switching EQ off must never switch the mixer on.
    private func edit(wakes: Bool = true, _ change: (inout SoundMixerSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
        if wakes, !enabled && Self.availability.isUsable { enabled = true }
    }

    func setVolume(_ volume: Double, for app: String) {
        edit { settings in
            var rule = settings.rule(for: app)
            rule.volume = SoundMixerGain.snapped(volume)
            settings.setRule(rule, for: app)
        }
    }

    func setMuted(_ muted: Bool, for app: String) {
        edit { settings in
            var rule = settings.rule(for: app)
            rule.muted = muted
            settings.setRule(rule, for: app)
        }
    }

    /// nil follows the default output.
    func route(_ app: String, to deviceUID: String?) {
        edit { settings in
            var rule = settings.rule(for: app)
            rule.deviceUID = deviceUID == defaultOutputUID && deviceUID != nil ? nil : deviceUID
            settings.setRule(rule, for: app)
        }
    }

    func reset(_ app: String) { edit { $0.setRule(MixerAppRule(), for: app) } }

    /// The device whose curve the EQ card edits: the default output.
    var eqDeviceUID: String? { defaultOutputUID }
    var eqDeviceName: String { outputs.first { $0.id == defaultOutputUID }?.name ?? "this Mac" }
    var eqProfile: EQProfile { settings.eqProfile(forDevice: eqDeviceUID) }
    var eqDeviceHasOwnCurve: Bool { eqDeviceUID.map { settings.deviceEQ[$0] != nil } ?? false }

    var eqEnabled: Bool {
        get { settings.eqEnabled }
        set { edit(wakes: newValue) { $0.eqEnabled = newValue } }
    }

    private func editProfile(_ change: (inout EQProfile) -> Void) {
        edit { settings in
            if let uid = eqDeviceUID, settings.deviceEQ[uid] != nil {
                change(&settings.deviceEQ[uid]!)
            } else {
                change(&settings.eq)
            }
            settings.eqEnabled = true
        }
    }

    func setBand(_ index: Int, gain: Double) {
        guard (0..<SoundEQ.bandCount).contains(index) else { return }
        editProfile { profile in
            var gains = profile.gains
            gains[index] = (min(max(gain, SoundEQ.gainRange.lowerBound), SoundEQ.gainRange.upperBound) * 2).rounded() / 2
            profile = EQProfile(preset: EQPreset.matching(gains), gains: gains)
        }
    }

    func choose(_ preset: EQPreset) {
        guard let gains = preset.gains else { return }
        editProfile { $0 = EQProfile(preset: preset, gains: gains) }
    }

    /// Gives the current output its own curve (starting from the shared one), or drops it.
    func setOwnCurve(_ own: Bool) {
        guard let uid = eqDeviceUID else { return }
        edit { settings in settings.deviceEQ[uid] = own ? (settings.deviceEQ[uid] ?? settings.eq) : nil }
    }

    /// The level an app is set to, for readouts: "80 %", "Muted".
    func readout(for app: String) -> String {
        let rule = rule(for: app)
        return rule.muted ? "Muted" : "\(Int((rule.volume * 100).rounded())) %"
    }

    /// Whether an app is running through a tap right now.
    func isTapped(_ app: String) -> Bool { pipelines.contains { $0.id == "app:" + app && !$0.retiring } }

    // MARK: Diagnostics and live tests

    var diagnostics: String {
        var statuses = pipelines
        if #available(macOS 14.2, *), let graph = graphBox as? MixerGraph { statuses = graph.currentStatuses() }
        let running = statuses.map { s in
            String(format: "%@@%@:g%.3f:eq%d:%.0fHz:cb%llu:aud%llu%@", s.id, s.outputUID, s.gain, s.eq ? 1 : 0, s.sampleRate,
                   s.callbacks, s.audible, s.retiring ? ":retiring" : "")
        }.joined(separator: ";")
        let profile = settings.eqProfile(forDevice: defaultOutputUID)
        return "mixer=\(enabled ? "on" : "off") mixerAvail=\(Self.availability.isUsable ? "yes" : "no") mixerTCC=\(permission.rawValue)"
            + " mixerProcesses=\(processes.count) mixerPlaying=\(apps.filter(\.playing).map(\.id).joined(separator: ",").nilIfEmpty ?? "-")"
            + " mixerRules=\(settings.apps.count) mixerDefault=\(defaultOutputUID ?? "-") mixerOutputs=\(outputs.count)"
            + " mixerEQ=\(settings.eqEnabled ? profile.preset.rawValue : "off") mixerEQGains=\(profile.gains.map { String(format: "%g", $0) }.joined(separator: ","))"
            + " mixerPipelines=\(statuses.count) mixerRunning=\(running.nilIfEmpty ?? "-") mixerProblem=\(problem ?? "-")"
    }

    /// `atelier://mixer?…` — see the integration notes. Applied in order, then the system is
    /// read again.
    func handleTest(_ items: [URLQueryItem]) {
        let app = items.first { $0.name == "app" }?.value
        var band: Int?
        for item in items {
            let value = item.value ?? ""
            switch item.name {
            case "on": enabled = value == "1"
            case "volume": if let app, let percent = Double(value) { setVolume(percent / 100, for: app) }
            case "mute": if let app { setMuted(value == "1", for: app) }
            case "device": if let app { route(app, to: value == "default" || value.isEmpty ? nil : value) }
            case "reset":
                if value == "all" { settings = SoundMixerSettings() } else { reset(value) }
            case "eq": eqEnabled = value == "1"
            case "preset": if let preset = EQPreset(rawValue: value) { choose(preset) }
            case "band": band = Int(value)
            case "gain": if let band, let gain = Double(value) { setBand(band, gain: gain) }
            case "owncurve": setOwnCurve(value == "1")
            case "watch": if value == "1" { startWatching() } else { stopWatching() }
            case "teardown": restoreOnQuit()
            default: break
            }
        }
        refresh()
        if items.contains(where: { $0.name == "dump" }) {
            // After the graph has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    let mixer = SoundMixer.shared
                    let lines = [mixer.diagnostics]
                        + mixer.apps.map { "app \($0.id) name=\($0.name) playing=\($0.playing) processes=\($0.processes.count) rule=\(mixer.readout(for: $0.id)) device=\(mixer.rule(for: $0.id).deviceUID ?? "default") tapped=\(mixer.isTapped($0.id))" }
                        + mixer.outputs.map { "output \($0.id) name=\($0.name) default=\($0.id == mixer.defaultOutputUID)" }
                    try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "atelier-mixer.txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }
}
