import Foundation
import JavaScriptCore
import Testing
@testable import DockCore

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: - Manifests

private func manifest(_ json: String) -> (PluginManifest?, ThemeValidation) {
    PluginManifest.parse(Data(json.utf8), files: ["main.js"])
}

@Test func minimalManifestDefaultsEntry() {
    let (parsed, result) = manifest(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0"}"#)
    #expect(result.isValid)
    #expect(parsed?.entry == "main.js")
    #expect(parsed?.permissions == [])
    #expect(parsed?.symbol == "puzzlepiece.extension")
}

@Test func manifestErrorsAreSpecific() {
    let (_, unknown) = manifest(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0","permissions":["files"]}"#)
    #expect(unknown.errors.first?.path == "permissions[0]")
    let (_, noHosts) = manifest(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0","permissions":["network"]}"#)
    #expect(noHosts.errors.first?.path == "network.hosts")
    let (_, badHost) = manifest(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0","permissions":["network"],"network":{"hosts":["https://api.github.com/x"]}}"#)
    #expect(badHost.errors.first?.path == "network.hosts[0]")
    let (_, local) = manifest(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0","permissions":["network"],"network":{"hosts":["localhost.localdomain.local"]}}"#)
    #expect(!local.isValid)
    let (_, escape) = manifest(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0","entry":"../evil.js"}"#)
    #expect(escape.errors.first?.path == "entry")
    let (_, missing) = manifest(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0","entry":"other.js"}"#)
    #expect(missing.errors.first?.message.contains("not in the bundle") == true)
}

@Test func networkIsGatedThreeWays() {
    let plugin = PluginManifest(id: "a.b", name: "A", version: "1.0.0", permissions: [.network], hosts: ["api.github.com"])
    let ok = URL(string: "https://api.github.com/notifications")!
    #expect((try? PluginNetwork.allows(ok, manifest: plugin, granted: [.network]).get()) != nil)
    #expect((try? PluginNetwork.allows(ok, manifest: plugin, granted: []).get()) == nil, "asked for but not granted")
    #expect((try? PluginNetwork.allows(URL(string: "http://api.github.com/")!, manifest: plugin, granted: [.network]).get()) == nil)
    #expect((try? PluginNetwork.allows(URL(string: "https://github.com/")!, manifest: plugin, granted: [.network]).get()) == nil)
    #expect((try? PluginNetwork.allows(URL(string: "https://api.github.com:8443/")!, manifest: plugin, granted: [.network]).get()) == nil)
    #expect((try? PluginNetwork.allows(URL(string: "https://u:p@api.github.com/")!, manifest: plugin, granted: [.network]).get()) == nil)
    let unasked = PluginManifest(id: "a.b", name: "A", version: "1.0.0", hosts: ["api.github.com"])
    #expect((try? PluginNetwork.allows(ok, manifest: unasked, granted: [.network]).get()) == nil, "granted but never asked for")
    #expect(PluginNetwork.canOpen(URL(string: "https://example.com")!))
    #expect(!PluginNetwork.canOpen(URL(string: "file:///etc/passwd")!))
    #expect(!PluginNetwork.canOpen(URL(string: "x-apple.systempreferences:com.apple.Security")!))
}

@Test func exampleManifestsValidate() throws {
    let folder = repository.appendingPathComponent("examples/plugins")
    let bundles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == PluginManifest.bundleExtension }
    #expect(bundles.count == 4)
    for bundle in bundles {
        let data = try Data(contentsOf: bundle.appendingPathComponent(PluginManifest.fileName))
        let (parsed, result) = PluginManifest.parse(data, files: ["main.js"])
        #expect(parsed != nil, "\(bundle.lastPathComponent): \(result.errors)")
        #expect(result.warnings.isEmpty)
    }
}

// MARK: - Views and messages

@Test func viewsParseFromPlainValues() throws {
    #expect(try PluginNode.parse(.string("Hi")) == .text("Hi", PluginTextStyle()))
    #expect(try PluginNode.parse(.number(3)) == .text("3", PluginTextStyle()))
    let ring = try PluginNode.parse(try JSONValue.parse(#"{"type":"ring","value":1.7,"label":"Max","color":"accent"}"#))
    #expect(ring == .ring(value: 1, label: "Max", color: .named("accent"), width: 6))
    let stack = try PluginNode.parse(try JSONValue.parse(#"{"type":"hstack","spacing":99,"children":["a",{"type":"spacer"}]}"#))
    guard case .stack(let axis, let spacing, _, let children) = stack else { Issue.record("not a stack"); return }
    #expect(axis == .horizontal && spacing == 40 && children.count == 2)
    let spark = try PluginNode.parse(.object(["type": .string("sparkline"), "values": .array((0..<500).map { .number(Double($0)) })]))
    if case .sparkline(let values, _, _) = spark { #expect(values.count == PluginNode.maxPoints) }
}

@Test func viewsRejectWhatTheyCannotDraw() {
    #expect(throws: PluginFailure.self) { try PluginNode.parse(.object(["type": .string("webview")])) }
    #expect(throws: PluginFailure.self) { try PluginNode.parse(.object(["type": .string("symbol"), "name": .string("../../x")])) }
    var deep: JSONValue = .string("x")
    for _ in 0..<12 { deep = .object(["type": .string("vstack"), "children": .array([deep])]) }
    #expect(throws: PluginFailure.self) { try PluginNode.parse(deep) }
    let wide = JSONValue.array((0..<400).map { _ in .string("x") })
    #expect(throws: PluginFailure.self) { try PluginNode.parse(wide) }
}

@Test func messagesAreClampedAndChecked() throws {
    let widget = try PluginMessage.decode(kind: "widget", payload: #"{"id":"w","refresh":1,"size":"huge"}"#)
    #expect(widget == .widget(PluginWidgetSpec(id: "w", title: "w", size: .small, refresh: 5)))
    let command = try PluginMessage.decode(kind: "command", payload: #"{"id":"c","title":"Go","shortcut":"Shift+Command+P"}"#)
    #expect(command == .command(PluginCommandSpec(id: "c", title: "Go", subtitle: nil, shortcut: "cmd+shift+p")))
    #expect(throws: PluginFailure.self) { try PluginMessage.decode(kind: "command", payload: #"{"id":"c","title":"Go","shortcut":"shift+p"}"#) }
    #expect(throws: PluginFailure.self) { try PluginMessage.decode(kind: "openURL", payload: #"{"url":"file:///Users"}"#) }
    #expect(throws: PluginFailure.self) { try PluginMessage.decode(kind: "widget", payload: #"{"id":"has space"}"#) }
    #expect(throws: PluginFailure.self) { try PluginMessage.decode(kind: "launchMissiles", payload: "{}") }
    let http = try PluginMessage.decode(kind: "http", payload: #"{"request":1,"url":"https://api.github.com/x","headers":{"Accept":"json","Cookie":"a=b","Host":"evil"}}"#)
    #expect(http == .http(request: 1, url: URL(string: "https://api.github.com/x")!, headers: ["Accept": "json"]))
    let tile = try PluginMessage.decode(kind: "tile", payload: #"{"id":"t","text":"25:00:00:00","badge":12345,"progress":2}"#)
    #expect(tile == .tile(PluginTileSpec(id: "t", title: "t", symbol: nil, text: "25:00:00:00", badge: "1234", tint: nil, progress: 1)))
    #expect(PluginShortcut.symbols("ctrl+opt+p") == "⌃⌥P")
}

@Test func storageIsBounded() throws {
    var storage = PluginStorage()
    try storage.set("a", .number(1))
    #expect(storage.values["a"] == .number(1))
    try storage.set("a", .null)
    #expect(storage.values["a"] == nil)
    #expect(throws: PluginFailure.self) { try storage.set("big", .string(String(repeating: "x", count: PluginStorage.maxBytes))) }
    #expect(throws: PluginFailure.self) { try storage.set("", .number(1)) }
    let reloaded = PluginStorage(data: PluginStorage(values: ["k": .string("v")]).data)
    #expect(reloaded.values["k"] == .string("v"))
}

// MARK: - The JavaScript prelude, end to end

/// Runs a script under the real prelude with a native side that records every call, the way
/// PluginRuntime does, minus the threads. No network: http calls are recorded, never sent.
private final class Harness {
    let context = JSContext()!
    var calls: [(kind: String, message: PluginMessage?)] = []
    var errors: [String] = []
    var store = PluginStorage()

    init() {
        context.exceptionHandler = { [unowned self] _, exception in self.errors.append(exception?.toString() ?? "?") }
        let native: @convention(block) (String, String) -> String = { [unowned self] kind, payload in
            if kind.hasPrefix("storage.") {
                let value = (try? JSONValue.parse(payload)) ?? .null
                switch kind {
                case "storage.get": return self.store.values[value["key"]?.string ?? ""]?.text() ?? "null"
                case "storage.set": try? self.store.set(value["key"]?.string ?? "", value["value"]); return "null"
                default: return "[]"
                }
            }
            do {
                self.calls.append((kind, try PluginMessage.decode(kind: kind, payload: payload)))
                return "null"
            } catch {
                self.calls.append((kind, nil))
                return JSONValue.object(["__error": .string("\(error)")]).text()
            }
        }
        context.setObject(unsafeBitCast(native, to: AnyObject.self), forKeyedSubscript: "__atelierNative" as NSString)
        context.evaluateScript(PluginPrelude.source)
    }

    func run(_ script: String) { context.evaluateScript(script) }
    func call(_ method: String, _ arguments: [Any]) {
        context.objectForKeyedSubscript("__atelier").objectForKeyedSubscript(method).call(withArguments: arguments)
    }
    func messages(_ kind: String) -> [PluginMessage] { calls.filter { $0.kind == kind }.compactMap(\.message) }
}

@Test func preludeHidesTheNativeBridge() {
    let harness = Harness()
    #expect(harness.context.evaluateScript("typeof __atelierNative").toString() == "undefined")
    #expect(harness.context.evaluateScript("typeof atelier.widget").toString() == "function")
    #expect(harness.context.evaluateScript("typeof require + typeof fetch + typeof XMLHttpRequest").toString() == "undefinedundefinedundefined")
    harness.run("atelier.widget = null")
    #expect(harness.context.evaluateScript("typeof atelier.widget").toString() == "function", "atelier is frozen")
}

@Test func widgetRendersThroughDataAndView() {
    let harness = Harness()
    harness.run("""
    atelier.widget({ id: "cpu", title: "CPU", refresh: 30,
      data: async () => ({ load: 0.42 }),
      view: (d) => atelier.ui.vstack([atelier.ui.ring(d.load, { label: "42%" }), "busy"]) });
    """)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    #expect(harness.messages("widget") == [.widget(PluginWidgetSpec(id: "cpu", title: "CPU", size: .small, refresh: 30))])
    harness.call("render", ["cpu"])
    let views = harness.messages("widgetView")
    #expect(views.count == 1)
    if case .widgetView(let id, .stack(.vertical, _, _, let children))? = views.first {
        #expect(id == "cpu")
        #expect(children.first == .ring(value: 0.42, label: "42%", color: nil, width: 6))
    } else {
        Issue.record("unexpected \(views)")
    }
}

@Test func widgetErrorsComeBackAsMessages() {
    let harness = Harness()
    harness.run(#"atelier.widget({ id: "w", data: () => { throw new Error("offline") } })"#)
    harness.call("render", ["w"])
    #expect(harness.messages("widgetError") == [.widgetError(id: "w", message: "offline")])
}

@Test func commandsDispatchToTheirFunction() {
    let harness = Harness()
    harness.run(#"let ran = 0; atelier.command({ title: "Do It", run: () => { ran += 1 } });"#)
    #expect(harness.messages("command") == [.command(PluginCommandSpec(id: "do-it", title: "Do It", subtitle: nil, shortcut: nil))])
    harness.call("dispatch", ["command:do-it:run", "null"])
    harness.call("dispatch", ["command:nope:run", "null"])
    #expect(harness.context.evaluateScript("ran").toInt32() == 1)
}

@Test func nativeRefusalsBecomeJavaScriptErrors() {
    let harness = Harness()
    harness.run(#"let caught = ""; try { atelier.openURL("file:///etc") } catch (e) { caught = e.message }"#)
    #expect(harness.context.evaluateScript("caught").toString().contains("only https"))
}

@Test func httpResolvesThroughSettle() {
    let harness = Harness()
    harness.run(#"let got = null; atelier.http.get("https://api.github.com/x").then(r => { got = r.json().n + r.status })"#)
    guard case .http(let request, let url, _)? = harness.messages("http").first else { Issue.record("no request"); return }
    #expect(url.host() == "api.github.com")
    harness.call("settle", [request, true, #"{"status":200,"ok":true,"text":"{\"n\":1}"}"#])
    #expect(harness.context.evaluateScript("got").toInt32() == 201)
}

@Test func timersAndEventsRoundTrip() {
    let harness = Harness()
    harness.run(#"let fired = 0, seen = ""; const t = setTimeout(() => { fired++ }, 50); atelier.on("appActivated", (p) => { seen = p.name });"#)
    #expect(harness.messages("timer") == [.timer(id: 1, milliseconds: 50, repeats: false)])
    #expect(harness.messages("on") == [.subscribe(.appActivated, interval: nil)])
    harness.call("fire", [1])
    harness.call("fire", [1])
    harness.call("emit", ["appActivated", #"{"name":"Safari"}"#])
    #expect(harness.context.evaluateScript("fired").toInt32() == 1, "a timeout fires once")
    #expect(harness.context.evaluateScript("seen").toString() == "Safari")
}

@Test func storageRoundTripsJSON() {
    let harness = Harness()
    harness.run(#"atelier.storage.set("state", { left: 90, on: true }); var back = atelier.storage.get("state").left; var none = atelier.storage.get("x", 7);"#)
    #expect(harness.context.evaluateScript("back").toInt32() == 90)
    #expect(harness.context.evaluateScript("none").toInt32() == 7)
    #expect(harness.store.values["state"]?["on"] == .bool(true))
}

/// The shipped examples load and register what their docs say, without touching the network.
@Test func examplePluginsRegister() throws {
    let folder = repository.appendingPathComponent("examples/plugins")
    let expected: [String: [String]] = [
        "pomodoro.atelierplugin": ["tile", "widget", "command", "corner", "on"],
        "github-notifications.atelierplugin": ["tile", "widget", "command"],
        "random-palette.atelierplugin": ["command", "corner"],
    ]
    for (name, kinds) in expected {
        let harness = Harness()
        let source = try String(contentsOf: folder.appendingPathComponent(name).appendingPathComponent("main.js"), encoding: .utf8)
        harness.run(source)
        #expect(harness.errors.isEmpty, "\(name): \(harness.errors)")
        for kind in kinds { #expect(!harness.messages(kind).isEmpty, "\(name) should send \(kind)") }
        #expect(harness.calls.allSatisfy { $0.message != nil }, "\(name) sent a call the bridge refused: \(harness.calls.filter { $0.message == nil }.map(\.kind))")
    }
}
