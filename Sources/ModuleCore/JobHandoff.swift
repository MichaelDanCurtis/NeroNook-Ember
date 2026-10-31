import Foundation
import CryptoKit

public enum HandoffProblem: Error, LocalizedError {
    case invalid, signIn, forbidden, desktopUnavailable, busyConversation, untrustedOrigin, originalUnconfirmed, unavailable, changedTarget, storage
    public var errorDescription: String? {
        switch self {
        case .invalid: return "Fuego returned an unexpected response. No task was retried."
        case .signIn: return "Sign in to Fuego to continue."
        case .forbidden: return "Your Fuego account does not have permission for this action. Check its organization and agent access in Fuego."
        case .desktopUnavailable: return "Fuego's desktop gateway does not support this operation. No account-permission change is needed; use its supported per-user handoff API."
        case .busyConversation: return "This agent already has an unsettled turn in your Fuego conversation. Let it finish or inspect it in Fuego before sending another task."
        case .untrustedOrigin: return "Fuego rejected this request's origin before accepting it. The plugin's request context needs repair; changing account permissions will not help."
        case .originalUnconfirmed: return "This original task save is still unconfirmed. Recheck it rather than sending the same task again."
        case .unavailable: return "Fuego is unavailable. Check the original task before trying again."
        case .changedTarget: return "This agent's configuration changed. Review the current target again."
        case .storage: return "Job history could not be saved. New handoffs are disabled."
        }
    }
}

public struct HandoffTarget: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let company: UUID
    public let companyName: String
    public let name: String
    public let device: UUID
    public let provider: String
    public let workspace: String
    public let account: String
    public let instructions: String
    public let configuration: String
    public var companyPrefix: String?
    public static func decode(_ object: [String: Any], company: UUID, companyName: String, companyPrefix: String? = nil) throws -> Self {
        guard object["companyId"] as? String == company.uuidString.lowercased() || (object["companyId"] as? String).flatMap(UUID.init(uuidString:)) == company,
              let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
              object["adapterType"] as? String == "fuego_remote",
              ["active", "idle", "running"].contains(object["status"] as? String ?? ""),
              let config = object["adapterConfig"] as? [String: Any],
              let device = (config["deviceId"] as? String).flatMap(UUID.init(uuidString:)),
              let workspace = config["workspaceHandle"] as? String, !workspace.isEmpty, workspace.utf8.count <= 160,
              let account = config["accountHandle"] as? String, !account.isEmpty, account.utf8.count <= 160,
              let instructions = config["instructions"] as? String, instructions.utf8.count <= 8192, Self.printable(instructions),
              let name = object["name"] as? String, !name.isEmpty, name.utf8.count <= 160,
              companyName.utf8.count <= 160 else { throw HandoffProblem.invalid }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        guard data.count <= 32768 else { throw HandoffProblem.invalid }
        return .init(id: id, company: company, companyName: companyName, name: name, device: device,
                     provider: String((config["provider"] as? String ?? "Registered account").prefix(100)),
                     workspace: workspace, account: account, instructions: instructions,
                     configuration: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), companyPrefix: companyPrefix)
    }
    public static func printable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || [9, 10, 13].contains($0.value) }
    }
}

public enum HandoffPhase: String, Codable, Sendable {
    case preparing, submitting, queued, running, cancelling, succeeded, failed, cancelled, uncertain, skipped
    public var settled: Bool { [.succeeded, .failed, .cancelled, .skipped].contains(self) }
    public var title: String {
        switch self {
        case .preparing: return "Creating task"
        case .submitting: return "Requesting run"
        case .queued: return "Queued by Fuego"
        case .running: return "Running"
        case .cancelling: return "Cancellation requested"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled by Fuego"
        case .uncertain: return "Outcome unknown"
        case .skipped: return "Not started"
        }
    }
}

public enum HandoffRoute: String, Codable, Sendable { case task, conversation }
public struct HandoffJob: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let server: String
    public let target: HandoffTarget
    public let task: String
    public let created: Date
    public var issue: UUID?
    public var issueLabel: String?
    public var run: UUID?
    public var phase: HandoffPhase = .preparing
    public var detail = "Saving a Fuego task before requesting execution."
    public var result = ""
    public var events: [String] = []
    public var lastRead: Date?
    public var cancelID: UUID?
    public var cancelSent = false
    public var admitted = false
    public var eventSequence = 0
    public var route: HandoffRoute?
    public var conversationUser: String?
    public init(id: UUID = UUID(), server: String, target: HandoffTarget, task: String, created: Date = Date()) throws {
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, task.utf8.count <= 2048, HandoffTarget.printable(task),
              (try? FuegoServer(server)) != nil else { throw HandoffProblem.invalid }
        self.id = id; self.server = server; self.target = target; self.task = task; self.created = created
    }
    public mutating func recover() {
        if !phase.settled {
            phase = .uncertain
            detail = run == nil ? "The app closed before the handoff was confirmed. Inspect the original task in Fuego; nothing will be resent." : "Reconnecting to the original run. Execution has not been retried."
        }
    }
    public mutating func receive(_ object: [String: Any], now: Date = Date()) throws {
        guard let run, (object["id"] as? String).flatMap(UUID.init(uuidString:)) == run,
              (object["companyId"] as? String).flatMap(UUID.init(uuidString:)) == target.company,
              (object["agentId"] as? String).flatMap(UUID.init(uuidString:)) == target.id,
              let state = object["status"] as? String else { throw HandoffProblem.invalid }
        let payload = object["resultJson"] as? [String: Any] ?? [:]
        if let issueID = object["issueId"] as? String, UUID(uuidString: issueID) != issue { throw HandoffProblem.invalid }
        let remote = payload["state"] as? String
        let next: HandoffPhase
        switch state {
        case "queued": next = .queued
        case "running": next = .running
        case "succeeded": next = remote == "uncertain" ? .uncertain : .succeeded
        case "failed", "timed_out", "interrupted": next = remote == "uncertain" || state == "interrupted" ? .uncertain : .failed
        case "cancelled":
            // The control-plane cancellation row alone is not proof that a
            // remotely admitted process stopped. Wait for its bound result.
            next = remote == "uncertain" ? .uncertain : remote == "cancelled" || remote == "completed" || remote == "failed" ? .cancelled : .cancelling
        default: throw HandoffProblem.invalid
        }
        // A stale running poll must not erase a confirmed terminal result.
        if phase.settled, next != phase { return }
        phase = cancelSent && !next.settled && next != .uncertain ? .cancelling : next
        lastRead = now
        if remote == "completed" || payload["commandId"] != nil { admitted = true }
        let final = payload["finalResponse"] as? String ?? object["summary"] as? String ?? ""
        result = Self.bounded(final, bytes: 12000)
        let error = object["error"] as? String ?? object["errorMessage"] as? String ?? ""
        switch phase {
        case .queued: detail = "Fuego accepted the run into its queue. Computer admission is not yet confirmed."
        case .running: detail = admitted ? "Dispatched to the selected computer. Waiting for its result." : "Fuego is preparing or executing this run. Computer admission is not yet confirmed."
        case .cancelling: detail = "Stop was requested for this run. Waiting for Fuego's confirmed outcome; completed effects cannot be undone."
        case .succeeded: detail = "Fuego reports success for this run. Inspect the result before relying on external effects."
        case .cancelled: detail = "Fuego reports this run cancelled. Actions completed before cancellation are not undone."
        case .uncertain: detail = "Fuego cannot confirm the execution outcome. Inspect this original run; do not resubmit it."
        case .failed: detail = error.isEmpty ? "Fuego reports this run failed. Any partial effects require inspection." : Self.bounded(error, bytes: 500)
        default: break
        }
    }
    /// Unbound legacy rows cannot be admitted or mutate a cursor. Production
    /// callers use the original body plus its captured target below.
    public mutating func receiveEvents(_ objects: [[String: Any]]) throws { throw HandoffProblem.unavailable }
    /// Stage only event presentation/cursor. No row establishes admission or effects.
    public func stagingEvents(_ data: Data, target: RunEventReadTarget) throws -> Self {
        guard target.matches(self) else { throw HandoffProblem.invalid }
        _ = try RunEventReadContract.decodePage(data)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HandoffProblem.invalid }
        var copy = self, cursor = target.afterSeq
        for row in rows {
            guard let company = row["companyId"] as? String, company.utf8.elementsEqual(target.companyID.uuidString.lowercased().utf8),
                  let agent = row["agentId"] as? String, agent.utf8.elementsEqual(target.agentID.uuidString.lowercased().utf8),
                  let run = row["runId"] as? String, run.utf8.elementsEqual(target.runID.uuidString.lowercased().utf8),
                  let number = row["seq"] as? NSNumber, let seq = Int(exactly: number.int64Value), seq > cursor else { throw HandoffProblem.invalid }
            cursor = seq
            if let message = row["message"] as? String, !message.isEmpty {
                copy.events.append(Self.bounded(message, bytes: 360)); copy.events = Array(copy.events.suffix(12))
            }
        }
        copy.eventSequence = cursor
        return copy
    }
    public mutating func receiveConversation(_ object: [String: Any], now: Date = Date()) throws {
        guard let conversation = object["conversation"] as? [String: Any],
              let conversationID = (conversation["id"] as? String).flatMap(UUID.init(uuidString:)),
              (conversation["companyId"] as? String).flatMap(UUID.init(uuidString:)) == target.company,
              (conversation["agentId"] as? String).flatMap(UUID.init(uuidString:)) == target.id,
              let user = conversation["userId"] as? String, !user.isEmpty, user.utf8.count <= 160,
              conversationUser == nil || conversationUser == user,
              issue == nil || issue == conversationID,
              let messages = object["messages"] as? [[String: Any]], messages.count <= 200,
              let turns = object["turns"] as? [[String: Any]], turns.count <= 100 else { throw HandoffProblem.invalid }
        let ownMessages = messages.filter { ($0["clientRequestId"] as? String).flatMap(UUID.init(uuidString:)) == id && $0["role"] as? String == "user" }
        let ownTurns = turns.filter { ($0["clientRequestId"] as? String).flatMap(UUID.init(uuidString:)) == id }
        guard ownMessages.count == 1, ownTurns.count == 1, let message = ownMessages.first, let turn = ownTurns.first,
              message["body"] as? String == task,
              let messageID = (message["id"] as? String).flatMap(UUID.init(uuidString:)),
              (turn["id"] as? String).flatMap(UUID.init(uuidString:)) == messageID,
              let status = turn["status"] as? String else { throw HandoffProblem.invalid }
        let runID = (turn["runId"] as? String).flatMap(UUID.init(uuidString:))
        guard run == nil || run == runID else { throw HandoffProblem.invalid }
        if let rawRun = turn["runId"] as? String, UUID(uuidString: rawRun) == nil { throw HandoffProblem.invalid }
        let next: HandoffPhase
        switch status {
        case "pending": next = .queued
        case "running": next = .running
        case "succeeded": next = .succeeded
        case "failed": next = .failed
        case "cancelled": next = .cancelled
        case "uncertain": next = cancelSent ? .cancelling : .uncertain
        default: throw HandoffProblem.invalid
        }
        if phase.settled, next != phase { return }
        var final = result
        if next == .succeeded {
            guard let replyID = (turn["replyMessageId"] as? String).flatMap(UUID.init(uuidString:)), let runID else { throw HandoffProblem.invalid }
            let replies = messages.filter { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == replyID && $0["role"] as? String == "assistant" && ($0["runId"] as? String).flatMap(UUID.init(uuidString:)) == runID }
            guard replies.count == 1, let body = replies.first?["body"] as? String else { throw HandoffProblem.invalid }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, HandoffTarget.printable(body) else { throw HandoffProblem.invalid }
            final = Self.bounded(body, bytes: 12000)
        }
        // Validate the entire bound turn and published reply before committing.
        // A malformed success response must leave the original receipt intact.
        issue = conversationID; conversationUser = user; run = runID; lastRead = now; result = final
        phase = cancelSent && !next.settled && next != .uncertain ? .cancelling : next
        let error = turn["error"] as? String ?? ""
        switch phase {
        case .queued: detail = "Fuego saved this exact request in your private conversation. Waiting for its run."
        case .running: detail = "Fuego is responding to this original request. Computer admission is reported separately."
        case .succeeded: detail = "Fuego completed this request and published the linked final answer."
        case .cancelled: detail = "Fuego confirms this conversation turn cancelled. Previously completed effects are not undone."
        case .cancelling: detail = "Cancellation requested. Waiting for Fuego's confirmed stop on the computer."
        case .failed: detail = error.isEmpty ? "Fuego could not complete this request." : Self.bounded(error, bytes: 500)
        case .uncertain: detail = error.isEmpty ? "This original request needs reconciliation. Nothing was resent." : Self.bounded(error, bytes: 500)
        default: break
        }
    }
    public static func bounded(_ value: String, bytes: Int) -> String {
        var out = ""
        for c in value { if out.utf8.count + String(c).utf8.count > bytes { break }; out.append(c) }
        return out
    }
}

public struct FuegoServer: Equatable, Sendable {
    public let origin: String
    public init(_ raw: String) throws {
        guard raw.utf8.count <= 512, let c = URLComponents(string: raw), c.scheme == "https",
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || c.port == 443, c.path == "" || c.path == "/",
              let host = c.host?.lowercased(), c.percentEncodedHost == c.host,
              host.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#, options: .regularExpression) != nil,
              !["localhost", "local", "internal", "lan", "test", "invalid", "example"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw HandoffProblem.invalid }
        origin = "https://" + host
    }
    public func contains(_ url: URL?) -> Bool {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "https" && c.user == nil && c.password == nil && c.host == URL(string: origin)?.host && (c.port == nil || c.port == 443)
    }
}

public final class HandoffStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [HandoffJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw HandoffProblem.storage }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1024 * 1024 else { throw HandoffProblem.storage }
        let data = try Data(contentsOf: url)
        guard data.count <= 1024 * 1024 else { throw HandoffProblem.storage }
        var jobs = try JSONDecoder().decode([HandoffJob].self, from: data)
        guard jobs.count <= 20, Set(jobs.map(\.id)).count == jobs.count else { throw HandoffProblem.storage }
        for i in jobs.indices { jobs[i].recover() }
        return jobs
    }
    public func save(_ jobs: [HandoffJob]) throws {
        guard jobs.count <= 20 else { throw HandoffProblem.storage }
        let data = try JSONEncoder().encode(jobs)
        guard data.count <= 1024 * 1024 else { throw HandoffProblem.storage }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw HandoffProblem.storage }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
