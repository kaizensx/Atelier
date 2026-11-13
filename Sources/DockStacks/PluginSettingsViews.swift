import AppKit
import DockCore
import SwiftUI

// Plugin settings drawn by Atelier from the manifest, the per-plugin resource meter, and the
// safe-mode banner.

/// The settings a plugin declares, as rows. Values are checked strictly before they are kept;
/// secrets go to the Keychain and are never shown again.
struct PluginSettingsForm: View {
    let plugin: InstalledPlugin
    @ObservedObject private var registry = PluginRegistry.shared
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            RowGroup {
                ForEach(plugin.manifest.settings) { setting in
                    SettingRow(title: setting.title, detail: setting.detail, density: .compact) {
                        PluginSettingControl(plugin: plugin, setting: setting, problem: $problem)
                    }
                }
            }
            .id(registry.settingsRevision)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(DS.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PluginSettingControl: View {
    let plugin: InstalledPlugin
    let setting: PluginSetting
    @Binding var problem: String?
    @ObservedObject private var registry = PluginRegistry.shared
    @State private var draft = ""
    @State private var editing = false

    private var value: JSONValue { registry.settingValue(plugin, setting) }

    private func save(_ next: JSONValue) {
        problem = registry.setSetting(plugin, setting, next).map { "\(setting.title): \($0)" }
    }

    var body: some View {
        switch setting.kind {
        case .toggle:
            LuxSwitch(isOn: Binding(get: { value.bool ?? false }, set: { save(.bool($0)) }), label: setting.title)
        case .choice:
            Picker(setting.title, selection: Binding(get: { value.string ?? "" }, set: { save(.string($0)) })) {
                ForEach(setting.options, id: \.value) { option in Text(option.title).tag(option.value) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        case .color:
            ColorPicker(setting.title, selection: Binding(get: {
                value.string.flatMap(ThemeColor.init(hex:)).map { Color($0) } ?? DS.Ink.accent
            }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                save(.string(ThemeColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent).hex))
            }), supportsOpacity: false)
            .labelsHidden()
        case .secret:
            HStack(spacing: 6) {
                SecureField(registry.hasSecret(plugin, setting) ? "Saved in the Keychain" : "Not set", text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit { commitSecret() }
                Button("Save") { commitSecret() }.buttonStyle(ModPill(prominent: false)).disabled(draft.isEmpty)
                if registry.hasSecret(plugin, setting) {
                    Button("Clear") { save(.null) }.buttonStyle(ModPill(prominent: false))
                }
            }
        case .text, .number, .hotkeyHint:
            TextField(placeholder, text: Binding(get: { editing ? draft : shown }, set: { draft = $0; editing = true }))
                .textFieldStyle(.roundedBorder).frame(width: setting.kind == .text ? 200 : 120)
                .onSubmit { commitText() }
                .onChange(of: registry.settingsRevision) { _, _ in editing = false }
        }
    }

    private var shown: String {
        switch value {
        case .string(let text): text
        case .number(let number): PluginNodeText.format(number)
        default: ""
        }
    }

    private var placeholder: String {
        switch setting.kind {
        case .number:
            switch (setting.min, setting.max) {
            case (let min?, let max?): "\(PluginNodeText.format(min))–\(PluginNodeText.format(max))"
            default: "Number"
            }
        case .hotkeyHint: "cmd+shift+p"
        default: ""
        }
    }

    private func commitText() {
        defer { editing = false }
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { save(.null); return }
        if setting.kind == .number {
            guard let number = Double(text.replacingOccurrences(of: ",", with: ".")) else {
                problem = "\(setting.title): \"\(text)\" is not a number."; return
            }
            save(.number(number))
        } else {
            save(.string(text))
        }
    }

    private func commitSecret() {
        guard !draft.isEmpty else { return }
        save(.string(draft))
        draft = ""
    }
}

/// Number formatting shared with plugin views.
enum PluginNodeText {
    static func format(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(format: "%g", number)
    }
}

/// Calls, script time and network requests of a running plugin, refreshed every two seconds.
struct PluginActivityView: View {
    let plugin: InstalledPlugin
    @ObservedObject private var registry = PluginRegistry.shared
    @State private var snapshot: PluginMeter.Snapshot?

    var body: some View {
        let requests = (registry.networkLog[plugin.id] ?? []).suffix(8).reversed()
        VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVITY").font(DS.eyebrow).tracking(1.2).foregroundStyle(DS.Ink.tertiary).padding(.top, 4)
            HStack(spacing: 14) {
                meter("Calls", snapshot.map { "\($0.callsPerMinute)/min" } ?? "–")
                meter("Script time", snapshot.map { String(format: "%.0f ms/min", $0.millisecondsPerMinute) } ?? "–")
                meter("Requests", "\(registry.networkLog[plugin.id]?.count ?? 0)")
                if registry.isAsleep(plugin.id) { ModChip(text: "Asleep", symbol: "moon.zzz", hue: DS.Ink.secondary) }
            }
            if !requests.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(requests)) { entry in
                        HStack(spacing: 8) {
                            Text(entry.method).frame(width: 52, alignment: .leading)
                            Text(entry.host + entry.path).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(entry.status.map(String.init) ?? "failed").foregroundStyle(statusColor(entry.status))
                            Text("\(entry.milliseconds) ms").frame(width: 60, alignment: .trailing)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file)).frame(width: 64, alignment: .trailing)
                        }
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.Ink.secondary)
                    }
                }
            }
        }
        .task(id: plugin.id) {
            while !Task.isCancelled {
                registry.stats(plugin.id) { snapshot = $0 }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func meter(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            Text(value).font(DS.Typo.value).foregroundStyle(DS.Ink.primary).monospacedDigit()
        }
    }

    private func statusColor(_ status: Int?) -> Color {
        guard let status else { return .red }
        return (200..<300).contains(status) ? DS.Ink.secondary : .orange
    }
}

/// After two launches in a row that crashed while plugins ran, Atelier starts with plugins off
/// and says so here once, with a way to turn them back on.
struct PluginSafeModeBanner: View {
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        if let running = registry.safeMode, registry.safeModeBannerShown {
            let names = running.map { id in registry.installed.first { $0.id == id }?.manifest.name ?? id }
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 16, weight: .semibold)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plugins are off for now").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                    Text("Atelier quit unexpectedly twice in a row while \(names.isEmpty ? "plugins" : names.formatted(.list(type: .and))) ran, so it started with every plugin off.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.s)
                Button("Turn Plugins Back On") { registry.leaveSafeMode() }.buttonStyle(ModPill())
                Button("Dismiss") { registry.safeModeBannerShown = false }.buttonStyle(ModPill(prominent: false))
            }
            .padding(DS.Space.m)
            .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5) }
        }
    }
}
