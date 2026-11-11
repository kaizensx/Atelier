import Testing
@testable import DockCore

@Test func stageChromeFollowsTheRelease() {
    for major in [14, 15] {
        let chrome = ShellStageChrome.forRelease(major: major)
        #expect(!chrome.liquidGlass)
        #expect(chrome.menuBarBand)
        #expect(chrome.dockCornerFraction < 0.3)
        #expect(!chrome.capsuleLabels)
    }
    for major in [26, 27] {
        let chrome = ShellStageChrome.forRelease(major: major)
        #expect(chrome.liquidGlass)
        #expect(!chrome.menuBarBand)
        #expect(chrome.capsuleLabels)
        // Reduce Transparency brings the band back on Tahoe.
        #expect(ShellStageChrome.forRelease(major: major, reduceTransparency: true).menuBarBand)
    }
}

@Test func menuBarHeightPrefersTheMeasuredGap() {
    // A notched 16-inch MacBook Pro at its default size.
    #expect(ShellMenuBar.height(frameMaxY: 1117, visibleMaxY: 1080, notchInset: 32) == 37)
    // An external display: the standard bar.
    #expect(ShellMenuBar.height(frameMaxY: 1440, visibleMaxY: 1416, notchInset: 0) == 24)
    // Menu bar set to hide itself: no gap, so the notch height or the standard bar.
    #expect(ShellMenuBar.height(frameMaxY: 1117, visibleMaxY: 1117, notchInset: 32) == 32)
    #expect(ShellMenuBar.height(frameMaxY: 900, visibleMaxY: 900, notchInset: 0) == 24)
    // A Dock moved to the top by another tool is not mistaken for a menu bar.
    #expect(ShellMenuBar.height(frameMaxY: 900, visibleMaxY: 780, notchInset: 0) == 24)
}

@Test func notchWidthNeedsBothSides() {
    #expect(ShellMenuBar.notchWidth(screenWidth: 1728, leftArea: 783, rightArea: 760) == 185)
    #expect(ShellMenuBar.notchWidth(screenWidth: 1728, leftArea: nil, rightArea: 760) == nil)
    #expect(ShellMenuBar.notchWidth(screenWidth: 1728, leftArea: 864, rightArea: 864) == nil)
}

@Test func frameBudgetFollowsTheDisplay() {
    let sixty = ShellFrameBudget(maximumFramesPerSecond: 60)
    #expect(abs(sixty.frameMs - 16.67) < 0.01)
    #expect(sixty.lateMs > 24 && sixty.lateMs < 26)
    #expect(sixty.hitchMs > 41)
    let promotion = ShellFrameBudget(maximumFramesPerSecond: 120)
    #expect(abs(promotion.lateMs - 12.5) < 0.01)
    #expect(promotion.hitchMs == 25)
    // Nothing reported: assume 60 Hz.
    #expect(ShellFrameBudget(maximumFramesPerSecond: 0).refreshRate == 60)
}

@Test func lightTierSparesIntelGPUs() {
    let apple = ShellLightTier.choose(appleGPU: true, lowPowerDevice: false, lowPowerMode: false, refreshRate: 120)
    #expect(apple == ShellLightTier(resolution: 0.5, maxFPS: 120))
    let intel = ShellLightTier.choose(appleGPU: false, lowPowerDevice: true, lowPowerMode: false, refreshRate: 60)
    #expect(intel.resolution < 0.5 && intel.maxFPS == 60)
    let amd = ShellLightTier.choose(appleGPU: false, lowPowerDevice: false, lowPowerMode: false, refreshRate: 120)
    #expect(amd.maxFPS == 60)
    let saving = ShellLightTier.choose(appleGPU: true, lowPowerDevice: false, lowPowerMode: true, refreshRate: 120)
    #expect(saving.maxFPS == 30)
}

@Test func reportReadsLikeABugReport() {
    let facts = ShellMacFacts(osVersion: "14.7.2", osBuild: "23H311", model: "MacBookPro15,1", chip: "Intel Core i9-8950HK",
                              appleSilicon: false, translated: false,
                              displays: [.init(name: "Built-in Retina Display", main: true, builtIn: true, points: "1440×900",
                                               scale: 2, refreshRate: 60, notch: false, edrHeadroom: 1)],
                              trackpad: "Built-in, Force Touch", sip: "On", appVersion: "1.0 (1)")
    let text = facts.report
    #expect(text.contains("macOS 14.7.2 Sonoma (23H311)"))
    #expect(text.contains("Intel Core i9-8950HK, Intel"))
    #expect(text.contains("60 Hz, SDR"))
    #expect(!text.contains("notch"))
    #expect(text.contains("System Integrity Protection: On"))
    let xdr = ShellMacFacts.Display(name: "Built-in", main: true, builtIn: true, points: "1728×1117", scale: 2,
                                    refreshRate: 120, notch: true, edrHeadroom: 16)
    #expect(xdr.range == "XDR (16× EDR)")
}
