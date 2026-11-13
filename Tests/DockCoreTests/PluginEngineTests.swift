import Foundation
import JavaScriptCore
import Testing
@testable import DockCore

// The plugin engine's newer parts: interactive views, settings, activation, messaging,
// strings, assets, more http methods, safe mode and the resource meter.

private func node(_ json: String) throws -> PluginNode { try PluginNode.parse(try JSONValue.parse(json)) }

private func manifest(_ extra: String) -> (PluginManifest?, ThemeValidation) {
    PluginManifest.parse(Data(#"{"format":1,"id":"com.example.x","name":"X","version":"1.0.0"\#(extra)}"#.utf8), files: ["main.js"])
}

// MARK: - Views

@Test func interactiveViewsParse() throws {
    #expect(try node(#"{"type":"button","title":"Go","symbol":"play.fill","action":"go"}"#)
            == .button(PluginButton(title: "Go", symbol: "play.fill", style: .prominent, action: "go")))
    #expect(try node(#"{"type":"button","symbol":"gear","style":"plain","action":"_w.0"}"#)
            == .button(PluginButton(title: "", symbol: "gear", style: .plain, action: "_w.0")))
    #expect(try node(#"{"type":"toggle","label":"Sound","on":true,"action":"sound"}"#) == .toggle(label: "Sound", on: true, action: "sound"))
    #expect(throws: PluginFailure.self) { try node(#"{"type":"button","title":"Go"}"#) }
    #expect(throws: PluginFailure.self) { try node(#"{"type":"button","title":"Go","action":"has space"}"#) }
    #expect(throws: PluginFailure.self) { try node(#"{"type":"button","action":"x"}"#) }
    #expect(throws: PluginFailure.self) { try node(#"{"type":"toggle","label":"x"}"#) }
}

@Test func imagesNeedAnAssetOrHTTPS() throws {
    #expect(try node(#"{"type":"image","asset":"art/icon.png","width":999,"radius":8,"fit":"fill"}"#)
            == .image(PluginImage(source: .asset("art/icon.png"), width: 600, height: nil, fit: .fill, radius: 8)))
    #expect(try node(#"{"type":"image","url":"https://example.com/a.png"}"#)
            == .image(PluginImage(source: .url(URL(string: "https://example.com/a.png")!), width: nil, height: nil, fit: .fit, radius: 0)))
    for bad in [#"{"type":"image","asset":"../secret.png"}"#, #"{"type":"image","asset":"/etc/a.png"}"#,
                #"{"type":"image","asset":"main.js"}"#, #"{"type":"image","asset":".hidden.png"}"#,
                #"{"type":"image","url":"http://example.com/a.png"}"#, #"{"type":"image","url":"file:///a.png"}"#,
                #"{"type":"image"}"#] {
        #expect(throws: PluginFailure.self, "\(bad)") { try node(bad) }
    }
}

@Test func chartsGridsProgressAndDividers() throws {
    let chart = try node(#"{"type":"chart","kind":"line","series":[{"label":"A","values":[1,2,"x",3],"color":"mint"}],"labels":["a","b"],"max":-4}"#)
    #expect(chart == .chart(PluginChart(kind: .line, series: [.init(label: "A", values: [1, 2, 3], color: .named("mint"))], labels: ["a", "b"], max: nil)))
    let short = try node(#"{"type":"chart","values":[4,5]}"#)
    if case .chart(let c) = short { #expect(c.kind == .bar && c.series.count == 1 && c.series[0].values == [4, 5]) } else { Issue.record("not a chart") }
    let long = try PluginNode.parse(.object(["type": .string("chart"), "values": .array((0..<500).map { .number(Double($0)) })]))
    if case .chart(let c) = long { #expect(c.series[0].values.count == PluginChart.maxValues) }
    let many = JSONValue.object(["type": .string("chart"), "series": .array((0..<9).map { _ in .object(["values": .array([.number(1)])]) })])
    #expect(throws: PluginFailure.self) { try PluginNode.parse(many) }
    #expect(try node(#"{"type":"grid","columns":9,"children":["a","b"]}"#) == .grid(columns: 6, [.text("a", PluginTextStyle()), .text("b", PluginTextStyle())]))
    #expect(try node(#"{"type":"progress","value":2,"label":"Up"}"#) == .progress(value: 1, label: "Up", color: nil))
    #expect(try node(#"{"type":"divider"}"#) == .divider)
}

@Test func stacksCanAnimate() throws {
    let faded = try node(#"{"type":"vstack","transition":"fade","children":["a"]}"#)
    guard case .transition(.fade, .stack(.vertical, _, _, let children)) = faded else { Issue.record("\(faded)"); return }
    #expect(children.count == 1)
    // An unknown transition is ignored, not an error, and plain stacks stay plain.
    if case .stack = try node(#"{"type":"hstack","transition":"spin","children":[]}"#) {} else { Issue.record("expected a plain stack") }
}

@Test func viewBudgetIsTwoHundredForty() throws {
    let fits = JSONValue.array((0..<(PluginNode.maxNodes - 1)).map { _ in .string("x") })
    #expect(throws: Never.self) { try PluginNode.parse(fits) }
    let over = JSONValue.array((0..<PluginNode.maxNodes).map { _ in .string("x") })
    #expect(throws: PluginFailure.self) { try PluginNode.parse(over) }
    #expect(PluginNode.maxNodes == 240)
}

@Test func treesReportTheirActionsAndImages() throws {
    let tree = try node(#"{"type":"vstack","transition":"slide","children":[{"type":"button","title":"A","action":"a"},{"type":"grid","children":[{"type":"toggle","label":"B","action":"b"},{"type":"image","asset":"i.png"}]}]}"#)
    #expect(tree.actions == ["a", "b"])
    #expect(tree.images.map(\.source) == [.asset("i.png")])
}

// MARK: - Bridge calls

@Test func httpSendDecodes() throws {
    let post = try PluginMessage.decode(kind: "httpSend", payload: #"{"request":2,"method":"post","url":"https://api.example.com/x","json":{"a":1},"headers":{"Cookie":"no"}}"#)
    #expect(post == .httpSend(request: 2, method: "POST", url: URL(string: "https://api.example.com/x")!, headers: ["Content-Type": "application/json"], body: #"{"a":1}"#))
    let put = try PluginMessage.decode(kind: "httpSend", payload: #"{"request":3,"method":"PUT","url":"https://a.example.com/","body":"x=1","headers":{"Content-Type":"text/plain"}}"#)
    #expect(put == .httpSend(request: 3, method: "PUT", url: URL(string: "https://a.example.com/")!, headers: ["Content-Type": "text/plain"], body: "x=1"))
    #expect(throws: PluginFailure.self) { try PluginMessage.decode(kind: "httpSend", payload: #"{"request":1,"method":"TRACE","url":"https://a.example.com/"}"#) }
    #expect(throws: PluginFailure.self) { try PluginMessage.decode(kind: "httpSend", payload: #"{"request":1,"method":"POST","url":"https://a.example.com/","body":{"a":1}}"#) }
}

@Test func sendNeedsAnIdAndStaysSmall() throws {
    #expect(try PluginMessage.decode(kind: "send", payload: #"{"to":"com.example.timer","payload":{"n":1}}"#)
            == .send(to: "com.example.timer", payload: .object(["n": .number(1)])))
    #expect(throws: PluginFailure.self) { try PluginMessage.decode(kind: "send", payload: #"{"to":"nope","payload":1}"#) }
    let big = JSONValue.object(["to": .string("com.example.timer"), "payload": .string(String(repeating: "x", count: 70_000))])
    #expect(throws: PluginFailure.self) { try PluginMessage.decode(kind: "send", big) }
}

@Test func newEventsCanBeSubscribed() throws {
    for event in ["update", "settingsChanged", "message", "sleep", "wake", "screensLocked", "screensUnlocked", "displaysChanged", "powerSource"] {
        let message = try PluginMessage.decode(kind: "on", payload: #"{"event":"\#(event)"}"#)
        #expect(message == .subscribe(PluginEvent(rawValue: event)!, interval: nil))
    }
}

// MARK: - Manifest

@Test func settingsParseStrictly() {
    let (parsed, result) = manifest(##","settings":[{"key":"focus","type":"number","title":"Focus","default":25,"min":1,"max":120},{"key":"token","type":"secret","title":"Token"},{"key":"mode","type":"choice","title":"Mode","options":["a",{"value":"b","title":"Bee"}],"default":"b"},{"key":"tint","type":"color","title":"Tint","default":"#ff0000"},{"key":"keys","type":"hotkeyHint","title":"Keys","default":"Shift+Cmd+K"}]"##)
    #expect(result.isValid, "\(result.errors)")
    #expect(result.warnings.isEmpty)
    #expect(parsed?.settings.map(\.key) == ["focus", "token", "mode", "tint", "keys"])
    #expect(parsed?.setting("mode")?.options.last == PluginSetting.Option(value: "b", title: "Bee"))
    #expect(parsed?.setting("tint")?.defaultValue == .string("#FF0000"))
    #expect(parsed?.setting("keys")?.defaultValue == .string("cmd+shift+k"))

    let cases: [(String, String)] = [
        (#"[{"key":"a","type":"slider","title":"A"}]"#, "settings[0].type"),
        (#"[{"key":"a b","type":"text","title":"A"}]"#, "settings[0].key"),
        (#"[{"key":"a","type":"text"}]"#, "settings[0].title"),
        (#"[{"key":"a","type":"number","title":"A","default":"x"}]"#, "settings[0].default"),
        (#"[{"key":"a","type":"number","title":"A","default":200,"max":100}]"#, "settings[0].default"),
        (#"[{"key":"a","type":"secret","title":"A","default":"hunter2"}]"#, "settings[0].default"),
        (#"[{"key":"a","type":"choice","title":"A"}]"#, "settings[0].options"),
        (#"[{"key":"a","type":"text","title":"A"},{"key":"a","type":"text","title":"B"}]"#, "settings[1].key"),
        (#"{"key":"a"}"#, "settings"),
    ]
    for (json, path) in cases {
        let (_, bad) = manifest(#","settings":"# + json)
        #expect(bad.errors.first?.path == path, "\(json): \(bad.errors)")
    }
    let tooMany = "[" + (0...PluginSetting.maxCount).map { #"{"key":"k\#($0)","type":"text","title":"T"}"# }.joined(separator: ",") + "]"
    #expect(!manifest(#","settings":"# + tooMany).1.isValid)
}

@Test func settingValuesAreCheckedByType() {
    let number = PluginSetting(key: "n", kind: .number, title: "N", min: 1, max: 10)
    #expect(number.check(.number(5)) == .success(.number(5)))
    #expect(number.check(.number(11)) != .success(.number(11)))
    #expect(number.check(.string("5")) != .success(.string("5")))
    #expect(number.check(.number(.infinity)) != .success(.number(.infinity)))
    #expect(number.check(.null) == .success(.null))
    let flag = PluginSetting(key: "f", kind: .toggle, title: "F")
    #expect(flag.check(.bool(true)) == .success(.bool(true)))
    #expect(flag.check(.number(1)) != .success(.number(1)))
    let text = PluginSetting(key: "t", kind: .text, title: "T")
    #expect(text.check(.string(String(repeating: "x", count: PluginSetting.maxText + 1))) != .success(.null))
    let color = PluginSetting(key: "c", kind: .color, title: "C")
    #expect(color.check(.string("#00ff00")) == .success(.string("#00FF00")))
    #expect(color.check(.string("green")) != .success(.string("green")))
    let hint = PluginSetting(key: "h", kind: .hotkeyHint, title: "H")
    #expect(hint.check(.string("opt+space")) == .success(.string("opt+space")))
    #expect(hint.check(.string("p")) != .success(.string("p")))
    let choice = PluginSetting(key: "m", kind: .choice, title: "M", options: [.init(value: "a", title: "A")])
    #expect(choice.check(.string("a")) == .success(.string("a")))
    #expect(choice.check(.string("z")) != .success(.string("z")))
    #expect(PluginSetting(key: "s", kind: .secret, title: "S").storageKey == "settings.s")
}

@Test func activationAndContributions() {
    let legacy = manifest("").0
    #expect(legacy?.activation == nil)
    #expect(legacy?.startsOnDemand == false, "plugins without activation start as before")
    #expect(manifest(#","activation":["onStartup","onCommand"]"#).0?.startsOnDemand == false)

    let (lazy, result) = manifest(#","activation":["onCommand","onWidgetVisible","onEvent:wake","onTimer"],"contributes":{"timer":10,"commands":[{"id":"go","title":"Go"}],"widgets":[{"id":"w","title":"W","size":"medium"}],"tiles":[{"id":"t","title":"T","symbol":"timer"}],"cornerActions":[{"id":"c","title":"C"}]}"#)
    #expect(result.isValid, "\(result.errors)")
    #expect(lazy?.startsOnDemand == true)
    #expect(lazy?.activation == [.onCommand, .onWidgetVisible, .onEvent(.wake), .onTimer])
    #expect(lazy?.contributes.commands == [PluginCommandSpec(id: "go", title: "Go", subtitle: nil, shortcut: nil)])
    #expect(lazy?.contributes.widgets.first?.size == .medium)
    #expect(lazy?.contributes.tiles.first?.symbol == "timer")
    #expect(lazy?.contributes.corners.first?.symbol == "puzzlepiece.extension")
    #expect(lazy?.contributes.timer == 60, "woken at most once a minute")

    #expect(manifest(#","activation":["onBoot"]"#).1.errors.first?.path == "activation[0]")
    #expect(manifest(#","activation":["onEvent:nope"]"#).1.errors.first?.path == "activation[0]")
    #expect(manifest(#","activation":[]"#).1.errors.first?.path == "activation")
    #expect(manifest(#","activation":["onTimer"]"#).1.errors.first?.path == "contributes.timer")
    #expect(manifest(#","contributes":{"commands":[{"id":"go"}]}"#).1.errors.first?.path == "contributes.commands[0]")
}

@Test func messagingNeedsBothSides() {
    var a = PluginManifest(id: "com.example.a", name: "A", version: "1.0.0")
    var b = PluginManifest(id: "com.example.b", name: "B", version: "1.0.0")
    #expect(!PluginMessaging.allows(from: a, to: b))
    a.messages.send = ["com.example.b"]
    #expect(!PluginMessaging.allows(from: a, to: b), "the receiver has not opted in")
    b.messages.receive = ["com.example.a"]
    #expect(PluginMessaging.allows(from: a, to: b))
    #expect(!PluginMessaging.allows(from: b, to: a), "one direction only")
    let (parsed, result) = manifest(#","messages":{"send":["com.example.b"],"receive":["com.example.c"]}"#)
    #expect(result.isValid)
    #expect(parsed?.messages == PluginMessaging(send: ["com.example.b"], receive: ["com.example.c"]))
    #expect(manifest(#","messages":{"send":["not an id"]}"#).1.errors.first?.path == "messages.send[0]")
}

@Test func stringsPickThePreferredLanguage() {
    let tables = ["en": ["hi": "Hello", "bye": "Bye"], "pt": ["hi": "Olá"], "pt-BR": ["hi": "Oi"], "de": ["hi": "Hallo"]]
    #expect(PluginStrings.pick(tables, preferred: ["pt-BR"]) == ["hi": "Oi", "bye": "Bye"])
    #expect(PluginStrings.pick(tables, preferred: ["pt-PT"]) == ["hi": "Olá", "bye": "Bye"])
    #expect(PluginStrings.pick(tables, preferred: ["fr", "de-AT"]) == ["hi": "Hallo", "bye": "Bye"])
    #expect(PluginStrings.pick(tables, preferred: ["ja"]) == ["hi": "Hello", "bye": "Bye"])
    #expect(PluginStrings.format("{n} of {total}", ["n": .number(3), "total": .number(5)]) == "3 of 5")
    #expect(manifest(#","strings":{"en":{"a":"A"},"x!":{"a":"b"}}"#).1.errors.first?.path == "strings.x!")
    #expect(manifest(#","strings":{"en":{"a":1}}"#).1.errors.first?.path == "strings.en.a")
}

@Test func assetsStayInsideThePlugin() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("atelier-assets-\(UUID().uuidString)")
    let plugin = root.appendingPathComponent("p.atelierplugin")
    try FileManager.default.createDirectory(at: plugin.appendingPathComponent("art"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0x89, 0x50]).write(to: plugin.appendingPathComponent("art/icon.png"))
    try Data(count: PluginAssets.maxBytes + 1).write(to: plugin.appendingPathComponent("big.png"))
    try Data([1]).write(to: root.appendingPathComponent("outside.png"))
    try FileManager.default.createSymbolicLink(at: plugin.appendingPathComponent("link.png"), withDestinationURL: root.appendingPathComponent("outside.png"))

    #expect((try? PluginAssets.resolve("art/icon.png", in: plugin).get()) != nil)
    #expect((try? PluginAssets.resolve("big.png", in: plugin).get()) == nil, "over 2 MB")
    #expect((try? PluginAssets.resolve("link.png", in: plugin).get()) == nil, "a link out of the folder")
    #expect((try? PluginAssets.resolve("../outside.png", in: plugin).get()) == nil)
    #expect((try? PluginAssets.resolve("missing.png", in: plugin).get()) == nil)
    #expect(!PluginAssets.isValidPath("art/icon.svg"))
    #expect(PluginAssets.isValidPath("art/Photo.HEIC"))
}

// MARK: - Safe mode, meter, idle

@Test func safeModeAfterTwoCrashesInARow() {
    var streak = 0
    streak = PluginSafeMode.streak(previous: streak, lastRunCrashed: true, pluginsWereRunning: true)
    #expect(streak == 1 && !PluginSafeMode.isSafe(streak: streak))
    streak = PluginSafeMode.streak(previous: streak, lastRunCrashed: true, pluginsWereRunning: true)
    #expect(PluginSafeMode.isSafe(streak: streak))
    #expect(PluginSafeMode.streak(previous: 1, lastRunCrashed: true, pluginsWereRunning: false) == 0, "no plugins ran: not theirs")
    #expect(PluginSafeMode.streak(previous: 1, lastRunCrashed: false, pluginsWereRunning: true) == 0, "a clean run resets it")
}

@Test func meterCountsTheLastMinute() {
    var meter = PluginMeter()
    let now = Date()
    meter.record(at: now.addingTimeInterval(-90), seconds: 0.5)
    meter.record(at: now.addingTimeInterval(-10), seconds: 0.02)
    meter.record(at: now, seconds: 0.03)
    let snapshot = meter.snapshot(at: now)
    #expect(snapshot.callsPerMinute == 2)
    #expect(abs(snapshot.millisecondsPerMinute - 50) < 0.001)
    #expect(snapshot.lastCall == now)
}

@Test func idlePluginsSleepAfterTenMinutes() {
    let now = Date()
    let old = now.addingTimeInterval(-PluginIdle.limit - 1)
    #expect(PluginIdle.canSleep(timers: 0, visibleWidgets: 0, pendingRequests: 0, lastCall: old, now: now))
    #expect(!PluginIdle.canSleep(timers: 0, visibleWidgets: 0, pendingRequests: 0, lastCall: now.addingTimeInterval(-60), now: now))
    #expect(!PluginIdle.canSleep(timers: 1, visibleWidgets: 0, pendingRequests: 0, lastCall: old, now: now))
    #expect(!PluginIdle.canSleep(timers: 0, visibleWidgets: 1, pendingRequests: 0, lastCall: old, now: now))
    #expect(!PluginIdle.canSleep(timers: 0, visibleWidgets: 0, pendingRequests: 1, lastCall: old, now: now))
}

// MARK: - The prelude, end to end

@Test func inlineActionsGetIdsAndCallBack() {
    let harness = Harness()
    harness.run("""
    let taps = 0, last = null;
    atelier.action("named", () => { taps += 10 });
    atelier.widget({ id: "w", view: () => atelier.ui.vstack([
      atelier.ui.button("Go", () => { taps += 1 }),
      atelier.ui.toggle("On", false, (p) => { last = p.on }),
      atelier.ui.button("Named", "named", { style: "plain" }),
    ]) });
    """)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    harness.call("render", ["w"])
    guard case .widgetView(_, let view)? = harness.messages("widgetView").last else { Issue.record("no view"); return }
    #expect(view.actions == ["_w.0", "_w.1", "named"])
    harness.call("dispatch", ["action:_w.0", "null"])
    harness.call("dispatch", ["action:_w.1", #"{"on":true}"#])
    harness.call("dispatch", ["action:named", "null"])
    #expect(harness.context.evaluateScript("taps").toInt32() == 11)
    #expect(harness.context.evaluateScript("last").toBool() == true)
    // A new render binds the fresh inline functions under the same ids.
    harness.call("render", ["w"])
    harness.call("dispatch", ["action:_w.0", "null"])
    #expect(harness.context.evaluateScript("taps").toInt32() == 12)
    harness.run(#"try { atelier.action("bad id", () => {}) } catch (e) { var refused = true }"#)
    #expect(harness.context.evaluateScript("refused").toBool() == true)
}

@Test func settingsStringsAndAssetsFromTheScript() throws {
    let parsed = manifest(#","settings":[{"key":"n","type":"number","title":"N","default":3,"max":9}],"strings":{"en":{"hi":"Hello {name}"}}"#).0
    let harness = Harness(manifest: parsed)
    harness.run("""
    var a = atelier.settings.get("n");
    atelier.settings.set("n", 7);
    var b = atelier.settings.get("n");
    var refused = ""; try { atelier.settings.set("n", 99) } catch (e) { refused = e.message }
    var missing = ""; try { atelier.settings.get("zzz") } catch (e) { missing = e.message }
    var all = atelier.settings.all().n;
    var hi = atelier.t("hi", { name: "Ana" }), raw = atelier.t("nope");
    var asset = atelier.asset("art/a.png");
    """)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    #expect(harness.context.evaluateScript("a").toInt32() == 3)
    #expect(harness.context.evaluateScript("b").toInt32() == 7)
    #expect(harness.context.evaluateScript("all").toInt32() == 7)
    #expect(harness.context.evaluateScript("refused").toString().contains("at most 9"))
    #expect(!harness.context.evaluateScript("missing").toString().isEmpty)
    #expect(harness.context.evaluateScript("hi").toString() == "Hello Ana")
    #expect(harness.context.evaluateScript("raw").toString() == "nope")
    #expect(harness.context.evaluateScript("asset").toString() == "art/a.png")
    #expect(harness.store.values["settings.n"] == .number(7))
}

@Test func postSendAndLifecycleFromTheScript() {
    let harness = Harness()
    harness.run("""
    let posted = null, got = null, updated = null;
    atelier.http.post("https://api.example.com/items", { json: { name: "x" } }).then(r => { posted = r.status });
    atelier.send("com.example.other", { hello: 1 });
    atelier.on("message", (m) => { got = m.from + ":" + m.payload.hello });
    atelier.on("update", (v) => { updated = v.from + ">" + v.to });
    """)
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    guard case .httpSend(let request, "POST", _, let headers, let body)? = harness.messages("httpSend").first else { Issue.record("no post"); return }
    #expect(headers["Content-Type"] == "application/json" && body == #"{"name":"x"}"#)
    harness.call("settle", [request, true, #"{"status":201,"ok":true,"text":""}"#])
    #expect(harness.context.evaluateScript("posted").toInt32() == 201)
    #expect(harness.messages("send") == [.send(to: "com.example.other", payload: .object(["hello": .number(1)]))])
    harness.call("emit", ["message", #"{"from":"com.example.other","payload":{"hello":2}}"#])
    harness.call("emit", ["update", #"{"from":"1.0.0","to":"1.1.0"}"#])
    #expect(harness.context.evaluateScript("got").toString() == "com.example.other:2")
    #expect(harness.context.evaluateScript("updated").toString() == "1.0.0>1.1.0")
}

@Test func pomodoroExampleUsesTheNewAPI() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundle = repository.appendingPathComponent("examples/plugins/pomodoro.atelierplugin")
    let (parsed, result) = PluginManifest.parse(try Data(contentsOf: bundle.appendingPathComponent("manifest.json")), files: ["main.js"])
    #expect(result.isValid && result.warnings.isEmpty, "\(result.issues)")
    #expect(parsed?.version == "1.1.0")
    #expect(parsed?.settings.map(\.key) == ["focus", "break", "notify"])
    let harness = Harness(manifest: parsed)
    harness.run(try String(contentsOf: bundle.appendingPathComponent("main.js"), encoding: .utf8))
    harness.call("render", ["focus"])
    #expect(harness.errors.isEmpty, "\(harness.errors)")
    guard case .widgetView(_, let view)? = harness.messages("widgetView").last else { Issue.record("no view"); return }
    #expect(view.actions.count == 2, "start/pause and reset buttons")
    func has(_ match: (PluginNode) -> Bool, in node: PluginNode) -> Bool {
        if match(node) { return true }
        switch node {
        case .stack(_, _, _, let children), .grid(_, let children): return children.contains { has(match, in: $0) }
        case .transition(_, let inner): return has(match, in: inner)
        default: return false
        }
    }
    #expect(has({ if case .chart = $0 { true } else { false } }, in: view))
    // Changing the focus length while paused resets the timer to it.
    harness.run(#"atelier.settings.set("focus", 50)"#)
    harness.call("emit", ["settingsChanged", #"{"key":"focus","value":50}"#])
    #expect(harness.messages("tile").last.map { if case .tile(let spec) = $0 { spec.text == "50:00" } else { false } } == true)
}
