import Foundation
import WebKit

/// Reads what a bridge needs from a website the user signs in on, in the app's web view: its
/// cookies, its local storage and what the bridge's script finds, so the user never copies
/// cookies. The page runs in a data store of its own, kept only while the sign-in lasts.
@MainActor
public final class WebsiteLoginReader: NSObject, WKNavigationDelegate {
    public let webView: WKWebView
    private let step: NetworkLoginStep.Website
    private let done: Regex<AnyRegexOutput>?
    /// Everything the bridge needs was read, and the page is the one after signing in.
    private let finished: ([String: String]) -> Void
    private var values: [String: String] = [:]
    private var reading: Task<Void, Never>?
    private var isFinished = false

    public init(step: NetworkLoginStep.Website, finished: @escaping ([String: String]) -> Void) {
        self.step = step
        self.finished = finished
        done = step.doneURLPattern.flatMap { pattern in bestEffort("website sign-in: the bridge's done pattern") { try Regex(pattern) } }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.customUserAgent = step.userAgent
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Opens the page, and reads it until it has what the bridge needs.
    public func start() {
        webView.load(URLRequest(url: step.url))
        reading = Task { [weak self] in
            // the cookies of a page's own requests (no navigation) come without a delegate call.
            while !Task.isCancelled {
                await self?.read()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        reading?.cancel()
        reading = nil
        webView.stopLoading()
    }

    /// What was read so far has every field the bridge needs: the user may finish by hand where
    /// the page never reaches the address the bridge waits for.
    public var hasRequired: Bool {
        step.fields.allSatisfy { !$0.required || values[$0.id] != nil }
    }

    /// What was read so far.
    public var readValues: [String: String] { values }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await read() }
    }

    private func read() async {
        guard !isFinished else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var scripted: [String: String] = [:]
        if let extract = step.extractJS, !extract.isEmpty {
            scripted = await evaluate(extract)
        }
        for field in step.fields where values[field.id] == nil {
            for source in field.sources {
                if let value = await value(of: source, cookies: cookies, scripted: scripted), !value.isEmpty {
                    values[field.id] = value
                    break
                }
            }
        }
        guard hasRequired, isAtDone else { return }
        isFinished = true
        stop()
        finished(values)
    }

    /// The page is where the bridge waits for it, or the bridge waits for no page.
    private var isAtDone: Bool {
        guard let done else { return true }
        guard let url = webView.url?.absoluteString else { return false }
        return url.firstMatch(of: done) != nil
    }

    private func value(of source: NetworkLoginStep.Website.Source, cookies: [HTTPCookie], scripted: [String: String]) async -> String? {
        switch source {
        case .cookie(let name, let domain):
            return cookies.first { cookie in
                cookie.name == name && domain.map { Self.domain(cookie.domain, isIn: $0) } != false
            }?.value
        case .localStorage(let name):
            guard let key = bestEffort("website sign-in: quote a key", { String(decoding: try JSONEncoder().encode(name), as: UTF8.self) })
            else { return nil }
            return await bestEffort("website sign-in: local storage") {
                try await webView.evaluateJavaScript("window.localStorage.getItem(\(key))")
            } as? String
        case .script(let name):
            return scripted[name]
        case .unreadable:
            return nil
        }
    }

    /// The bridge's script: a promise of the fields it finds, as an object of strings.
    private func evaluate(_ script: String) async -> [String: String] {
        let body = "const result = await (\(script)); return result ? JSON.stringify(result) : null;"
        let object = await bestEffort("website sign-in: the bridge's script") { () async throws -> [String: Any]? in
            guard let json = try await webView.callAsyncJavaScript(body, contentWorld: .defaultClient) as? String else { return nil }
            return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        }
        return (object ?? nil)?.compactMapValues { $0 as? String } ?? [:]
    }

    /// A cookie's domain (`.facebook.com`, `www.facebook.com`) is `domain` or under it.
    nonisolated static func domain(_ cookieDomain: String, isIn domain: String) -> Bool {
        let cookie = cookieDomain.trimmingPrefix(".").lowercased()
        let wanted = domain.trimmingPrefix(".").lowercased()
        return cookie == wanted || cookie.hasSuffix("." + wanted)
    }
}
