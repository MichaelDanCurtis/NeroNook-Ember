import Foundation
import NookPluginSDK

public enum BridgeConnection: String, Codable, Sendable { case connecting, connected, disconnected }
public enum JobState: String, Codable, Sendable {
    case accepted, launching, started, completed, failed, cancelled, uncertain
}
public struct RecentJob: Codable, Equatable, Sendable, Identifiable {
    public let runId: UUID
    public let commandId: UUID
    public let state: JobState
    public var id: UUID { runId }
    public init(runId: UUID, commandId: UUID, state: JobState) { self.runId = runId; self.commandId = commandId; self.state = state }
}
public struct BridgeStatus: Codable, Equatable, Sendable {
    public let observedAt: Int64
    public let validUntil: Int64
    public let deviceId: UUID
    public let provider: String
    public let connection: BridgeConnection
    public let sessionEpoch: UInt64?
    public let ready: Bool
    public let lastGatewayAt: Int64?
    public let paused: Bool
    public let activeJobs: UInt32
    public let uncertainJobs: UInt32
    public let recentJobs: [RecentJob]
    public init(observedAt: Int64, validUntil: Int64, deviceId: UUID, provider: String = "codex", connection: BridgeConnection, sessionEpoch: UInt64? = nil, ready: Bool = false, lastGatewayAt: Int64? = nil, paused: Bool = false, activeJobs: UInt32 = 0, uncertainJobs: UInt32 = 0, recentJobs: [RecentJob] = []) {
        self.observedAt = observedAt; self.validUntil = validUntil; self.deviceId = deviceId; self.provider = provider; self.connection = connection; self.sessionEpoch = sessionEpoch; self.ready = ready; self.lastGatewayAt = lastGatewayAt; self.paused = paused; self.activeJobs = activeJobs; self.uncertainJobs = uncertainJobs; self.recentJobs = recentJobs
    }
    public func validate(now: Int64) throws {
        guard observedAt > 0, observedAt <= now + 2_000, observedAt <= validUntil,
              validUntil - observedAt <= 15_000, validUntil > now, now - observedAt < 15_000,
              provider == "codex", recentJobs.count <= 20,
              Set(recentJobs.map(\.runId)).count == recentJobs.count,
              Set(recentJobs.map(\.commandId)).count == recentJobs.count,
              connection != .connected || (sessionEpoch != nil && lastGatewayAt.map({ $0 > 0 && $0 <= now + 2_000 && now - $0 <= 30_000 }) == true),
              !ready || (connection == .connected && !paused) else { throw BrokerProblem.invalidResponse }
    }
    public func fresh(at now: Int64) -> Bool { (try? validate(now: now)) != nil }
}
public struct StatusRequest: Encodable, Sendable {
    public let version = 1
    public let requestId: UUID
    public let operation = "status"
    public init(requestId: UUID = UUID()) { self.requestId = requestId }
}
private struct StatusResponse: Decodable { let version: Int; let requestId: UUID; let snapshot: BridgeStatus }
public enum BrokerProblem: Error, LocalizedError, Sendable {
    case unavailable, untrustedPeer, invalidResponse, timedOut
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Fuego Compute is unavailable. Start or update the local runtime."
        case .untrustedPeer: return "The local Fuego Compute identity could not be verified."
        case .invalidResponse: return "Fuego Compute returned an incompatible or expired status."
        case .timedOut: return "Fuego Compute did not respond in time."
        }
    }
}
public enum StatusCodec {
    public static let maximumResponseBytes = 32_768
    public static func decode(_ data: Data, requestId: UUID, now: Int64) throws -> BridgeStatus {
        guard !data.isEmpty, data.count <= maximumResponseBytes else { throw BrokerProblem.invalidResponse }
        do {
            // Version 1 is an allowlisted metadata message. Reject additional
            // fields so future additions cannot silently enter this client.
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["version", "requestId", "snapshot"]),
                  let snapshot = object["snapshot"] as? [String: Any],
                  Set(snapshot.keys) == Set(["observedAt", "validUntil", "deviceId", "provider", "connection", "sessionEpoch", "ready", "lastGatewayAt", "paused", "activeJobs", "uncertainJobs", "recentJobs"]),
                  let jobs = snapshot["recentJobs"] as? [[String: Any]], jobs.count <= 20,
                  jobs.allSatisfy({ Set($0.keys) == Set(["runId", "commandId", "state"]) }) else { throw BrokerProblem.invalidResponse }
            let value = try JSONDecoder().decode(StatusResponse.self, from: data)
            guard value.version == 1, value.requestId == requestId else { throw BrokerProblem.invalidResponse }
            try value.snapshot.validate(now: now)
            return value.snapshot
        } catch { throw BrokerProblem.invalidResponse }
    }
    public static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
