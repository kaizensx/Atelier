import Foundation

// MARK: - XDR Boost: the rules, with no AppKit in sight
//
// Boost lifts the whole desktop into an XDR panel's extended range by multiplying it with an
// EDR layer. Everything that went wrong with it came from doing the right thing at the wrong
// moment: multiplying while the display was asleep or locked (dark on return), before EDR had
// engaged (a harsh jump at login), or by more than the panel can sustain over the whole screen
// (the brightness keys stopped doing anything above half). These rules decide when and by how
// much, as plain functions the tests can walk through every case of.

public enum XDRBoostPolicy {
    /// Full-screen light an XDR panel keeps up indefinitely. Its 1600-nit peak is for highlights;
    /// past this the panel's own power limit pulls the whole picture back, so asking for more only
    /// flattens the top of the brightness range.
    public static let sustainedNits = 1000.0

    /// Where full brightness with Boost fully on lands: above the sustained limit on purpose.
    /// Everyday screens are mixed or dark, and there the panel has power to spare, so 1300 nits
    /// is real light; only an all-white screen is held back by the panel itself, and the curve
    /// still rises there, just more gently. 1440 nits is 2.4× on a 600-nit panel: 1000 and 1300
    /// looked visibly dimmer, a fixed 2.67× went flat above half brightness.
    public static let topNits = 1440.0

    /// SDR white at full brightness on this panel: 600 nits on recent XDR MacBook Pros, 500 on
    /// the first ones and on the Pro Display XDR.
    public static func sdrWhite(model: String, builtIn: Bool) -> Double {
        guard builtIn else { return 500 }
        return sdr600Models.contains(model) ? 600 : 500
    }

    /// Models whose SDR white is 600 nits (from BrightIntosh's device table, which tracks Apple's).
    public static let sdr600Models: Set<String> = [
        "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
        "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
        "Mac17,2", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9",
    ]

    /// The panel's peak: what macOS's EDR headroom is measured against (headroom = peak / SDR
    /// white now), 1600 nits on every XDR panel.
    public static let peakNits = 1600.0

    /// SDR white right now, from the headroom macOS reports while EDR is engaged: 600 nits at
    /// full brightness on this Mac, less as the brightness keys go down.
    public static func sdrNow(headroom: Double, sdrWhite: Double) -> Double {
        guard headroom > engagedHeadroom else { return sdrWhite }
        return min(sdrWhite, peakNits / headroom)
    }

    /// Light on screen, in nits, for SDR white `s` with Boost fully on. A soft knee rather than a
    /// fixed multiplier: low brightness gets the whole peak-to-SDR ratio (2.67× here), and the
    /// curve bends so full brightness lands on `topNits` (2.4× here). Every brightness step is
    /// therefore still a step: a fixed 2.67× hit the panel's limit at about half brightness, and
    /// above that the keys did nothing.
    public static func boostedNits(sdrNow s: Double, sdrWhite: Double) -> Double {
        let c = peakNits / max(sdrWhite, 1)
        let a = max(c * sdrWhite / topNits - 1, 0) / max(sdrWhite, 1)
        return c * s / (1 + a * s)
    }

    /// The multiplier for a Boost amount (0…1) at the headroom macOS reports now. It eases from
    /// 1× (amount 0) to the knee curve (amount 1), and never passes the headroom, where it would
    /// only clip highlights. Rounded to hundredths so the brightness keys glide it in steps
    /// instead of making it twitch.
    public static func factor(amount: Double, headroom: Double, sdrWhite: Double) -> Double {
        let s = sdrNow(headroom: headroom, sdrWhite: sdrWhite)
        let full = boostedNits(sdrNow: s, sdrWhite: sdrWhite) / max(s, 1)
        let wanted = 1 + min(max(amount, 0), 1) * (full - 1)
        let capped = min(wanted, max(headroom, 1))
        return (capped * 100).rounded() / 100
    }

    /// EDR is engaged once the headroom macOS reports rises past this.
    public static let engagedHeadroom = 1.05
    /// How long a resumed or new Boost waits after the screen is back before it starts, so macOS
    /// has finished its own wake work (it resets displays and their curves then).
    public static let settleDelay = 0.8
    /// Extra wait at launch, on top of `settleDelay`: at login the display is still settling.
    public static let launchExtraDelay = 1.5
    /// How long Boost waits for EDR to engage before it gives up on this attempt.
    public static let engageTimeout = 6.0
    /// The glide from 1× to the target and back: long enough to read as light changing, not as
    /// a flash.
    public static let rampDuration = 0.6
}

/// Where Boost stands. One display or many, the engine keeps a single state; layers follow it.
public enum XDRBoostState: Equatable, Sendable {
    /// Off, nothing on screen.
    case off
    /// Wanted, but the screen is asleep, locked, or changing: no layer up, nothing multiplied.
    case suspended
    /// Wanted and the screen is back: waiting `settleDelay` before putting a layer up.
    case settling(since: Double)
    /// Layer up at 1×, waiting for macOS to put the display into EDR.
    case engaging(since: Double)
    /// Gliding the multiplier from one value to another.
    case ramping(from: Double, to: Double, start: Double)
    /// Steady at the multiplier.
    case on(Double)
}

/// What happens to Boost.
public enum XDRBoostEvent: Equatable, Sendable {
    case turnOn
    case turnOff
    /// Screen asleep, screen saver, locked, fast user switch away, display about to change.
    case suspend
    /// Screen awake and unlocked again, the session back, displays settled.
    case resume
    /// A tick of the engine's clock, with the headroom macOS reports now and the target factor.
    case tick(now: Double, headroom: Double, target: Double)
}

public enum XDRBoostMachine {
    /// The next state. `wanted` is whether the owner has Boost on.
    public static func next(_ state: XDRBoostState, _ event: XDRBoostEvent, wanted: Bool) -> XDRBoostState {
        switch event {
        case .turnOff:
            return .off
        case .turnOn:
            // Turning on while the screen is away waits for it; otherwise it starts settling.
            if case .suspended = state { return .suspended }
            if case .off = state { return .settling(since: -.infinity) }
            return state
        case .suspend:
            return wanted ? .suspended : .off
        case .resume:
            guard wanted else { return .off }
            if case .suspended = state { return .settling(since: -1) }  // stamped on the next tick
            return state
        case .tick(let now, let headroom, let wantedTarget):
            // Turned off: glide back to 1× and only then take the layer away, so switching Boost
            // off looks like light dimming, not a cut.
            let target = wanted ? wantedTarget : 1
            if !wanted {
                switch state {
                case .off, .suspended, .settling, .engaging: return .off
                case .on(let value) where value <= 1.001: return .off
                default: break
                }
            }
            switch state {
            case .off, .suspended:
                return state
            case .settling(let since):
                // A fresh settle is stamped with the first tick's time.
                if since < 0 { return .settling(since: now) }
                return now - since >= XDRBoostPolicy.settleDelay ? .engaging(since: now) : state
            case .engaging(let since):
                if headroom > XDRBoostPolicy.engagedHeadroom {
                    return .ramping(from: 1, to: target, start: now)
                }
                // EDR never came (an HDR cooldown, another app holding the display): try again
                // later rather than multiplying an SDR picture.
                return now - since > XDRBoostPolicy.engageTimeout ? .settling(since: now) : state
            case .ramping(let from, let to, let start):
                // A new target mid-glide (a slider, the headroom moving) glides from where it is.
                let value = rampValue(from: from, to: to, start: start, now: now)
                if abs(target - to) > 0.001 { return .ramping(from: value, to: target, start: now) }
                return now - start >= XDRBoostPolicy.rampDuration ? .on(to) : state
            case .on(let value):
                if headroom <= XDRBoostPolicy.engagedHeadroom {
                    // EDR dropped out (cooldown, an HDR video ending elsewhere took it): back to
                    // 1× until it returns, never multiplying SDR into clipping.
                    return .engaging(since: now)
                }
                if !wanted { return .ramping(from: value, to: 1, start: now) }
                // Lit and steady, the factor follows its target frame by frame, no glide: the
                // brightness keys animate the backlight (and the headroom with it) over about a
                // quarter of a second, and a glide on top lagged behind it, so each key press
                // flashed brighter and then sank. Following exactly keeps the light in step.
                return abs(target - value) > 0.001 ? .on(target) : state
            }
        }
    }

    /// The multiplier to draw in a state at a time.
    public static func factor(_ state: XDRBoostState, now: Double) -> Double {
        switch state {
        case .off, .suspended, .settling, .engaging: 1
        case .ramping(let from, let to, let start): rampValue(from: from, to: to, start: start, now: now)
        case .on(let value): value
        }
    }

    /// Whether a layer should be on screen in a state. Engaging keeps one up at 1× so the
    /// display can enter EDR; suspended and settling keep none, so nothing can be left behind.
    public static func showsLayer(_ state: XDRBoostState) -> Bool {
        switch state {
        case .off, .suspended, .settling: false
        case .engaging, .ramping, .on: true
        }
    }

    static func rampValue(from: Double, to: Double, start: Double, now: Double) -> Double {
        let t = min(max((now - start) / XDRBoostPolicy.rampDuration, 0), 1)
        // Ease in-out: light that starts and settles gently.
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return from + (to - from) * e
    }
}
