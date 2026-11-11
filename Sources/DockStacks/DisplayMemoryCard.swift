import AppKit
import DockCore
import SwiftUI

// MARK: - Display Memory card
//
// In the Window Engine chapter, under its own "Display Memory" header between Focus and Keys and
// tools. The hero plate is a live map of the displays connected now with the windows remembered
// for them, drawn to scale; below it, every setup Atelier knows, each with its own mini-map, its
// window count, Restore Now and Forget.
//
// Motion: the plate's windows settle with a critically damped spring when the memory changes
// (a restore, a new snapshot), and Reduce Motion turns that into nothing at all.

struct DisplayMemoryCard: View {
    var trusted: Bool
    @ObservedObject private var memory = DisplayMemory.shared
    private let hue = DS.Spectrum.windows

    private var current: DisplaySetup? { memory.setups.first { $0.id == memory.currentKey } }

    var body: some View {
        let enabled = Binding(get: { memory.enabled }, set: { memory.setEnabled($0) })
        HeroCard("Display Memory",
                 pitch: "Plug in, unplug, wake, change resolution: every window goes back where it was on that setup.",
                 isOn: enabled, hue: hue,
                 readout: memory.setups.isEmpty ? nil : "\(memory.setups.count)",
                 readoutCaption: memory.setups.count == 1 ? "setup" : "setups") {
            plate
        } controls: {
            controls
        }
        .onAppear { if memory.currentKey == nil { memory.resume() } }
    }

    private var plate: some View {
        let configuration = current?.configuration ?? DisplayMemory.currentConfiguration()
        return SetupMap(configuration: configuration, windows: current?.windows ?? [], hue: hue,
                        highlight: true, showWindows: memory.enabled)
            .padding(.horizontal, 36).padding(.top, 30).padding(.bottom, 22)
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            NeedsAccessRow(reason: "To read and move windows when displays change.", previewTrusted: trusted ? nil : false)
            if let status = memory.status {
                Text(status).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if memory.setups.isEmpty {
                Text("Setups appear here as Atelier sees them. Full-screen windows are left alone, and nothing is launched.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(memory.setups) { setup in
                SetupRow(setup: setup, isCurrent: setup.id == memory.currentKey, hue: hue,
                         restore: { memory.restoreNow(setup.id) }, forget: { memory.forget(setup.id) })
            }
        }
    }
}

/// One remembered setup: mini-map, name, window count, when it was last seen, and its actions.
private struct SetupRow: View {
    let setup: DisplaySetup
    let isCurrent: Bool
    let hue: Color
    let restore: () -> Void
    let forget: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            SetupMap(configuration: setup.configuration, windows: setup.windows, hue: hue, highlight: isCurrent, showWindows: true)
                .frame(width: 92, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(setup.configuration.summary).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    if isCurrent {
                        Text("NOW").font(DS.Typo.badge).tracking(0.6).foregroundStyle(hue)
                            .padding(.horizontal, 5).frame(height: 15)
                            .background(hue.opacity(0.14), in: .capsule)
                    }
                }
                Text(detail).font(DS.caption).monospacedDigit().foregroundStyle(DS.Ink.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore Now", action: restore).buttonStyle(MemoryPill(prominent: isCurrent, hue: hue))
                .disabled(setup.windows.isEmpty)
            Button(action: forget) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .accessibilityLabel("Forget \(setup.configuration.summary)")
        }
        .padding(DS.Space.s)
        .background(isCurrent ? hue.opacity(0.07) : DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private var detail: String {
        let count = setup.windows.count == 1 ? "1 window" : "\(setup.windows.count) windows"
        let screens = setup.configuration.displays.count == 1 ? "1 display" : "\(setup.configuration.displays.count) displays"
        let seen = Self.relative.localizedString(for: setup.updated, relativeTo: Date())
        return "\(count) · \(screens) · \(seen)"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// The displays of a configuration drawn to scale in their arrangement, with its windows.
struct SetupMap: View {
    let configuration: DisplayConfiguration
    let windows: [RememberedWindow]
    let hue: Color
    var highlight: Bool
    var showWindows: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let bounds = configuration.bounds
            let scale = bounds.isNull || bounds.isEmpty ? 1
                : min(proxy.size.width / bounds.width, proxy.size.height / bounds.height)
            let offset = CGPoint(x: (proxy.size.width - bounds.width * scale) / 2, y: (proxy.size.height - bounds.height * scale) / 2)
            let map = { (r: CGRect) in
                CGRect(x: offset.x + (r.minX - bounds.minX) * scale, y: offset.y + (r.minY - bounds.minY) * scale,
                       width: r.width * scale, height: r.height * scale)
            }
            let small = proxy.size.width < 140
            ZStack(alignment: .topLeading) {
                ForEach(Array(configuration.displays.enumerated()), id: \.offset) { _, display in
                    let r = map(display.frame)
                    RoundedRectangle(cornerRadius: small ? 2 : 5, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(highlight ? 0.11 : 0.07), Color.white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay {
                            RoundedRectangle(cornerRadius: small ? 2 : 5, style: .continuous)
                                .strokeBorder(highlight ? hue.opacity(0.55) : DS.Ink.edge, lineWidth: small ? 0.5 : 0.75)
                        }
                        .overlay(alignment: .bottomLeading) {
                            if !small {
                                Text(display.name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(DS.Ink.tertiary)
                                    .lineLimit(1).padding(6)
                            }
                        }
                        .frame(width: max(r.width - 2, 1), height: max(r.height - 2, 1))
                        .offset(x: r.minX + 1, y: r.minY + 1)
                }
                if showWindows {
                    // Back to front, so the frontmost window is drawn last.
                    ForEach(windows.sorted { $0.order > $1.order }, id: \.order) { window in
                        let r = map(window.frame).intersection(map(bounds))
                        if !r.isNull {
                            RoundedRectangle(cornerRadius: small ? 1 : 3, style: .continuous)
                                .fill(hue.opacity(window.order == 0 ? 0.42 : 0.2))
                                .overlay {
                                    RoundedRectangle(cornerRadius: small ? 1 : 3, style: .continuous)
                                        .strokeBorder(Color.white.opacity(window.order == 0 ? 0.5 : 0.22), lineWidth: 0.5)
                                }
                                .frame(width: max(r.width, 2), height: max(r.height, 2))
                                .offset(x: r.minX, y: r.minY)
                        }
                    }
                }
            }
            .animation(reduceMotion ? nil : DS.Motion.arrive, value: windows)
        }
        .accessibilityElement()
        .accessibilityLabel("\(configuration.summary), \(windows.count) windows")
    }
}

private struct MemoryPill: ButtonStyle {
    var prominent: Bool
    var hue: Color
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(prominent ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fillStrong), in: .capsule)
            .overlay { Capsule().strokeBorder(prominent ? Color.white.opacity(0.2) : DS.Ink.edge, lineWidth: 0.5) }
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DS.Motion.touch, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
