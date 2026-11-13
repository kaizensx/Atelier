#if DEBUG
import AppKit
import DockCore
import SwiftUI

/// `DockStacks --render-plugins <folder>` (debug builds): the plugin views and the settings
/// form as PNGs, light and dark, from fixed data. Starts no plugin and changes nothing.
@MainActor
enum PluginRenders {
    static func run(into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func tree(_ json: String) -> PluginNode {
            (try? JSONValue.parse(json)).flatMap { try? PluginNode.parse($0) } ?? .text("parse failed", PluginTextStyle())
        }
        let pomodoro = tree(#"""
        {"type":"hstack","spacing":14,"children":[
          {"type":"vstack","align":"center","spacing":8,"children":[
            {"type":"ring","value":0.36,"label":"16:02","color":"#FF6B5A","width":7},
            {"type":"hstack","spacing":6,"children":[
              {"type":"button","title":"Pause","symbol":"pause.fill","action":"a"},
              {"type":"button","title":"","symbol":"arrow.counterclockwise","style":"plain","action":"b"}]}]},
          {"type":"vstack","spacing":6,"transition":"fade","children":[
            {"type":"text","text":"Focusing","size":12,"weight":"semibold","color":"secondary"},
            {"type":"text","text":"3 today","size":11,"color":"tertiary"},
            {"type":"chart","kind":"bar","values":[2,4,1,0,5,3,3],"labels":["M","T","W","T","F","S","S"],"color":"#FF6B5A"}]}]}
        """#)
        let gallery = tree(#"""
        {"type":"vstack","spacing":10,"children":[
          {"type":"hstack","spacing":8,"children":[
            {"type":"button","title":"Prominent","symbol":"play.fill","action":"a"},
            {"type":"button","title":"Plain","style":"plain","action":"b"}]},
          {"type":"toggle","label":"Sound","on":true,"action":"c"},
          {"type":"progress","value":0.62,"label":"Upload","color":"mint"},
          {"type":"divider"},
          {"type":"grid","columns":3,"children":["One","Two","Three","Four","Five","Six"]},
          {"type":"chart","kind":"line","series":[{"label":"In","values":[3,5,4,8,6,9]},{"label":"Out","values":[1,2,4,3,5,4],"color":"orange"}]},
          {"type":"chart","kind":"area","values":[1,3,2,5,4,6],"color":"teal"},
          {"type":"image","asset":"missing.png","width":48,"height":48,"radius":10}]}
        """#)
        var manifest = PluginManifest(id: "com.example.render-preview", name: "Preview", version: "1.0.0")
        manifest.settings = [
            PluginSetting(key: "focus", kind: .number, title: "Focus minutes", defaultValue: .number(25), min: 1, max: 120),
            PluginSetting(key: "notify", kind: .toggle, title: "Notify when a session ends", defaultValue: .bool(true)),
            PluginSetting(key: "mode", kind: .choice, title: "Mode", detail: "How sessions follow each other.",
                          defaultValue: .string("auto"), options: [.init(value: "auto", title: "Automatic"), .init(value: "manual", title: "Manual")]),
            PluginSetting(key: "tint", kind: .color, title: "Colour", defaultValue: .string("#FF6B5A")),
            PluginSetting(key: "token", kind: .secret, title: "API token", detail: "Stored in your Keychain."),
            PluginSetting(key: "keys", kind: .hotkeyHint, title: "Shortcut hint"),
        ]
        let plugin = InstalledPlugin(manifest: manifest, folder: folder, warnings: [])
        func card(_ node: PluginNode, width: CGFloat, height: CGFloat) -> AnyView {
            AnyView(PluginNodeView(node: node)
                .environment(\.pluginHost, PluginViewHost(plugin: "com.example.render-preview", folder: folder))
                .frame(width: width, height: height, alignment: .topLeading)
                .padding(14)
                .background(Color(red: 0.12, green: 0.13, blue: 0.16), in: .rect(cornerRadius: 18)))
        }
        let states: [(String, AnyView)] = [
            ("pomodoro-widget", card(pomodoro, width: 300, height: 130)),
            ("gallery", card(gallery, width: 300, height: 560)),
            ("settings", AnyView(PluginSettingsForm(plugin: plugin).frame(width: 560).padding(20).background(Color.black))),
        ]
        for (name, view) in states {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    print("failed: \(name)"); continue
                }
                let url = folder.appendingPathComponent("plugins-\(name)-\(scheme == .dark ? "dark" : "light").png")
                try? png.write(to: url)
                print(url.path)
            }
        }
    }
}
#endif
