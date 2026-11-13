import DockCore
import SwiftUI

/// Stacks chapter: stacks that running plugins offer, each one click from the Atelier Dock.
struct PluginStacksSection: View {
    @ObservedObject private var hooks = PluginHooks.shared
    @ObservedObject private var dock = OwnDock.shared

    var body: some View {
        if !hooks.stacks.isEmpty {
            SectionHeader("From Plugins", symbol: "puzzlepiece.extension",
                          detail: "Stacks your plugins fill. Each opens on the Atelier Dock with what the plugin lists.", hue: DockHubHue.tint)
            RowGroup {
                ForEach(hooks.stacks) { stack in
                    let added = dock.hasPlugin(.stack, key: stack.id)
                    SettingRow(title: stack.spec.title, detail: "From \(stack.pluginName).", symbol: stack.spec.symbol, density: .compact) {
                        if added {
                            Button("Remove") { dock.remove(id: PluginDockPath.make(.stack, key: stack.id)) }
                                .buttonStyle(ModPill(prominent: false))
                        } else {
                            Button("Add to Atelier Dock") { dock.addPlugin(.stack, key: stack.id) }
                                .buttonStyle(ModPill())
                                .disabled(!dock.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// A plugin's page in Mods, In Atelier: what it plugged into through hooks.
struct PluginHookRows: View {
    let plugin: String
    var go: (Chapter) -> Void
    @ObservedObject private var hooks = PluginHooks.shared
    @ObservedObject private var dock = OwnDock.shared

    var body: some View {
        ForEach(hooks.palettes.filter { $0.plugin == plugin }) { palette in
            SettingRow(title: palette.spec.title,
                       detail: palette.spec.prefix.map { "Command palette. Type \u{201C}\($0) \u{201D} and a search." } ?? "Command palette. Answers as you type.",
                       symbol: "sparkle.magnifyingglass", density: .compact) {
                Button("Open") { CommandController.shared.toggle() }.buttonStyle(ModPill(prominent: false))
            }
        }
        ForEach(hooks.stacks.filter { $0.plugin == plugin }) { stack in
            SettingRow(title: stack.spec.title, detail: "Stack for the Atelier Dock.", symbol: stack.spec.symbol, density: .compact) {
                if dock.hasPlugin(.stack, key: stack.id) {
                    Button("Stacks") { go(.stacks) }.buttonStyle(ModPill(prominent: false))
                } else {
                    Button("Add to Dock") { dock.addPlugin(.stack, key: stack.id) }.buttonStyle(ModPill())
                }
            }
        }
        ForEach(PluginMenuBar.shared.titles(for: plugin), id: \.self) { title in
            SettingRow(title: title, detail: "Menu bar item.", symbol: "menubar.rectangle", density: .compact) { EmptyView() }
        }
        ForEach(PluginPanels.shared.titles(for: plugin), id: \.self) { title in
            SettingRow(title: title, detail: "Window. The plugin opens it when it needs to.", symbol: "macwindow", density: .compact) { EmptyView() }
        }
        if hooks.tileHooks.keys.contains(where: { $0.hasPrefix(plugin + "/") }) {
            SettingRow(title: "Dock tile menu", detail: "Right-click its Dock tile, or press and hold it, for the plugin's menu.",
                       symbol: "contextualmenu.and.cursorarrow", density: .compact) { EmptyView() }
        }
    }
}

extension PluginHooks {
    /// Whether a plugin plugged anything in through hooks, for "Nothing to open".
    func hasAny(_ plugin: String) -> Bool {
        palettes.contains { $0.plugin == plugin } || stacks.contains { $0.plugin == plugin }
            || !PluginMenuBar.shared.titles(for: plugin).isEmpty || !PluginPanels.shared.titles(for: plugin).isEmpty
    }
}

/// Dock chapter's Tile menu: the Dock tiles running plugins offer.
struct PluginTileMenuItems: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var dock = OwnDock.shared

    var body: some View {
        if !registry.dockTiles.isEmpty {
            Divider()
            Section("From Plugins") {
                ForEach(registry.dockTiles) { tile in
                    let added = dock.hasPlugin(.tile, key: tile.id)
                    Button(added ? tile.spec.title + " (in the dock)" : tile.spec.title) { dock.addPlugin(.tile, key: tile.id) }
                        .disabled(added)
                }
            }
        }
    }
}
