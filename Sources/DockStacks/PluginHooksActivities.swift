import AppKit
import DockCore
import SwiftUI

struct PluginActivity: Identifiable, Equatable {
    let plugin: String
    let pluginName: String
    var spec: PluginActivitySpec
    var id: String { plugin + "/" + spec.id }
}

/// Live activities: small pills under the menu bar, in the middle of the screen, in the style
/// of Atelier HUD's pill and in a panel of the same kind (it never takes focus and sits over
/// full-screen apps). At most three show at once, newest at the bottom; a click calls the
/// plugin's `onTap`.
@MainActor
final class PluginActivities: ObservableObject {
    static let shared = PluginActivities()
    @Published private(set) var shown: [PluginActivity] = []
    private var panel: HUDPanel?
    private var expiries: [String: Task<Void, Never>] = [:]

    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 50

    /// Nil when shown, or why not.
    func set(_ spec: PluginActivitySpec, plugin: String, pluginName: String) -> String? {
        let activity = PluginActivity(plugin: plugin, pluginName: pluginName, spec: spec)
        if let until = spec.until, until <= Date() { end(plugin: plugin, id: spec.id); return nil }
        if let index = shown.firstIndex(where: { $0.id == activity.id }) {
            shown[index] = activity
        } else {
            guard shown.count < PluginActivitySpec.maxShown else {
                return "at most \(PluginActivitySpec.maxShown) live activities show at once. End one first."
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { shown.append(activity) }
        }
        expiries.removeValue(forKey: activity.id)?.cancel()
        if let until = spec.until {
            let key = activity.id
            expiries[key] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.end(plugin: plugin, id: spec.id)
            }
        }
        layout()
        return nil
    }

    func end(plugin: String, id: String) {
        let key = plugin + "/" + id
        expiries.removeValue(forKey: key)?.cancel()
        guard shown.contains(where: { $0.id == key }) else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { shown.removeAll { $0.id == key } }
        layout()
    }

    func clear(plugin: String) {
        for activity in shown where activity.plugin == plugin { end(plugin: plugin, id: activity.spec.id) }
    }

    func tap(_ activity: PluginActivity) {
        PluginRegistry.shared.runtime(activity.plugin)?.invoke("activity:\(activity.spec.id):onTap")
    }

    private func layout() {
        guard !shown.isEmpty, let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        let frame = screen.frame
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
        let height = CGFloat(shown.count) * (Self.rowHeight + 6) + 12
        panel.setFrame(NSRect(x: frame.midX - Self.width / 2, y: frame.maxY - menuBar - height, width: Self.width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentView = NSHostingView(rootView: PluginActivityStack(model: self))
        self.panel = panel
        return panel
    }
}

struct PluginActivityStack: View {
    @ObservedObject var model: PluginActivities

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.shown) { activity in
                PluginActivityPill(activity: activity)
                    .onTapGesture { model.tap(activity) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 6)
        .frame(width: PluginActivities.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One activity, drawn like Atelier HUD's pill: glass capsule, symbol, words, an optional bar.
struct PluginActivityPill: View {
    let activity: PluginActivity

    var body: some View {
        let spec = activity.spec
        let tint = spec.tint?.color(accent: DS.Ink.accent) ?? DS.Ink.accent
        HStack(spacing: 11) {
            Image(systemName: spec.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spec.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let until = spec.until, spec.text.isEmpty {
                        Text(timerInterval: Date()...max(until, Date()), countsDown: true)
                            .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                    } else if !spec.text.isEmpty {
                        Text(spec.text).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }
                if let progress = spec.progress {
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.16))
                            .overlay(alignment: .leading) {
                                Capsule().fill(tint).frame(width: max(4, proxy.size.width * progress))
                            }
                    }
                    .frame(height: 4)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: progress)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: PluginActivities.width - 20, height: PluginActivities.rowHeight)
        .atelierGlass(.regular.tint(.black.opacity(0.28)), in: .capsule)
        .contentShape(Capsule())
        .help("\(spec.title), from \(activity.pluginName)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spec.title). \(spec.text)")
        .accessibilityAddTraits(.isButton)
    }
}
