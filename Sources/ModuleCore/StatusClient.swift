import Foundation
import Darwin
import Security

public protocol StatusReading: Sendable { func read() async throws -> BridgeStatus }

/// The plugin reads only the authenticated metadata endpoint. It does not open
/// the bridge's config, credentials, logs, durable journal or job workspaces.
public struct LocalStatusClient: StatusReading, Sendable {
    public static let serverRequirement = "identifier \"cloud.fuego.compute\" and anchor apple generic and certificate leaf[subject.OU] = \"2GFVXB3249\""
    public static var endpoint: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Fuego/Bridge/state/IPC/status.sock")
    }
    public init() {}
    public func read() async throws -> BridgeStatus {
        let task = Task.detached(priority: .utility) { try Self.exchange() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func readBlocking() throws -> BridgeStatus { try Self.exchange() }
    private static func exchange() throws -> BridgeStatus {
        try Task.checkCancellation()
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        let path = endpoint.path
        try validateEndpoint(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerProblem.unavailable }
        defer { Darwin.close(fd) }
        var noPipe: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw BrokerProblem.unavailable }
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw BrokerProblem.unavailable }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else { throw BrokerProblem.unavailable }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw BrokerProblem.unavailable }
            try SocketIO.wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var socketError: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else { throw BrokerProblem.unavailable }
        }
        // Keep the descriptor nonblocking. Every wait shares one monotonic
        // exchange deadline, so slow byte delivery cannot renew the timeout.
        try authenticateServer(fd)
        try SocketIO.check(deadline)
        let request = StatusRequest()
        var body = try JSONEncoder().encode(request); body.append(10)
        guard body.count <= 2048 else { throw BrokerProblem.invalidResponse }
        try SocketIO.write(body, to: fd, deadline: deadline)
        let response = try SocketIO.readFrame(from: fd, deadline: deadline)
        return try StatusCodec.decode(response, requestId: request.requestId, now: StatusCodec.now)
    }
    private static func validateEndpoint(_ path: String) throws {
        var directory = stat(), socket = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard parent.hasPrefix(home + "/") else { throw BrokerProblem.unavailable }
        var ancestor = URL(fileURLWithPath: parent)
        while true {
            var attributes = stat()
            guard lstat(ancestor.path, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_mode & S_IFMT == S_IFDIR else { throw BrokerProblem.unavailable }
            if ancestor.path == home { break }
            ancestor.deleteLastPathComponent()
            guard ancestor.path == home || ancestor.path.hasPrefix(home + "/") else { throw BrokerProblem.unavailable }
        }
        guard lstat(parent, &directory) == 0, directory.st_uid == geteuid(),
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_mode & 0o777 == 0o700,
              lstat(path, &socket) == 0, socket.st_uid == geteuid(),
              socket.st_mode & S_IFMT == S_IFSOCK, socket.st_mode & 0o777 == 0o600 else { throw BrokerProblem.unavailable }
    }
    private static func authenticateServer(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw BrokerProblem.untrustedPeer }
        // LOCAL_PEERTOKEN returns the kernel's immutable peer audit token;
        // signature lookup is bound to this connection rather than a reused PID.
        var token = [UInt32](repeating: 0, count: 8), length: socklen_t = 32
        guard getsockopt(fd, 0 /* SOL_LOCAL */, 0x006 /* LOCAL_PEERTOKEN */, &token, &length) == 0, length == 32 else { throw BrokerProblem.untrustedPeer }
        let data = token.withUnsafeBytes { Data($0) }
        var peer: SecCode?, requirement: SecRequirement?
        let attributes = [kSecGuestAttributeAudit as String: data] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess,
              let peer,
              SecRequirementCreateWithString(serverRequirement as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(peer, SecCSFlags(rawValue: 1 << 29) /* kSecCSNoNetworkAccess from Security/CSCommon.h */, requirement) == errSecSuccess else { throw BrokerProblem.untrustedPeer }
    }
}

/// An absolute monotonic I/O budget. Repeated partial reads do not renew it.
struct ExchangeDeadline {
    let expiresAt: UInt64
    func remainingMilliseconds(at now: UInt64) throws -> Int32 {
        guard now < expiresAt else { throw BrokerProblem.timedOut }
        let remaining = expiresAt - now
        return Int32(min(3000, max(1, (remaining + 999_999) / 1_000_000)))
    }
}

/// Internal nonblocking framing shared by the authenticated production client
/// and isolated socketpair tests. It accepts no path or authentication override.
enum SocketIO {
    static func check(_ deadline: UInt64) throws {
        try Task.checkCancellation()
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw BrokerProblem.timedOut }
    }
    static func wait(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            try check(deadline)
            let milliseconds = try ExchangeDeadline(expiresAt: deadline).remainingMilliseconds(at: DispatchTime.now().uptimeNanoseconds)
            var event = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&event, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw result == 0 ? BrokerProblem.timedOut : BrokerProblem.unavailable }
            try check(deadline)
            return
        }
    }

    static func write(_ data: Data, to fd: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw BrokerProblem.unavailable }; offset += count
            }
        }
    }
    static func readFrame(from fd: Int32, deadline: UInt64) throws -> Data {
        var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while response.count <= StatusCodec.maximumResponseBytes {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw BrokerProblem.unavailable }
            response.append(contentsOf: buffer.prefix(count))
            if let end = response.firstIndex(of: 10) {
                guard end == response.count - 1, end <= StatusCodec.maximumResponseBytes else { throw BrokerProblem.invalidResponse }
                try check(deadline); return Data(response[..<end])
            }
        }
        throw BrokerProblem.invalidResponse
    }
}
