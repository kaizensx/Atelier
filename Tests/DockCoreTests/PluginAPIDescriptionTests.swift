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
    }
}

@Test func descriptionListsEveryEvent() throws {
    let listed = names(try description()["events"], "name")
    for event in PluginEvent.allCases { #expect(listed.contains(event.rawValue), "plugin-api.json lacks the event \(event.rawValue)") }
}

@Test func descriptionListsEveryManifestKey() throws {
    let listed = names(try description()["manifest"], "key")
    for field in PluginManifest.fields { #expect(listed.contains(field.key), "plugin-api.json lacks the manifest key \(field.key)") }
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
    // And every view listed without a later "since" parses in this build.
    for view in api["views"]?.array ?? [] where view["since"] == nil {
        let type = view["type"]?.string ?? ""
        #expect((try? PluginNode.parse(.object(["type": .string(type), "name": .string("timer")]))) != nil, "the app does not draw \(type)")
    }
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

/// The Playground's and `atelier-mod new`'s plugin templates run under the real prelude, register
/// something, and send only messages the app accepts.
@Test func pluginTemplatesRunUnderThePrelude() throws {
    let folder = repository.appendingPathComponent("sdk/cli/templates/plugin")
    let templates = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
    #expect(templates.count >= 3)
    for name in templates {
        let source = try String(contentsOf: folder.appendingPathComponent(name).appendingPathComponent("main.js"), encoding: .utf8)
        let context = JSContext()!
        var errors: [String] = [], kinds: [String] = []
        context.exceptionHandler = { _, exception in errors.append(exception?.toString() ?? "?") }
        let native: @convention(block) (String, String) -> String = { kind, payload in
            kinds.append(kind)
            if kind.hasPrefix("storage.") { return kind == "storage.keys" ? "[]" : "null" }
            do { _ = try PluginMessage.decode(kind: kind, payload: payload); return "null" } catch {
                errors.append("\(kind): \(error)")
                return JSONValue.object(["__error": .string("\(error)")]).text()
            }
        }
        context.setObject(unsafeBitCast(native, to: AnyObject.self), forKeyedSubscript: "__atelierNative" as NSString)
        context.evaluateScript(PluginPrelude.source)
        context.evaluateScript(source)
        #expect(errors.isEmpty, "\(name): \(errors)")
        #expect(kinds.contains("widget") || kinds.contains("tile") || kinds.contains("command"), "\(name) registers nothing")
        let meta = try JSONValue.parse(Data(contentsOf: folder.appendingPathComponent(name).appendingPathComponent("template.json")))
        #expect(meta["title"]?.string?.isEmpty == false)
    }
}
