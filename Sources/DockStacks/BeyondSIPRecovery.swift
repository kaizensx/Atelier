import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Recovery Assistant
//
// The honest answer to "a button that turns SIP off": there isn't one, and there shouldn't be.
// SIP's state lives in a Secure-Enclave-signed boot policy that can only be changed from recoveryOS
// with the person physically present. No app can do it, and Atelier does not try. What Atelier can
// do is make the legitimate path easy and hard to get wrong:
//
//   * Prepare — a QR code the person scans to read the exact Recovery steps for THIS Mac on their
//     phone while they are in Recovery (where they cannot see this screen), the csrutil command on
//     the clipboard, and, on Intel, a confirmed one-click restart into Recovery. Apple silicon has
//     no programmatic path into Recovery, so there it is spelled out instead.
//   * Finish setup — once the Mac comes back with SIP partly off, a single administrator prompt
//     that sets the boot argument if Apple silicon still needs it (then a restart), installs the
//     scripting addition and loads it. It never runs without the explicit click.
//   * Undo — how to put SIP back (from Recovery, since that is the only place it can be done) and a
//     one-click removal of the bridge from this side.
//
// All privileged work is in DockBridge (finishSetup/restartIntoRecovery/uninstall); this file is
// only the guidance and the buttons that call them.

/// Builds a QR image for the on-phone checklist. Pure; CoreImage renders it on the main thread.
private func bridgeRecoveryQRImage(_ text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    // Scale the 1-module-per-pixel output up so it is crisp at display size.
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

/// The csrutil incantation, in one place: exactly the three protections the bridge needs off.
private let bridgeRecoveryCSRCommand = "csrutil enable --without fs --without debug --without nvram"

/// Where the QR code leads: Apple's own page on disabling and enabling SIP, which a phone opens
/// as a normal web page. A QR of plain text only shows a block of words, if anything.
private let bridgeRecoveryGuideURL = "https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection"

/// The plain-text checklist encoded into the QR code and shown on screen, for this Mac's platform.
private func bridgeRecoveryChecklist(appleSilicon: Bool) -> [String] {
    if appleSilicon {
        return [
            "Apple menu → Shut Down.",
            "Hold the power button until “Loading startup options”.",
            "Options → Continue, then pick your admin account.",
            "Menu bar: Utilities → Terminal.",
            "Run:  \(bridgeRecoveryCSRCommand)",
            "Run:  reboot",
            "Back in macOS: Atelier → Beyond SIP → Finish setup.",
        ]
    }
    return [
        "Restart and hold ⌘R until the Apple logo.",
        "Menu bar: Utilities → Terminal.",
        "Run:  \(bridgeRecoveryCSRCommand)",
        "Run:  reboot",
        "Back in macOS: Atelier → Beyond SIP → Finish setup.",
        "Intel needs no boot argument.",
    ]
}

struct BridgeRecoveryAssistant: View {
    @ObservedObject private var bridge = DockBridge.shared
    @State private var expanded = true
    /// Inside the Dock Bridge's first step: no card or header of its own, the step already says what it is.
    var embedded = false
    private let hue = DS.Spectrum.windows

    private var appleSilicon: Bool { MacPlatform.appleSilicon }
    /// SIP is already partly off, so the person is past Prepare and ready to Finish.
    private var sipReady: Bool { bridge.sip.isBridgeCapable }

    var body: some View {
        if embedded {
            VStack(alignment: .leading, spacing: DS.Space.l) { stages }
        } else {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                header
                if expanded { stages }
            }
            .padding(DS.Inset.card)
            .background { CardSurface(style: .standard) }
            .animation(DS.Motion.gentle(DS.Motion.reveal), value: expanded)
            .animation(DS.Motion.gentle(DS.Motion.reveal), value: sipReady)
        }
    }

    @ViewBuilder private var stages: some View {
        BridgeRecoveryPrepare(appleSilicon: appleSilicon, done: sipReady)
        BridgeRecoveryFinish(enabled: sipReady, appleSilicon: appleSilicon,
                             bootArgPresent: bridge.bootArgPresent)
        BridgeRecoveryUndo()
    }

    private var header: some View {
        Button { expanded.toggle() } label: {
            HStack(alignment: .center, spacing: DS.Space.m) {
                Image(systemName: "lifepreserver")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(hue)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recovery Assistant").font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                    Text("Turning SIP off is a Recovery-only step, by Apple’s design. This walks you through it safely, then finishes the rest in one click.")
                        .font(DS.body).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Ink.secondary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.995))
        .accessibilityLabel("Recovery Assistant, \(expanded ? "expanded" : "collapsed")")
    }
}

// MARK: - Prepare

private struct BridgeRecoveryPrepare: View {
    let appleSilicon: Bool
    let done: Bool
    @State private var showRestartConfirm = false
    @State private var copied = false
    @State private var problem: String?
    private let hue = DS.Spectrum.windows

    private var checklist: [String] { bridgeRecoveryChecklist(appleSilicon: appleSilicon) }
    var body: some View {
        BridgeRecoverySection(number: 1, title: "Prepare", done: done,
                              caption: done ? "SIP is already partly off on this Mac — skip to Finish setup."
                                            : "You’ll do this in Recovery, where this window isn’t available. Keep the steps on your phone.") {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                qrRow
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(Array(checklist.enumerated()), id: \.offset) { index, line in
                        stepRow(index + 1, line)
                    }
                }
                actions
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.caption).foregroundStyle(DS.Spectrum.sensors)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One step: a numbered disc, the words, and a command shown as code when the step is one.
    private func stepRow(_ number: Int, _ line: String) -> some View {
        let isCommand = line.hasPrefix("Run:")
        let text = isCommand ? String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces) : line
        return HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(hue)
                .frame(width: 20, height: 20)
                .background(hue.opacity(0.14), in: .circle)
            if isCommand {
                Text(text)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Ink.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 8, style: .continuous))
            } else {
                Text(text).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    /// The code and what it does, side by side, so nobody scans it expecting something else.
    private var qrRow: some View {
        HStack(alignment: .center, spacing: DS.Space.l) {
            Group {
                if let image = bridgeRecoveryQRImage(bridgeRecoveryGuideURL) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 92, height: 92)
                        .padding(6)
                        .background(.white, in: .rect(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Ink.fill)
                        .frame(width: 104, height: 104)
                        .overlay { Image(systemName: "qrcode").font(.system(size: 26)).foregroundStyle(DS.Ink.glyph) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Scan with your iPhone camera", systemImage: "camera.viewfinder")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                Text("Opens Apple’s own guide to turning SIP off and on, so the steps stay with you in Recovery.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("developer.apple.com").font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Ink.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("QR code that opens Apple’s guide to System Integrity Protection")
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bridgeRecoveryCSRCommand, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(copied ? "Copied the command" : "Copy the csrutil command").font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(copied ? hue : DS.Ink.primary)
                .padding(.horizontal, 12).frame(height: 30)
                .background(DS.Ink.fillStrong, in: .capsule)
                .contentShape(Capsule())
            }
            .buttonStyle(Pressable(scale: 0.96))
            .animation(DS.Motion.hover, value: copied)

            if appleSilicon {
                Label("On Apple silicon: shut down, then press and hold the power button until startup options appear. There is no programmatic way in.",
                      systemImage: "power")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button { showRestartConfirm = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "restart").font(.system(size: 11, weight: .semibold))
                        Text("Restart into Recovery…").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(hue, in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.96))
                .help("Sets the next boot to Recovery and restarts now. Save your work first.")
                .alert("Restart into Recovery now?", isPresented: $showRestartConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Restart", role: .destructive) {
                        Task { @MainActor in
                            do { try await DockBridge.shared.restartIntoRecovery() }
                            catch { problem = (error as NSError).localizedDescription }
                        }
                    }
                } message: {
                    Text("Your Mac will restart immediately into Recovery. Save any open work — unsaved changes will be lost. In Recovery, open Utilities → Terminal and run the copied command.")
                }
            }
        }
    }
}

// MARK: - Finish setup

private struct BridgeRecoveryFinish: View {
    let enabled: Bool
    let appleSilicon: Bool
    let bootArgPresent: Bool
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    private let hue = DS.Spectrum.windows

    private var willNeedRestart: Bool { appleSilicon && !bootArgPresent }

    var body: some View {
        BridgeRecoverySection(number: 2, title: "Finish setup", done: DockBridge.shared.status.isReady,
                              caption: enabled
                                ? (willNeedRestart
                                   ? "One administrator prompt sets the arm64e boot argument and installs the bridge. A restart is needed before it can load."
                                   : "One administrator prompt installs the scripting addition and loads it into the Dock.")
                                : "Available once your Mac comes back from Recovery with SIP partly off.") {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Button {
                    guard !busy else { return }
                    busy = true; message = nil
                    Task { @MainActor in
                        do {
                            let outcome = try await DockBridge.shared.finishSetup()
                            isError = false
                            message = outcome == .needsRestart
                                ? "Boot argument set and bridge installed. Restart your Mac, then tap Finish setup again to load it."
                                : "Done. The Dock bridge is loaded — everything below is unlocked."
                        } catch {
                            isError = true
                            message = (error as NSError).localizedDescription
                        }
                        busy = false
                    }
                } label: {
                    HStack(spacing: 7) {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold)) }
                        Text("Finish setup").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(enabled ? Color.black.opacity(0.85) : DS.Ink.tertiary)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(enabled ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fillStrong), in: .capsule)
                    .overlay { Capsule().strokeBorder(Color.white.opacity(enabled ? 0.18 : 0.08), lineWidth: 0.5) }
                    .contentShape(Capsule())
                }
                .buttonStyle(Pressable(scale: 0.96))
                .disabled(!enabled || busy)
                .animation(DS.Motion.hover, value: enabled)

                if let message {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(DS.caption).foregroundStyle(isError ? DS.Spectrum.sensors : hue)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .animation(DS.Motion.gentle(DS.Motion.reveal), value: message)
        }
    }
}

// MARK: - Undo

private struct BridgeRecoveryUndo: View {
    @ObservedObject private var bridge = DockBridge.shared
    @State private var busy = false
    @State private var message: String?
    private let caution = DS.Spectrum.sensors

    var body: some View {
        BridgeRecoverySection(number: 3, title: "Undo", done: false,
                              caption: "Put everything back whenever you want, in this order.") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                // 1. The bridge goes first: deleting it needs an administrator, not SIP, so it
                // works with SIP on or off.
                if bridge.installed || message != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Remove the bridge from this Mac").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        Text("Takes the scripting addition out of /Library/ScriptingAdditions. Every window power stops at once.")
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: DS.Space.s) {
                            if bridge.installed { removeButton }
                            if let message {
                                Text(message).font(DS.caption).foregroundStyle(DS.Ink.secondary).transition(.opacity)
                            }
                        }
                        .animation(DS.Motion.hover, value: message)
                    }
                }
                // 2 and 3. The boot argument is cleared while NVRAM is still unprotected: once
                // csrutil enable has run, macOS refuses to change boot-args.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turn SIP back on").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    Text("First clear the boot argument in macOS, while SIP is still partly off. Then turn SIP on from Recovery (the same place you lowered it).")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if MacPlatform.appleSilicon {
                        CommandBlock(where: "First, in macOS, in Terminal", command: "sudo nvram -d boot-args")
                    }
                    CommandBlock(where: MacPlatform.appleSilicon ? "Then in Recovery → Utilities → Terminal" : "In Recovery → Utilities → Terminal",
                                 command: "csrutil enable")
                }
            }
        }
    }

    private var removeButton: some View {
        Button {
            guard !busy else { return }
            busy = true; message = nil
            Task { @MainActor in
                do { try await DockBridge.shared.uninstall(); message = "Removed." }
                catch { message = (error as NSError).localizedDescription }
                busy = false
            }
        } label: {
            HStack(spacing: 7) {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "trash").font(.system(size: 11.5, weight: .semibold)) }
                Text(busy ? "Waiting for the password…" : "Remove the bridge").font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 14).frame(height: 30)
            .background(DS.Ink.fillStrong, in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.96))
        .disabled(busy)
    }
}

// MARK: - Shared step chrome

/// One numbered block of the assistant: a glyph, a title, a caption, and its content.
private struct BridgeRecoverySection<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let caption: String
    @ViewBuilder var content: Content
    private let hue = DS.Spectrum.windows

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            glyph.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(title).font(DS.title).foregroundStyle(DS.Ink.primary)
                Text(caption).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content.padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var glyph: some View {
        if done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black.opacity(0.85), hue)
        } else {
            // Lettered (A, B, C) so they read as parts of the Dock Bridge's numbered step 1.
            Text(["A", "B", "C", "D"][min(max(number - 1, 0), 3)])
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(hue.opacity(0.28), in: .circle)
                .overlay { Circle().strokeBorder(hue, lineWidth: 1.25) }
        }
    }
}
