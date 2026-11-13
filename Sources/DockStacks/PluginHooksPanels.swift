import AppKit
import DockCore
import WebKit

// HTML panels: a plugin's own small window, showing a page it supplies. The page is sealed off:
//  * no network at all: a content rule list blocks every load but the page's own scheme and
//    inline data, and a Content-Security-Policy (sent as a header and as a meta tag) allows
//    nothing remote, no frames, no forms, no connections;
//  * files only from the plugin's own folder, read-only, through the `atelier-asset:` scheme;
//    no file URLs;
//  * no navigation away from the page, no popups, no camera or microphone, and WebRTC is
//    removed before the page runs;
//  * an ephemeral data store, so nothing is kept between openings;
//  * the page reaches Atelier only through `window.atelier.post(message)` and
//    `window.atelier.onMessage(fn)`, plain JSON up to 64 KB, delivered to its own plugin.

struct PluginPanelKey: Hashable { let plugin: String; let id: String }

@MainActor
final class PluginPanels {
    static let shared = PluginPanels()
    private var panels: [PluginPanelKey: PluginPanelWindow] = [:]
    private static var rules: WKContentRuleList?
    private static var compiling: [@MainActor (WKContentRuleList?) -> Void]?

    func set(_ spec: PluginPanelSpec, plugin: String, pluginName: String, folder: URL) {
        let key = PluginPanelKey(plugin: plugin, id: spec.id)
        if let existing = panels[key] {
            existing.update(spec)
        } else {
            panels[key] = PluginPanelWindow(spec: spec, plugin: plugin, pluginName: pluginName, folder: folder)
        }
    }

    /// False when there is no such panel.
    func show(plugin: String, id: String) -> Bool {
        guard let panel = panels[PluginPanelKey(plugin: plugin, id: id)] else { return false }
        panel.show()
        return true
    }

    func hide(plugin: String, id: String) { panels[PluginPanelKey(plugin: plugin, id: id)]?.orderOut(nil) }

    func post(_ message: JSONValue, plugin: String, id: String) {
        panels[PluginPanelKey(plugin: plugin, id: id)]?.deliver(message)
    }

    func clear(plugin: String) {
        for key in panels.keys where key.plugin == plugin {
            panels.removeValue(forKey: key)?.tearDown()
        }
    }

    func titles(for plugin: String) -> [String] {
        panels.filter { $0.key.plugin == plugin }.map(\.value.spec.title).sorted()
    }

    /// Blocks every load but the panel's own scheme and inline data. Compiled once.
    static func ruleList(_ done: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if let rules { done(rules); return }
        if compiling != nil { compiling?.append(done); return }
        compiling = [done]
        let json = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^atelier-asset:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "atelier-plugin-panels-v1", encodedContentRuleList: json) { list, _ in
            MainActor.assumeIsolated {
                rules = list
                let waiting = compiling ?? []
                compiling = nil
                waiting.forEach { $0(list) }
            }
        }
    }
}

/// The policy every panel page gets. Plugins may add their own, which can only narrow it.
enum PluginPanelPolicy {
    static let scheme = "atelier-asset"
    static let pagePath = "/__panel__.html"
    static let csp = "default-src 'none'; script-src 'unsafe-inline' atelier-asset:; style-src 'unsafe-inline' atelier-asset:; "
        + "img-src atelier-asset: data: blob:; font-src atelier-asset: data:; media-src atelier-asset: data: blob:; "
        + "connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; "
        + "form-action 'none'; base-uri 'none'; manifest-src 'none'"

    /// The page with the policy as its first meta tag, after a doctype if there is one.
    static func page(_ html: String) -> String {
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"><meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">"
        if html.lowercased().hasPrefix("<!doctype"), let end = html.firstIndex(of: ">") {
            return String(html[...end]) + meta + String(html[html.index(after: end)...])
        }
        return meta + html
    }

    /// Runs before the page: the bridge, and WebRTC removed (the policy cannot stop it).
    static let bridge = #"""
    (() => {
      "use strict";
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.atelier;
      for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCSessionDescription", "RTCIceCandidate"]) {
        try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
      }
      const listeners = [];
      Object.defineProperty(window, "atelier", { value: Object.freeze({
        post(message) {
          const text = JSON.stringify(message === undefined ? null : message);
          if (text.length > 65536) throw new Error("A message may be at most 64 KB of JSON.");
          handler.postMessage(text);
        },
        onMessage(fn) {
          if (typeof fn !== "function") throw new TypeError("onMessage takes a function");
          listeners.push(fn);
        },
      }), writable: false, configurable: false });
      Object.defineProperty(window, "__atelierDeliver", { value: (text) => {
        const message = JSON.parse(text);
        for (const fn of listeners) { try { fn(message); } catch (e) { console.error(e); } }
      }, writable: false, configurable: false });
    })();
    """#
}

final class PluginPanelWindow: NSPanel, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private(set) var spec: PluginPanelSpec
    let plugin: String
    let pluginName: String
    private var webView: WKWebView?
    private let assets: PluginAssetHandler
    /// A random host per window, so pages of different panels never share an origin.
    private let host = "p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var queued: [JSONValue] = []
    private var loaded = false
    private var wantsShow = false

    private var pageURL: URL { URL(string: "\(PluginPanelPolicy.scheme)://\(host)\(PluginPanelPolicy.pagePath)")! }

    init(spec: PluginPanelSpec, plugin: String, pluginName: String, folder: URL) {
        self.spec = spec
        self.plugin = plugin
        self.pluginName = pluginName
        self.assets = PluginAssetHandler(folder: folder, page: PluginPanelPolicy.page(spec.html))
        var style: NSWindow.StyleMask = [.titled, .closable, .utilityWindow]
        if spec.resizable { style.insert(.resizable) }
        super.init(contentRect: NSRect(x: 0, y: 0, width: spec.width, height: spec.height), styleMask: style, backing: .buffered, defer: true)
        title = "\(spec.title) \u{2014} \(pluginName)"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        center()
        MainActor.assumeIsolated {
            PluginPanels.ruleList { [weak self] rules in self?.build(rules) }
        }
    }

    @MainActor private func build(_ rules: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(assets, forURLScheme: PluginPanelPolicy.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let content = configuration.userContentController
        if let rules { content.add(rules) }
        content.addUserScript(WKUserScript(source: PluginPanelPolicy.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        content.add(WeakMessageHandler(self), contentWorld: .page, name: "atelier")
        let view = WKWebView(frame: contentRect(forFrameRect: frame), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        view.allowsMagnification = false
        view.setValue(false, forKey: "drawsBackground")
        contentView = view
        webView = view
        // Without its rules the page would not be sealed: it stays blank instead.
        guard rules != nil else {
            PluginRegistry.shared.runtime(plugin)?.note("error", "panel \(spec.id): the panel could not be sealed off from the network, so it was not opened.")
            return
        }
        view.load(URLRequest(url: pageURL))
    }

    @MainActor func update(_ spec: PluginPanelSpec) {
        let pageChanged = spec.html != self.spec.html
        self.spec = spec
        title = "\(spec.title) \u{2014} \(pluginName)"
        if spec.resizable { styleMask.insert(.resizable) } else { styleMask.remove(.resizable) }
        setContentSize(NSSize(width: spec.width, height: spec.height))
        if pageChanged {
            assets.page = PluginPanelPolicy.page(spec.html)
            loaded = false
            if webView?.url != nil || webView != nil { webView?.load(URLRequest(url: pageURL)) }
        }
    }

    @MainActor func show() {
        orderFrontRegardless()
    }

    @MainActor func deliver(_ message: JSONValue) {
        guard loaded, let webView else { queued.append(message); queued = Array(queued.suffix(32)); return }
        webView.callAsyncJavaScript("window.__atelierDeliver(text)", arguments: ["text": message.text()], in: nil, in: .page) { _ in }
    }

    @MainActor func tearDown() {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.stopLoading()
        orderOut(nil)
        contentView = nil
        webView = nil
    }

    // MARK: WKNavigationDelegate — the page itself and nothing else.

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let own = url?.scheme == PluginPanelPolicy.scheme && url?.host() == host && url?.path() == PluginPanelPolicy.pagePath
        let allowed = own && navigationAction.targetFrame?.isMainFrame == true && navigationAction.navigationType == .other
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let waiting = queued
        queued = []
        waiting.forEach(deliver)
    }

    // MARK: WKUIDelegate — no popups, no camera or microphone.

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: Messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        let runtime = PluginRegistry.shared.runtime(plugin)
        guard text.utf8.count <= PluginPanelSpec.maxMessageBytes, let value = try? JSONValue.parse(text) else {
            runtime?.note("warn", "panel \(spec.id): a message from the page was not JSON, or larger than 64 KB, and was dropped.")
            return
        }
        let payload = JSONValue.object(["id": .string(spec.id), "message": value])
        runtime?.emit(.panelMessage, payload: payload)
        runtime?.invoke("panel:\(spec.id):onMessage", payload: value)
    }
}

/// The message handler holds its window weakly: WebKit keeps handlers alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Serves `atelier-asset://<host>/…`: the page from memory, everything else read-only from
/// the plugin's own folder. Nothing outside it, no folders, nothing large.
final class PluginAssetHandler: NSObject, WKURLSchemeHandler {
    let folder: URL
    var page: String
    static let maxFileBytes = 8 * 1024 * 1024
    static let types: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
        "webp": "image/webp", "css": "text/css", "js": "text/javascript", "json": "application/json",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "txt": "text/plain",
    ]

    init(folder: URL, page: String) {
        self.folder = folder
        self.page = page
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let path = url.path()
        let body: Data, type: String
        if path == PluginPanelPolicy.pagePath {
            body = Data(page.utf8)
            type = "text/html; charset=utf-8"
        } else if let data = Self.read(path, in: folder) {
            body = data.0
            type = data.1
        } else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: Self.headers("text/plain"))!)
            task.didReceive(Data())
            task.didFinish()
            return
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: Self.headers(type))!)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func headers(_ type: String) -> [String: String] {
        ["Content-Type": type, "Content-Security-Policy": PluginPanelPolicy.csp, "X-DNS-Prefetch-Control": "off",
         "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"]
    }

    /// A file inside the plugin's folder, by URL path, with its type. Nil for anything else.
    static func read(_ urlPath: String, in folder: URL) -> (Data, String)? {
        let relative = String((urlPath.removingPercentEncoding ?? urlPath).drop { $0 == "/" })
        guard ThemeIdentifier.isSafeRelativePath(relative),
              let type = types[(relative as NSString).pathExtension.lowercased()] else { return nil }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let file = folder.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        var isFolder: ObjCBool = false
        guard file.path.hasPrefix(base + "/"), FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= maxFileBytes,
              let data = try? Data(contentsOf: file) else { return nil }
        return (data, type)
    }
}
