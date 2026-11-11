import DockCore
import Foundation
import Testing

/// The version and hardware decisions behind Display, Light, HUD and Sensors, tested with the
/// Mac described as parameters, so every chip and panel is covered on any machine.
@Suite struct DisplayCompatTests {
    // MARK: SMC types

    @Test func decodesIntelFixedPointFamily() {
        // sp96 (Intel power): 9 integer bits, 6 fraction bits. 25.5 W is 25.5 × 64 = 1632 = 0x0660.
        #expect(SMCDecode.value(type: "sp96", bytes: [0x06, 0x60]) == 25.5)
        // spb4: 11.4; -2 is 0xFFE0.
        #expect(SMCDecode.value(type: "spb4", bytes: [0xFF, 0xE0]) == -2)
        // fp2e: unsigned 2.14; 1.0 is 0x4000.
        #expect(SMCDecode.value(type: "fp2e", bytes: [0x40, 0x00]) == 1)
        // The hand-written cases still win.
        #expect(SMCDecode.value(type: "sp78", bytes: [0x24, 0x80]) == 36.5)
        // Bit splits that do not add up are not numbers.
        #expect(SMCDecode.value(type: "sp88", bytes: [0x01, 0x00]) == nil)
        #expect(SMCDecode.value(type: "spzz", bytes: [0x01, 0x00]) == nil)
        #expect(SMCDecode.value(type: "sp96", bytes: [0x06]) == nil)
    }

    // MARK: Chips

    @Test func recognisesChips() {
        #expect(SensorChip.from(brand: "Apple M5 Pro", appleSilicon: true) == .appleSilicon(generation: 5))
        #expect(SensorChip.from(brand: "Apple M1", appleSilicon: true) == .appleSilicon(generation: 1))
        #expect(SensorChip.from(brand: "Apple M3 Max", appleSilicon: true) == .appleSilicon(generation: 3))
        #expect(SensorChip.from(brand: "Apple M12 Ultra", appleSilicon: true) == .appleSilicon(generation: 12))
        #expect(SensorChip.from(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", appleSilicon: false) == .intel)
        // Rosetta on older systems reported a made-up name; the prefix guess takes over.
        #expect(SensorChip.from(brand: "VirtualApple @ 2.50GHz processor", appleSilicon: true) == .appleSiliconUnknown)
        #expect(SensorChip.from(brand: "Apple A18 Pro", appleSilicon: true) == .appleSiliconUnknown)
    }

    @Test func intelUsesItsOwnKeysAndNeverThePowerBoard() {
        let keys = ["TC0P", "TC0D", "TC1C", "TC2C", "Tp0P", "TG0P", "TB0T", "F0Ac", "F0Mn", "F0Mx", "FNum", "PSTR"]
        let plan = SensorKeyPlan.plan(keys: keys, chip: .intel)
        #expect(plan[.cpu] == ["TC0P", "TC0D", "TC1C", "TC2C"])
        #expect(plan[.gpu] == ["TG0P"])
        #expect(plan[.battery] == ["TB0T"])
        #expect(plan[.fan] == ["F0Ac", "F0Mn", "F0Mx"])
        #expect(plan[.power] == ["PSTR"])
        #expect(!(plan[.cpu] ?? []).contains("Tp0P"))
    }

    @Test func m3ReadsTeTfAndSplitsTheGPU() {
        let keys = ["Te05", "Tf04", "Tf09", "Tf14", "Tf18", "Tp0x", "TB0T", "PSTR"]
        let plan = SensorKeyPlan.plan(keys: keys, chip: .appleSilicon(generation: 3))
        #expect(plan[.cpu] == ["Te05", "Tf04", "Tf09"])
        #expect(plan[.gpu] == ["Tf14", "Tf18"])
    }

    @Test func m5UsesStatsTableNotEveryTpKey() {
        let keys = ["Tp00", "Tp04", "Tp1g", "Tg0U", "Tg43", "F0Ac"]
        let plan = SensorKeyPlan.plan(keys: keys, chip: .appleSilicon(generation: 5))
        #expect(plan[.cpu] == ["Tp00", "Tp04"])
        #expect(plan[.gpu] == ["Tg0U"])
    }

    @Test func unlistedChipFallsBackToPrefixes() {
        let keys = ["Tp0Z", "Te1Q", "Tg9Z", "TB0T"]
        let newer = SensorKeyPlan.plan(keys: keys, chip: .appleSilicon(generation: 9))
        #expect(newer[.cpu] == ["Tp0Z"])
        #expect(newer[.gpu] == ["Tg9Z"])
        let unknown = SensorKeyPlan.plan(keys: keys, chip: .appleSiliconUnknown)
        #expect(unknown[.cpu] == ["Tp0Z", "Te1Q"])
    }

    @Test func fanlessDesktopPlanHasNoFansOrBattery() {
        // A MacBook Air has no F<n>Ac keys; a Mac mini has no TB*T.
        let air = SensorKeyPlan.plan(keys: ["Tp01", "TB0T", "FNum"], chip: .appleSilicon(generation: 2))
        #expect(air[.fan] == nil)
        #expect(air[.battery] == ["TB0T"])
        let mini = SensorKeyPlan.plan(keys: ["Tp01", "F0Ac", "PSTR"], chip: .appleSilicon(generation: 2))
        #expect(mini[.battery] == nil)
        #expect(mini[.fan] == ["F0Ac"])
    }

    @Test func capabilitiesSayWhatIsMissing() {
        let air = SensorCapabilities(temperature: true, gpu: true, fans: false, power: true, battery: true, charger: true)
        #expect(air.any)
        #expect(!SensorCapabilities().any)
        #expect(SensorCapabilities.unknown.fans)
    }

    // MARK: Light

    private func display(_ name: String = "Built-in Retina Display", builtIn: Bool = true, potential: Double, gamma: Bool = true) -> LightDisplayInfo {
        LightDisplayInfo(name: name, builtIn: builtIn, potentialHeadroom: potential, takesGamma: gamma)
    }

    @Test func boostOnXDRModels() {
        #expect(LightCompat.boost([display(potential: 16)], model: "Mac17,8") == .available)
        // Listed model, even if the panel reports less right now.
        #expect(LightCompat.boost([display(potential: 2)], model: "MacBookPro18,3") == .available)
        // A Pro Display XDR on an Intel Mac Pro.
        #expect(LightCompat.boost([display("Pro Display XDR", builtIn: false, potential: 16)], model: "MacPro7,1") == .available)
        // A newer XDR MacBook Pro than the list knows: recognised by its headroom.
        #expect(LightCompat.boost([display(potential: 16)], model: "Mac99,1") == .available)
    }

    @Test func boostLimitedOrUnavailableElsewhere() {
        // A MacBook Air: a little EDR at lower brightness, no XDR.
        if case .limited = LightCompat.boost([display(potential: 2)], model: "Mac14,2") {} else { Issue.record("expected limited") }
        // An ordinary SDR monitor on an Intel Mac.
        if case .unavailable = LightCompat.boost([display("DELL U2720Q", builtIn: false, potential: 1)], model: "MacBookPro16,1") {} else {
            Issue.record("expected unavailable")
        }
        // An XDR panel seen only through AirPlay takes no gamma, so Boost cannot reach it.
        if case .unavailable = LightCompat.boost([display("Pro Display XDR", builtIn: false, potential: 16, gamma: false)], model: "Mac14,2") {} else {
            Issue.record("expected unavailable")
        }
    }

    @Test func gammaFeatures() {
        #expect(LightCompat.gamma([display(potential: 1)]) == .available)
        if case .unavailable = LightCompat.gamma([display("Sidecar Display", builtIn: false, potential: 1, gamma: false)]) {} else {
            Issue.record("expected unavailable")
        }
        if case .limited(let note) = LightCompat.gamma([display(potential: 1), display("iPad", builtIn: false, potential: 1, gamma: false)]) {
            #expect(note.contains("iPad"))
        } else { Issue.record("expected limited") }
        if case .limited(let note) = LightCompat.gamma([display(potential: 1)], runningApps: ["Finder", "f.lux"]) {
            #expect(note.contains("f.lux"))
        } else { Issue.record("expected limited") }
    }

    // MARK: Objective-C signatures

    @Test func parsesEncodings() {
        #expect(ObjCSignature.types("B36@0:8f16i20B24Q28") == ["B", "@", ":", "f", "i", "B", "Q"])
        #expect(ObjCSignature.types("v40@0:8@16Q24@?32") == ["v", "@", ":", "@", "Q", "@?"])
        #expect(ObjCSignature.types("v24@0:8^{Status=cc}16") == ["v", "@", ":", "^{Status=cc}"])
        #expect(ObjCSignature.types("v32@0:8{CGPoint=dd}16") == ["v", "@", ":", "{CGPoint=dd}"])
    }

    @Test func matchesMeasuredKeyboardMethods() {
        // As measured on macOS 27.3, arm64.
        #expect(ObjCSignature.matches("B36@0:8f16i20B24Q28", "B@:fiBQ"))
        #expect(ObjCSignature.matches("f24@0:8Q16", "f@:Q"))
        #expect(ObjCSignature.matches("d24@0:8Q16", "d@:Q"))
        // Intel encodes BOOL as char.
        #expect(ObjCSignature.matches("c24@0:8Q16", "B@:Q"))
        // A changed argument type is refused.
        #expect(!ObjCSignature.matches("f24@0:8i16", "f@:Q"))
        #expect(!ObjCSignature.matches("B28@0:8d16Q24", "B@:fQ"))
        // Setters may change their return without harm.
        #expect(ObjCSignature.matchesArguments("v32@0:8d16Q24", "B@:dQ"))
        #expect(!ObjCSignature.matchesArguments("v32@0:8f16Q24", "B@:dQ"))
    }

    // MARK: HUD notes

    @Test func hudNotesDependOnTheChip() {
        let apple = HUDCompat.keyboardKeysNote(appleSilicon: true, backlight: true, owned: true, seen: 0)
        let intel = HUDCompat.keyboardKeysNote(appleSilicon: false, backlight: true, owned: true, seen: 0)
        #expect(apple.contains("Apple silicon"))
        #expect(!intel.contains("Apple silicon"))
        #expect(HUDCompat.keyboardKeysNote(appleSilicon: false, backlight: false, owned: true, seen: 0).contains("No backlit"))
        #expect(HUDCompat.brightnessNote(appleSilicon: true, owned: true, tapActive: true, seen: 3, unseen: 0).contains("3 so far"))
        #expect(HUDCompat.brightnessNote(appleSilicon: false, owned: true, tapActive: true, seen: 0, unseen: 2).contains("Touch Bar"))
        #expect(HUDCompat.brightnessNote(appleSilicon: true, owned: false, tapActive: false, seen: 0, unseen: 0).contains("eases"))
    }
}
