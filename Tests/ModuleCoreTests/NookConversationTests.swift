import XCTest
@testable import ModuleCore

final class NookConversationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let modules = [["id":"test.weather","name":"Weather","enabled":"true"], ["id":"test.mail","name":"Mail","enabled":"true"]]
    private func request(_ question: String = "Open Weather, and what needs my attention?") throws -> NookConversationRequest {
        try .init(question:question,modules:modules,attention:[["name":"Mail","title":"Unread items","count":"10","private_body":"DO NOT SEND","module_id":"test.mail"]],now:now)
    }
    private func reply(_ request: NookConversationRequest, open: Any = NSNull(), nonce: String? = nil, extra: Bool = false) throws -> String {
        var result: [String:Any] = ["nonce":nonce ?? request.nonce,"answer":"Mail has ten unread items. I can show Weather.","open":open]
        if extra { result["script"] = "never run" }
        return String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!
    }
    func testPortableContextExcludesPrivateFieldsAndUsesTurnLocalAliases() throws {
        let r=try request()
        XCTAssertFalse(r.prompt.contains("DO NOT SEND")); XCTAssertFalse(r.prompt.contains("test.mail"))
        XCTAssertTrue(r.prompt.contains("Unread items")); XCTAssertTrue(r.prompt.contains("10"))
        XCTAssertLessThanOrEqual(r.prompt.utf8.count,2048)
        XCTAssertNotEqual(r.nonce,try request().nonce)
    }
    func testAnswerAndExactOpeningProposal() throws {
        let r=try request(), response=try r.response(reply(r,open:"m0"),now:now.addingTimeInterval(10))
        XCTAssertEqual(response.moduleID,"test.weather"); XCTAssertEqual(response.moduleName,"Weather")
        XCTAssertNil(try r.response(reply(r),now:now).moduleID)
    }
    func testOldQuestionAndInventedModulesCannotBecomeActions() throws {
        let r=try request()
        for text in [try reply(r,open:"test.weather"),try reply(r,open:"m9"),try reply(r,nonce:UUID().uuidString),try reply(r,extra:true),"```json\n" + (try reply(r)) + "\n```","Open Weather"] {
            XCTAssertThrowsError(try r.response(text,now:now))
        }
    }
    func testExpiredFutureAndOversizeRepliesFail() throws {
        let r=try request(), text=try reply(r,open:"m0")
        XCTAssertThrowsError(try r.response(text,now:now.addingTimeInterval(301)))
        XCTAssertThrowsError(try r.response(text,now:now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try r.response(String(repeating:"x",count:4097),now:now))
    }
    func testInvalidContextNeverProducesAPrompt() throws {
        XCTAssertThrowsError(try request(" "))
        XCTAssertThrowsError(try request(String(repeating:"🐈",count:151)))
        XCTAssertThrowsError(try NookConversationRequest(question:"hi",modules:modules+modules,attention:[]))
        XCTAssertThrowsError(try NookConversationRequest(question:"hi",modules:[["id":"test.off","name":"Disabled","enabled":"false"]],attention:[]))
    }
    func testContextBudgetDoesNotSilentlyDropModulesOrNotificationRows() throws {
        let many=(0..<32).map { ["id":"test.module\($0)","name":String(repeating:"a",count:100),"enabled":"true"] }
        XCTAssertThrowsError(try NookConversationRequest(question:"hello",modules:many,attention:[]))
        XCTAssertThrowsError(try NookConversationRequest(question:"hello",modules:modules,attention:Array(repeating:["name":"Inbox"],count:33)))
    }
    func testStopNeverClaimsAnAcceptedOrFinishedTurnWasUnsent() throws {
        let target=HandoffTarget(id:UUID(),company:UUID(),companyName:"Test",name:"Ember",device:UUID(),provider:"codex",workspace:"owned",account:"test",instructions:"Test",configuration:"test")
        var job=try HandoffJob(server:"https://fuego.example.org",target:target,task:"Question")
        XCTAssertEqual(NookConversationStop(job:nil,submitting:false),.unsent)
        XCTAssertEqual(NookConversationStop(job:nil,submitting:true),.pending)
        XCTAssertEqual(NookConversationStop(job:job,submitting:false),.pending)
        job.run=UUID();job.phase = .running
        XCTAssertEqual(NookConversationStop(job:job,submitting:false),.admitted(job.id))
        for phase in [HandoffPhase.succeeded,.failed,.cancelled,.skipped] {
            job.phase=phase
            XCTAssertEqual(NookConversationStop(job:job,submitting:false),.finished)
            XCTAssertFalse(NookConversationStop(job:job,submitting:false).message.contains("Nothing was sent"))
        }
    }
}
