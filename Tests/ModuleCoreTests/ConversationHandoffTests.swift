import XCTest
import NookPluginSDK
@testable import ModuleCore

private let company = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
private let agentID = UUID(uuidString: "a2222222-2222-4222-8222-222222222222")!
private let device = UUID(uuidString: "a3333333-3333-4333-8333-333333333333")!
private let conversationID = UUID(uuidString: "a4444444-4444-4444-8444-444444444444")!
private let runID = UUID(uuidString: "a5555555-5555-4555-8555-555555555555")!
private let messageID = UUID(uuidString: "a6666666-6666-4666-8666-666666666666")!
private let replyID = UUID(uuidString: "a7777777-7777-4777-8777-777777777777")!
private func agent() -> [String: Any] {
    ["id": agentID.uuidString, "companyId": company.uuidString, "name": "Test agent", "status": "idle", "adapterType": "fuego_remote", "adapterConfig": ["deviceId": device.uuidString, "workspaceHandle": "private-workspace", "accountHandle": "test-account", "provider": "codex", "instructions": "Use the reviewed task."]]
}
private func snapshot(_ job: HandoffJob?, status: String = "pending", run: Bool = true) -> [String: Any] {
    let binding: [String: Any] = ["id": conversationID.uuidString, "companyId": company.uuidString, "agentId": agentID.uuidString, "userId": "test-owner", "state": "waiting"]
    var messages: [[String: Any]] = [], turns: [[String: Any]] = []
    if let job {
        messages.append(["id": messageID.uuidString, "role": "user", "body": job.task, "clientRequestId": job.id.uuidString, "runId": NSNull()])
        var turn: [String: Any] = ["id": messageID.uuidString, "clientRequestId": job.id.uuidString, "status": status, "runId": run ? runID.uuidString as Any : NSNull(), "replyMessageId": NSNull(), "error": NSNull()]
        if status == "succeeded" {
            turn["replyMessageId"] = replyID.uuidString
            messages.append(["id": replyID.uuidString, "role": "assistant", "body": "Exact published answer", "clientRequestId": NSNull(), "runId": runID.uuidString])
        }
        if status == "uncertain" { turn["error"] = "Cancellation is waiting for confirmed stop on the computer." }
        turns.append(turn)
    }
    return ["conversation": binding, "messages": messages, "turns": turns, "hasEarlierMessages": false, "limits": ["maxTextBytes": 4096, "maxEnvelopeBytes": 8192, "maxContextBytes": 8192]]
}
@MainActor private final class ConversationAPI: FuegoAPI {
    let server = "https://fuego-bridge.curtishome.org"
    var job: HandoffJob?
    var status = "pending", withRun = true
    var busy = false, lostSend = false, lostCancel = false
    var sends = 0, cancels = 0, legacyWrites = 0
    var paths: [String] = []
    func request(_ request: FuegoRequest) async throws -> Data {
        paths.append(request.path)
        let value: Any
        switch request {
        case .companies: value = [["id": company.uuidString, "name": "Test organization", "issuePrefix": "TEST"]]
        case .agents: value = [agent()]
        case .agent: value = agent()
        case .conversation:
            var current = snapshot(job, status: status, run: withRun)
            if busy { current["turns"] = [["status": "running"]] }
            value = current
        case .sendConversation(let original):
            sends += 1; job = original
            if lostSend { throw HandoffProblem.unavailable }
            value = snapshot(original, status: status, run: withRun)
        case .cancelRemote(let run):
            cancels += 1
            if lostCancel { throw HandoffProblem.unavailable }
            value = ["id": run.uuidString, "companyId": company.uuidString, "agentId": agentID.uuidString, "status": "cancelled"]
        case .cancelConversation: throw HandoffProblem.invalid
        case .events: value = [["seq": 1, "runId": runID.uuidString, "eventType": "fuego.dispatch", "message": "Dispatched to the selected computer"]]
        case .create, .invoke, .cancel: legacyWrites += 1; throw HandoffProblem.invalid
        default: throw HandoffProblem.invalid
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
@MainActor final class ConversationHandoffTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func controller(_ api: ConversationAPI) -> HandoffController { .init(api: api, store: .init(url: root.appendingPathComponent("jobs.json")), route: .conversation) }
    private func prepared(_ api: ConversationAPI) async throws -> HandoffController {
        let model = controller(api); await model.refreshTargets(); try model.prepare(target: agentID, task: "Return the exact requested answer."); return model
    }
    private func job() throws -> HandoffJob {
        var job = try HandoffJob(server: ConversationAPI().server, target: HandoffTarget.decode(agent(), company: company, companyName: "Test", companyPrefix: "TEST"), task: "Return the exact requested answer.")
        job.route = .conversation; return job
    }
    func testWaitTracksExactDraftAndOnlyCompletesOnItsPublishedAnswer() async throws {
        let api = ConversationAPI(), model = try await prepared(api), waiter = HandoffWaitController(controller: model)
        let id = model.review!.id, request = UUID(); var updates: [PluginRunUpdate] = []
        waiter.send = { received, update in XCTAssertEqual(received, request); updates.append(update) }
        try waiter.start(request, values: ["request_id": .string(id.uuidString)])
        await waiter.tick(); XCTAssertEqual(updates.last?.phase, .running); XCTAssertEqual(api.sends, 0)
        await model.approve(id); api.status = "running"; await model.poll(); await waiter.tick()
        XCTAssertEqual(updates.last?.phase, .running)
        model.selectedJob = UUID() // User selection is not the correlation authority.
        api.status = "succeeded"; await model.poll(); await waiter.tick()
        XCTAssertEqual(updates.last?.phase, .succeeded)
        XCTAssertEqual(updates.last?.values["result"], .string("Exact published answer"))
        XCTAssertEqual(updates.last?.values["request_id"], .string(id.uuidString))
        try HandoffActions.wait.output.validate(updates.last!.values)
        let count = updates.count; await waiter.tick(); XCTAssertEqual(updates.count, count)
        XCTAssertEqual(api.sends, 1); XCTAssertEqual(api.cancels, 0)
    }
    func testWaitStopBeforeSendDiscardsOnlyItsDraftWithoutRemoteMutation() async throws {
        let api = ConversationAPI(), model = try await prepared(api), waiter = HandoffWaitController(controller: model)
        let request = UUID(), id = model.review!.id; var last: PluginRunUpdate?
        waiter.send = { _, update in last = update }
        try waiter.start(request, values: ["request_id": .string(id.uuidString)])
        waiter.requestCancel(request); await waiter.tick(); await model.approve(id)
        XCTAssertEqual(last?.phase, .cancelled); XCTAssertNil(model.review)
        XCTAssertEqual(api.sends, 0); XCTAssertEqual(api.cancels, 0)
    }
    func testWaitStopSendsOnceAndWaitsForBoundRemoteCancellation() async throws {
        let api = ConversationAPI(), model = try await prepared(api), waiter = HandoffWaitController(controller: model)
        let id = model.review!.id, request = UUID(); var last: PluginRunUpdate?
        waiter.send = { _, update in last = update }
        try waiter.start(request, values: ["request_id": .string(id.uuidString)])
        await model.approve(id); api.status = "running"; await model.poll()
        waiter.requestCancel(request); await waiter.tick(); waiter.requestCancel(request); await waiter.tick()
        XCTAssertEqual(last?.phase, .cancelling); XCTAssertEqual(api.cancels, 1)
        api.status = "uncertain"; await model.poll(); await waiter.tick()
        XCTAssertEqual(last?.phase, .cancelling)
        api.status = "cancelled"; await model.poll(); await waiter.tick()
        XCTAssertEqual(last?.phase, .cancelled); XCTAssertEqual(api.sends, 1); XCTAssertEqual(api.cancels, 1)
    }
    func testWaitCancelBeforeRunIDWaitsAndCancelsTheOriginalOnceItIsKnown() async throws {
        let api = ConversationAPI(); api.withRun = false
        let model = try await prepared(api), waiter = HandoffWaitController(controller: model)
        let id = model.review!.id, request = UUID(); var last: PluginRunUpdate?
        waiter.send = { _, update in last = update }
        try waiter.start(request, values: ["request_id": .string(id.uuidString)])
        await model.approve(id); waiter.requestCancel(request); await waiter.tick()
        XCTAssertEqual(last?.phase, .cancelling); XCTAssertEqual(api.cancels, 0)
        api.withRun = true; api.status = "running"; await model.poll(); await waiter.tick()
        XCTAssertEqual(api.cancels, 1); XCTAssertEqual(last?.phase, .cancelling)
        api.status = "cancelled"; await model.poll(); await waiter.tick()
        XCTAssertEqual(last?.phase, .cancelled); XCTAssertEqual(api.sends, 1)
    }
    func testLostWaitStopAcknowledgementNeverRetriesAndDeadlineIsUnknown() async throws {
        let api = ConversationAPI(), model = try await prepared(api), waiter = HandoffWaitController(controller: model)
        let id = model.review!.id, request = UUID(), now = Date(); var last: PluginRunUpdate?
        waiter.send = { _, update in last = update }
        try waiter.start(request, values: ["request_id": .string(id.uuidString)], now: now)
        await model.approve(id); api.lostCancel = true; waiter.requestCancel(request)
        await waiter.tick(); await waiter.tick()
        XCTAssertEqual(api.cancels, 1); XCTAssertEqual(last?.phase, .cancelling)
        await waiter.tick(now: now.addingTimeInterval(3601))
        XCTAssertEqual(last?.phase, .interrupted); XCTAssertEqual(api.cancels, 1)
        XCTAssertTrue(last?.message.contains("unknown") == true)
    }
    func testWaitExpiryMissingIDAndDuplicateBindingsNeverSend() async throws {
        let api = ConversationAPI(), model = try await prepared(api), waiter = HandoffWaitController(controller: model)
        let id = model.review!.id, request = UUID(); var last: PluginRunUpdate?
        waiter.send = { _, update in last = update }
        XCTAssertThrowsError(try waiter.start(UUID(), values: ["request_id": .string(UUID().uuidString)]))
        try waiter.start(request, values: ["request_id": .string(id.uuidString)])
        XCTAssertThrowsError(try waiter.start(UUID(), values: ["request_id": .string(id.uuidString)]))
        await waiter.tick(now: model.review!.expires.addingTimeInterval(1))
        XCTAssertEqual(last?.phase, .cancelled); XCTAssertEqual(api.sends, 0)
    }
    func testWaitPreservesSuccessWhenStopRacesCompletionAndBoundsUTF8Result() async throws {
        let api = ConversationAPI(), model = try await prepared(api), waiter = HandoffWaitController(controller: model)
        let id = model.review!.id, request = UUID(); var last: PluginRunUpdate?
        waiter.send = { _, update in last = update }
        try waiter.start(request, values: ["request_id": .string(id.uuidString)])
        await model.approve(id); api.status = "succeeded"; waiter.requestCancel(request); await waiter.tick()
        XCTAssertEqual(last?.phase, .succeeded); XCTAssertEqual(api.cancels, 0)
        XCTAssertLessThanOrEqual(HandoffJob.bounded(String(repeating: "字🙂", count: 1000), bytes: 2048).utf8.count, 2048)
    }
    func testSDKPreparesOnlyAReviewAndCannotOverwriteTheDraftOrSend() async throws {
        let api = ConversationAPI(), model = controller(api); await model.refreshTargets()
        let values: [String: PluginValue] = ["target_id": .string(agentID.uuidString), "task": .string("Draft from a workflow.")]
        let result = try HandoffActions.prepareDraft(values, controller: model)
        try HandoffActions.prepare.output.validate(result)
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(result["review_id"], .string(review.id.uuidString))
        XCTAssertEqual(api.sends, 0); XCTAssertEqual(api.legacyWrites, 0); XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertThrowsError(try HandoffActions.prepareDraft(values, controller: model)); XCTAssertEqual(model.review, review)
        XCTAssertEqual(HandoffActions.statusValues(nil, review: review)["phase"], .string("Waiting for your review"))
        await model.approve(review.id)
        XCTAssertEqual(api.sends, 1); XCTAssertEqual(model.jobs.first?.id, review.id)
        try HandoffActions.read.output.validate(HandoffActions.statusValues(model.jobs.first))
    }
    func testSDKRejectsExtraFieldsInvalidTargetsAndContextReset() async throws {
        let api = ConversationAPI(), model = controller(api); await model.refreshTargets()
        for values: [String: PluginValue] in [
            ["target_id": .string(agentID.uuidString), "task": .string("Draft"), "approve": .boolean(true)],
            ["target_id": .string(UUID().uuidString), "task": .string("Draft")],
            ["target_id": .string(agentID.uuidString), "task": .string("/new")]
        ] { XCTAssertThrowsError(try HandoffActions.prepareDraft(values, controller: model)) }
        XCTAssertNil(model.review); XCTAssertTrue(model.jobs.isEmpty); XCTAssertEqual(api.sends, 0)
    }
    func testSDKCatalogIsBoundedAndOmitsInstructionsAndAccountDetails() throws {
        let target = try HandoffTarget.decode(agent(), company: company, companyName: String(repeating: "字", count: 50))
        let values = HandoffActions.targetValues(Array(repeating: target, count: 20))
        try HandoffActions.list.output.validate(values)
        guard case .string(let raw) = values["targets"] else { return XCTFail("Expected target catalog") }
        XCTAssertLessThanOrEqual(raw.utf8.count, 2048)
        XCTAssertFalse(raw.contains(target.instructions)); XCTAssertFalse(raw.contains(target.account)); XCTAssertFalse(raw.contains(target.device.uuidString))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: String]])
        XCTAssertLessThanOrEqual(rows.count, 12); XCTAssertEqual(values["count"], .number(Double(rows.count)))
    }
    func testReviewedSendUsesOnlyPrivateConversationFieldsAndNeverGeneralTaskMutation() async throws {
        let api = ConversationAPI(), model = try await prepared(api)
        XCTAssertEqual(api.sends, 0)
        let id = model.review!.id; await model.approve(id); await model.approve(id)
        XCTAssertEqual(api.sends, 1); XCTAssertEqual(api.legacyWrites, 0)
        XCTAssertEqual(model.jobs[0].id, id); XCTAssertEqual(model.jobs[0].route, .conversation)
        XCTAssertEqual(model.jobs[0].conversationUser, "test-owner"); XCTAssertEqual(model.jobs[0].run, runID)
        let request = FuegoRequest.sendConversation(model.jobs[0])
        XCTAssertEqual(Set(request.body!.keys), Set(["body", "clientRequestId"]))
        XCTAssertEqual(request.body?["clientRequestId"] as? String, id.uuidString.lowercased())
        XCTAssertTrue(request.path.hasSuffix("/messages")); XCTAssertFalse(request.path.contains("/issues"))
        XCTAssertEqual(model.inspectURL(id)?.absoluteString, api.server + "/TEST/agents/" + agentID.uuidString.lowercased() + "/runs/" + runID.uuidString.lowercased())
    }
    func testExistingUnsettledTurnBlocksBeforeAnyWrite() async throws {
        let api = ConversationAPI(), model = try await prepared(api); api.busy = true
        let id = model.review!.id
        let waiter = HandoffWaitController(controller: model), request = UUID()
        var last: PluginRunUpdate?
        waiter.send = { _, update in last = update }
        try waiter.start(request, values: ["request_id": .string(id.uuidString)])
        await model.approve(id); await waiter.tick()
        XCTAssertEqual(api.sends, 0); XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertTrue(model.message.contains("unsettled turn"))
        XCTAssertEqual(last?.phase, .failed)
        XCTAssertTrue(last?.message.contains("unsettled turn") == true)
        XCTAssertTrue(last?.message.contains("No job was submitted") == true)
        XCTAssertNil(model.reviewFailure(id, server: "https://different.example"))
        // A later draft cannot erase the original refusal or inherit it.
        try model.prepare(target: agentID, task: "Another explicitly reviewed task.")
        let newID = model.review!.id
        XCTAssertNil(model.reviewFailure(newID, server: api.server))
        XCTAssertNotNil(model.reviewFailure(id, server: api.server))
        api.busy = false; await model.approve(newID)
        XCTAssertEqual(api.sends, 1); XCTAssertEqual(model.jobs.first?.id, newID)
    }
    func testSavedPendingTurnWithoutRunResolvesByReadingOriginalRequest() async throws {
        let api = ConversationAPI(); api.withRun = false
        let model = try await prepared(api); await model.approve(model.review!.id)
        XCTAssertEqual(model.jobs[0].phase, .queued); XCTAssertNil(model.jobs[0].run)
        api.withRun = true; api.status = "running"; await model.poll()
        XCTAssertEqual(model.jobs[0].run, runID); XCTAssertEqual(model.jobs[0].phase, .running)
        XCTAssertFalse(model.jobs[0].admitted, "Resolving the original conversation run does not establish computer admission."); XCTAssertEqual(api.sends, 1)
    }
    func testLostSendRecoveryAndRestartNeverResend() async throws {
        let api = ConversationAPI(), model = try await prepared(api); api.lostSend = true
        await model.approve(model.review!.id)
        XCTAssertEqual(model.jobs[0].phase, .uncertain); XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.reviewFailure(model.jobs[0].id, server: api.server), "A lost POST response is not a confirmed preflight refusal")
        let reopened = controller(api); await reopened.reconcile(reopened.jobs[0].id)
        XCTAssertEqual(reopened.jobs[0].phase, .queued); XCTAssertEqual(reopened.jobs[0].run, runID)
        XCTAssertEqual(api.sends, 1); XCTAssertTrue(reopened.canSubmit)
    }
    func testPublishedReplySurvivesRestartAndNoReplay() async throws {
        let api = ConversationAPI(), model = try await prepared(api); await model.approve(model.review!.id)
        api.status = "succeeded"; await model.poll()
        XCTAssertEqual(model.jobs[0].result, "Exact published answer"); XCTAssertEqual(model.jobs[0].phase, .succeeded)
        let reopened = controller(api); await reopened.poll()
        XCTAssertEqual(reopened.jobs[0].result, "Exact published answer"); XCTAssertEqual(api.sends, 1)
    }
    func testMalformedOrUnrelatedSuccessCannotMutateReceipt() throws {
        let original = try job()
        for key in ["companyId", "agentId", "userId", "id"] {
            var receipt = original, response = snapshot(original, status: "succeeded")
            var binding = response["conversation"] as! [String: Any]
            binding[key] = key == "userId" ? "other-owner" : UUID().uuidString
            response["conversation"] = binding
            receipt.conversationUser = "test-owner"; receipt.issue = conversationID
            let saved = receipt
            XCTAssertThrowsError(try receipt.receiveConversation(response)); XCTAssertEqual(receipt, saved)
        }
        for mutation in ["task", "request", "replyRun", "missingReply", "status"] {
            var receipt = original, response = snapshot(original, status: "succeeded")
            var messages = response["messages"] as! [[String: Any]], turns = response["turns"] as! [[String: Any]]
            switch mutation {
            case "task": messages[0]["body"] = "Another task"
            case "request": messages[0]["clientRequestId"] = UUID().uuidString
            case "replyRun": messages[1]["runId"] = UUID().uuidString
            case "missingReply": messages.removeLast()
            default: turns[0]["status"] = "invented"
            }
            response["messages"] = messages; response["turns"] = turns
            XCTAssertThrowsError(try receipt.receiveConversation(response)); XCTAssertEqual(receipt, original)
        }
    }
    func testCancellationWaitsForAuthoritativeStopAndIsNeverRepeated() async throws {
        let api = ConversationAPI(); api.status = "running"
        let model = try await prepared(api); await model.approve(model.review!.id)
        let id = model.jobs[0].id; api.status = "uncertain"; await model.cancel(id); await model.cancel(id)
        XCTAssertEqual(model.jobs[0].phase, .cancelling); XCTAssertEqual(api.cancels, 1)
        let request = FuegoRequest.cancelRemote(runID)
        XCTAssertTrue(request.body!.isEmpty); XCTAssertTrue(request.path.hasSuffix(runID.uuidString.lowercased() + "/cancel"))
        api.status = "cancelled"; await model.poll(); XCTAssertEqual(model.jobs[0].phase, .cancelled)
    }
    func testLostCancellationRemainsReadOnlyAfterRestart() async throws {
        let api = ConversationAPI(), model = try await prepared(api); await model.approve(model.review!.id)
        api.lostCancel = true; let id = model.jobs[0].id; await model.cancel(id)
        let reopened = controller(api); await reopened.cancel(id); api.status = "running"; await reopened.poll()
        XCTAssertEqual(api.cancels, 1); XCTAssertEqual(reopened.jobs[0].phase, .cancelling)
    }
    func testDelayedConfirmedStopReplacesItsTransportWarning() async throws {
        let api = ConversationAPI(), model = try await prepared(api); await model.approve(model.review!.id)
        api.lostCancel = true; await model.cancel(model.jobs[0].id)
        XCTAssertTrue(model.message.contains("unavailable"))
        api.status = "cancelled"; await model.poll()
        XCTAssertEqual(model.jobs[0].phase, .cancelled)
        XCTAssertTrue(model.message.contains("confirms this conversation turn cancelled"))
        XCTAssertEqual(api.cancels, 1)
    }
    func testAlreadySettledTurnAvoidsStopMutation() async throws {
        let api = ConversationAPI(), model = try await prepared(api); await model.approve(model.review!.id)
        api.status = "succeeded"; await model.cancel(model.jobs[0].id)
        XCTAssertEqual(api.cancels, 0); XCTAssertEqual(model.jobs[0].phase, .succeeded)
        XCTAssertEqual(model.jobs[0].result, "Exact published answer")
    }
    func testForeignRunAndTerminalRegressionAreRejectedOrIgnored() throws {
        var receipt = try job(); try receipt.receiveConversation(snapshot(receipt, status: "succeeded"))
        let final = receipt
        try receipt.receiveConversation(snapshot(receipt, status: "running")); XCTAssertEqual(receipt, final)
        var foreign = snapshot(receipt, status: "succeeded"), turns = foreign["turns"] as! [[String: Any]]
        turns[0]["runId"] = UUID().uuidString; foreign["turns"] = turns
        XCTAssertThrowsError(try receipt.receiveConversation(foreign)); XCTAssertEqual(receipt, final)
    }
    func testLegacyReceiptsDecodeAndConversationResetIsNeverSubmitted() async throws {
        var original = try job(); original.route = nil; original.conversationUser = nil
        let encoded = try JSONEncoder().encode(original)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "route"); object.removeValue(forKey: "conversationUser")
        let decoded = try JSONDecoder().decode(HandoffJob.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.route); XCTAssertNil(decoded.conversationUser)
        let api = ConversationAPI(), model = try await prepared(api)
        XCTAssertThrowsError(try model.prepare(target: agentID, task: "/new")); XCTAssertEqual(api.sends, 0)
    }
}
