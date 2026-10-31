import Foundation
import Combine

public enum FuegoRequest {
    case companies, agents(UUID), agent(UUID), create(HandoffJob), invoke(HandoffJob), run(UUID), events(UUID, Int), cancel(UUID, UUID), findTask(HandoffJob), findRuns(HandoffJob), conversation(HandoffJob), sendConversation(HandoffJob), cancelConversation(HandoffJob, UUID), cancelRemote(UUID)
    public var method: String {
        switch self { case .create, .invoke, .cancel, .sendConversation, .cancelConversation, .cancelRemote: return "POST"; default: return "GET" }
    }
    public var path: String {
        switch self {
        case .companies: return "/api/companies?scope=accessible"
        case .agents(let id): return "/api/companies/\(id.uuidString.lowercased())/agents"
        case .agent(let id): return "/api/agents/\(id.uuidString.lowercased())"
        case .create(let job): return "/api/companies/\(job.target.company.uuidString.lowercased())/issues"
        case .invoke(let job): return "/api/agents/\(job.target.id.uuidString.lowercased())/heartbeat/invoke"
        case .run(let id): return "/api/heartbeat-runs/\(id.uuidString.lowercased())"
        case .events(let id, let seq): return "/api/heartbeat-runs/\(id.uuidString.lowercased())/events?afterSeq=\(max(0, seq))&limit=50"
        case .cancel(let id, _): return "/api/heartbeat-runs/\(id.uuidString.lowercased())/cancel"
        case .cancelRemote(let id): return "/api/heartbeat-runs/\(id.uuidString.lowercased())/cancel"
        case .findTask(let job): return "/api/companies/\(job.target.company.uuidString.lowercased())/issues?assigneeAgentId=\(job.target.id.uuidString.lowercased())&q=\(job.id.uuidString.prefix(8))&limit=25"
        case .findRuns(let job): return "/api/companies/\(job.target.company.uuidString.lowercased())/heartbeat-runs?agentId=\(job.target.id.uuidString.lowercased())&limit=100"
        case .conversation(let job): return "/api/companies/\(job.target.company.uuidString.lowercased())/ember/\(job.target.id.uuidString.lowercased())"
        case .sendConversation(let job): return "/api/companies/\(job.target.company.uuidString.lowercased())/ember/\(job.target.id.uuidString.lowercased())/messages"
        case .cancelConversation(let job, _): return "/api/companies/\(job.target.company.uuidString.lowercased())/ember/\(job.target.id.uuidString.lowercased())/cancel"
        }
    }
    public var body: [String: Any]? {
        switch self {
        case .create(let job): return ["title": "Nook · " + String(job.task.prefix(72)) + " [" + job.id.uuidString.prefix(8) + "]", "description": job.task, "status": "backlog", "assigneeAgentId": job.target.id.uuidString.lowercased(), "priority": "medium"]
        case .invoke(let job): return ["reason": "nero_nook_handoff", "triggerDetail": "manual", "idempotencyKey": job.id.uuidString.lowercased(), "payload": ["issueId": job.issue!.uuidString.lowercased()], "forceFreshSession": true]
        case .cancel(_, let id): return ["cancellationRequestId": id.uuidString.lowercased()]
        // Correlated cancellationRequestId belongs to Paperclip's native run
        // coordinator. Fuego remote-adapter runs use its normal per-run Stop.
        // Our durable local cancellation ID still fences against replay.
        case .cancelRemote: return [:]
        case .sendConversation(let job): return ["body": job.task, "clientRequestId": job.id.uuidString.lowercased()]
        case .cancelConversation(let job, let id): return ["runId": job.run!.uuidString.lowercased(), "cancellationRequestId": id.uuidString.lowercased()]
        default: return nil
        }
    }
}
@MainActor public protocol FuegoAPI: AnyObject {
    var server: String { get }
    func request(_ request: FuegoRequest) async throws -> Data
}

public struct FuegoCompany: Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public var prefix: String? = nil
}
public struct HandoffReview: Equatable {
    public let id: UUID
    public let server: String
    public let target: HandoffTarget
    public let task: String
    public let expires: Date
}

@MainActor public final class HandoffController: ObservableObject {
    public let api: FuegoAPI
    private let store: HandoffStore
    private let route: HandoffRoute
    @Published public private(set) var companies: [FuegoCompany] = []
    @Published public private(set) var targets: [HandoffTarget] = []
    @Published public private(set) var jobs: [HandoffJob] = []
    @Published public private(set) var review: HandoffReview?
    @Published public private(set) var message = "Connect your Fuego account to hand off a task."
    @Published public private(set) var busy = false
    @Published public private(set) var storageFailed = false
    @Published public var company: UUID? {
        didSet { if company != oldValue { retireConversationReads() } }
    }
    @Published public var selectedJob: UUID?
    private var generation = 0
    public private(set) var conversationReadGeneration: UInt64 = 1
    private func retireConversationReads() {
        conversationReadGeneration = conversationReadGeneration > 0 && conversationReadGeneration < 9_007_199_254_740_991 ? conversationReadGeneration + 1 : 0
    }
    private var reading = false
    // A preflight refusal has no remote job receipt. Keep a bounded, exact-ID
    // outcome so workflow observers cannot mistake it for the user pressing Back.
    private var reviewFailures: [UUID: (server: String, message: String, date: Date)] = [:]
    public func reviewFailure(_ id: UUID, server: String) -> String? {
        guard let failure = reviewFailures[id], failure.server == server else { return nil }
        return failure.message
    }
    public init(api: FuegoAPI, store: HandoffStore, route: HandoffRoute = .task) {
        self.api = api; self.store = store; self.route = route
        do { jobs = try store.load(); selectedJob = jobs.first?.id } catch { storageFailed = true; message = HandoffProblem.storage.localizedDescription }
    }
    public var activeJob: HandoffJob? { jobs.first { $0.id == selectedJob } ?? jobs.first }
    // A lost create acknowledgement cannot have reached this app's invocation
    // step. Keep its receipt, forbid resending it, but allow a distinct task.
    // An ambiguous invocation can already be executing and still blocks handoff.
    public var canSubmit: Bool { !busy && !storageFailed && !jobs.contains { ($0.route == .conversation || $0.issue != nil) && $0.run == nil && $0.phase == .uncertain } }
    public var hasUnconfirmedSave: Bool { jobs.contains { $0.route != .conversation && $0.issue == nil && $0.phase == .uncertain } }
    public func invalidate() { generation += 1; retireConversationReads(); review = nil; targets = []; companies = []; message = "Fuego connection changed. Existing tasks will not be resent." }
    private func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 524288, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HandoffProblem.invalid }; return value
    }
    private func array(_ data: Data) throws -> [[String: Any]] {
        guard data.count <= 524288, let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], value.count <= 100 else { throw HandoffProblem.invalid }; return value
    }
    public func refreshTargets() async {
        guard !busy else { return }
        generation += 1; let current = generation
        do {
            let values = try array(await api.request(.companies))
            var next: [FuegoCompany] = []
            for value in values {
                guard let id = (value["id"] as? String).flatMap(UUID.init(uuidString:)), let name = value["name"] as? String, !name.isEmpty, name.utf8.count <= 160 else { continue }
                let prefix = value["issuePrefix"] as? String
                next.append(.init(id: id, name: name, prefix: prefix?.range(of: #"^[A-Z][A-Z0-9]{0,15}$"#, options: .regularExpression) != nil ? prefix : nil))
            }
            guard current == generation else { return }
            companies = next
            if !companies.contains(where: { $0.id == company }) { company = companies.first?.id }
            guard let company, let selected = companies.first(where: { $0.id == company }) else { targets = []; message = "No accessible Fuego organization was found."; return }
            let agents = try array(await api.request(.agents(company)))
            let nextTargets = agents.compactMap { try? HandoffTarget.decode($0, company: company, companyName: selected.name, companyPrefix: selected.prefix) }
            guard current == generation else { return }
            targets = nextTargets
            message = targets.isEmpty ? "No active remote Fuego agent is configured in this organization. Configure its computer and workspace in Fuego." : "Choose an agent, write a task, then review the handoff."
        } catch {
            guard current == generation else { return }
            targets = []; review = nil; message = safe(error)
        }
    }
    public func prepare(target id: UUID, task: String, now: Date = Date()) throws {
        guard canSubmit, let target = targets.first(where: { $0.id == id }), !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, task.utf8.count <= 2048, HandoffTarget.printable(task) else { throw HandoffProblem.invalid }
        guard route != .conversation || task.trimmingCharacters(in: .whitespacesAndNewlines) != "/new" else { throw HandoffProblem.invalid }
        if jobs.contains(where: { $0.phase == .uncertain && $0.task == task.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            message = HandoffProblem.originalUnconfirmed.localizedDescription; throw HandoffProblem.originalUnconfirmed
        }
        review = .init(id: UUID(), server: api.server, target: target, task: task.trimmingCharacters(in: .whitespacesAndNewlines), expires: now.addingTimeInterval(120))
    }
    public func dismissReview() { review = nil }
    public func approve(_ id: UUID, now: Date = Date()) async {
        guard canSubmit, let proposal = review, proposal.id == id, proposal.server == api.server, proposal.expires > now else { review = nil; message = "This review expired. Review the task again."; return }
        review = nil; busy = true; defer { busy = false }
        do {
            let value = try object(await api.request(.agent(proposal.target.id)))
            let target = try HandoffTarget.decode(value, company: proposal.target.company, companyName: proposal.target.companyName, companyPrefix: proposal.target.companyPrefix)
            guard target == proposal.target else { throw HandoffProblem.changedTarget }
            var job = try HandoffJob(id: proposal.id, server: proposal.server, target: target, task: proposal.task)
            job.route = route
            if route == .conversation {
                let current = try object(await api.request(.conversation(job)))
                guard let turns = current["turns"] as? [[String: Any]], turns.count <= 100,
                      turns.allSatisfy({ ["pending", "running", "succeeded", "failed", "cancelled", "uncertain"].contains($0["status"] as? String ?? "") }),
                      let limits = current["limits"] as? [String: Any], let maxText = limits["maxTextBytes"] as? Int,
                      maxText >= job.task.utf8.count else { throw HandoffProblem.invalid }
                if let conversation = current["conversation"] as? [String: Any] {
                    guard (conversation["companyId"] as? String).flatMap(UUID.init(uuidString:)) == target.company,
                          (conversation["agentId"] as? String).flatMap(UUID.init(uuidString:)) == target.id,
                          let user = conversation["userId"] as? String, !user.isEmpty, user.utf8.count <= 160,
                          let issue = (conversation["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw HandoffProblem.invalid }
                    job.conversationUser = user; job.issue = issue
                } else if !(current["conversation"] is NSNull) { throw HandoffProblem.invalid }
                guard !turns.contains(where: { ["pending", "running", "uncertain"].contains($0["status"] as? String ?? "") }) else { throw HandoffProblem.busyConversation }
                job.detail = "Submitting the reviewed task through Fuego's private desktop job API."
            }
            if jobs.count >= 20 {
                guard let i = jobs.lastIndex(where: { $0.phase.settled }) else { throw HandoffProblem.storage }
                jobs.remove(at: i)
            }
            jobs.insert(job, at: 0); selectedJob = job.id
            try persist() // Durable before either external mutation.
            do {
                if route == .conversation {
                    let snapshot = try object(await api.request(.sendConversation(job)))
                    try receiveConversation(job.id, snapshot); try persist()
                    message = "Fuego accepted the original request. Follow its turn and linked run below."
                    return
                }
                let issue = try object(await api.request(.create(job)))
                guard let issueID = (issue["id"] as? String).flatMap(UUID.init(uuidString:)),
                      (issue["companyId"] as? String).flatMap(UUID.init(uuidString:)) == target.company,
                      (issue["assigneeAgentId"] as? String).flatMap(UUID.init(uuidString:)) == target.id,
                      issue["status"] as? String == "backlog", issue["description"] as? String == job.task else { throw HandoffProblem.invalid }
                update(job.id) { $0.issue = issueID; $0.issueLabel = issue["identifier"] as? String; $0.phase = .submitting; $0.detail = "Task saved. Requesting its original Fuego run." }
                try persist()
                let current = jobs.first { $0.id == job.id }!
                let run = try object(await api.request(.invoke(current)))
                if run["status"] as? String == "skipped" {
                    update(job.id) { $0.phase = .skipped; $0.detail = "Fuego did not start a run. The saved task remains in Fuego." }
                } else {
                    guard let runID = (run["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw HandoffProblem.invalid }
                    update(job.id) { $0.run = runID }
                    try receiveRun(job.id, run)
                }
                try persist(); message = "Handoff recorded. Follow its original run below."
            } catch {
                if (error as? HandoffProblem) == .untrustedOrigin || (error as? HandoffProblem) == .desktopUnavailable {
                    let reason = (error as? HandoffProblem) == .desktopUnavailable ? "Fuego's desktop gateway rejected this unsupported operation." : "Fuego's origin guard rejected this request before its handler ran."
                    update(job.id) { $0.phase = .failed; $0.detail = reason + " Any earlier saved task remains; no run was confirmed and nothing will be retried." }
                } else {
                    update(job.id) { $0.phase = .uncertain; $0.detail = "Handoff confirmation was lost. Inspect the original task in Fuego before doing anything else. Nothing will be resent." }
                }
                try? persist(); message = safe(error)
            }
        } catch {
            message = safe(error)
            if !jobs.contains(where: { $0.id == proposal.id }) {
                if reviewFailures.count >= 20, let oldest = reviewFailures.min(by: { $0.value.date < $1.value.date })?.key { reviewFailures[oldest] = nil }
                reviewFailures[proposal.id] = (proposal.server, message, now)
            }
        }
    }
    private func update(_ id: UUID, _ body: (inout HandoffJob) -> Void) { if let index = jobs.firstIndex(where: { $0.id == id }) { body(&jobs[index]) } }
    private func receiveRun(_ id: UUID, _ object: [String: Any]) throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw HandoffProblem.invalid }
        try jobs[index].receive(object)
    }
    private func receiveConversation(_ id: UUID, _ object: [String: Any]) throws {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { throw HandoffProblem.invalid }
        var copy = jobs[index]; try copy.receiveConversation(object); jobs[index] = copy
    }
    public func poll() async {
        guard !reading, !busy else { return }; reading = true; defer { reading = false }
        // With a UI selection, do not spend the four-job budget on another
        // company. Without one, retain original-job reconciliation semantics;
        // the real Session still refuses missing selected-company authority.
        for job in jobs.filter({ $0.server == api.server && ($0.route != .conversation || company == nil || $0.target.company == company) && ($0.run != nil || $0.route == .conversation) && !$0.phase.settled }).prefix(4) {
            do {
                if job.route == .conversation {
                    let snapshot = try object(await api.request(.conversation(job)))
                    try receiveConversation(job.id, snapshot); try persist()
                    // A delayed verified stop/result supersedes the transport
                    // warning for this selected cancellation. Keep unrelated
                    // task or account failures intact.
                    if selectedJob == job.id, let updated = jobs.first(where: { $0.id == job.id }),
                       updated.cancelSent, updated.phase.settled { message = updated.detail }
                    if let current = jobs.first(where: { $0.id == job.id }), let runID = current.run,
                       let events = try? array(await api.request(.events(runID, current.eventSequence))), let index = jobs.firstIndex(where: { $0.id == job.id }) {
                        try jobs[index].receiveEvents(events); try persist()
                    }
                    continue
                }
                guard let runID = job.run else { continue }
                let run = try object(await api.request(.run(runID)))
                try receiveRun(job.id, run)
                try persist()
                // A missing event stream cannot hide a confirmed final answer.
                if let events = try? array(await api.request(.events(runID, job.eventSequence))),
                   let index = jobs.firstIndex(where: { $0.id == job.id }) {
                    try jobs[index].receiveEvents(events); try persist()
                }
            } catch {
                update(job.id) { $0.detail = "Progress is unavailable. The original run may still be active. Reconnect to inspect it; nothing is resent." }
                message = safe(error)
            }
        }
    }
    public func cancel(_ id: UUID) async {
        guard !busy, let job = jobs.first(where: { $0.id == id }), job.server == api.server, let run = job.run, !job.phase.settled, !job.cancelSent, !storageFailed else { return }
        busy = true; defer { busy = false }
        let requestID = UUID()
        update(id) { $0.cancelSent = true; $0.cancelID = requestID; $0.phase = .cancelling; $0.detail = "Requesting cancellation of this exact Fuego run. Existing effects cannot be undone." }
        do {
            try persist() // Never resend an ambiguous cancellation.
            if job.route == .conversation {
                let before = try object(await api.request(.conversation(job)))
                try receiveConversation(id, before); try persist()
                if jobs.first(where: { $0.id == id })?.phase.settled == true { return }
                let response = try object(await api.request(.cancelRemote(run)))
                guard (response["id"] as? String).flatMap(UUID.init(uuidString:)) == run,
                      (response["companyId"] as? String).flatMap(UUID.init(uuidString:)) == job.target.company,
                      (response["agentId"] as? String).flatMap(UUID.init(uuidString:)) == job.target.id else { throw HandoffProblem.invalid }
                // The Stop acknowledgement alone does not mean the computer
                // stopped. Only this owner's bound conversation DTO settles it.
                try receiveConversation(id, object(await api.request(.conversation(job))))
            } else {
                let response = try object(await api.request(.cancel(run, requestID)))
                try receiveRun(id, response)
            }
            try persist()
        } catch { update(id) { $0.detail = "The cancellation request could not be confirmed. Fuego may still be running this task. Refresh its original run." }; try? persist(); message = safe(error) }
    }
    public func reconcile(_ id: UUID) async {
        guard !busy, !storageFailed, var job = jobs.first(where: { $0.id == id }), job.server == api.server, job.phase == .uncertain else { return }
        busy = true; defer { busy = false }
        do {
            if job.route == .conversation {
                let snapshot = try object(await api.request(.conversation(job)))
                try receiveConversation(id, snapshot); try persist(); message = "Original request recovered by its exact saved identifier. Nothing was resent."; return
            }
            if job.issue == nil {
                let tasks = try array(await api.request(.findTask(job)))
                let expectedTitle = FuegoRequest.create(job).body?["title"] as? String
                let matches = tasks.filter {
                    ($0["companyId"] as? String).flatMap(UUID.init(uuidString:)) == job.target.company &&
                    ($0["assigneeAgentId"] as? String).flatMap(UUID.init(uuidString:)) == job.target.id &&
                    $0["title"] as? String == expectedTitle && $0["description"] as? String == job.task
                }
                guard matches.count == 1, let task = matches.first,
                      let issue = (task["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                    message = "The bounded search did not find one exact original task. Nothing was resent. Inspect Fuego manually."; return
                }
                job.issue = issue; job.issueLabel = task["identifier"] as? String
                update(id) { $0.issue = job.issue; $0.issueLabel = job.issueLabel }; try persist()
            }
            if job.run == nil {
                let runs = try array(await api.request(.findRuns(job)))
                let matches = runs.filter {
                    let context = $0["contextSnapshot"] as? [String: Any]
                    let issue = $0["issueId"] as? String ?? context?["issueId"] as? String
                    return (issue.flatMap(UUID.init(uuidString:))) == job.issue &&
                        ($0["agentId"] as? String).flatMap(UUID.init(uuidString:)) == job.target.id &&
                        ($0["companyId"] as? String).flatMap(UUID.init(uuidString:)) == job.target.company
                }
                guard matches.count == 1, let run = matches.first,
                      let runID = (run["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                    message = "The original task is saved, but its run is not uniquely confirmed in the latest 100 runs. Nothing was resent."; return
                }
                job.run = runID; update(id) { $0.run = runID }; try receiveRun(id, run); try persist()
            } else if let runID = job.run {
                let run = try object(await api.request(.run(runID))); try receiveRun(id, run); try persist()
            }
            message = "The original task and run were found by read-only inspection. No task was retried."
        } catch { message = safe(error) }
    }
    public func inspectURL(_ id: UUID) -> URL? {
        guard let job = jobs.first(where: { $0.id == id }), let issue = job.issue else { return nil }
        if job.route == .conversation, let companyPrefix = job.target.companyPrefix, let run = job.run {
            return URL(string: job.server + "/" + companyPrefix + "/agents/" + job.target.id.uuidString.lowercased() + "/runs/" + run.uuidString.lowercased())
        }
        let label = job.issueLabel ?? ""
        let prefix = label.range(of: #"^[A-Z][A-Z0-9]{0,15}-[0-9]+$"#, options: .regularExpression) != nil ? String(label.split(separator: "-")[0]) + "/" : ""
        return URL(string: job.server + "/" + prefix + "issues/" + issue.uuidString.lowercased())
    }
    private func persist() throws {
        do { try store.save(jobs) } catch { storageFailed = true; message = HandoffProblem.storage.localizedDescription; throw HandoffProblem.storage }
    }
    private func safe(_ error: Error) -> String { (error as? HandoffProblem)?.localizedDescription ?? HandoffProblem.unavailable.localizedDescription }
}
