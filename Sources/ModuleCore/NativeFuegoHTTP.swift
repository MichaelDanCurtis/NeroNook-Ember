import Foundation

public struct FuegoHTTPResult {
    public let status: Int
    public let body: Data
    public let response: HTTPURLResponse
}

private final class FuegoHTTPDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// Native writes use only cookies supplied by this plugin's own WebKit store.
/// No global cookie/credential store, redirect, certificate override or retry.
public enum NativeFuegoHTTP {
    public static func cookieHeaders(_ cookies: [HTTPCookie], url: URL, server: FuegoServer, now: Date = Date()) throws -> [String: String] {
        guard server.contains(url), cookies.count <= 256, let host = url.host else { throw HandoffProblem.invalid }
        let applicable = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            let domainMatches = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            let pathMatches = url.path == cookie.path || (url.path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || url.path.dropFirst(cookie.path.count).first == "/"))
            return domainMatches && pathMatches && (cookie.expiresDate == nil || cookie.expiresDate! > now)
        }
        let headers = HTTPCookie.requestHeaderFields(with: applicable)
        guard headers.values.reduce(0, { $0 + $1.utf8.count }) <= 16384 else { throw HandoffProblem.invalid }
        return headers
    }
    public static func perform(_ request: URLRequest, server: FuegoServer) async throws -> FuegoHTTPResult {
        try await perform(request, server: server, configuration: configuration())
    }
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 12
        return config
    }
    static func perform(_ request: URLRequest, server: FuegoServer, configuration: URLSessionConfiguration) async throws -> FuegoHTTPResult {
        guard server.contains(request.url), request.httpMethod == "POST" else { throw HandoffProblem.invalid }
        let session = URLSession(configuration: configuration, delegate: FuegoHTTPDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, server.contains(response.url),
                  response.mimeType?.lowercased() == "application/json", response.expectedContentLength <= 524288 else { throw HandoffProblem.invalid }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 524288 else { throw HandoffProblem.invalid }
                if data.count % 4096 == 0 { try Task.checkCancellation() }
                data.append(byte)
            }
            return .init(status: response.statusCode, body: data, response: response)
        } onCancel: { session.invalidateAndCancel() }
    }
}
