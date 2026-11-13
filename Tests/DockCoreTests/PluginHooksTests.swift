import Foundation
import JavaScriptCore
import Testing
@testable import DockCore

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func decode(_ kind: String, _ json: String) throws(PluginFailure) -> PluginHookMessage {
    try PluginHookMessage.decode(kind: kind, payload: json)
}

private func fails(_ kind: String, _ json: String) -> Bool {
    (try? decode(kind, json)) == nil
}

// MARK: - Decoding

@Test func menusAreBoundedAndNestOnce() throws {
    let menu = try PluginMenuEntry.parse(try JSONValue.parse(#"""
    [{"title":"Open","symbol":"bell","action":"action:menuBar:x:1","checked":true},
     "separator",
     {"title":"More","submenu":[{"title":"Deep","action":"action:menuBar:x:2","enabled":false}]}]
    """#), path: "menu")
    #expect(menu.count == 3)
    #expect(PluginMenuEntry.count(menu) == 4)
    #expect(menu[0] == .item(PluginMenuItem(title: "Open", symbol: "bell", action: "action:menuBar:x:1", checked: true, enabled: true)))
    #expect(menu[1] == .separator)
    let nested = #"[{"title":"A","submenu":[{"title":"B","submenu":[{"title":"C"}]}]}]"#
    #expect((try? PluginMenuEntry.parse(try JSONValue.parse(nested), path: "m")) == nil, "depth 3 is refused")
    let many = "[" + (0..<41).map { _ in #"{"title":"x"}"# }.joined(separator: ",") + "]"
    #expect((try? PluginMenuEntry.parse(try JSONValue.parse(many), path: "m")) == nil, "41 items are refused")
    #expect((try? PluginMenuEntry.parse(try JSONValue.parse(#"[{"title":"x","action":"javascript:alert(1)"}]"#), path: "m")) == nil,
            "only prelude action keys")
    #expect((try? PluginMenuEntry.parse(try JSONValue.parse(#"[{"title":""}]"#), path: "m")) == nil)
}

@Test func paletteProvidersAnswerOnlyToTheirPrefix() throws {
    guard case .palette(let spec) = try decode("palette", #"{"id":"repos","title":"GitHub","prefix":"GH"}"#) else { Issue.record(); return }
    #expect(spec.prefix == "gh")
    #expect(spec.query(for: "gh atelier mods") == "atelier mods")
    #expect(spec.query(for: "GH Atelier") == "Atelier")
    #expect(spec.query(for: "gh") == nil)
    #expect(spec.query(for: "ghost") == nil)
    #expect(spec.query(for: "atelier") == nil)
    let open = PluginPaletteSpec(id: "all", title: "All", prefix: nil)
    #expect(open.query(for: "  notes ") == "notes")
    #expect(open.query(for: "   ") == nil)
    #expect(fails("palette", #"{"id":"x","prefix":"has space"}"#))
}

@Test func menuBarItemsAreShortAndNamed() throws {
    guard case .menuBar(let spec) = try decode("menuBar", #"{"id":"inbox","title":"GitHub","symbol":"bell","text":"12345678901234567890","menu":[]}"#) else {
        Issue.record(); return
    }
    #expect(spec.text == "1234567890123456")
    #expect(fails("menuBar", #"{"id":"inbox","title":"Nothing to show"}"#), "needs a symbol or a text")
    #expect(fails("menuBar", #"{"id":"inbox","symbol":"Not A Symbol"}"#))
}

@Test func tilesTakeLinksAndTextNeverFiles() throws {
    guard case .tileHooks(let hooks) = try decode("tileHooks", #"{"id":"hub","accepts":["url","text"],"menu":[{"title":"A","action":"action:tile:hub:1"}]}"#) else {
        Issue.record(); return
    }
    #expect(hooks.accepts == [.url, .text])
    #expect(fails("tileHooks", #"{"id":"hub","accepts":["file"]}"#))
    let both: Set<PluginDropKind> = [.url, .text]
    #expect(PluginHookCheck.dropValue(url: "https://github.com/a/b", text: nil, fileCount: 0, accepts: both)! == (.url, "https://github.com/a/b"))
    #expect(PluginHookCheck.dropValue(url: "https://github.com/a/b", text: nil, fileCount: 1, accepts: both) == nil, "files never")
    #expect(PluginHookCheck.dropValue(url: "file:///etc/passwd", text: nil, fileCount: 0, accepts: [.url]) == nil)
    #expect(PluginHookCheck.dropValue(url: nil, text: "file:///etc/passwd", fileCount: 0, accepts: [.text]) == nil)
    #expect(PluginHookCheck.dropValue(url: nil, text: "hello", fileCount: 0, accepts: [.url]) == nil, "text only when asked for")
    #expect(PluginHookCheck.dropValue(url: nil, text: "hello", fileCount: 0, accepts: [.text])! == (.text, "hello"))
    let big = String(repeating: "x", count: PluginTileHooks.maxDropBytes + 1)
    #expect(PluginHookCheck.dropValue(url: nil, text: big, fileCount: 0, accepts: [.text]) == nil, "8 KB at most")
}

@Test func panelsAreBounded() throws {
    guard case .panel(let spec) = try decode("panel", #"{"id":"dash","title":"Dash","width":5000,"height":10,"html":"<p>hi</p>"}"#) else {
        Issue.record(); return
    }
    #expect(spec.width == 1200 && spec.height == 120 && !spec.resizable)
    let big = String(repeating: "a", count: PluginPanelSpec.maxHTMLBytes + 1)
    #expect(fails("panel", JSONValue.object(["id": .string("d"), "html": .string(big)]).text()))
    #expect(fails("panel", #"{"id":"d"}"#), "html is required")
    let message = String(repeating: "m", count: PluginPanelSpec.maxMessageBytes)
    #expect(fails("panelPost", JSONValue.object(["id": .string("d"), "message": .string(message)]).text()), "64 KB of JSON at most")
    #expect(PluginPanelSpec.maxHTMLBytes == 512 * 1024)
}

@Test func activitiesAndStacksDecode() throws {
    guard case .activity(let activity) = try decode("activity", #"{"id":"t","title":"Focus","symbol":"timer","text":"24:59","progress":2,"until":"2030-01-01T00:00:00.000Z"}"#) else {
        Issue.record(); return
    }
    #expect(activity.progress == 1)
    #expect(activity.until == Date(timeIntervalSince1970: 1_893_456_000))
    guard case .stack(let stack) = try decode("stack", #"{"id":"pulls","title":"PRs","refresh":-5}"#) else { Issue.record(); return }
    #expect(stack.symbol == "square.stack.3d.up" && stack.refresh == 0)
    #expect(fails("scenes.apply", #"{"request":1}"#))
    #expect(try decode("scenes.list", #"{"request":3}"#) == .scenesList(request: 3))
}

@Test func resultRowsAreClippedAndChecked() throws {
    let rows = PluginResultItem.parse(try JSONValue.parse(#"""
    [{"title":"One","subtitle":"s","symbol":"book","action":"action:palette:x:1"},
     {"subtitle":"no title"},
     {"title":"Two","symbol":"Not Valid","image":"../../etc/x.png","action":"nope"},
     {"title":"Three","image":"icons/pr.png"},
     "plain"]
    """#), limit: 20)
    #expect(rows.map(\.title) == ["One", "Two", "Three", "plain"])
    #expect(rows[1].symbol == nil && rows[1].image == nil && rows[1].action == nil)
    #expect(rows[2].image == "icons/pr.png")
    let many = JSONValue.array((0..<80).map { .string("r\($0)") })
    #expect(PluginResultItem.parse(many, limit: PluginStackSpec.maxItems).count == 60)
}

@Test func hookPermissionsAndLimits() throws {
    #expect(try decode("menuBar", #"{"id":"a","symbol":"bell"}"#).permission == .menuBar)
    #expect(try decode("activityEnd", #"{"id":"a"}"#).permission == .liveActivities)
    #expect(try decode("panelShow", #"{"id":"a"}"#).permission == .panels)
    #expect(try decode("scenes.list", #"{"request":1}"#).permission == .scenes)
    #expect(try decode("palette", #"{"id":"a"}"#).permission == nil)
    var limits = PluginHookLimits()
    let bar = { (id: String) in try decode("menuBar", #"{"id":"\#(id)","symbol":"bell"}"#) }
    #expect(limits.admit(try bar("a")) == nil)
    #expect(limits.admit(try bar("b")) == nil)
    #expect(limits.admit(try bar("a")) == nil, "updating is not one more")
    #expect(limits.admit(try bar("c")) != nil, "two menu bar items at most")
    #expect(limits.admit(.menuBarRemove(id: "a")) == nil)
    #expect(limits.admit(try bar("c")) == nil)
}

@Test func newPermissionsAreInManifestsAndTheScan() {
    let (parsed, result) = PluginManifest.parse(Data(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0","permissions":["menuBar","liveActivities","scenes","panels"]}"#.utf8), files: ["main.js"])
    #expect(result.isValid, "\(result.errors)")
    #expect(parsed?.permissions == [.menuBar, .liveActivities, .scenes, .panels])
    for permission in [PluginPermission.menuBar, .liveActivities, .scenes, .panels] {
        #expect(!permission.title.isEmpty && !permission.detail.isEmpty && PluginNode.isSymbolName(permission.symbol))
    }
    let scan = ModScan.scan("atelier.menuBarItem({}); atelier.liveActivity({}); atelier.scenes.list(); atelier.panel({}); atelier.on('panelMessage', f)")
    #expect(scan.used == [.menuBar, .liveActivities, .scenes, .panels])
    #expect(ModScan.scan("atelier.paletteProvider({}); atelier.stackProvider({})").used.isEmpty)
}

@Test func stackValuesAndDockPathsRoundTrip() {
    let value = PluginStackValue(plugin: "com.example.hub", action: "action:stack:pulls:3", symbol: "arrow.triangle.pull", imagePath: nil)
    #expect(PluginStackValue(value.encoded) == value)
    #expect(PluginStackValue("nonsense") == nil)
    let path = PluginDockPath.make(.stack, key: "com.example.hub/pulls")
    #expect(path == "atelier:plugin:stack:com.example.hub/pulls")
    #expect(PluginDockPath.parse(path)?.role == .stack)
    #expect(PluginDockPath.parse(path)?.key == "com.example.hub/pulls")
    #expect(PluginDockPath.parse("atelier:plugin:other:a/b") == nil)
    #expect(PluginDockPath.parse("atelier:clock") == nil)
}

// MARK: - Through the real prelude

/// The prelude with a native side that decodes both kinds of call, like PluginRuntime.
private final class HookHarness {
    let context = JSContext()!
    var calls: [(kind: String, hook: PluginHookMessage?, message: PluginMessage?)] = []
    var errors: [String] = []

    init() {
        context.exceptionHandler = { [unowned self] _, exception in self.errors.append(exception?.toString() ?? "?") }
        let native: @convention(block) (String, String) -> String = { [unowned self] kind, payload in
            if kind.hasPrefix("storage.") { return kind == "storage.keys" ? "[]" : "null" }
            if PluginHookMessage.handles(kind) {
                do { self.calls.append((kind, try PluginHookMessage.decode(kind: kind, payload: payload), nil)); return "null" } catch {
                    self.calls.append((kind, nil, nil))
                    return JSONValue.object(["__error": .string("\(error)")]).text()
                }
            }
            do { self.calls.append((kind, nil, try PluginMessage.decode(kind: kind, payload: payload))); return "null" } catch {
                self.calls.append((kind, nil, nil))
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
    func hooks(_ kind: String) -> [PluginHookMessage] { calls.filter { $0.kind == kind }.compactMap(\.hook) }
    func value(_ expression: String) -> JSValue { context.evaluateScript(expression) }
}

@Test func menuFunctionsBecomeActionKeys() {
    let harness = HookHarness()
    harness.run(#"""
    let picked = "";
    const item = atelier.menuBarItem({ id: "inbox", symbol: "bell", text: "3", menu: [
      { title: "Open", action: () => { picked = "open" } }, "separator",
      { title: "More", submenu: [{ title: "Deep", action: () => { picked = "deep" } }] } ] });
    """#)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    guard case .menuBar(let spec)? = harness.hooks("menuBar").first, case .item(let open) = spec.menu[0],
          case .submenu(_, _, let children) = spec.menu[2], case .item(let deep) = children[0] else { Issue.record("\(harness.calls)"); return }
    harness.call("dispatch", [open.action!, "null"])
    #expect(harness.value("picked").toString() == "open")
    harness.call("dispatch", [deep.action!, "null"])
    #expect(harness.value("picked").toString() == "deep")
    // Replacing the menu drops the old functions.
    harness.run(#"item.update({ menu: [{ title: "New", action: () => { picked = "new" } }] })"#)
    harness.call("dispatch", [open.action!, "null"])
    #expect(harness.value("picked").toString() == "deep", "an old menu's action no longer runs")
    #expect(harness.hooks("menuBar").count == 2)
}

@Test func paletteSearchAnswersWithRows() {
    let harness = HookHarness()
    harness.run(#"""
    let opened = "";
    atelier.paletteProvider({ id: "repos", title: "GitHub", prefix: "gh", search: async (query) =>
      Array.from({ length: 30 }, (_, i) => ({ title: query + " " + i, symbol: "book", action: () => { opened = query + i } })) });
    """#)
    #expect(harness.hooks("palette") == [.palette(PluginPaletteSpec(id: "repos", title: "GitHub", prefix: "gh"))])
    harness.call("ask", ["palette:repos:search", 7, "\"atelier\""])
    guard case .reply(let request, let ok, let value, _)? = harness.hooks("hooks.reply").first else { Issue.record("\(harness.calls)"); return }
    #expect(request == 7 && ok)
    let rows = PluginResultItem.parse(value, limit: PluginPaletteSpec.maxResults)
    #expect(rows.count == 20 && rows[0].title == "atelier 0")
    harness.call("dispatch", [rows[3].action!, "null"])
    #expect(harness.value("opened").toString() == "atelier3")
    harness.call("ask", ["palette:nope:search", 8, "\"x\""])
    if case .reply(_, let failed, _, let error)? = harness.hooks("hooks.reply").last {
        #expect(!failed && error?.contains("Nothing answers") == true)
    }
}

@Test func tileMenusAndDropsAndStacks() {
    let harness = HookHarness()
    harness.run(#"""
    let dropped = null;
    const tile = atelier.dockTile({ id: "hub", symbol: "bell", accepts: ["url"], onDrop: (d) => { dropped = d.kind + " " + d.value },
      menu: [{ title: "Open", action: () => {} }] });
    atelier.dockTile({ id: "plain", symbol: "bell" });
    const stack = atelier.stackProvider({ id: "pulls", title: "Pull Requests", symbol: "arrow.triangle.pull", refresh: 60,
      items: () => [{ title: "Fix", subtitle: "repo #1", action: () => {} }] });
    stack.refresh();
    """#)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    #expect(harness.hooks("tileHooks").count == 1, "a tile without a menu or drops sends nothing extra")
    harness.call("dispatch", ["tile:hub:onDrop", #"{"kind":"url","value":"https://github.com/x"}"#])
    #expect(harness.value("dropped").toString() == "url https://github.com/x")
    #expect(harness.hooks("stack") == [.stack(PluginStackSpec(id: "pulls", title: "Pull Requests", symbol: "arrow.triangle.pull", refresh: 60))])
    #expect(harness.hooks("stackChanged") == [.stackChanged(id: "pulls")])
    harness.call("ask", ["stack:pulls:items", 2, "null"])
    if case .reply(_, true, let value, _)? = harness.hooks("hooks.reply").first {
        #expect(PluginResultItem.parse(value, limit: 60).first?.subtitle == "repo #1")
    } else { Issue.record("no reply") }
}

@Test func scenesActivitiesAndPanelsThroughThePrelude() {
    let harness = HookHarness()
    harness.run(#"""
    let names = null, tapped = 0, heard = null;
    atelier.scenes.list().then((list) => { names = list.map((s) => s.name).join(",") });
    const live = atelier.liveActivity({ id: "focus", title: "Focus", symbol: "timer", text: "25:00", onTap: () => { tapped++ } });
    live.update({ text: "24:59", progress: 0.1 });
    live.end();
    const panel = atelier.panel({ id: "dash", title: "Dash", html: "<p>hi</p>" });
    panel.show(); panel.post({ n: 1 }); panel.hide();
    atelier.on("panelMessage", (m) => { heard = m.id + ":" + m.message.open });
    """#)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    guard case .scenesList(let request)? = harness.hooks("scenes.list").first else { Issue.record(); return }
    harness.call("settle", [request, true, #"{"scenes":[{"name":"Work"},{"name":"Home"}]}"#])
    #expect(harness.value("names").toString() == "Work,Home")
    #expect(harness.hooks("activity").count == 2)
    if case .activity(let spec)? = harness.hooks("activity").last { #expect(spec.text == "24:59" && spec.progress == 0.1) }
    harness.call("dispatch", ["activity:focus:onTap", "null"])
    #expect(harness.value("tapped").toInt32() == 1)
    #expect(harness.hooks("activityEnd") == [.activityEnd(id: "focus")])
    #expect(harness.hooks("panelPost") == [.panelPost(id: "dash", message: .object(["n": .number(1)]))])
    #expect(harness.hooks("panelShow").count == 1 && harness.hooks("panelHide").count == 1)
    harness.call("emit", ["panelMessage", #"{"id":"dash","message":{"open":"x"}}"#])
    #expect(harness.value("heard").toString() == "dash:x")
}

/// The example that uses every hook loads, registers each one, and asks for exactly the
/// permissions its script uses.
@Test func githubHubExampleUsesEveryHook() throws {
    let bundle = repository.appendingPathComponent("examples/plugins/github-hub.atelierplugin")
    let (manifest, result) = PluginManifest.parse(try Data(contentsOf: bundle.appendingPathComponent("manifest.json")), files: ["main.js"])
    #expect(result.isValid && result.warnings.isEmpty, "\(result.issues)")
    let source = try String(contentsOf: bundle.appendingPathComponent("main.js"), encoding: .utf8)
    #expect(ModScan.scan(source).used == Set(manifest?.permissions ?? []))
    let harness = HookHarness()
    harness.run(source)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    for kind in ["palette", "menuBar", "tile", "tileHooks", "stack", "panel", "on"] {
        #expect(harness.calls.contains { $0.kind == kind && ($0.hook != nil || $0.message != nil) }, "should send \(kind)")
    }
    #expect(harness.calls.allSatisfy { $0.hook != nil || $0.message != nil }, "refused: \(harness.calls.filter { $0.hook == nil && $0.message == nil }.map(\.kind))")
}
