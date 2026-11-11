import Foundation
import Testing
@testable import DockCore

// Every typing buffer is rendered offline here and checked the way an ear would complain:
// silence, clipping, a click at either end, a sound that rings too long, packs that sound alike.

@Test func typingBuffersAreCleanAndInRange() {
    for voice in TypingVoice.allCases {
        let pack = TypingSynth.renderPack(voice)
        #expect(pack.count == TypingKeyClass.allCases.count)
        for kind in TypingKeyClass.allCases {
            let variants = pack[kind.rawValue]
            #expect(variants.count == TypingSynth.variants)
            let length = TypingSynth.length(voice, kind)
            for buffer in variants {
                let label = "\(voice.rawValue)/\(kind)"
                #expect(buffer.count == Int(length * TypingSynth.sampleRate), "\(label) length")
                #expect(length >= 0.04 && length <= 1.2, "\(label) rings \(length) s")
                let finite = buffer.allSatisfy { $0.isFinite }
                #expect(finite, "\(label) has NaN")
                let peak = buffer.reduce(0) { max($0, abs($1)) }
                // Normalised to its target, far from full scale, so overlapping keys do not clip.
                #expect(abs(peak - TypingSynth.peak(voice, kind)) < 1e-3, "\(label) peak \(peak)")
                #expect(peak < 0.7, "\(label) too hot")
                // Starts from silence and ends in silence: no click at either edge.
                #expect(abs(buffer[0]) < 1e-3, "\(label) starts with a jump")
                #expect(abs(buffer[buffer.count - 1]) < 1e-4, "\(label) ends with a jump")
                // Not a near-silent buffer: the energy is real.
                let rms = (buffer.reduce(0) { $0 + Double($1 * $1) } / Double(buffer.count)).squareRoot()
                #expect(rms > 0.005, "\(label) rms \(rms)")
                // Most of the energy is up front: a key press, not a drone.
                let head = buffer.prefix(buffer.count / 2).reduce(0) { $0 + Double($1 * $1) }
                let all = buffer.reduce(0) { $0 + Double($1 * $1) }
                #expect(head / all > 0.6, "\(label) energy late")
            }
        }
    }
}

@Test func typingVariantsDifferButRenderDeterministically() {
    for voice in TypingVoice.allCases {
        let a = TypingSynth.render(voice, .key, variant: 0)
        let b = TypingSynth.render(voice, .key, variant: 1)
        #expect(a != b, "\(voice) variants identical")
        #expect(a == TypingSynth.render(voice, .key, variant: 0), "\(voice) not deterministic")
        // The space bar is its own sound, not the letter key again.
        #expect(TypingSynth.render(voice, .space, variant: 0) != a)
    }
}

@Test func typingPacksSoundDistinct() {
    // Zero crossings per second is a crude brightness measure, enough to tell packs apart.
    func brightness(_ voice: TypingVoice) -> Double {
        let buffer = TypingSynth.render(voice, .key, variant: 0)
        var crossings = 0
        for i in 1..<buffer.count where (buffer[i - 1] < 0) != (buffer[i] < 0) { crossings += 1 }
        return Double(crossings) / (Double(buffer.count) / TypingSynth.sampleRate)
    }
    let values = TypingVoice.allCases.map { ($0, brightness($0)) }
    #expect(brightness(.thock) < brightness(.linear))
    #expect(brightness(.topre) < brightness(.click))
    #expect(brightness(.laptop) > brightness(.thock))
    // No two packs within 3 % of each other on this measure, or on their length.
    for (i, a) in values.enumerated() {
        for b in values.dropFirst(i + 1) {
            let close = abs(a.1 - b.1) / max(a.1, b.1) < 0.03
            let sameLength = TypingSynth.length(a.0, .key) == TypingSynth.length(b.0, .key)
            #expect(!(close && sameLength), "\(a.0) and \(b.0) sound alike")
        }
    }
}

@Test func typewriterReturnRingsTheBell() {
    let ret = TypingSynth.render(.typewriter, .returnKey, variant: 0)
    #expect(Double(ret.count) / TypingSynth.sampleRate > 0.9)
    // The carriage stop near the end is still audible.
    let tail = ret[Int(0.52 * TypingSynth.sampleRate)..<Int(0.6 * TypingSynth.sampleRate)]
    #expect(tail.reduce(0) { max($0, abs($1)) } > 0.05)
}

@Test func typingKeyClasses() {
    #expect(TypingKeyClass.of(keyCode: 49) == .space)
    #expect(TypingKeyClass.of(keyCode: 36) == .returnKey)
    #expect(TypingKeyClass.of(keyCode: 76) == .returnKey)
    #expect(TypingKeyClass.of(keyCode: 51) == .backspace)
    #expect(TypingKeyClass.of(keyCode: 56) == .modifier)
    #expect(TypingKeyClass.of(keyCode: 0) == .key)
    #expect(TypingKeyClass.modifierMask(keyCode: 55) == 1 << 20)
    #expect(TypingKeyClass.modifierMask(keyCode: 57) == nil)
    #expect(Set(TypingVoice.ordered) == Set(TypingVoice.allCases))
    // Stored raw values from earlier releases still decode.
    for raw in ["thock", "click", "typewriter", "bubble"] { #expect(TypingVoice(rawValue: raw) != nil) }
}

@Test func typingPackRendersFast() {
    // A pack is rendered off the main thread when it is picked. Even an unoptimised test
    // build, sharing the CPU with the rest of the suite, does the heaviest one quickly.
    let start = Date()
    _ = TypingSynth.renderPack(.typewriter)
    #expect(Date().timeIntervalSince(start) < 1.5)
}
