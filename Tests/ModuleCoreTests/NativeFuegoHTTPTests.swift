import Foundation
import XCTest
@testable import ModuleCore

private final class FixtureHTTPProtocol: URLProtocol {
    static var payload = Data("{\"ok\":true}".utf8)
    static var mime = "application/json"
    static var received: URLRequest?
    static var receivedBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.received = request
        Self.receivedBody = request.httpBody
        if Self.receivedBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024), data = Data()
            while true { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
            Self.receivedBody = data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": Self.mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor final class NativeFuegoHTTPTests: XCTestCase {
    let server = try! FuegoServer("https://fuego.example.org")
    override func setUp() { FixtureHTTPProtocol.payload = Data("{\"ok\":true}".utf8); FixtureHTTPProtocol.mime = "application/json"; FixtureHTTPProtocol.received = nil; FixtureHTTPProtocol.receivedBody = nil }
    private func request(_ url: String = "https://fuego.example.org/api/test") -> URLRequest { var request = URLRequest(url: URL(string: url)!); request.httpMethod = "POST"; request.setValue("https://fuego.example.org", forHTTPHeaderField: "Origin"); request.httpBody = Data("{}".utf8); return request }
    private func config() -> URLSessionConfiguration { let config = NativeFuegoHTTP.configuration(); config.protocolClasses = [FixtureHTTPProtocol.self]; return config }
    func testActualStreamingRequestRetainsExactBodyAndOrigin() async throws {
        let result = try await NativeFuegoHTTP.perform(request(), server: server, configuration: config())
        XCTAssertEqual(result.status, 200); XCTAssertEqual(result.body, FixtureHTTPProtocol.payload)
        XCTAssertEqual(FixtureHTTPProtocol.receivedBody, Data("{}".utf8))
        XCTAssertEqual(FixtureHTTPProtocol.received?.value(forHTTPHeaderField: "Origin"), server.origin)
    }
    func testForeignOriginIsRejectedBeforeTransport() async throws {
        do { _ = try await NativeFuegoHTTP.perform(request("https://foreign.example.org/api/test"), server: server, configuration: config()); XCTFail("Foreign request admitted") } catch {}
        XCTAssertNil(FixtureHTTPProtocol.received)
    }
    func testNonJSONAndOversizedStreamsAreRejected() async throws {
        FixtureHTTPProtocol.mime = "text/html"
        do { _ = try await NativeFuegoHTTP.perform(request(), server: server, configuration: config()); XCTFail("HTML accepted") } catch {}
        FixtureHTTPProtocol.mime = "application/json"; FixtureHTTPProtocol.payload = Data(repeating: 65, count: 524289)
        do { _ = try await NativeFuegoHTTP.perform(request(), server: server, configuration: config()); XCTFail("Oversize accepted") } catch {}
    }
    func testOwnCookieScopeExcludesOtherDomainsExpiredCookiesAndPathPrefixes() throws {
        func cookie(_ name: String, domain: String, path: String, expires: Date? = nil) -> HTTPCookie {
            var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "dummy", .domain: domain, .path: path, .secure: "TRUE"]
            if let expires { props[.expires] = expires }; return HTTPCookie(properties: props)!
        }
        let cookies = [cookie("session", domain: "fuego.example.org", path: "/"), cookie("other", domain: "foreign.example.org", path: "/"), cookie("prefix", domain: "fuego.example.org", path: "/api/t"), cookie("expired", domain: "fuego.example.org", path: "/", expires: Date(timeIntervalSince1970: 0))]
        let header = try NativeFuegoHTTP.cookieHeaders(cookies, url: request().url!, server: server)["Cookie"] ?? ""
        XCTAssertTrue(header.contains("session=dummy")); XCTAssertFalse(header.contains("other")); XCTAssertFalse(header.contains("prefix")); XCTAssertFalse(header.contains("expired"))
        XCTAssertThrowsError(try NativeFuegoHTTP.cookieHeaders(cookies, url: URL(string: "https://foreign.example.org")!, server: server))
    }
}
