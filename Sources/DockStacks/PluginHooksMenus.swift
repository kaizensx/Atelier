import AppKit
import DockCore

/// A menu item that calls a plugin back.
final class PluginMenuAction: NSMenuItem {
    private var plugin = ""
    private var key = ""

    convenience init(_ item: PluginMenuItem, plugin: String) {
        self.init(title: item.title, action: #selector(fire), keyEquivalent: "")
        self.plugin = plugin
        self.key = item.action ?? ""
        target = self
        state = item.checked ? .on : .off
        isEnabled = item.enabled && item.action != nil
        if let symbol = item.symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @objc private func fire() {
        let plugin = plugin, key = key
        MainActor.assumeIsolated { PluginHooks.shared.perform(plugin, key) }
    }
}

@MainActor
enum PluginMenus {
    /// NSMenuItems for a plugin's menu entries. Menus that hold them should not auto-enable.
    static func items(_ entries: [PluginMenuEntry], plugin: String) -> [NSMenuItem] {
        entries.map { entry in
            switch entry {
            case .separator:
                return .separator()
            case .item(let item):
                return PluginMenuAction(item, plugin: plugin)
            case .submenu(let title, let symbol, let children):
                let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if let symbol { holder.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                items(children, plugin: plugin).forEach(submenu.addItem)
                holder.submenu = submenu
                return holder
            }
        }
    }

    /// A small grey line naming the plugin, so the owner always knows whose menu this is.
    static func footer(_ pluginName: String) -> NSMenuItem {
        let item = NSMenuItem(title: "From the plugin \u{201C}\(pluginName)\u{201D}", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// Menu bar items plugins asked for. Atelier owns each NSStatusItem; a plugin only describes it.
@MainActor
final class PluginMenuBar {
    static let shared = PluginMenuBar()
    private var items: [String: NSStatusItem] = [:]
    /// What each shows, for the plugin's page in Mods.
    private(set) var specs: [String: (plugin: String, spec: PluginMenuBarSpec)] = [:]

    func set(_ spec: PluginMenuBarSpec, plugin: String, pluginName: String) {
        let key = plugin + "/" + spec.id
        let item = items[key] ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        items[key] = item
        specs[key] = (plugin, spec)
        if let button = item.button {
            button.image = spec.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: spec.title) }
            button.image?.isTemplate = true
            button.title = spec.text ?? ""
            button.imagePosition = spec.text == nil ? .imageOnly : (spec.symbol == nil ? .noImage : .imageLeading)
            button.toolTip = "\(spec.title) (\(pluginName))"
            button.setAccessibilityLabel(spec.text.map { "\(spec.title), \($0)" } ?? spec.title)
        }
        let menu = NSMenu(title: spec.title)
        menu.autoenablesItems = false
        PluginMenus.items(spec.menu, plugin: plugin).forEach(menu.addItem)
        if !spec.menu.isEmpty { menu.addItem(.separator()) }
        menu.addItem(PluginMenus.footer(pluginName))
        item.menu = menu
    }

    func remove(plugin: String, id: String) {
        let key = plugin + "/" + id
        if let item = items.removeValue(forKey: key) { NSStatusBar.system.removeStatusItem(item) }
        specs[key] = nil
    }

    func clear(plugin: String) {
        for key in items.keys where key.hasPrefix(plugin + "/") {
            remove(plugin: plugin, id: String(key.dropFirst(plugin.count + 1)))
        }
    }

    func titles(for plugin: String) -> [String] {
        specs.values.filter { $0.plugin == plugin }.map(\.spec.title).sorted()
    }
}
