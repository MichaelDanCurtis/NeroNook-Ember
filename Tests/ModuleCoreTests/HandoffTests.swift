import XCTest
@testable import ModuleCore

private let companyID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let agentID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let deviceID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let issueID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
private let runID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
private func agent(_ workspace: String = "test-workspace") -> [String: Any] {
    ["id": agentID.uuidString, "companyId": companyID.uuidString, "name": "Test agent", "status": "idle", "adapterType": "fuego_remote", "adapterConfig": ["deviceId": deviceID.uuidString, "accountHandle": "test-account", "workspaceHandle": workspace, "instructions": "Return the requested answer.", "provider": "codex"]]
}
private func makeRun(_ status: String, result: [String: Any] = [:]) -> [String: Any] {
    ["id": runID.uuidString, "companyId": companyID.uuidString, "agentId": agentID.uuidString, "status": status, "resultJson": result]
}
@MainActor private final class FakeAPI: FuegoAPI {
    let server = "https://fuego-bridge.curtishome.org"
    var workspace = "test-workspace"
    var paths: [String] = []
    var creates = 0, invokes = 0, cancels = 0
    var loseCreate = false, loseInvoke = false, loseCancel = false, loseEvents = false
    var status = "queued"
    var result: [String: Any] = [:]
    var createdJob: HandoffJob?
    var foundRunCount = 1
    var rejectOrigin = false
    func request(_ request: FuegoRequest) async throws -> Data {
        paths.append(request.path)
        let value: Any
        switch request {
        case .companies: value = [["id": companyID.uuidString, "name": "Test organization"]]
        case .agents: value = [agent(workspace)]
        case .agent: value = agent(workspace)
        case .create(let job):
            creates += 1; createdJob = job; if rejectOrigin { throw HandoffProblem.untrustedOrigin }; if loseCreate { throw HandoffProblem.unavailable }
            value = ["id": issueID.uuidString, "companyId": companyID.uuidString, "assigneeAgentId": agentID.uuidString, "identifier": "TEST-1", "status": "backlog", "description": job.task]
        case .invoke: invokes += 1; if loseInvoke { throw HandoffProblem.unavailable }; value = makeRun(status, result: result)
        case .run: value = makeRun(status, result: result)
        case .events(let target):
            if loseEvents { throw HandoffProblem.unavailable }
            value = [["id": 1, "companyId": target.companyID.uuidString.lowercased(),
                      "agentId": target.agentID.uuidString.lowercased(), "runId": target.runID.uuidString.lowercased(),
                      "seq": target.afterSeq + 1, "eventType": "fuego.dispatch", "stream": "system", "level": "info",
                      "color": NSNull(), "message": "Dispatched to selected computer", "payload": NSNull(),
                      "createdAt": "2026-10-30T12:00:00Z"]]
        case .cancel: cancels += 1; if loseCancel { throw HandoffProblem.unavailable }; value = makeRun(status, result: result)
        case .findTask:
            if let job = createdJob {
                var task = FuegoRequest.create(job).body!; task["id"] = issueID.uuidString; task["companyId"] = companyID.uuidString; task["identifier"] = "TEST-1"; value = [task]
            } else { value = [] as [[String: Any]] }
        case .findRuns:
            var run = makeRun(status, result: result); run["issueId"] = issueID.uuidString
            value = invokes > 0 ? Array(repeating: run, count: foundRunCount) : []
        case .conversation, .sendConversation, .cancelConversation, .cancelRemote: throw HandoffProblem.invalid
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
@MainActor final class HandoffTests: XCTestCase {
    var directory: URL!
    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }
    private func controller(_ api: FakeAPI) -> HandoffController { .init(api: api, store: .init(url: directory.appendingPathComponent("jobs.json"))) }
    private func prepared(_ api: FakeAPI) async throws -> HandoffController {
        let model = controller(api); await model.refreshTargets(); try model.prepare(target: agentID, task: "Return Nook handoff check."); return model
    }
    func testReviewDoesNotMutateAndApproveCreatesOneBacklogTaskAndRun() async throws {
        let api = FakeAPI(), model = try await prepared(api)
        XCTAssertEqual(api.creates, 0); XCTAssertEqual(api.invokes, 0)
        let id = model.review!.id; await model.approve(id); await model.approve(id)
        XCTAssertEqual(api.creates, 1); XCTAssertEqual(api.invokes, 1)
        XCTAssertEqual(model.jobs.first?.issue, issueID); XCTAssertEqual(model.jobs.first?.run, runID)
        XCTAssertEqual(model.jobs.first?.phase, .queued)
        let body = FuegoRequest.create(model.jobs[0]).body!
        XCTAssertEqual(body["status"] as? String, "backlog")
        let invoke = FuegoRequest.invoke(model.jobs[0]).body!
        XCTAssertEqual((invoke["payload"] as? [String: String])?["issueId"], issueID.uuidString.lowercased())
        XCTAssertNotNil(invoke["idempotencyKey"])
    }
    func testTargetChangeBeforeApprovalNeverMutates() async throws {
        let api = FakeAPI(), model = try await prepared(api); api.workspace = "changed-workspace"
        await model.approve(model.review!.id)
        XCTAssertEqual(api.creates, 0); XCTAssertEqual(api.invokes, 0)
        XCTAssertTrue(model.message.contains("configuration changed"))
    }
    func testExpiredOrDismissedReviewCannotExecute() async throws {
        let api = FakeAPI(), model = try await prepared(api), id = model.review!.id
        await model.approve(id, now: Date().addingTimeInterval(121)); XCTAssertEqual(api.creates, 0)
        try model.prepare(target: agentID, task: "Another task"); let another = model.review!.id
        model.dismissReview(); await model.approve(another); XCTAssertEqual(api.creates, 0)
    }
    func testLostCreateNeverResendsOriginalButAllowsADistinctTask() async throws {
        let api = FakeAPI(), model = try await prepared(api); api.loseCreate = true
        await model.approve(model.review!.id); await model.poll(); await model.refreshTargets()
        XCTAssertEqual(api.creates, 1); XCTAssertEqual(api.invokes, 0)
        XCTAssertEqual(model.jobs.first?.phase, .uncertain); XCTAssertTrue(model.canSubmit)
        XCTAssertThrowsError(try model.prepare(target: agentID, task: "Return Nook handoff check."))
        try model.prepare(target: agentID, task: "A separate unrelated task")
        let reopened = controller(api); XCTAssertEqual(reopened.jobs.first?.phase, .uncertain); XCTAssertTrue(reopened.canSubmit)
    }
    func testLostInvocationRetainsOriginalTaskAndNeverResends() async throws {
        let api = FakeAPI(), model = try await prepared(api); api.loseInvoke = true
        await model.approve(model.review!.id); await model.poll()
        XCTAssertEqual(api.invokes, 1); XCTAssertEqual(model.jobs.first?.issue, issueID)
        XCTAssertNil(model.jobs.first?.run); XCTAssertEqual(model.jobs.first?.phase, .uncertain)
        XCTAssertFalse(model.canSubmit)
    }
    func testExplicitOriginGuardRejectionIsFailedAndNeverRetried() async throws {
        let api = FakeAPI(), model = try await prepared(api); api.rejectOrigin = true
        await model.approve(model.review!.id); await model.poll()
        XCTAssertEqual(api.creates, 1); XCTAssertEqual(api.invokes, 0)
        XCTAssertEqual(model.jobs.first?.phase, .failed); XCTAssertNil(model.jobs.first?.run)
        XCTAssertTrue(model.message.contains("request's origin")); XCTAssertTrue(model.canSubmit)
    }
    func testProgressAndFinalResultUseOriginalRunAfterRestart() async throws {
        let api = FakeAPI(), model = try await prepared(api); await model.approve(model.review!.id)
        let reopened = controller(api); XCTAssertEqual(reopened.jobs.first?.phase, .uncertain)
        api.status = "running"; api.result = ["commandId": "authored-command"]; await reopened.poll()
        XCTAssertEqual(reopened.jobs.first?.phase, .running); XCTAssertTrue(reopened.jobs.first?.admitted == true)
        api.status = "succeeded"; api.result = ["state": "completed", "commandId": "command", "finalResponse": "Nook handoff check."]
        await reopened.poll(); XCTAssertEqual(reopened.jobs.first?.phase, .succeeded); XCTAssertEqual(reopened.jobs.first?.result, "Nook handoff check.")
        XCTAssertEqual(api.invokes, 1); XCTAssertEqual(api.creates, 1)
        XCTAssertEqual(controller(api).jobs.first?.result, "Nook handoff check.")
    }
    func testCancellationIsRequestedOnceAndNeverClaimedFromRunningResponse() async throws {
        let api = FakeAPI(), model = try await prepared(api); api.status = "running"; await model.approve(model.review!.id)
        let id = model.jobs[0].id; await model.cancel(id); await model.cancel(id)
        XCTAssertEqual(api.cancels, 1); XCTAssertEqual(model.jobs.first?.phase, .cancelling)
        api.status = "cancelled"; api.result = ["state": "cancelled"]; await model.poll(); XCTAssertEqual(model.jobs.first?.phase, .cancelled)
    }
    func testAmbiguousCancellationIsNotRetriedAfterReopen() async throws {
        let api = FakeAPI(), model = try await prepared(api); await model.approve(model.review!.id); api.loseCancel = true
        let id = model.jobs[0].id; await model.cancel(id)
        let reopened = controller(api); await reopened.cancel(id)
        XCTAssertEqual(api.cancels, 1); XCTAssertTrue(reopened.jobs[0].cancelSent)
        api.status = "running"; await reopened.poll(); XCTAssertEqual(reopened.jobs[0].phase, .cancelling)
    }
    func testControlPlaneCancellationAloneDoesNotClaimComputerStopped() async throws {
        let api = FakeAPI(), model = try await prepared(api); await model.approve(model.review!.id)
        api.status = "cancelled"; await model.cancel(model.jobs[0].id)
        XCTAssertEqual(model.jobs[0].phase, .cancelling)
        api.result = ["state": "cancelled"]; await model.poll()
        XCTAssertEqual(model.jobs[0].phase, .cancelled)
    }
    func testMissingEventsDoNotHideVerifiedResult() async throws {
        let api = FakeAPI(), model = try await prepared(api); await model.approve(model.review!.id)
        api.status = "succeeded"; api.result = ["state": "completed", "finalResponse": "Kept answer"]
        api.loseEvents = true; await model.poll()
        XCTAssertEqual(model.jobs[0].phase, .succeeded); XCTAssertEqual(model.jobs[0].result, "Kept answer")
        XCTAssertTrue(model.jobs[0].detail.contains("success"))
    }
    func testHistoryPermissionsAndScopedTaskLink() async throws {
        let api = FakeAPI(), model = try await prepared(api); await model.approve(model.review!.id)
        let path = directory.appendingPathComponent("jobs.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(model.inspectURL(model.jobs[0].id)?.absoluteString, api.server + "/TEST/issues/" + issueID.uuidString.lowercased())
    }
    func testReadOnlyReconciliationFindsLostInvocationWithoutRetry() async throws {
        let api = FakeAPI(), model = try await prepared(api); api.loseInvoke = true
        await model.approve(model.review!.id); let id = model.jobs[0].id
        XCTAssertNil(model.jobs[0].run); api.loseInvoke = false; await model.reconcile(id)
        XCTAssertEqual(model.jobs[0].run, runID); XCTAssertEqual(model.jobs[0].phase, .queued)
        XCTAssertEqual(api.creates, 1); XCTAssertEqual(api.invokes, 1); XCTAssertTrue(model.canSubmit)
    }
    func testReconciliationDoesNotGuessMissingOrAmbiguousRuns() async throws {
        let api = FakeAPI(), model = try await prepared(api); api.loseCreate = true
        await model.approve(model.review!.id); let id = model.jobs[0].id
        await model.reconcile(id); XCTAssertEqual(model.jobs[0].issue, issueID)
        XCTAssertNil(model.jobs[0].run); XCTAssertEqual(api.invokes, 0); XCTAssertFalse(model.canSubmit)
        api.invokes = 1; api.foundRunCount = 2; await model.reconcile(id)
        XCTAssertNil(model.jobs[0].run); XCTAssertFalse(model.canSubmit)
    }
    func testForeignRunAndUnknownStateAreRejected() throws {
        var job = try HandoffJob(server: FakeAPI().server, target: HandoffTarget.decode(agent(), company: companyID, companyName: "Test"), task: "Task")
        job.run = runID
        var foreign = makeRun("running"); foreign["agentId"] = deviceID.uuidString
        XCTAssertThrowsError(try job.receive(foreign)); XCTAssertThrowsError(try job.receive(makeRun("made-up")))
        XCTAssertThrowsError(try job.receiveEvents([["seq": 1, "runId": deviceID.uuidString, "message": "Wrong job"]]))
    }
    func testUncertainRemoteOutcomeOverridesSuccessAndTerminalCannotRegress() throws {
        var job = try HandoffJob(server: FakeAPI().server, target: HandoffTarget.decode(agent(), company: companyID, companyName: "Test"), task: "Task"); job.run = runID
        try job.receive(makeRun("succeeded", result: ["state": "uncertain"])); XCTAssertEqual(job.phase, .uncertain)
        try job.receive(makeRun("succeeded", result: ["state": "completed"])); XCTAssertEqual(job.phase, .succeeded)
        try job.receive(makeRun("running")); XCTAssertEqual(job.phase, .succeeded)
    }
    func testFormattingBoundsPreserveUnicodeAndTaskRejectsOversize() throws {
        let target = try HandoffTarget.decode(agent(), company: companyID, companyName: "Test")
        XCTAssertThrowsError(try HandoffJob(server: FakeAPI().server, target: target, task: String(repeating: "🐈", count: 513)))
        XCTAssertEqual(HandoffJob.bounded("🐈🐈猫", bytes: 8), "🐈🐈")
    }
    func testStorageFailurePreventsAnyExternalMutation() async throws {
        let api = FakeAPI(), blocked = directory.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let model = HandoffController(api: api, store: .init(url: blocked)); await model.refreshTargets()
        XCTAssertTrue(model.storageFailed); XCTAssertFalse(model.canSubmit); XCTAssertEqual(api.creates, 0)
    }
    func testServerRejectsCredentialsPathsAndUnencryptedLocalEndpoints() throws {
        for url in ["http://localhost:3100", "https://a:b@example.com", "https://server.example.com/path", "https://192.168.1.1", "https://host.local", "https://example.com?token=x"] { XCTAssertThrowsError(try FuegoServer(url)) }
        let server = try FuegoServer("https://fuego-bridge.curtishome.org/")
        XCTAssertTrue(server.contains(URL(string: server.origin + "/FUE/ember")))
        XCTAssertFalse(server.contains(URL(string: "https://evil.example.com")))
    }
}
