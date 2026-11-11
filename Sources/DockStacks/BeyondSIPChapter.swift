import AppKit
import SwiftUI

// MARK: - Beyond SIP: the chapter
//
// On most Macs SIP is on, so this chapter is mostly seen locked. Locked still sells: every plate
// plays on hover, every stage preview shows the effect, and the Dock Bridge card at the top is an
// honest, step-by-step way in (and out) with the exact commands and what they cost.

struct BeyondSIPChapter: View {
    @ObservedObject private var bridge = DockBridge.shared
    @ObservedObject private var model = BeyondSIP.shared
    private let hue = DS.Spectrum.windows

    var body: some View {
        Text("Six window powers macOS keeps for the Dock. Atelier asks the Dock for them, through a small bridge.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                model.resume()
                SpacesIndicator.shared.refresh()
                Task { await DockBridge.shared.refresh() }
            }

        BridgeStatusHero()

        SectionHeader("Windows", symbol: "macwindow.on.rectangle",
                      detail: bridge.status.isReady ? "Every change is undone the moment you switch it off."
                                                    : "Locked until the Dock Bridge is ready. Hover a plate to see what you get.",
                      hue: hue)
        OpacityHero()
        PinHero()
        StickyHero()
        PiPHero()
        NoShadowHero()

        SectionHeader("Spaces", symbol: "square.split.2x1", hue: hue)
        SpacesStudioHero()
    }
}

// MARK: - The hero, with a lock

/// A HeroCard that can be locked: the plate still plays and the stage still previews, but the
/// switch becomes a lock and the tuning stays hidden. `isOn == nil` is a hero with no switch
/// (Spaces Studio): unlocked, it is simply lit with its controls open.
struct BridgeHero<Plate: View, Controls: View>: View {
    let title: String
    let pitch: String
    var isOn: Binding<Bool>?
    let locked: Bool
    var readout: String?
    var readoutCaption: String?
    var preview: StagePreviewSpec?
    var plate: Plate
    var controls: Controls
    @State private var hover = false
    @State private var sweeps = 0
    private let hue = DS.Spectrum.windows

    init(_ title: String, pitch: String, isOn: Binding<Bool>?, locked: Bool,
         readout: String? = nil, readoutCaption: String? = nil, preview: StagePreviewSpec? = nil,
         @ViewBuilder plate: () -> Plate, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.pitch = pitch
        self.isOn = isOn
        self.locked = locked
        self.readout = readout
        self.readoutCaption = readoutCaption
        self.preview = preview
        self.plate = plate()
        self.controls = controls()
    }

    private var lit: Bool { !locked && (isOn?.wrappedValue ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if !locked { isOn?.wrappedValue.toggle() } } label: { plateView }
                .buttonStyle(Pressable(scale: locked || isOn == nil ? 1 : 0.985))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                        Text(pitch).font(DS.body).foregroundStyle(DS.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if locked {
                        LockPill()
                    } else if let isOn {
                        LuxSwitch(isOn: isOn, label: title, tint: hue, size: .large)
                    }
                }
                if lit {
                    controls.transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, 14)
            .padding(.bottom, DS.Space.s)
        }
        .padding(DS.Inset.plate)
        .background { CardSurface(style: lit ? .lit(hue) : .standard) }
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(hover ? 0.1 : 0), lineWidth: 0.5)
        }
        .animation(DS.Motion.gentle(DS.Motion.reveal), value: lit)
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .onChange(of: lit) { _, on in if on { sweeps += 1 } }
        .stagePreview(preview)
        .accessibilityElement(children: .contain)
        .accessibilityHint(locked ? "Needs the Dock Bridge, set up at the top of this page." : "")
    }

    private var plateView: some View {
        ZStack(alignment: .topLeading) {
            RadialGradient(colors: [hue.opacity(lit ? 0.45 : 0.14), .clear],
                           center: UnitPoint(x: 0.5, y: 1.1), startRadius: 0, endRadius: 260)
            plate.frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.black.opacity(lit ? 0 : 0.3).allowsHitTesting(false)
            HStack(spacing: 6) {
                HeroBadge(text: "Beyond SIP", hue: hue)
                Spacer(minLength: 0)
                if locked { LockBadge() }
            }
            .padding(10)
            if let readout {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(readout).font(DS.Typo.readout).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    if let readoutCaption {
                        Text(readoutCaption.uppercased()).font(DS.Typo.badge).tracking(0.8)
                            .foregroundStyle(DS.Ink.secondary)
                    }
                }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
            }
        }
        .frame(height: 148)
        .background(Color(red: 0.06, green: 0.065, blue: 0.08))
        .overlay { SweepLight(trigger: sweeps) }
        .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
    }
}

extension BridgeHero where Controls == EmptyView {
    init(_ title: String, pitch: String, isOn: Binding<Bool>?, locked: Bool,
         readout: String? = nil, readoutCaption: String? = nil, preview: StagePreviewSpec? = nil,
         @ViewBuilder plate: () -> Plate) {
        self.init(title, pitch: pitch, isOn: isOn, locked: locked, readout: readout, readoutCaption: readoutCaption,
                  preview: preview, plate: plate, controls: { EmptyView() })
    }
}

/// On the plate: what it is waiting for, in words.
private struct LockBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "lock.fill").font(.system(size: 8.5, weight: .bold))
            Text("NEEDS THE DOCK BRIDGE").font(DS.Typo.badge).tracking(0.8)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(.black.opacity(0.45), in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
    }
}

/// In place of the switch: a lock the size of the switch, so the row keeps its shape.
private struct LockPill: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.Ink.secondary)
            .frame(width: 52, height: 30)
            .background(DS.Ink.fill, in: .capsule)
            .overlay { Capsule().strokeBorder(DS.Ink.edge, lineWidth: 0.5) }
            .help("Set up the Dock Bridge at the top of this page to use this.")
            .accessibilityLabel("Locked")
    }
}

// MARK: - The Dock Bridge

struct BridgeStatusHero: View {
    @ObservedObject private var bridge = DockBridge.shared
    @State private var checking = false
    @State private var working: Int?
    @State private var problem: String?
    @State private var sweeps = 0
    private let hue = DS.Spectrum.windows
    private let caution = DS.Spectrum.sensors

    private var status: BridgeStatus { bridge.status }

    /// Which step is next: 1 SIP, 2 install, 3 load, 4 done. Nil when the bridge failed.
    private var step: Int? {
        switch status {
        case .sipEnabled, .needsBootArgument: 1
        case .notInstalled: 2
        case .notLoaded: 3
        case .ready: 4
        case .failed: nil
        }
    }

    private func state(_ number: Int) -> BridgeStepState {
        guard let step else { return number == 1 ? .done : .current }
        if number < step { return .done }
        return number == step ? .current : .locked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LivePlate { size, since in BridgePlate(size: size, since: since, ready: status.isReady) }
                .overlay(alignment: .topLeading) { HeroBadge(text: "The Dock Bridge", hue: hue).padding(10) }
                .overlay(alignment: .bottomTrailing) { readout.padding(DS.Space.m).allowsHitTesting(false) }
                .frame(height: 168)
                .background(Color(red: 0.06, green: 0.065, blue: 0.08))
                .overlay { SweepLight(trigger: sweeps) }
                .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                }
            VStack(alignment: .leading, spacing: DS.Space.l) {
                header
                VStack(alignment: .leading, spacing: 0) {
                    sipStep
                    installStep
                    loadStep
                    readyStep
                }
                if let message = problem ?? failure {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.caption).foregroundStyle(caution)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, 14)
            .padding(.bottom, DS.Space.s)
        }
        .padding(DS.Inset.plate)
        .background { CardSurface(style: status.isReady ? .lit(hue) : .standard) }
        .animation(DS.Motion.gentle(DS.Motion.reveal), value: status)
        .animation(DS.Motion.gentle(DS.Motion.reveal), value: problem)
        .onChange(of: status.isReady) { _, ready in if ready { sweeps += 1 } }
        .stagePreview(.focus("bridge.dock", "The Dock Bridge", region: StageRegion.dock("bottom")))
    }

    private var failure: String? { if case .failed(let message) = status { message } else { nil } }

    private var readout: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Group {
                if case .ready(let version) = status { Text("v\(version)") } else { Text("\(min(step ?? 1, 3)) / 3") }
            }
            .font(DS.Typo.readout).foregroundStyle(.white)
            .contentTransition(.numericText())
            Text(status.isReady ? "BRIDGE" : "SETUP").font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text("The Dock Bridge").font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                Text("Only the Dock may fade, pin or shrink another app's window. Atelier asks it through a small scripting addition, the way yabai does.")
                    .font(DS.body).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                StatusPill(status: status)
                recheck
            }
        }
    }

    private var recheck: some View {
        Button {
            guard !checking else { return }
            checking = true
            problem = nil
            Task {
                await DockBridge.shared.refresh()
                checking = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .rotationEffect(.degrees(checking ? 360 : 0))
                    .animation(checking ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: checking)
                Text(checking ? "Checking…" : "Re-check").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(DS.Ink.fillStrong, in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.95))
        .help("Reads SIP, the boot argument, the installed bridge and the Dock again.")
    }

    // Step 1

    private var sipStep: some View {
        let bootPending = status == .needsBootArgument
        return BridgeStep(number: 1, title: bootPending ? "Add the boot argument" : "Partly turn off System Integrity Protection",
                          state: state(1), last: false) {
            if state(1) == .done {
                Text("Done. SIP is partly off on this Mac.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
            } else {
                // One place for the Recovery-only part: the assistant carries the commands, the
                // QR checklist and the one-click finish, so nothing here repeats it.
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text(bootPending ? "SIP is partly off. One restart with the boot argument is left; Finish setup below adds it."
                                     : "SIP keeps everything, even you, out of the Dock. The bridge needs three of its guards lowered: files, debugging and NVRAM. The rest stay on.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecurityNote(hue: caution)
                    BridgeRecoveryAssistant(embedded: true)
                }
            }
        }
    }

    // Whether this Mac needs the arm64e boot argument, decided by the running machine rather than
    // the compiled slice, so the Intel slice under Rosetta on Apple silicon still shows the step.
    private static var appleSilicon: Bool { MacPlatform.appleSilicon }

    private static var recoveryHint: String {
        appleSilicon ? "In Recovery: shut down, hold the power button, choose Options, then Utilities › Terminal"
                     : "In Recovery: restart holding ⌘R, then Utilities › Terminal"
    }

    // Steps 2 and 3

    private var installStep: some View {
        BridgeStep(number: 2, title: "Install the bridge", state: state(2), last: false) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Copies Atelier's scripting addition to /Library/ScriptingAdditions. macOS asks for an administrator password.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s) {
                    if state(2) != .done {
                        BridgeButton(title: "Install…", symbol: "shippingbox", busy: working == 2,
                                     enabled: state(2) == .current && working == nil) {
                            run(2) { try await DockBridge.shared.install() }
                        }
                    }
                    // Whenever it is on disk, SIP on or off: removing it needs no SIP change.
                    if bridge.installed {
                        BridgeButton(title: "Remove", symbol: "trash", busy: working == 5, enabled: working == nil, prominent: false) {
                            run(5) { try await DockBridge.shared.uninstall() }
                        }
                        .help("Takes the scripting addition out of /Library/ScriptingAdditions. Every effect stops.")
                    }
                }
            }
        }
    }

    private var loadStep: some View {
        BridgeStep(number: 3, title: "Load it into the Dock", state: state(3), last: false) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Needed again after the Dock restarts, after you log in, or after a macOS update.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state(3) != .done {
                    BridgeButton(title: "Load", symbol: "dock.arrow.up.rectangle", busy: working == 3,
                                 enabled: state(3) == .current && working == nil) {
                        run(3) { try await DockBridge.shared.load() }
                    }
                }
            }
        }
    }

    private var readyStep: some View {
        BridgeStep(number: 4, title: status.isReady ? "Ready" : "Ready", state: status.isReady ? .done : .locked, last: true) {
            Group {
                if case .ready(let version) = status {
                    Text("The Dock answers. Bridge \(version). Everything below is yours.")
                } else {
                    Text("Every power below unlocks here.")
                }
            }
            .font(DS.caption).foregroundStyle(status.isReady ? DS.Ink.primary : DS.Ink.tertiary)
        }
    }

    private func run(_ number: Int, _ action: @escaping @MainActor () async throws -> Void) {
        working = number
        problem = nil
        Task { @MainActor in
            do { try await action() } catch {
                let text = (error as NSError).localizedDescription
                problem = text.isEmpty ? "That did not work. Try again, or Re-check." : text
            }
            await DockBridge.shared.refresh()
            working = nil
        }
    }
}

enum BridgeStepState { case done, current, locked }

/// One step of the path: a glyph on a thread that runs down to the next, a title, and what to do.
private struct BridgeStep<Content: View>: View {
    let number: Int
    let title: String
    let state: BridgeStepState
    let last: Bool
    @ViewBuilder var content: Content
    private let hue = DS.Spectrum.windows

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(spacing: 0) {
                glyph.frame(width: 24, height: 24)
                if !last {
                    Rectangle()
                        .fill(state == .done ? hue.opacity(0.55) : DS.Ink.hairline)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(DS.title)
                    .foregroundStyle(state == .locked ? DS.Ink.tertiary : DS.Ink.primary)
                if state != .locked || number == 4 { content } else {
                    content.opacity(0.55)
                }
            }
            .padding(.bottom, last ? 0 : DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(state == .done ? "done" : state == .current ? "to do now" : "not yet")")
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black.opacity(0.85), hue)
        case .current:
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(hue.opacity(0.28), in: .circle)
                .overlay { Circle().strokeBorder(hue, lineWidth: 1.25) }
        case .locked:
            Image(systemName: number == 4 ? "sparkles" : "lock.fill")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(DS.Ink.glyph)
                .frame(width: 22, height: 22)
                .background(DS.Ink.fill, in: .circle)
                .overlay { Circle().strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
        }
    }
}

/// Where the Mac stands, in two or three words, in the colour of what it means.
private struct StatusPill: View {
    let status: BridgeStatus

    private var text: String {
        switch status {
        case .sipEnabled: "SIP is on"
        case .needsBootArgument: "Needs boot argument"
        case .notInstalled: "Not installed"
        case .notLoaded: "Not loaded"
        case .ready(let version): "Ready · \(version)"
        case .failed: "Needs attention"
        }
    }

    private var hue: Color {
        switch status {
        case .ready: DS.Spectrum.windows
        case .failed, .sipEnabled: DS.Spectrum.sensors
        default: DS.Spectrum.light
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(hue).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(hue.opacity(0.14), in: .capsule)
        .overlay { Capsule().strokeBorder(hue.opacity(0.4), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dock Bridge: \(text)")
    }
}

/// A command to type, exactly, with a Copy chip that says when it did.
struct CommandBlock: View {
    let `where`: String
    let command: String
    var highlighted = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(`where`).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                Text(command)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Ink.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        Text(copied ? "Copied" : "Copy").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(copied ? DS.Spectrum.windows : DS.Ink.primary)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(DS.Ink.fillStrong, in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.95))
                .accessibilityLabel("Copy command")
                .animation(DS.Motion.hover, value: copied)
            }
            .padding(.leading, DS.Space.m).padding(.trailing, 6).padding(.vertical, 6)
            .background(.black.opacity(0.38), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlighted ? DS.Spectrum.windows.opacity(0.6) : DS.Ink.hairline, lineWidth: highlighted ? 1 : 0.5)
            }
        }
    }
}

/// The cost, said plainly, and the way back.
private struct SecurityNote: View {
    let hue: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hue)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("This lowers macOS protection.").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                Text("Malware that reaches this Mac could modify system processes, the Dock among them. You can turn SIP back on anytime: clear the boot argument with sudo nvram -d boot-args first, then run csrutil enable from Recovery. The bridge then simply stops.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hue.opacity(0.08), in: .rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(hue.opacity(0.3), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A step's action. Disabled until its step is reachable; spins while it runs.
private struct BridgeButton: View {
    let title: String
    let symbol: String
    let busy: Bool
    let enabled: Bool
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(enabled ? (prominent ? Color.black.opacity(0.85) : DS.Ink.primary) : DS.Ink.tertiary)
            .padding(.horizontal, 14).frame(height: 30)
            .background(enabled && prominent ? AnyShapeStyle(DS.Spectrum.windows) : AnyShapeStyle(DS.Ink.fillStrong), in: .capsule)
            .overlay { Capsule().strokeBorder(Color.white.opacity(enabled ? 0.18 : 0.08), lineWidth: 0.5) }
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.96))
        .disabled(!enabled || busy)
        .animation(DS.Motion.hover, value: enabled)
    }
}

// MARK: - The six powers

private struct OpacityHero: View {
    @ObservedObject private var bridge = DockBridge.shared
    @ObservedObject private var model = BeyondSIP.shared
    @State private var apps: [BridgeApp] = []

    private var lowest: Double { model.opacityApps.values.min() ?? 0.6 }

    var body: some View {
        BridgeHero("Window Opacity", pitch: "See through the windows you are not using, app by app.",
                   isOn: $model.opacityEnabled, locked: !bridge.status.isReady,
                   readout: "\(Int((lowest * 100).rounded()))%", readoutCaption: "Opacity",
                   preview: .overlay("bsip.opacity", "Window Opacity", isOn: model.opacityEnabled) { BridgeStagePreviews.opacity($0) }) {
            LivePlate { size, since in BridgeOpacityPlate(size: size, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Segments(selection: $model.opacityMode, options: BridgeOpacityMode.allCases.map { ($0, $0.title) })
                VStack(spacing: 0) {
                    ForEach(apps) { app in
                        appRow(app)
                        if app.id != apps.last?.id { Rectangle().fill(DS.Ink.hairline).frame(height: 0.5) }
                    }
                }
                Text(model.opacityMode == .inactive ? "The window you are in stays solid. Every other window of these apps fades."
                                                    : "Every window of these apps, the one you are in too.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        }
        .onAppear { apps = BridgeApp.running(configured: Array(model.opacityApps.keys)) }
    }

    private func appRow(_ app: BridgeApp) -> some View {
        let binding = Binding(get: { model.alpha(for: app.id) }, set: { model.setAlpha($0, for: app.id) })
        return HStack(spacing: 10) {
            Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
            Text(app.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                .frame(width: 120, alignment: .leading)
            LuxSlider(value: binding, range: 0.15...1, label: "\(app.name) opacity", tint: DS.Spectrum.windows) {
                model.opacityCommitted()
            }
            Text(binding.wrappedValue >= 0.995 ? "Solid" : "\(Int((binding.wrappedValue * 100).rounded()))%")
                .font(DS.Typo.value).foregroundStyle(binding.wrappedValue >= 0.995 ? DS.Ink.tertiary : DS.Ink.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(minHeight: 36)
    }
}

/// An app for the opacity list: the running ones, and any already set that are not running.
struct BridgeApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage

    @MainActor static func running(configured: [String]) -> [BridgeApp] {
        var seen = Set<String>()
        var list: [BridgeApp] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !seen.contains(id) else { continue }
            seen.insert(id)
            list.append(BridgeApp(id: id, name: app.localizedName ?? id, icon: app.icon ?? NSImage()))
        }
        for id in configured where !seen.contains(id) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            list.append(BridgeApp(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                                  icon: NSWorkspace.shared.icon(forFile: url.path)))
        }
        let set = Set(configured)
        // Apps already faded first, then by name.
        return list.sorted { a, b in
            let fa = set.contains(a.id), fb = set.contains(b.id)
            return fa != fb ? fa : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

private struct PinHero: View {
    @ObservedObject private var bridge = DockBridge.shared
    @ObservedObject private var model = BeyondSIP.shared

    var body: some View {
        BridgeHero("Pin on Top", pitch: "Keep one window above all the others, from any app.",
                   isOn: $model.pinEnabled, locked: !bridge.status.isReady,
                   readout: model.pinned.isEmpty ? model.combo(for: .pin)?.display ?? "—" : "\(model.pinned.count)",
                   readoutCaption: model.pinned.isEmpty ? "Shortcut" : "Pinned",
                   preview: .overlay("bsip.pin", "Pin on Top", isOn: model.pinEnabled) { BridgeStagePreviews.pin($0) }) {
            LivePlate { size, since in BridgePinPlate(size: size, since: since) }
        } controls: {
            MarkedControls(action: .pin, windows: model.pinned, empty: "Nothing pinned yet.", release: "Unpin") { id in
                Task { await BeyondSIP.shared.unpin(id) }
            }
        }
    }
}

private struct StickyHero: View {
    @ObservedObject private var bridge = DockBridge.shared
    @ObservedObject private var model = BeyondSIP.shared

    var body: some View {
        BridgeHero("Sticky Windows", pitch: "One window on every desktop, there whichever Space you switch to.",
                   isOn: $model.stickyEnabled, locked: !bridge.status.isReady,
                   readout: model.sticky.isEmpty ? model.combo(for: .sticky)?.display ?? "—" : "\(model.sticky.count)",
                   readoutCaption: model.sticky.isEmpty ? "Shortcut" : "Sticky",
                   preview: .overlay("bsip.sticky", "Sticky Windows", isOn: model.stickyEnabled) { BridgeStagePreviews.sticky($0) }) {
            LivePlate { size, since in BridgeStickyPlate(size: size, since: since) }
        } controls: {
            MarkedControls(action: .sticky, windows: model.sticky, empty: "No window is on every desktop yet.", release: "Unstick") { id in
                Task { await BeyondSIP.shared.unstick(id) }
            }
        }
    }
}

/// Shortcut, then the windows it changed, each with a way back.
private struct MarkedControls: View {
    let action: BridgeAction
    let windows: [BridgeMarkedWindow]
    let empty: String
    let release: String
    let onRelease: (CGWindowID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ShortcutLine(action: action)
            if windows.isEmpty {
                Text(empty).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(windows) { window in
                        HStack(spacing: 10) {
                            if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                            Text(window.label).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Chip(release) { onRelease(window.id) }
                        }
                        .frame(minHeight: 36)
                        .transition(.opacity)
                        if window.id != windows.last?.id { Rectangle().fill(DS.Ink.hairline).frame(height: 0.5) }
                    }
                }
                .animation(DS.Motion.gentle(DS.Motion.arrive), value: windows)
            }
        }
    }
}

/// "Shortcut ⌃⌥P", recordable, and the last thing it did.
private struct ShortcutLine: View {
    let action: BridgeAction
    @ObservedObject private var model = BeyondSIP.shared

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Text("Shortcut").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 60, alignment: .leading)
            BridgeKeyRecorder(action: action)
            Spacer(minLength: 0)
            if let note = model.lastAction {
                Text(note).font(DS.caption).foregroundStyle(DS.Spectrum.windows).lineLimit(1)
                    .transition(.opacity)
            }
        }
        .animation(DS.Motion.hover, value: model.lastAction)
    }
}

/// Click, then press the keys. Escape cancels; Delete clears. Uses the Tools recorder.
private struct BridgeKeyRecorder: View {
    let action: BridgeAction
    @ObservedObject private var model = BeyondSIP.shared
    @StateObject private var recorder = RecorderModel()

    var body: some View {
        let combo = model.combo(for: action)
        let conflict = model.conflicts.contains(action)
        Button {
            if recorder.recording {
                recorder.end()
            } else {
                model.suspendKeys(true)
                recorder.begin { BeyondSIP.shared.setCombo($0, for: action) }
            }
        } label: {
            Text(recorder.recording ? (recorder.rejected ? "Add ⌘, ⌥ or ⌃" : "Type shortcut…") : combo?.display ?? "Set Shortcut")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(combo == nil && !recorder.recording ? DS.Ink.secondary : DS.Ink.primary)
                .frame(minWidth: 86).frame(height: 28).padding(.horizontal, 8)
                .background(recorder.recording ? AnyShapeStyle(DS.Spectrum.windows.opacity(0.45)) : AnyShapeStyle(DS.Ink.fillStrong),
                            in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    if conflict {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Spectrum.sensors.opacity(0.8), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
        .help(conflict ? "Another app already owns this shortcut." : "Click, then press the keys. Escape cancels, Delete clears.")
        .onChange(of: recorder.recording) { _, on in if !on { BeyondSIP.shared.suspendKeys(false) } }
        .onDisappear { recorder.end() }
        .animation(DS.Motion.settle, value: recorder.recording)
        .accessibilityLabel("\(action.title) shortcut")
        .accessibilityValue(combo?.display ?? "None")
    }
}

private struct PiPHero: View {
    @ObservedObject private var bridge = DockBridge.shared
    @ObservedObject private var model = BeyondSIP.shared

    var body: some View {
        BridgeHero("Picture in Picture", pitch: "Shrink any window into a corner and keep it playing. Again to bring it back.",
                   isOn: $model.pipEnabled, locked: !bridge.status.isReady,
                   readout: "\(Int(bridgePiPScale * 100))%", readoutCaption: "Size",
                   preview: .overlay("bsip.pip", "Picture in Picture", isOn: model.pipEnabled) { BridgeStagePreviews.pip($0, corner: model.pipCorner) }) {
            LivePlate { size, since in BridgePiPPlate(size: size, since: since, corner: model.pipCorner) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ShortcutLine(action: .pip)
                HStack(spacing: DS.Space.m) {
                    Text("Corner").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 60, alignment: .leading)
                    Segments(selection: $model.pipCorner, options: BridgeCorner.allCases.map { ($0, $0.title) }) { corner in
                        .overlay("bsip.pip." + corner.rawValue, "Picture in Picture", isOn: true) { BridgeStagePreviews.pip($0, corner: corner) }
                    }
                }
                HStack {
                    Text(model.pipped.isEmpty ? "No window is shrunk." : "\(model.pipped.count) window\(model.pipped.count == 1 ? "" : "s") shrunk.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    Spacer()
                    if !model.pipped.isEmpty { Chip("Restore all") { BeyondSIP.shared.restoreAllPiP() } }
                }
            }
        }
    }
}

private struct NoShadowHero: View {
    @ObservedObject private var bridge = DockBridge.shared
    @ObservedObject private var model = BeyondSIP.shared

    var body: some View {
        BridgeHero("No Shadows", pitch: "Flat, crisp windows everywhere. Shadows return the moment you switch it off.",
                   isOn: $model.noShadowEnabled, locked: !bridge.status.isReady,
                   readout: model.noShadowEnabled && bridge.status.isReady ? "0 pt" : "24 pt", readoutCaption: "Shadow",
                   preview: .overlay("bsip.shadow", "No Shadows", isOn: model.noShadowEnabled) { BridgeStagePreviews.noShadow($0) }) {
            LivePlate { size, since in BridgeNoShadowPlate(size: size, since: since) }
        }
    }
}

// MARK: - Spaces Studio

private struct SpacesStudioHero: View {
    @ObservedObject private var bridge = DockBridge.shared
    @ObservedObject private var spaces = SpacesIndicator.shared
    @State private var order: [DesktopSpace] = []
    @State private var dragging: Int?
    @State private var busy = false
    /// Add, remove and reorder call Dock functions the payload has no verified address for on
    /// macOS 27 (Native/arm64_payload.m returns 0), so they would look live and do nothing.
    private let editable = ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27

    var body: some View {
        BridgeHero("Spaces Studio", pitch: !editable
                   ? "Jump to any desktop through the Dock. Adding, removing and reordering wait for a verified macOS 27 pass."
                   : "Add, remove and reorder desktops from here, without Mission Control.",
                   isOn: nil, locked: !bridge.status.isReady,
                   readout: "\(max(spaces.spaces.count, 1))", readoutCaption: spaces.spaces.count == 1 ? "Desktop" : "Desktops",
                   preview: .overlay("bsip.spaces", "Spaces Studio", isOn: true) { BridgeStagePreviews.spaces($0, count: max(spaces.spaces.count, 3)) }) {
            LivePlate { size, since in BridgeSpacesPlate(size: size, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ScrollView(.horizontal) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(order) { space in tile(space) }
                        if editable { addTile }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                Text(editable ? "Click to go there. Drag to reorder. The current desktop cannot be removed."
                              : "Click to go there. Adding, removing and reordering are off on macOS 27 until they are verified.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
            .opacity(busy ? 0.6 : 1)
        }
        .onAppear { spaces.refresh(); order = spaces.spaces }
        .onReceive(spaces.$spaces) { order = $0 }
    }

    private func tile(_ space: DesktopSpace) -> some View {
        BridgeSpaceTile(space: space, name: spaces.name(space), canRemove: editable && !space.current && order.count > 1) {
            act { await BeyondSIP.shared.focusSpace(space.sid) }
        } remove: {
            act { await BeyondSIP.shared.destroySpace(space.sid) }
        }
        .opacity(dragging == space.sid ? 0.4 : 1)
        .draggable(String(space.sid)) {
            BridgeSpaceThumb(number: space.number, current: space.current, lifted: true).frame(width: 96, height: 60)
        }
        .dropDestination(for: String.self) { items, _ in
            guard editable, let raw = items.first, let moved = Int(raw), moved != space.sid,
                  let from = order.firstIndex(where: { $0.sid == moved }),
                  let to = order.firstIndex(where: { $0.sid == space.sid }) else { return false }
            var next = order
            let item = next.remove(at: from)
            next.insert(item, at: to)
            withAnimation(DS.Motion.gentle(DS.Motion.settle)) { order = next }
            act { await BeyondSIP.shared.reorder(next.map(\.sid)) }
            return true
        } isTargeted: { _ in }
    }

    private var addTile: some View {
        Button { act { await BeyondSIP.shared.createSpace() } } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(DS.Spectrum.windows.opacity(0.7))
                    .frame(width: 96, height: 60)
                    .overlay { Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Spectrum.windows) }
                Text("New").font(DS.caption).foregroundStyle(DS.Ink.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
        .accessibilityLabel("New desktop")
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            await work()
            busy = false
        }
    }
}

private struct BridgeSpaceTile: View {
    let space: DesktopSpace
    let name: String
    let canRemove: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            Button(action: open) {
                BridgeSpaceThumb(number: space.number, current: space.current).frame(width: 96, height: 60)
            }
            .buttonStyle(Pressable(scale: 0.97))
            .overlay(alignment: .topLeading) {
                if hover && canRemove {
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(.black.opacity(0.7), in: .circle)
                            .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
                    }
                    .buttonStyle(Pressable(scale: 0.9))
                    .offset(x: -5, y: -5)
                    .transition(.opacity)
                    .accessibilityLabel("Remove \(name)")
                }
            }
            Text(name).font(DS.caption).foregroundStyle(space.current ? DS.Ink.primary : DS.Ink.secondary).lineLimit(1)
                .frame(width: 96)
        }
        .onHover { hover = $0 }
        .animation(DS.Motion.hover, value: hover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name + (space.current ? ", current" : ""))
    }
}

/// A desktop in miniature: a wallpaper wash, two little windows, the current one lit.
struct BridgeSpaceThumb: View {
    let number: Int
    var current = false
    var lifted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let hue = Angle.degrees(Double(number) * 47)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hue: 0.62 + Double(number % 5) * 0.04, saturation: 0.45, brightness: 0.42),
                                    Color(hue: 0.75 + Double(number % 3) * 0.05, saturation: 0.5, brightness: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .hueRotation(hue * 0.2)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.white.opacity(0.22))
                .frame(width: 34, height: 22).offset(x: 10 + Double(number % 3) * 8, y: 12)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.white.opacity(0.34))
                .frame(width: 30, height: 20).offset(x: 46 - Double(number % 2) * 10, y: 26)
            Text("\(number)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                .padding(5)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(current ? DS.Spectrum.windows : .white.opacity(0.12), lineWidth: current ? 1.5 : 0.5) }
        .scaleEffect(lifted ? 1.04 : 1)
    }
}
