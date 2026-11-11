import DockCore
import Foundation
import JavaScriptCore

/// What a runtime reports to the main thread.
enum PluginSignal: Sendable {
    case message(PluginMessage)
    case log(level: String, text: String)
    /// The script could not start, or stopped responding.
    case failed(String)
    case started
}

/// One plugin's JavaScript world: its own virtual machine and context, on its own serial queue.
/// Nothing in here runs on the main thread, and nothing from the main thread touches the
/// context: calls arrive as `invoke`, results leave through `signal`, which hops to main.
///
/// Thread safety: every stored property below except the `let`s is read and written only on
/// `queue`. That is the whole contract behind `@unchecked Sendable`.
final class PluginRuntime: @unchecked Sendable {
    let manifest: PluginManifest
    let folder: URL
    let granted: Set<PluginPermission>
    private let queue: DispatchQueue
    private let signal: @Sendable (PluginSignal) -> Void

    private var machine: JSVirtualMachine?
    private var context: JSContext?
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var refreshers: [String: DispatchSourceTimer] = [:]
    private var eventTimers: [DispatchSourceTimer] = []
    private var storage: PluginStorage
    private var storageDirty = false
    private var registered = Set<String>()
    private var pendingRequests = 0
    private var stopped = false
    /// Consecutive calls that hit the time limit. Three in a row and the plugin is stopped.
    private var timeouts = 0
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Atelier-Plugin/\(PluginPrelude.apiVersion) (\(manifest.id))"]
        return URLSession(configuration: configuration)
    }()

    /// Each entry into the script may run this long before JavaScriptCore stops it.
    static let callLimit: Double = 1.0
    static let maxConcurrentRequests = 4
    static let maxResponseBytes = 2 * 1024 * 1024

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/PluginData", isDirectory: true)
    }
    private var storageURL: URL { Self.dataFolder.appendingPathComponent(manifest.id + ".json") }

    init(manifest: PluginManifest, folder: URL, granted: Set<PluginPermission>, signal: @escaping @Sendable (PluginSignal) -> Void) {
        self.manifest = manifest
        self.folder = folder
        self.granted = granted.intersection(manifest.permissions)
        self.signal = signal
        self.queue = DispatchQueue(label: "atelier.plugin." + manifest.id, qos: .utility)
        self.storage = PluginStorage()
    }

    // MARK: Lifecycle

    func start() { queue.async { self.boot() } }

    func stop() {
        queue.async {
            self.stopped = true
            self.flushStorage()
            self.timers.values.forEach { $0.cancel() }
            self.refreshers.values.forEach { $0.cancel() }
            self.eventTimers.forEach { $0.cancel() }
            self.timers = [:]; self.refreshers = [:]; self.eventTimers = []
            self.session.invalidateAndCancel()
            self.context = nil
            self.machine = nil
        }
    }

    private func boot() {
        let script = folder.appendingPathComponent(manifest.entry)
        guard let data = try? Data(contentsOf: script), data.count <= PluginManifest.maxScriptBytes,
              let source = String(data: data, encoding: .utf8) else {
            signal(.failed("Couldn’t read \(manifest.entry), or it is larger than \(PluginManifest.maxScriptBytes / 1024) KB."))
            return
        }
        storage = (try? Data(contentsOf: storageURL)).map(PluginStorage.init(data:)) ?? PluginStorage()
        guard let machine = JSVirtualMachine(), let context = JSContext(virtualMachine: machine) else {
            signal(.failed("JavaScriptCore is unavailable."))
            return
        }
        self.machine = machine
        self.context = context
        context.name = manifest.name
        Self.limitExecution(of: context, seconds: Self.callLimit)
        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            let text = exception?.toString() ?? "Unknown error"
            if text.contains("JavaScript execution terminated") { self.noteTimeout() }
            let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
            self.signal(.log(level: "error", text: line > 0 ? "\(text) (line \(line))" : text))
        }
        let bridge: @convention(block) (String, String) -> String = { [weak self] kind, payload in
            self?.handle(kind: kind, payload: payload) ?? "null"
        }
        context.setObject(unsafeBitCast(bridge, to: AnyObject.self), forKeyedSubscript: "__atelierNative" as NSString)
        context.evaluateScript(PluginPrelude.source, withSourceURL: URL(string: "atelier://prelude.js"))
        context.evaluateScript(source, withSourceURL: script)
        signal(.started)
    }

    /// JavaScriptCore's watchdog. The function is exported by the framework but declared only
    /// in its private header, so it is looked up at runtime. Without it, a script that loops
    /// forever blocks only its own queue: Atelier stays responsive and the plugin can be
    /// turned off, but that queue's thread stays busy until Atelier quits.
    private static func limitExecution(of context: JSContext, seconds: Double) {
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit"),
              let global = context.jsGlobalContextRef else { return }
        let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
        setLimit(JSContextGetGroup(global), seconds, nil, nil)
    }

    private func noteTimeout() {
        timeouts += 1
        signal(.log(level: "error", text: "A call ran longer than \(Self.callLimit) s and was stopped."))
        if timeouts >= 3 {
            signal(.failed("Stopped after running too long three times in a row."))
        }
    }

    // MARK: Calls in

    /// Runs `__atelier.<method>(args…)` on the plugin's queue.
    private func enter(_ method: String, _ arguments: [any Sendable]) {
        queue.async {
            guard !self.stopped, let context = self.context,
                  let target = context.objectForKeyedSubscript("__atelier")?.objectForKeyedSubscript(method) else { return }
            target.call(withArguments: arguments.map { $0 as Any })
            if context.exception == nil { self.timeouts = 0 }
            context.exception = nil
            self.scheduleFlush()
        }
    }

    func invoke(_ key: String, payload: JSONValue = .null) { enter("dispatch", [key, payload.text()]) }
    func render(widget id: String) { enter("render", [id]) }
    func emit(_ event: PluginEvent, payload: JSONValue) { enter("emit", [event.rawValue, payload.text()]) }
    /// Answers a pending promise, such as `atelier.prompt`.
    func settle(_ request: Int, ok: Bool, payload: JSONValue) { enter("settle", [request, ok, payload.text()]) }

    // MARK: Calls out (always on `queue`, from inside the script)

    private func handle(kind: String, payload: String) -> String {
        if kind.hasPrefix("storage.") { return handleStorage(kind, payload) }
        let message: PluginMessage
        do { message = try PluginMessage.decode(kind: kind, payload: payload) } catch {
            return Self.error(error.description)
        }
        switch message {
        case .widget(let spec):
            guard register("widget:" + spec.id) else { return Self.tooMany }
            scheduleRefresh(spec)
            enter("render", [spec.id])
        case .tile(let spec):
            guard register("tile:" + spec.id) else { return Self.tooMany }
        case .command(let spec):
            guard register("command:" + spec.id) else { return Self.tooMany }
        case .corner(let spec):
            guard register("corner:" + spec.id) else { return Self.tooMany }
        case .subscribe(let event, let interval):
            if event == .timer, let interval { scheduleEventTimer(interval) }
        case .notify:
            guard granted.contains(.notifications) else { return Self.error(PluginFailure.permission("notifications").description) }
        case .openURL:
            guard granted.contains(.openURL) else { return Self.error(PluginFailure.permission("openURL").description) }
        case .themeApply:
            guard granted.contains(.appearance) else { return Self.error(PluginFailure.permission("appearance").description) }
        case .timer(let id, let ms, let repeats):
            setTimer(id: id, milliseconds: ms, repeats: repeats)
            return "null"
        case .clearTimer(let id):
            timers.removeValue(forKey: id)?.cancel()
            return "null"
        case .http(let request, let url, let headers):
            switch PluginNetwork.allows(url, manifest: manifest, granted: granted) {
            case .failure(let failure): return Self.error(failure.description)
            case .success:
                guard pendingRequests < Self.maxConcurrentRequests else { return Self.error("At most \(Self.maxConcurrentRequests) requests at once.") }
                fetch(request: request, url: url, headers: headers)
            }
            return "null"
        case .log(let level, let text):
            signal(.log(level: level, text: text))
            return "null"
        case .widgetView, .widgetError, .prompt:
            break
        }
        signal(.message(message))
        return "null"
    }

    /// Counts each id once, so updating a tile is not a new registration.
    private func register(_ key: String) -> Bool {
        if registered.contains(key) { return true }
        guard registered.count < PluginMessage.maxRegistrations else { return false }
        registered.insert(key)
        return true
    }

    private static let tooMany = error("A plugin may register at most \(PluginMessage.maxRegistrations) widgets, tiles, commands and corner actions.")

    private static func error(_ text: String) -> String {
        JSONValue.object(["__error": .string(text)]).text()
    }

    // MARK: Storage

    private func handleStorage(_ kind: String, _ payload: String) -> String {
        guard let value = try? JSONValue.parse(payload) else { return Self.error("storage: bad arguments.") }
        let key = value["key"]?.string ?? ""
        switch kind {
        case "storage.get": return storage.values[key]?.text() ?? "null"
        case "storage.keys": return JSONValue.array(storage.values.keys.sorted().map(JSONValue.string)).text()
        case "storage.set":
            do { try storage.set(key, value["value"]) } catch { return Self.error(error.description) }
            storageDirty = true
            return "null"
        default: return Self.error("Unknown storage call.")
        }
    }

    private var flushScheduled = false
    private func scheduleFlush() {
        guard storageDirty, !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 1) {
            self.flushScheduled = false
            self.flushStorage()
        }
    }

    private func flushStorage() {
        guard storageDirty else { return }
        storageDirty = false
        try? FileManager.default.createDirectory(at: Self.dataFolder, withIntermediateDirectories: true)
        try? storage.data.write(to: storageURL, options: .atomic)
    }

    // MARK: Timers

    private func makeTimer(after seconds: Double, repeating: Double?, _ fire: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let start = DispatchTime.now() + max(0, seconds)
        if let repeating { timer.schedule(deadline: start, repeating: repeating, leeway: .milliseconds(Int(repeating * 100))) }
        else { timer.schedule(deadline: start, leeway: .milliseconds(20)) }
        timer.setEventHandler(handler: fire)
        timer.resume()
        return timer
    }

    private func setTimer(id: Int, milliseconds: Double, repeats: Bool) {
        timers.removeValue(forKey: id)?.cancel()
        guard timers.count < 64 else { signal(.log(level: "warn", text: "More than 64 timers; this one was ignored.")); return }
        let seconds = milliseconds / 1000
        timers[id] = makeTimer(after: seconds, repeating: repeats ? max(1, seconds) : nil) { [weak self] in
            guard let self else { return }
            if !repeats { self.timers[id] = nil }
            self.enter("fire", [id])
        }
    }

    private func scheduleRefresh(_ spec: PluginWidgetSpec) {
        refreshers.removeValue(forKey: spec.id)?.cancel()
        refreshers[spec.id] = makeTimer(after: spec.refresh, repeating: spec.refresh) { [weak self] in
            self?.enter("render", [spec.id])
        }
    }

    private func scheduleEventTimer(_ interval: Double) {
        guard eventTimers.count < 4 else { return }
        eventTimers.append(makeTimer(after: interval, repeating: interval) { [weak self] in
            self?.enter("emit", [PluginEvent.timer.rawValue, JSONValue.object(["date": .number(Date().timeIntervalSince1970 * 1000)]).text()])
        })
    }

    // MARK: Network

    private func fetch(request: Int, url: URL, headers: [String: String]) {
        pendingRequests += 1
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let started = Date()
        session.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            // A redirect may not leave the listed hosts.
            let finalHost = http?.url?.host()?.lowercased()
            self.queue.async {
                self.pendingRequests -= 1
                let payload: JSONValue, ok: Bool
                if let error {
                    ok = false; payload = .object(["error": .string(error.localizedDescription)])
                } else if let finalHost, !self.manifest.hosts.contains(finalHost) {
                    ok = false; payload = .object(["error": .string("Redirected to \(finalHost), which is not listed in network.hosts.")])
                } else if (data?.count ?? 0) > Self.maxResponseBytes {
                    ok = false; payload = .object(["error": .string("The response was larger than 2 MB.")])
                } else {
                    ok = true
                    let status = http?.statusCode ?? 0
                    payload = .object([
                        "status": .number(Double(status)), "ok": .bool((200..<300).contains(status)),
                        "text": .string(data.map { String(decoding: $0, as: UTF8.self) } ?? ""),
                        "headers": .object(Dictionary((http?.allHeaderFields ?? [:]).compactMap { key, value -> (String, JSONValue)? in
                            guard let key = key as? String, let value = value as? String else { return nil }
                            return (key.lowercased(), .string(value))
                        }, uniquingKeysWith: { first, _ in first })),
                    ])
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                self.signal(.log(level: "debug", text: "GET \(url.absoluteString) → \(ok ? String(http?.statusCode ?? 0) : "failed") in \(ms) ms"))
                self.enter("settle", [request, ok, payload.text()])
            }
        }.resume()
    }
}
