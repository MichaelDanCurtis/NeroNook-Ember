import XCTest
@testable import ModuleCore

@MainActor final class RunEventReadProducerTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) }; roots = [] }
    private func job(_ route: HandoffRoute = .task) throws -> HandoffJob {
        let target = HandoffTarget(id: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!, company: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!, companyName: "Authored", name: "Agent", device: UUID(), provider: "fixture", workspace: "fixture", account: "fixture", instructions: "", configuration: "fixture")
        var value = try HandoffJob(server: "https://fuego.example.org", target: target, task: "Authored task")
        value.run = UUID(); value.issue = UUID(); value.route = route; value.phase = .running
        value.events = ["existing"]; value.eventSequence = 4
        if route == .conversation { value.conversationUser = "opaque-human" }
        return value
    }
    private func row(_ target: RunEventReadTarget, seq: Int? = nil) -> [String: Any] {
        ["id": 1, "companyId": target.companyID.uuidString.lowercased(), "agentId": target.agentID.uuidString.lowercased(),
         "runId": target.runID.uuidString.lowercased(), "seq": seq ?? target.afterSeq + 1,
         "eventType": "fuego.dispatch", "stream": "future", "level": "", "color": NSNull(),
         "message": "event text", "payload": ["ready": true, "Stop": true, "zero": 0, "null": NSNull()],
         "createdAt": "2026-10-30T12:00Z", "future": ["opaque": "e\u{301}"]]
    }
    private func body(_ rows: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) }
    private func raw(_ data: Data, human: String = "opaque-human") -> [String: Any] {
        ["status": 200, "contentType": "application/json; charset=utf-8", "body": String(decoding: data, as: UTF8.self),
         "beforeUser": human, "afterUser": human, "eventGetCount": 1, "normalProofReadCount": 2]
    }
    private func controller(_ route: HandoffRoute, api: EventProducerAPI, clock: EventClock) throws -> (HandoffController, HandoffStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); roots.append(root)
        let store = HandoffStore(url: root.appendingPathComponent("jobs.json")), value = try job(route)
        try store.save([value]); api.job = value
        let model = HandoffController(api: api, store: store, route: route, eventClock: { clock.sample() })
        model.company = value.target.company; api.model = model
        return (model, store)
    }
    func testBoundTargetRejectsMissingRunInvalidCursorAndGenerationBeforeTransport() throws {
        var value = try job(); value.run = nil
        XCTAssertThrowsError(try RunEventReadTarget(job: value, generation: 1, now: 0))
        value.run = UUID()
        for cursor in [-1, 9_007_199_254_740_992] { value.eventSequence = cursor; XCTAssertThrowsError(try RunEventReadTarget(job: value, generation: 1, now: 0)) }
        value.eventSequence = 0
        for generation in [UInt64(0), UInt64(9_007_199_254_740_992)] { XCTAssertThrowsError(try RunEventReadTarget(job: value, generation: generation, now: 0)) }
        for now in [-1, Double.infinity, Double.nan] { XCTAssertThrowsError(try RunEventReadTarget(job: value, generation: 1, now: now)) }
        let target = try RunEventReadTarget(job: value, generation: 1, now: 0)
        XCTAssertEqual(FuegoRequest.events(target).path, "/api/heartbeat-runs/\(value.run!.uuidString.lowercased())/events?afterSeq=0&limit=50")
        XCTAssertEqual(FuegoRequest.events(target).method, "GET"); XCTAssertNil(FuegoRequest.events(target).body)
    }
    func testProductionEpochTransitionMakesExhaustionAbsorbing() {
        let maximum: UInt64 = 9_007_199_254_740_991
        XCTAssertEqual(RunEventReadProducerOwner.nextEpoch(1), 2)
        XCTAssertEqual(RunEventReadProducerOwner.nextEpoch(maximum - 1), maximum)
        let exhausted = RunEventReadProducerOwner.nextEpoch(maximum)
        XCTAssertEqual(exhausted, 0)
        XCTAssertEqual(RunEventReadProducerOwner.nextEpoch(exhausted), 0)
        XCTAssertEqual(RunEventReadProducerOwner.nextEpoch(UInt64.max), 0)
    }
    func testActualOwnerAcceptsOriginalOpaqueBytesAndDoesNotInferAdmission() throws {
        let value = try job(), target = try RunEventReadTarget(job: value, generation: 1, now: 100)
        let data = try body([row(target)]), owner = RunEventReadProducerOwner()
        let ticket = try owner.begin(target, current: { true }, clock: { 100 })
        let accepted = try owner.accept(raw(data), ticket: ticket, current: { true }, clock: { 101 })
        XCTAssertEqual(accepted, data)
        let staged = try value.stagingEvents(accepted, target: target)
        XCTAssertEqual(staged.eventSequence, 5); XCTAssertEqual(staged.events, ["existing", "event text"])
        XCTAssertFalse(staged.admitted); XCTAssertEqual(staged.phase, value.phase); XCTAssertEqual(staged.result, value.result)
        XCTAssertEqual(value.eventSequence, 4); XCTAssertEqual(value.events, ["existing"])
    }
    func testEventBOMDataIsAcceptedWithoutSilentlyRemovingItsBytes() throws {
        let target = try RunEventReadTarget(job: job(), generation: 1, now: 0), owner = RunEventReadProducerOwner()
        let data = Data([0xef, 0xbb, 0xbf]) + (try body([row(target)]))
        let projection = raw(data)
        XCTAssertEqual(Array((projection["body"] as! String).utf8.prefix(3)), [0xef, 0xbb, 0xbf])
        let ticket = try owner.begin(target, current: { true }, clock: { 0 })
        let accepted = try owner.accept(projection, ticket: ticket, current: { true }, clock: { 1 })
        XCTAssertEqual(accepted, data)
        XCTAssertEqual(try RunEventReadContract.decodePage(accepted).data, data)
    }
    func testInitialOwnerRefusalAndQueueExpiryDoNotBeginRead() throws {
        let target = try RunEventReadTarget(job: job(), generation: 1, now: 0), owner = RunEventReadProducerOwner()
        XCTAssertThrowsError(try owner.begin(target, current: { false }, clock: { 0 }))
        XCTAssertThrowsError(try owner.begin(target, current: { true }, clock: { 12_000 }))
        let ticket = try owner.begin(target, current: { true }, clock: { 100 })
        XCTAssertEqual(try owner.remaining(ticket, current: { true }, clock: { 300 }), 11_700)
        XCTAssertThrowsError(try owner.check(ticket, current: { true }, clock: { 299 }))
    }
    func testContextCallbackTimeAndReentrantCloseAreInsideDeadline() throws {
        let target = try RunEventReadTarget(job: job(), generation: 1, now: 0), owner = RunEventReadProducerOwner()
        var now = 0.0
        XCTAssertThrowsError(try owner.begin(target, current: { now = 12_000; return true }, clock: { now }))
        now = 0
        let ticket = try owner.begin(target, current: { true }, clock: { now })
        XCTAssertThrowsError(try owner.check(ticket, current: { owner.close(); return true }, clock: { now }))
        XCTAssertThrowsError(try owner.begin(target, current: { true }, clock: { 0 }))
    }
    func testCloseRetireAndSameIDReplacementRejectLateCallbackWithoutClearingNewLease() throws {
        let target = try RunEventReadTarget(job: job(), generation: 1, now: 0), owner = RunEventReadProducerOwner()
        let first = try owner.begin(target, current: { true }, clock: { 0 })
        let second = try owner.begin(target, current: { true }, clock: { 0 })
        owner.finish(first)
        XCTAssertThrowsError(try owner.accept(raw(body([row(target)])), ticket: first, current: { true }, clock: { 0 }))
        _ = try owner.accept(raw(body([row(target)])), ticket: second, current: { true }, clock: { 1 })
        owner.retire()
        XCTAssertThrowsError(try owner.check(second, current: { true }, clock: { 1 }))
        let third = try owner.begin(target, current: { true }, clock: { 1 }); owner.close()
        XCTAssertThrowsError(try owner.check(third, current: { true }, clock: { 1 }))
    }
    func testSameTextualTargetDoesNotReplaceActualInvocationIdentity() throws {
        let value = try job(), id = UUID()
        let first = try RunEventReadTarget(job: value, generation: 1, now: 0, requestID: id)
        let second = try RunEventReadTarget(job: value, generation: 1, now: 0, requestID: id)
        XCTAssertEqual(first.requestID, second.requestID); XCTAssertFalse(first.sameInvocation(as: second))
        let copy = first; XCTAssertTrue(copy.sameInvocation(as: first))
    }
    func testMissingWeakOwnerAndTaskCancellationRefuseLateAcceptance() async throws {
        let target = try RunEventReadTarget(job: job(), generation: 1, now: 0), owner = RunEventReadProducerOwner()
        var box: EventOwnerBox? = EventOwnerBox()
        let current = { [weak weakBox = box] in weakBox != nil }
        let ticket = try owner.begin(target, current: current, clock: { 0 })
        box = nil
        XCTAssertThrowsError(try owner.check(ticket, current: current, clock: { 0 }))
        let data = try body([row(target)])
        let task = Task { @MainActor in
            let held = try owner.begin(target, current: { true }, clock: { 0 })
            while !Task.isCancelled { await Task.yield() }
            return try owner.accept(self.raw(data), ticket: held, current: { true }, clock: { 1 })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled task admitted") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testReentrantClockRetirementAndLateWKCompletionAreRefused() throws {
        let target = try RunEventReadTarget(job: job(), generation: 1, now: 0), owner = RunEventReadProducerOwner()
        let ticket = try owner.begin(target, current: { true }, clock: { 0 })
        XCTAssertThrowsError(try owner.accept(raw(body([row(target)])), ticket: ticket, current: { true }, clock: { 12_000 }))
        XCTAssertThrowsError(try owner.check(ticket, current: { true }, clock: { owner.retire(); return 1 }))
    }
    func testFinalPostDecodeContextSpendsOriginalBudget() throws {
        let target = try RunEventReadTarget(job: job(), generation: 1, now: 0), owner = RunEventReadProducerOwner()
        var calls = 0, now = 0.0
        let current = { calls += 1; if calls == 4 { now = 12_000 }; return true }
        let ticket = try owner.begin(target, current: current, clock: { now })
        XCTAssertThrowsError(try owner.accept(raw(body([row(target)])), ticket: ticket, current: current, clock: { now }))
        XCTAssertEqual(calls, 4)
    }
    func testProjectionAndOpaqueHumanChecksDoNotLeakPayload() throws {
        let target = try RunEventReadTarget(job: job(), generation: 1, now: 0), owner = RunEventReadProducerOwner()
        for mutate in ["extra", "boolStatus", "boolCount", "count", "human", "unicode", "mime", "overflow"] {
            let ticket = try owner.begin(target, current: { true }, clock: { 0 }); var value = raw(try body([row(target)]))
            switch mutate {
            case "extra": value["private"] = "SECRET_CANARY"
            case "boolStatus": value["status"] = true
            case "boolCount": value["eventGetCount"] = true
            case "count": value["normalProofReadCount"] = 1
            case "human": value["afterUser"] = "other"
            case "unicode": value["beforeUser"] = "é"; value["afterUser"] = "e\u{301}"
            case "mime": value["contentType"] = "application/jsonp"
            default: value["body"] = String(repeating: " ", count: 524_289)
            }
            XCTAssertThrowsError(try owner.accept(value, ticket: ticket, current: { true }, clock: { 1 })) { XCTAssertFalse($0.localizedDescription.contains("SECRET_CANARY")) }
        }
    }
    func testLateBadRowsWrongScopeSequenceAndCountNeverMutateJob() throws {
        let value = try job(), target = try RunEventReadTarget(job: value, generation: 1, now: 0)
        for mutation in ["scope", "duplicate", "decrease", "payload", "count", "uppercase"] {
            var last = row(target, seq: 6), rows = [row(target), row(target, seq: 6)]
            switch mutation {
            case "scope": last["runId"] = UUID().uuidString.lowercased()
            case "duplicate": last["seq"] = 5
            case "decrease": last["seq"] = 4
            case "payload": last["payload"] = []
            case "uppercase": last["companyId"] = target.companyID.uuidString.uppercased()
            default: rows = (5...55).map { row(target, seq: $0) }
            }
            if mutation != "count" { rows[1] = last }
            XCTAssertThrowsError(try value.stagingEvents(body(rows), target: target))
            XCTAssertEqual(value.eventSequence, 4); XCTAssertEqual(value.events, ["existing"])
        }
        let fifty = try value.stagingEvents(body((5...54).map { row(target, seq: $0) }), target: target)
        XCTAssertEqual(fifty.eventSequence, 54); XCTAssertEqual(fifty.events.count, 12)
        XCTAssertEqual(try value.stagingEvents(body([]), target: target), value)
    }
    func testBothActualControllerCallersCommitFullPageAndPersistWithoutAdmission() async throws {
        for route in [HandoffRoute.task, .conversation] {
            let api = EventProducerAPI(), clock = EventClock(), (model, store) = try controller(route, api: api, clock: clock)
            api.events = { target in try self.body([self.row(target)]) }
            await model.poll()
            XCTAssertEqual(api.targets.count, 1); XCTAssertEqual(model.jobs[0].eventSequence, 5)
            XCTAssertEqual(model.jobs[0].events.last, "event text"); XCTAssertFalse(model.jobs[0].admitted)
            let disk = try JSONDecoder().decode([HandoffJob].self, from: Data(contentsOf: store.url))
            XCTAssertEqual(disk[0].eventSequence, 5); XCTAssertEqual(disk[0].events, model.jobs[0].events)
        }
    }
    func testBothControllerCallersKeepAllEventStateOnLateInvalidRow() async throws {
        for route in [HandoffRoute.task, .conversation] {
            let api = EventProducerAPI(), clock = EventClock(), (model, _) = try controller(route, api: api, clock: clock)
            api.events = { target in var last = self.row(target, seq: target.afterSeq + 2); last["agentId"] = UUID().uuidString; return try self.body([self.row(target), last]) }
            await model.poll()
            XCTAssertEqual(model.jobs[0].eventSequence, 4); XCTAssertEqual(model.jobs[0].events, ["existing"])
        }
    }
    func testMissingCompanyAndChangedSelectionNeverAcceptOrFallback() async throws {
        let api = EventProducerAPI(), clock = EventClock(), (model, _) = try controller(.task, api: api, clock: clock)
        model.company = nil; await model.poll(); XCTAssertTrue(api.targets.isEmpty)
        model.company = api.job.target.company
        api.events = { target in model.company = UUID(); model.company = target.companyID; return try self.body([self.row(target)]) }
        await model.poll(); XCTAssertEqual(api.targets.count, 1)
        XCTAssertEqual(model.jobs[0].eventSequence, 4); XCTAssertEqual(model.jobs[0].events, ["existing"])
    }
    func testControllerFinalClockExpiryLeavesCursorAndMessagesUntouched() async throws {
        let api = EventProducerAPI(), clock = EventClock(), (model, _) = try controller(.task, api: api, clock: clock)
        api.events = { target in try self.body([self.row(target)]) }
        clock.atSample = { sample in if sample == 4 { clock.value = 12_000 } }
        await model.poll()
        XCTAssertEqual(api.targets.count, 1); XCTAssertEqual(clock.calls, 4)
        XCTAssertEqual(model.jobs[0].eventSequence, 4); XCTAssertEqual(model.jobs[0].events, ["existing"])
    }
    func testRetiredProducerAfterReturnedBodyAndFinalCallbackExpiryCannotCommit() async throws {
        for finalExpiry in [false, true] {
            let api = EventProducerAPI(), clock = EventClock(), (model, _) = try controller(.task, api: api, clock: clock)
            api.events = { target in
                if !finalExpiry { api.producerCurrent = false }
                return try self.body([self.row(target)])
            }
            api.onCheck = { if finalExpiry && api.checks == 2 { clock.value = 12_000 } }
            await model.poll()
            XCTAssertEqual(model.jobs[0].eventSequence, 4); XCTAssertEqual(model.jobs[0].events, ["existing"])
            XCTAssertEqual(api.finishes, 1)
        }
    }
    func testHeldActualControllerEventReadCancellationRejectsLateBody() async throws {
        let api = EventProducerAPI(), clock = EventClock(), (model, _) = try controller(.task, api: api, clock: clock)
        var pending: CheckedContinuation<Data, Error>?
        api.events = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let task = Task { @MainActor in await model.poll() }
        for _ in 0..<1000 { if pending != nil { break }; await Task.yield() }
        guard let callback = pending, let target = api.targets.first else {
            task.cancel(); await task.value; XCTFail("Authored transport was not entered"); return
        }
        task.cancel(); callback.resume(returning: try body([row(target)])); await task.value
        XCTAssertEqual(model.jobs[0].eventSequence, 4); XCTAssertEqual(model.jobs[0].events, ["existing"])
        XCTAssertEqual(api.finishes, 1)
    }
    func testCancellationDuringEventAwaitSurvivesLatestArrayCommit() async throws {
        let api = EventProducerAPI(), clock = EventClock(), (model, _) = try controller(.task, api: api, clock: clock)
        api.events = { target in await model.cancel(target.jobID); return try self.body([self.row(target)]) }
        await model.poll()
        XCTAssertEqual(api.cancels, 1); XCTAssertTrue(model.jobs[0].cancelSent); XCTAssertNotNil(model.jobs[0].cancelID)
        XCTAssertEqual(model.jobs[0].phase, .cancelling); XCTAssertEqual(model.jobs[0].eventSequence, 5)
    }
    func testPreWriteFailureDoesNotPublishCursorAndBlocksLaterEventRequest() async throws {
        let api = EventProducerAPI(), clock = EventClock(), (model, store) = try controller(.task, api: api, clock: clock)
        api.events = { target in
            try FileManager.default.removeItem(at: store.url)
            try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
            return try self.body([self.row(target)])
        }
        await model.poll(); XCTAssertTrue(model.storageFailed)
        XCTAssertEqual(model.jobs[0].eventSequence, 4); XCTAssertEqual(model.jobs[0].events, ["existing"])
        await model.poll(); XCTAssertEqual(api.targets.count, 1); XCTAssertFalse(model.canSubmit)
    }
    func testWritablePostReplacementFailureCannotBeOverwrittenByHeldReconcileOrLaterPoll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); roots.append(root)
        let store = HandoffStore(url: root.appendingPathComponent("jobs.json"))
        let first = try job(), second = try job(), api = EventProducerAPI(), clock = EventClock()
        try store.save([first, second]); api.job = first
        var observedAdvanced = false
        let model = HandoffController(api: api, store: store, eventClock: { clock.sample() }, eventSaveCompleted: {
            let disk = try JSONDecoder().decode([HandoffJob].self, from: Data(contentsOf: store.url))
            XCTAssertEqual(disk[0].eventSequence, first.eventSequence + 1)
            observedAdvanced = true
            throw HandoffProblem.storage // Actual replacement succeeded; later completion failed.
        })
        model.company = first.target.company; api.model = model
        var pendingEvent: CheckedContinuation<Data, Error>?, pendingRun: CheckedContinuation<Data, Error>?
        api.events = { _ in try await withCheckedThrowingContinuation { pendingEvent = $0 } }
        api.runResponse = { id in
            if id == second.run! { return try await withCheckedThrowingContinuation { pendingRun = $0 } }
            return try api.runData(first)
        }
        let poll = Task { @MainActor in await model.poll() }
        for _ in 0..<1000 { if pendingEvent != nil { break }; await Task.yield() }
        guard let eventCallback = pendingEvent, let target = api.targets.first else {
            poll.cancel(); await poll.value; XCTFail("Event callback not entered"); return
        }
        let reconciliation = Task { @MainActor in await model.reconcile(second.id) }
        for _ in 0..<1000 { if pendingRun != nil { break }; await Task.yield() }
        guard let runCallback = pendingRun else {
            reconciliation.cancel(); eventCallback.resume(throwing: HandoffProblem.unavailable)
            await reconciliation.value; await poll.value; XCTFail("Reconcile callback not entered"); return
        }
        eventCallback.resume(returning: try body([row(target)])); await poll.value
        XCTAssertTrue(observedAdvanced); XCTAssertTrue(model.storageFailed)
        XCTAssertEqual(model.jobs[0].eventSequence, first.eventSequence)
        let advancedDisk = try Data(contentsOf: store.url)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: store.url.path))
        runCallback.resume(returning: try api.runData(second)); await reconciliation.value
        XCTAssertEqual(try Data(contentsOf: store.url), advancedDisk, "Generic persist must not overwrite an uncertain successful replacement")
        let calls = api.paths.count
        await model.poll(); await model.refreshTargets(); await model.reconcile(first.id); await model.cancel(first.id)
        XCTAssertEqual(api.paths.count, calls); XCTAssertFalse(model.canSubmit)
        XCTAssertEqual(try Data(contentsOf: store.url), advancedDisk)
        XCTAssertEqual(try JSONDecoder().decode([HandoffJob].self, from: advancedDisk)[0].eventSequence, first.eventSequence + 1)
    }
}

@MainActor private final class EventOwnerBox {}

@MainActor private final class EventClock {
    var value = 0.0
    var calls = 0
    var atSample: ((Int) -> Void)?
    func sample() -> Double { calls += 1; atSample?(calls); return value }
}
@MainActor private final class EventProducerAPI: FuegoAPI {
    let server = "https://fuego.example.org"
    var job: HandoffJob!
    var targets: [RunEventReadTarget] = [], cancels = 0
    weak var model: HandoffController?
    var producerCurrent = true, checks = 0, finishes = 0
    var onCheck: (() -> Void)?
    func checkEventRead(_ target: RunEventReadTarget) throws {
        checks += 1; onCheck?()
        guard producerCurrent, model?.eventReadIsCurrent(target) == true else { throw HandoffProblem.unavailable }
    }
    func finishEventRead(_ target: RunEventReadTarget) { finishes += 1 }
    var events: ((RunEventReadTarget) async throws -> Data)?
    var runResponse: ((UUID) async throws -> Data)?
    var paths: [String] = []
    func runData(_ value: HandoffJob) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": value.run!.uuidString, "companyId": value.target.company.uuidString,
            "agentId": value.target.id.uuidString, "status": "running", "resultJson": [:]])
    }
    func request(_ request: FuegoRequest) async throws -> Data {
        paths.append(request.path)
        let object: Any
        switch request {
        case .events(let target): targets.append(target); return try await events!(target)
        case .run(let id):
            if let runResponse { return try await runResponse(id) }
            return try runData(job)
        case .cancel, .cancelRemote:
            if request.method == "POST" { cancels += 1 }
            object = ["id": job.run!.uuidString, "companyId": job.target.company.uuidString, "agentId": job.target.id.uuidString, "status": "running", "resultJson": [:]]
        case .conversation:
            let id = UUID().uuidString
            object = ["conversation": ["id": job.issue!.uuidString, "companyId": job.target.company.uuidString, "agentId": job.target.id.uuidString, "userId": "opaque-human"],
                      "messages": [["id": id, "role": "user", "body": job.task, "clientRequestId": job.id.uuidString]],
                      "turns": [["id": id, "clientRequestId": job.id.uuidString, "runId": job.run!.uuidString, "status": "running"]]]
        default: throw HandoffProblem.unavailable
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
