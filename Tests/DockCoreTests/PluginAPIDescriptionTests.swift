import Foundation
import JavaScriptCore
import Testing
@testable import DockCore

// docs/plugin-api.json is the one description the SDK types, the atelier-mod CLI, the
// Playground's templates and the website's API page are built from. These tests fail when the
// app has a permission, event, view, manifest key or limit the description does not list, so
// the two cannot drift apart unnoticed.

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func description() throws -> JSONValue {
    try JSONValue.parse(Data(contentsOf: repository.appendingPathComponent("docs/plugin-api.json")))
}

private func names(_ list: JSONValue?, _ key: String) -> Set<String> {
    Set((list?.array ?? []).compactMap { $0[key]?.string })
}

@Test func descriptionListsEveryPermission() throws {
    let api = try description()
    let listed = names(api["permissions"], "name")
    for permission in PluginPermission.allCases {
        #expect(listed.contains(permission.rawValue), "plugin-api.json lacks the permission \(permission.rawValue)")
        let entry = api["permissions"]?.array?.first { $0["name"]?.string == permission.rawValue }
        #expect(entry?["title"]?.string == permission.title, "\(permission.rawValue): title differs from the app's")
        #expect(entry?["detail"]?.string == permission.detail, "\(permission.rawValue): detail differs from the app's")
        #expect(entry?["symbol"]?.string == permission.symbol, "\(permission.rawValue): symbol differs from the app's")
    }
    // And nothing the app does not have.
    for name in listed { #expect(PluginPermission(rawValue: name) != nil, "plugin-api.json lists \(name), which the app does not have") }
}

@Test func descriptionListsEveryEvent() throws {
    let listed = names(try description()["events"], "name")
    for event in PluginEvent.allCases { #expect(listed.contains(event.rawValue), "plugin-api.json lacks the event \(event.rawValue)") }
    for name in listed { #expect(PluginEvent(rawValue: name) != nil, "plugin-api.json lists the event \(name), which the app does not have") }
}

@Test func descriptionListsEveryManifestKey() throws {
    let listed = names(try description()["manifest"], "key")
    for field in PluginManifest.fields { #expect(listed.contains(field.key), "plugin-api.json lacks the manifest key \(field.key)") }
    for key in PluginManifest.engineKeys { #expect(listed.contains(key), "plugin-api.json lacks the manifest key \(key)") }
}

@Test func descriptionListsEveryViewTheAppDraws() throws {
    let api = try description()
    let listed = names(api["views"], "type")
    // The app names every view it draws when it refuses an unknown one.
    var drawn: [String] = []
    do { _ = try PluginNode.parse(.object(["type": .string("no-such-view")])) } catch {
        let text = error.description
        let list = text.components(separatedBy: "Use ").last ?? ""
        drawn = list.replacingOccurrences(of: " or ", with: ", ").replacingOccurrences(of: ".", with: "")
            .components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    #expect(drawn.count >= 10)
    for type in drawn { #expect(listed.contains(type), "plugin-api.json lacks the view \(type)") }
    // And every view listed parses in this build, given the keys its description says it needs.
    for view in api["views"]?.array ?? [] {
        let type = view["type"]?.string ?? ""
        let sample: JSONValue = .object(["type": .string(type), "name": .string("timer"), "title": .string("Go"), "label": .string("On"),
                                         "action": .string("go"), "asset": .string("a.png"), "values": .array([.number(1)])])
        #expect((try? PluginNode.parse(sample)) != nil, "the app does not draw \(type)")
    }
    #expect(drawn.count == listed.count, "plugin-api.json lists views the app does not draw: \(listed.subtracting(drawn))")
}

@Test func descriptionLimitsMatchTheApp() throws {
    let limits = Dictionary(uniqueKeysWithValues: (try description()["limits"]?.array ?? []).compactMap { item -> (String, Double)? in
        guard let key = item["key"]?.string, let value = item["value"]?.number else { return nil }
        return (key, value)
    })
    #expect(limits["registrations"] == Double(PluginMessage.maxRegistrations))
    #expect(limits["viewNodes"] == Double(PluginNode.maxNodes))
    #expect(limits["viewDepth"] == Double(PluginNode.maxDepth))
    #expect(limits["textLength"] == Double(PluginNode.maxText))
    #expect(limits["sparklinePoints"] == Double(PluginNode.maxPoints))
    #expect(limits["listRows"] == Double(PluginNode.maxRows))
    #expect(limits["scriptBytes"] == Double(PluginManifest.maxScriptBytes))
    #expect(limits["hosts"] == Double(PluginManifest.maxHosts))
    #expect(limits["storageBytes"] == Double(PluginStorage.maxBytes))
    #expect(limits["storageKeyLength"] == Double(PluginStorage.maxKeyLength))
    #expect(limits["settings"] == Double(PluginSetting.maxCount))
    #expect(limits["messagePayloadBytes"] == Double(PluginMessage.maxMessageBytes))
    #expect(limits["assetBytes"] == Double(PluginAssets.maxBytes))
    #expect(limits["chartSeries"] == Double(PluginChart.maxSeries))
    #expect(limits["chartValues"] == Double(PluginChart.maxValues))
    #expect(limits["stringLanguages"] == Double(PluginStrings.maxLanguages))
    #expect(limits["stringKeys"] == Double(PluginStrings.maxKeys))
    #expect(limits["paletteProviders"] == Double(PluginHookLimits.maxPalettes))
    #expect(limits["paletteRows"] == Double(PluginPaletteSpec.maxResults))
    #expect(limits["menuBarItems"] == Double(PluginMenuBarSpec.maxPerPlugin))
    #expect(limits["menuItems"] == Double(PluginMenuEntry.maxItems))
    #expect(limits["dropBytes"] == Double(PluginTileHooks.maxDropBytes))
    #expect(limits["stackProviders"] == Double(PluginStackSpec.maxPerPlugin))
    #expect(limits["stackItems"] == Double(PluginStackSpec.maxItems))
    #expect(limits["liveActivities"] == Double(PluginActivitySpec.maxShown))
    #expect(limits["panels"] == Double(PluginPanelSpec.maxPerPlugin))
    #expect(limits["panelHTMLBytes"] == Double(PluginPanelSpec.maxHTMLBytes))
    #expect(limits["panelMessageBytes"] == Double(PluginPanelSpec.maxMessageBytes))
}

@Test func descriptionDescribesEveryFunctionOfThePrelude() throws {
    let api = try description()
    let listed = names(api["api"], "name")
    let context = JSContext()!
    let native: @convention(block) (String, String) -> String = { _, _ in "null" }
    context.setObject(unsafeBitCast(native, to: AnyObject.self), forKeyedSubscript: "__atelierNative" as NSString)
    context.evaluateScript(PluginPrelude.source)
    let script = """
    (function () {
      const out = [];
      const walk = (o, path) => { for (const k of Object.keys(o)) {
        const v = o[k], p = path + "." + k;
        if (path === "atelier.ui") continue;
        out.push(p);
        if (v && typeof v === "object" && !Array.isArray(v)) walk(v, p);
      } };
      walk(atelier, "atelier");
      return JSON.stringify(out);
    })()
    """
    let found = try JSONValue.parse(Data(context.evaluateScript(script).toString().utf8)).array?.compactMap(\.string) ?? []
    #expect(found.count > 10)
    for name in found { #expect(listed.contains(name), "plugin-api.json lacks \(name)") }
    // Every helper in atelier.ui is a view the description lists.
    let helpers = context.evaluateScript("JSON.stringify(Object.keys(atelier.ui))").toString() ?? "[]"
    let views = Set((api["views"]?.array ?? []).compactMap { $0["helper"]?.string })
    for helper in (try JSONValue.parse(Data(helpers.utf8)).array ?? []).compactMap(\.string) {
        #expect(views.contains(helper), "plugin-api.json lacks the ui helper \(helper)")
    }
}

/// The Playground's and `atelier-mod new`'s plugin templates: their manifests parse, their scripts run
/// under the real prelude, register something, and every widget draws a view the app accepts.
@Test func pluginTemplatesRunUnderThePrelude() throws {
    let folder = repository.appendingPathComponent("sdk/cli/templates/plugin")
    let templates = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
    #expect(templates.count >= 4)
    for name in templates {
        let dir = folder.appendingPathComponent(name)
        let source = try String(contentsOf: dir.appendingPathComponent("main.js"), encoding: .utf8)
        let meta = try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("template.json")))
        #expect(meta["title"]?.string?.isEmpty == false)
        var root: [String: JSONValue] = ["format": .number(1), "id": .string("io.github.you." + name), "name": .string(name), "version": .string("1.0.0"),
                                         "permissions": meta["permissions"] ?? .array([])]
        if let hosts = meta["hosts"] { root["network"] = .object(["hosts": hosts]) }
        for (key, value) in meta["manifest"]?.object ?? [:] { root[key] = value }
        let (parsed, validation) = PluginManifest.parse(try JSONValue.object(root).data(pretty: false), files: ["main.js"])
        #expect(validation.isValid, "\(name): \(validation.issues)")
        let manifest = try #require(parsed)

        let context = JSContext()!
        var errors: [String] = [], kinds: [String] = [], widgets: [String] = [], views = 0
        context.exceptionHandler = { _, exception in errors.append(exception?.toString() ?? "?") }
        let native: @convention(block) (String, String) -> String = { kind, payload in
            kinds.append(kind)
            let value = (try? JSONValue.parse(payload)) ?? .null
            if kind.hasPrefix("storage.") { return kind == "storage.keys" ? "[]" : "null" }
            if kind == "settings.get" { return (manifest.setting(value["key"]?.string ?? "")?.defaultValue ?? .null).text() }
            if kind.hasPrefix("settings.") { return "null" }
            if kind == "env.strings" { return JSONValue.object(PluginStrings.pick(manifest.strings, preferred: ["en"]).mapValues(JSONValue.string)).text() }
            if PluginHookMessage.handles(kind) {
                do { _ = try PluginHookMessage.decode(kind: kind, payload: payload); return "null" } catch {
                    errors.append("\(kind): \(error)"); return JSONValue.object(["__error": .string("\(error)")]).text()
                }
            }
            do {
                let message = try PluginMessage.decode(kind: kind, payload: payload)
                if case .widget(let spec) = message { widgets.append(spec.id) }
                if case .widgetView = message { views += 1 }
                if case .widgetError(let id, let text) = message { errors.append("\(id): \(text)") }
                return "null"
            } catch {
                errors.append("\(kind): \(error)")
                return JSONValue.object(["__error": .string("\(error)")]).text()
            }
        }
        context.setObject(unsafeBitCast(native, to: AnyObject.self), forKeyedSubscript: "__atelierNative" as NSString)
        context.evaluateScript(PluginPrelude.source)
        context.evaluateScript(source)
        // Widgets whose data comes from the network fail offline by design; draw the others.
        let offline = meta["permissions"]?.array?.contains(.string("network")) == true
        if !offline {
            for id in widgets { context.objectForKeyedSubscript("__atelier").objectForKeyedSubscript("render").call(withArguments: [id]) }
            #expect(views >= widgets.count, "\(name): \(views) views for \(widgets.count) widgets")
        }
        #expect(errors.isEmpty, "\(name): \(errors)")
        #expect(kinds.contains("widget") || kinds.contains("tile") || kinds.contains("command"), "\(name) registers nothing")
    }
}

/// `atelier-mod new` makes packs from sdk/cli/templates/packs: each must pass the app's own checks.
@Test func packTemplatesPassTheAppsValidator() throws {
    let folder = repository.appendingPathComponent("sdk/cli/templates/packs")
    for kind in ModPackKind.allCases {
        let dir = folder.appendingPathComponent(kind.rawValue)
        let package = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasSuffix("." + kind.bundleExtension) },
                                   "no template for \(kind.rawValue)")
        switch ModPackDisk.load(dir.appendingPathComponent(package)) {
        case .success(let (_, report)): #expect(report.errors.isEmpty, "\(kind.rawValue): \(report.errors)")
        case .failure(let error): Issue.record("\(kind.rawValue): \(error)")
        }
    }
}
