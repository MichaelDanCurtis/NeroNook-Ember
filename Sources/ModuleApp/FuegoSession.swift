import AppKit
import SwiftUI
import WebKit
import ModuleCore
import NookPluginSDK

/// This plugin's own ordinary human web session. No Fuego Desktop, browser,
/// provider or Compute credentials are read, exported or imported.
@MainActor final class FuegoSession: NSObject, FuegoAPI, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    private(set) var endpoint: FuegoServer
    var server: String { endpoint.origin }
    private(set) var webView: WKWebView
    private let windows = PluginWindows()
    var onReady: (() -> Void)?
    var onChange: (() -> Void)?
    private var loaded = false
    private var started = false
    private var diagnosticPage = UUID()
    private var diagnosticNavigating = false
    private var conversationOrigin: EmberConversationReadOrigin
    private var closed = false
    private let conversationReads = EmberConversationReadOwner()
    var conversationOwner: ((HandoffJob) -> UInt64?)?
    private let eventReads = RunEventReadProducerOwner()
    private var eventTicket: RunEventReadProducerOwner.Ticket?
    var eventOwner: ((RunEventReadTarget) -> Bool)?
    init(server: String?) {
        let selection = EmberConversationReadOrigin(saved: server)
        conversationOrigin = selection
        endpoint = selection.endpoint
        let key = "fuegoWebProfile." + endpoint.origin
        let profile = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(profile.uuidString, forKey: key)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // Observe before any page load/read. Notifications carry no credentials.
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }
    func connect() {
        if !started { started = true; webView.load(URLRequest(url: URL(string: server)!)) }
        windows.show("sign-in", title: "Connect Fuego · " + (URL(string: server)?.host ?? ""), size: .init(width: 950, height: 700)) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) { Text("Sign in to Fuego").font(.headline); Text("This sign-in belongs only to the Fuego Nook plugin.").font(.caption).pluginSecondaryText() }
                    Spacer()
                    Button("Use this sign-in") {
                        guard !self.closed, self.loaded, !self.diagnosticNavigating, self.endpoint.contains(self.webView.url) else { return }
                        self.conversationReads.retire(); self.retireEventReads()
                        self.conversationOrigin.selectDisplayed()
                        UserDefaults.standard.set(self.server, forKey: "fuegoServer")
                        self.onReady?(); self.windows.close("sign-in")
                    }
                }.padding(16)
                FuegoSignInWebView(webView: self.webView)
            }
        }
    }
    func restore() {
        guard UserDefaults.standard.bool(forKey: "fuegoConnected") else { return }
        started = true; webView.load(URLRequest(url: URL(string: server)!))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        conversationReads.retire(); retireEventReads()
        diagnosticPage = UUID(); diagnosticNavigating = false
        loaded = endpoint.contains(webView.url)
        if loaded { onReady?() }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        conversationReads.retire(); retireEventReads()
        diagnosticPage = UUID(); diagnosticNavigating = true
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.targetFrame != nil && endpoint.contains(action.request.url) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { conversationReads.retire(); retireEventReads(); diagnosticPage = UUID(); diagnosticNavigating = false; loaded = false; onChange?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { conversationReads.retire(); retireEventReads(); diagnosticPage = UUID(); diagnosticNavigating = false; loaded = false; onChange?() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { conversationReads.retire(); retireEventReads(); diagnosticPage = UUID(); diagnosticNavigating = false; loaded = false; onChange?() }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { conversationReads.retire(); retireEventReads() }
    /// Explicit diagnostic only; does not load/restore a page or create a profile.
    /// The existing session performs GETs and projects bodies before returning.
    func connectionDiagnostic(company: UUID?) async -> FuegoConnectionDiagnostic {
        guard !Task.isCancelled, loaded, !diagnosticNavigating, endpoint.contains(webView.url) else { return .unknown(company: company) }
        let page = diagnosticPage
        let raw = try? await webView.callAsyncJavaScript(FuegoConnectionDiagnosticScript.source,
            arguments: ["origin": server, "company": company?.uuidString.lowercased() ?? ""], in: nil, contentWorld: .defaultClient)
        return FuegoConnectionDiagnostic.decode(raw, company: company).checked(company: company,
            samePage: !Task.isCancelled && page == diagnosticPage && loaded && !diagnosticNavigating && endpoint.contains(webView.url))
    }
    func request(_ request: FuegoRequest) async throws -> Data {
        guard loaded, endpoint.contains(webView.url) else { throw HandoffProblem.signIn }
        if case .conversation(let job) = request { return try await readConversation(job) }
        if case .events(let target) = request { return try await readEvents(target) }
        if request.method == "POST" { return try await nativeWrite(request) }
        let arguments: [String: Any] = ["path": request.path, "method": request.method,
                                       "body": request.body.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! } ?? "",
                                       "origin": server]
        // Fixed script in WebKit's isolated client world. It cannot be replaced by
        // page globals and exposes no native handlers, cookies, file or shell API.
        let script = """
        if (location.origin !== origin) return {status:0, body:''};
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 12000);
        try {
          const response = await fetch(origin + path, {method, credentials:'same-origin', redirect:'error', cache:'no-store', signal:controller.signal,
            referrer:origin+'/', referrerPolicy:'same-origin',
            headers:{'Accept':'application/json', ...(method==='POST'?{'Content-Type':'application/json'}:{})}, ...(body?{body}:{})});
          if (!response.headers.get('content-type')?.toLowerCase().includes('application/json')) return {status:0,body:''};
          const reader=response.body.getReader(); let chunks=[], count=0;
          for (;;) {const {done,value}=await reader.read(); if(done)break; count+=value.length;
            if(count>524288){await reader.cancel();return {status:0,body:''};}chunks.push(value);}
          const buffer=new Uint8Array(count); let at=0; for(const chunk of chunks){buffer.set(chunk,at);at+=chunk.length;}
          return {status:response.status,body:new TextDecoder('utf-8',{fatal:true}).decode(buffer)};
        } catch { return {status:0,body:''}; } finally {clearTimeout(timeout);}
        """
        let result: Any?
        do { result = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient) }
        catch { throw HandoffProblem.unavailable }
        guard let response = result as? [String: Any], let status = response["status"] as? Int else { throw HandoffProblem.invalid }
        if status == 401 { throw HandoffProblem.signIn }
        if status == 403 {
            if let body = response["body"] as? String, let data = body.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               value["error"] as? String == "Board mutation requires trusted browser origin" { throw HandoffProblem.untrustedOrigin }
            throw HandoffProblem.forbidden
        }
        guard (200..<300).contains(status), let body = response["body"] as? String, let data = body.data(using: .utf8), data.count <= 524288 else { throw HandoffProblem.unavailable }
        return data
    }
    private var conversationOriginQualified: Bool {
        !closed && conversationOrigin.qualified && loaded && !diagnosticNavigating && endpoint.contains(webView.url)
    }
    private func readConversation(_ job: HandoffJob) async throws -> Data {
        guard job.server.utf8.elementsEqual(server.utf8) else { throw HandoffProblem.unavailable }
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
        try Task.checkCancellation()
        let ticket = try conversationReads.begin(qualified: conversationOriginQualified, selection: conversationOwner?(job), now: now())
        defer { conversationReads.finish(ticket) }
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(EmberConversationReadScript.source,
                arguments: ["origin": server, "company": job.target.company.uuidString.lowercased(), "agent": job.target.id.uuidString.lowercased()],
                in: nil, contentWorld: .defaultClient)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw HandoffProblem.unavailable
        }
        let data = try conversationReads.accept(raw, ticket: ticket, origin: server, company: job.target.company, agent: job.target.id,
            qualified: conversationOriginQualified, selection: conversationOwner?(job), now: now(), cancelled: Task.isCancelled)
        // Decode and final owner callback use the original total admission budget.
        try conversationReads.check(ticket, qualified: conversationOriginQualified, selection: conversationOwner?(job), now: now(), cancelled: Task.isCancelled)
        return data
    }
    private func retireEventReads() { eventReads.retire(); eventTicket = nil }
    private func readEvents(_ target: RunEventReadTarget) async throws -> Data {
        let current: () -> Bool = { [weak self] in
            guard let self, target.server.utf8.elementsEqual(self.server.utf8) else { return false }
            let owned = self.eventOwner?(target) == true
            return owned && !self.closed && self.conversationOrigin.qualified && self.loaded
                && !self.diagnosticNavigating && self.endpoint.contains(self.webView.url)
        }
        let ticket = try eventReads.begin(target, current: current, clock: RunEventReadTarget.monotonicNow)
        eventTicket = ticket
        do {
            let remaining = try eventReads.remaining(ticket, current: current, clock: RunEventReadTarget.monotonicNow)
            let raw = try await webView.callAsyncJavaScript(RunEventReadScript.source,
                arguments: ["origin": server, "run": target.runID.uuidString.lowercased(), "afterSeq": target.afterSeq, "remainingMs": remaining],
                in: nil, contentWorld: .defaultClient)
            return try eventReads.accept(raw, ticket: ticket, current: current, clock: RunEventReadTarget.monotonicNow)
        } catch {
            eventReads.finish(ticket)
            if eventTicket === ticket { eventTicket = nil }
            if Task.isCancelled { throw CancellationError() }
            if error is RunEventReadContract.Failure || error is HandoffProblem { throw error }
            throw HandoffProblem.unavailable
        }
    }
    func checkEventRead(_ target: RunEventReadTarget) throws {
        guard let ticket = eventTicket, ticket.target.sameInvocation(as: target) else { throw HandoffProblem.unavailable }
        try eventReads.check(ticket, current: { [weak self] in
            guard let self else { return false }
            let owned = self.eventOwner?(target) == true
            return owned && !self.closed && self.conversationOrigin.qualified && self.loaded
                && !self.diagnosticNavigating && self.endpoint.contains(self.webView.url)
        }, clock: RunEventReadTarget.monotonicNow)
    }
    func finishEventRead(_ target: RunEventReadTarget) {
        guard let ticket = eventTicket, ticket.target.sameInvocation(as: target) else { return }
        eventReads.finish(ticket); eventTicket = nil
    }
    private func nativeWrite(_ value: FuegoRequest) async throws -> Data {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in cookieStore.getAllCookies { continuation.resume(returning: $0) } }
        try Task.checkCancellation()
        guard cookies.count <= 256, let url = URL(string: server + value.path), endpoint.contains(url) else { throw HandoffProblem.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.allHTTPHeaderFields = try NativeFuegoHTTP.cookieHeaders(cookies, url: url, server: endpoint)
        request.setValue(server, forHTTPHeaderField: "Origin")
        request.setValue(server + "/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try value.body.map { try JSONSerialization.data(withJSONObject: $0) }
        let result = try await NativeFuegoHTTP.perform(request, server: endpoint)
        // Keep ordinary server session refreshes in this same app-owned store.
        let headers = result.response.allHeaderFields.reduce(into: [String: String]()) { output, entry in
            if let key = entry.key as? String, let text = entry.value as? String { output[key] = text }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if url.host == domain || url.host?.hasSuffix("." + domain) == true { cookieStore.setCookie(cookie, completionHandler: nil) }
        }
        if result.status == 401 { throw HandoffProblem.signIn }
        if result.status == 403 {
            writeDiagnostic(result, request: value)
            let object = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]
            if object?["code"] as? String == "FUEGO_DESKTOP_CAPABILITY_NOT_ENABLED" { throw HandoffProblem.desktopUnavailable }
            let reason = object?["error"] as? String ?? (object?["error"] as? [String: Any])?["message"] as? String
            if reason == "Board mutation requires trusted browser origin" { throw HandoffProblem.untrustedOrigin }
            throw HandoffProblem.forbidden
        }
        guard (200..<300).contains(result.status) else { writeDiagnostic(result, request: value); throw HandoffProblem.unavailable }
        return result.body
    }
    private func writeDiagnostic(_ result: FuegoHTTPResult, request: FuegoRequest) {
        let object = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]
        var reason = object?["error"] as? String ?? (object?["error"] as? [String: Any])?["message"] as? String ?? object?["message"] as? String ?? "Unclassified server rejection"
        if ["password", "token", "cookie", "credential", "secret", "authorization"].contains(where: { reason.lowercased().contains($0) }) { reason = "Authentication detail omitted" }
        reason = HandoffJob.bounded(reason.replacingOccurrences(of: #"[A-Za-z0-9_=-]{48,}"#, with: "[redacted]", options: .regularExpression), bytes: 240)
        let note: [String: Any] = ["httpStatus": result.status, "method": request.method, "path": request.path, "reason": reason]
        if let root = try? PluginStorage.directory(id: FuegoModel.pluginID), let data = try? JSONSerialization.data(withJSONObject: note, options: [.sortedKeys]) {
            let url = root.appendingPathComponent("last-http-error-v1.json")
            try? data.write(to: url, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    func close() {
        closed = true; conversationReads.close(); eventReads.close(); eventTicket = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        diagnosticPage = UUID(); diagnosticNavigating = true; windows.closeAll(); webView.stopLoading()
    }
}
private struct FuegoSignInWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
