import XCTest
@testable import ModuleCore

@MainActor final class EmberConversationReadProducerTests: XCTestCase {
    private let company = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
    private let agent = UUID(uuidString: "a2222222-2222-4222-8222-222222222222")!
    private let origin = "https://fuego-bridge.curtishome.org"
    private func body(user: String = "owner") throws -> String {
        let value: [String: Any] = ["conversation": ["id": UUID().uuidString.lowercased(), "companyId": company.uuidString.lowercased(),
            "agentId": agent.uuidString.lowercased(), "userId": user, "state": "waiting"], "messages": [], "turns": [],
            "hasEarlierMessages": false, "limits": ["maxTextBytes": 4096, "maxEnvelopeBytes": 8192, "maxContextBytes": 8192]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func raw(user: String = "owner") throws -> [String: Any] {
        ["status": 200, "contentType": "application/json; charset=utf-8", "body": try body(user: user), "beforeUser": user, "afterUser": user]
    }
    func testRawOriginPresenceAndExplicitChoice() throws {
        for saved in [nil, "", "http://fuego-bridge.curtishome.org", "https://user:password@fuego-bridge.curtishome.org"] as [String?] {
            var selection = EmberConversationReadOrigin(saved: saved)
            XCTAssertFalse(selection.qualified)
            XCTAssertEqual(selection.endpoint.origin, origin)
            selection.selectDisplayed(); XCTAssertTrue(selection.qualified)
        }
        XCTAssertTrue(EmberConversationReadOrigin(saved: origin).qualified)
        XCTAssertEqual(EmberConversationReadOrigin(saved: "https://another-provider.org").endpoint.origin, "https://another-provider.org")
    }
    func testMissingOwnerOrQualificationCannotBegin() throws {
        let owner = EmberConversationReadOwner()
        XCTAssertThrowsError(try owner.begin(qualified: false, selection: 1, now: 0))
        XCTAssertThrowsError(try owner.begin(qualified: true, selection: nil, now: 0))
        XCTAssertThrowsError(try owner.begin(qualified: true, selection: 0, now: 0))
        XCTAssertThrowsError(try owner.begin(qualified: true, selection: 1, now: .nan))
    }
    func testRetirementCloseAndSupersessionRefuseLateResults() throws {
        let owner = EmberConversationReadOwner()
        let first = try owner.begin(qualified: true, selection: 1, now: 100)
        owner.retire() // Same maintained retirement used by page and cookie hooks.
        XCTAssertThrowsError(try owner.check(first, qualified: true, selection: 1, now: 101, cancelled: false))
        let second = try owner.begin(qualified: true, selection: 1, now: 102)
        let third = try owner.begin(qualified: true, selection: 1, now: 103)
        owner.finish(second) // An older cleanup must not clear its successor.
        XCTAssertThrowsError(try owner.check(second, qualified: true, selection: 1, now: 104, cancelled: false))
        XCTAssertNoThrow(try owner.check(third, qualified: true, selection: 1, now: 104, cancelled: false))
        owner.close()
        XCTAssertThrowsError(try owner.check(third, qualified: true, selection: 1, now: 105, cancelled: false))
        XCTAssertThrowsError(try owner.begin(qualified: true, selection: 1, now: 106))
    }
    func testCancellationSelectionAndSingleTotalDeadline() throws {
        let owner = EmberConversationReadOwner(), start = 100.0
        let ticket = try owner.begin(qualified: true, selection: 4, now: start)
        XCTAssertNoThrow(try owner.check(ticket, qualified: true, selection: 4, now: 12_099.99, cancelled: false))
        for now in [99, 12_100, .infinity, .nan] {
            XCTAssertThrowsError(try owner.check(ticket, qualified: true, selection: 4, now: now, cancelled: false))
        }
        XCTAssertThrowsError(try owner.check(ticket, qualified: true, selection: 6, now: 101, cancelled: false))
        XCTAssertThrowsError(try owner.check(ticket, qualified: false, selection: 4, now: 101, cancelled: false))
        XCTAssertThrowsError(try owner.check(ticket, qualified: true, selection: 4, now: 101, cancelled: true)) { XCTAssertTrue($0 is CancellationError) }
    }
    func testIndependentHumanJoinAndOriginalBytes() throws {
        let owner = EmberConversationReadOwner(), ticket = try owner.begin(qualified: true, selection: 1, now: 100)
        let projection = try raw()
        let bytes = try owner.accept(projection, ticket: ticket, origin: origin, company: company, agent: agent,
            qualified: true, selection: 1, now: 101, cancelled: false)
        XCTAssertEqual(bytes, Data((projection["body"] as! String).utf8))
        for field in ["beforeUser", "afterUser"] {
            var changed = projection; changed[field] = "another-owner"
            XCTAssertThrowsError(try owner.accept(changed, ticket: ticket, origin: origin, company: company, agent: agent,
                qualified: true, selection: 1, now: 101, cancelled: false))
        }
        // Canonically equivalent Swift strings are distinct opaque actor bytes.
        var changed = try raw(user: "\u{e9}"); changed["afterUser"] = "e\u{301}"
        XCTAssertThrowsError(try owner.accept(changed, ticket: ticket, origin: origin, company: company, agent: agent,
            qualified: true, selection: 1, now: 101, cancelled: false))
        owner.retire()
        XCTAssertThrowsError(try owner.check(ticket, qualified: true, selection: 1, now: 102, cancelled: false))
    }
    func testMalformedAndDeniedProjectionPreserveSafeErrors() throws {
        let owner = EmberConversationReadOwner(), ticket = try owner.begin(qualified: true, selection: 1, now: 0)
        for status in [true, 0, 401, 403, 503] as [Any] {
            var projection = try raw(); projection["status"] = status
            XCTAssertThrowsError(try owner.accept(projection, ticket: ticket, origin: origin, company: company, agent: agent,
                qualified: true, selection: 1, now: 1, cancelled: false)) {
                if let status = status as? Int, status == 401 { XCTAssertEqual($0.localizedDescription, HandoffProblem.signIn.localizedDescription) }
            }
        }
        var projection = try raw(); projection["private"] = "AUTHORED_PRIVATE_CANARY"
        XCTAssertThrowsError(try owner.accept(projection, ticket: ticket, origin: origin, company: company, agent: agent,
            qualified: true, selection: 1, now: 1, cancelled: false)) { XCTAssertFalse($0.localizedDescription.contains("AUTHORED_PRIVATE_CANARY")) }
    }
    func testActualControllerInitialAndFallbackSelectionStillPopulateTargets() async throws {
        let api = ProducerAPI(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = HandoffController(api: api, store: HandoffStore(url: root.appendingPathComponent("jobs.json")), route: .conversation)
        await controller.refreshTargets()
        XCTAssertEqual(controller.company, api.company); XCTAssertEqual(controller.targets.count, 1)
        let epoch = controller.conversationReadGeneration
        controller.company = api.other; controller.company = api.company
        XCTAssertGreaterThan(controller.conversationReadGeneration, epoch)
        api.company = api.other; await controller.refreshTargets()
        XCTAssertEqual(controller.company, api.other); XCTAssertEqual(controller.targets.count, 1)
        controller.invalidate(); XCTAssertGreaterThan(controller.conversationReadGeneration, epoch)
    }
    func testActualPollingFiltersHistoricalCompaniesBeforeFourJobLimit() async throws {
        let api = ProducerAPI(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HandoffStore(url: root.appendingPathComponent("jobs.json"))
        var jobs: [HandoffJob] = []
        for selected in [api.other, api.other, api.other, api.other, api.company] {
            var job = try HandoffJob(server: api.server, target: HandoffTarget.decode(api.agent(selected), company: selected, companyName: "Test"), task: "Authored read only")
            job.route = .conversation; jobs.append(job)
        }
        try store.save(jobs)
        let controller = HandoffController(api: api, store: store, route: .conversation)
        await controller.refreshTargets(); await controller.poll()
        XCTAssertEqual(api.reads, [jobs.last!.id]); XCTAssertEqual(controller.jobs.count, 5)
        XCTAssertEqual(controller.jobs.map(\.target.company), jobs.map(\.target.company))
    }
}

@MainActor private final class ProducerAPI: FuegoAPI {
    let server = "https://fuego-bridge.curtishome.org"
    var company = UUID(uuidString: "b1111111-1111-4111-8111-111111111111")!
    let other = UUID(uuidString: "b2222222-2222-4222-8222-222222222222")!
    var reads: [UUID] = []
    func agent(_ company: UUID) -> [String: Any] {
        ["id": "b3333333-3333-4333-8333-333333333333", "companyId": company.uuidString, "name": "Authored agent", "status": "idle", "adapterType": "fuego_remote",
         "adapterConfig": ["deviceId": "b4444444-4444-4444-8444-444444444444", "workspaceHandle": "authored", "accountHandle": "authored", "provider": "codex", "instructions": "Authored test only"]]
    }
    func request(_ request: FuegoRequest) async throws -> Data {
        let value: Any
        switch request {
        case .companies: value = [["id": company.uuidString, "name": "Authored company"]]
        case .agents(let id): value = [agent(id)]
        case .conversation(let job): reads.append(job.id); throw HandoffProblem.unavailable
        default: throw HandoffProblem.invalid
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
