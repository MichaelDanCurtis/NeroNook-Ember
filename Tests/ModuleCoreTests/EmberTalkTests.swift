import XCTest
@testable import ModuleCore
import NookPluginSDK

final class EmberTalkTests: XCTestCase {
    @MainActor func testMouthUsesOutputOfCurrentTurnAndClearsOnInterruptAndStop() throws {
        let (talk,wire)=try connected()
        wire.output("meter",level:0.9)
        XCTAssertEqual(talk.outputLevel,0,"Microphone level is never mouth activity")
        wire.output("final",text:"Hello",turn:1)
        let id=try XCTUnwrap(talk.ticket);talk.answer("Hello back",for:id)
        wire.output("speaking",turn:1);wire.output("playbackMeter",turn:1,level:0.8)
        XCTAssertEqual(talk.outputLevel,0.8)
        wire.output("speechStarted",turn:1);XCTAssertEqual(talk.outputLevel,0)
        wire.output("playbackMeter",turn:1,level:0.8);XCTAssertEqual(talk.outputLevel,0)
        talk.stop();wire.output("playbackMeter",turn:1,level:0.8);XCTAssertEqual(talk.outputLevel,0)
    }
    @MainActor private func connected() throws -> (EmberTalk, SpeechWire) {
        let talk=EmberTalk(), wire=SpeechWire(talk)
        talk.client.catalog([.init(address:.init("test.local-speech","speech_conversation"),action:PluginSpeechConversation.action)])
        XCTAssertTrue(wire.sent.isEmpty, "Discovery must never start capture")
        try talk.start()
        wire.id=try XCTUnwrap(wire.sent.last?.requestID)
        wire.output("ready",mode:"half")
        XCTAssertTrue(talk.active);XCTAssertTrue(talk.client.ready)
        return (talk,wire)
    }
    @MainActor func testExplicitStartAndStopAreEphemeral() throws {
        let (talk,wire)=try connected()
        XCTAssertEqual(wire.sent.first?.operation,.invoke)
        wire.output("partial",text:"Open Weather")
        XCTAssertEqual(talk.partial,"Open Weather")
        talk.stop();XCTAssertFalse(talk.active);XCTAssertEqual(talk.partial,"")
        XCTAssertEqual(wire.sent.last?.operation,.cancel)
        let count=wire.sent.count
        wire.output("final",text:"Open Weather",turn:1)
        XCTAssertEqual(wire.sent.count,count);XCTAssertNil(talk.ticket)
    }
    @MainActor func testSpeechStartedNeverPausesHalfDuplexCapture() throws {
        let (talk, wire) = try connected(); var words = ""
        talk.question = { text, _ in words = text }
        wire.output("speechStarted", turn: 0)
        XCTAssertFalse(wire.kinds.contains("interrupt"), "Provider already stopped output; echoing interrupt disables half-duplex input")
        wire.output("partial", text: "Which modules")
        XCTAssertEqual(talk.partial, "Which modules")
        wire.output("final", text: "Which modules need attention?", turn: 1)
        XCTAssertEqual(words, "Which modules need attention?")
        XCTAssertFalse(wire.kinds.contains("interrupt"), "Final is already a committed provider boundary")
        let id = try XCTUnwrap(talk.ticket); talk.answer("Weather needs attention.", for: id)
        wire.output("played", turn: 1)
        XCTAssertEqual(wire.kinds.last, "listen")
    }
    @MainActor func testReplyOnlyForCurrentSpokenTurnAndNeverTwice() throws {
        let (talk,wire)=try connected();var received:[(String,UUID)]=[]
        talk.question={received.append(($0,$1))}
        wire.output("final",text:"What needs attention?",turn:1)
        let id=try XCTUnwrap(received.first?.1)
        XCTAssertEqual(received.first?.0,"What needs attention?")
        talk.answer("Unrelated",for:UUID());XCTAssertFalse(wire.kinds.contains("speak"))
        talk.answer("One module needs attention.",for:id)
        talk.answer("Duplicate",for:id)
        XCTAssertEqual(wire.kinds.filter{$0=="speak"}.count,1)
        wire.output("played",turn:1)
        XCTAssertEqual(wire.kinds.last,"listen");XCTAssertNil(talk.ticket)
        talk.answer("History replay",for:id)
        XCTAssertEqual(wire.kinds.filter{$0=="speak"}.count,1)
    }
    @MainActor func testInterruptFencesOldReplyBeforeNextTurn() throws {
        let (talk,wire)=try connected();var interrupted:[UUID]=[]
        talk.interrupted={interrupted.append($0)}
        wire.output("final",text:"Open Weather",turn:1);let old=try XCTUnwrap(talk.ticket)
        wire.output("speechStarted",turn:1)
        XCTAssertEqual(interrupted,[old]);XCTAssertNil(talk.ticket)
        wire.output("final",text:"Actually, read notifications",turn:2);let next=try XCTUnwrap(talk.ticket)
        talk.answer("Old opening proposal",for:old)
        XCTAssertFalse(wire.kinds.contains("speak"))
        talk.answer("No new notifications.",for:next)
        XCTAssertEqual(wire.sent.last?.frame?.values["turn"],.number(2))
        wire.output("played",turn:1)
        XCTAssertEqual(talk.ticket,next,"A late playback ack cannot advance the new turn")
        wire.output("played",turn:2);XCTAssertNil(talk.ticket)
    }
    @MainActor func testStopCancelsCurrentTicketAndRestartDoesNotReplay() throws {
        let (talk,wire)=try connected();var cancelled:[UUID]=[];talk.interrupted={cancelled.append($0)}
        wire.output("final",text:"Open Weather",turn:1);let old=try XCTUnwrap(talk.ticket)
        talk.stop();talk.stop();XCTAssertEqual(cancelled,[old])
        talk.answer("Old result",for:old)
        let count=wire.sent.count
        try talk.start();wire.id=try XCTUnwrap(wire.sent.last?.requestID);wire.sequence=0;wire.output("ready")
        XCTAssertEqual(wire.sent.count,count+1);XCTAssertEqual(talk.phase,"listening")
        XCTAssertFalse(wire.kinds.contains("speak"));XCTAssertNil(talk.ticket)
    }
    @MainActor func testProviderRevocationOrCatalogEpochStopsInsteadOfReplaying() throws {
        let (talk,wire)=try connected();var cancelled=0;talk.interrupted={_ in cancelled+=1}
        wire.output("final",text:"Open Weather",turn:1)
        talk.client.catalog([])
        XCTAssertFalse(talk.active);XCTAssertNil(talk.ticket);XCTAssertEqual(cancelled,1)
        talk.client.catalog([.init(address:.init("test.local-speech","speech_conversation"),action:PluginSpeechConversation.action)])
        XCTAssertFalse(talk.active)
        XCTAssertEqual(wire.sent.filter{$0.operation == .invoke}.count,1)
    }
    @MainActor func testPermissionFailureAndMalformedStreamStopCleanly() throws {
        let talk=EmberTalk(),wire=SpeechWire(talk);talk.client.accessRequestsAvailable=true
        try talk.start();let id=try XCTUnwrap(wire.sent.last?.requestID)
        XCTAssertEqual(wire.sent.last?.operation,.requestAccess)
        talk.client.receive(.init(.failure,requestID:id,error:"Declined"))
        XCTAssertFalse(talk.active);XCTAssertEqual(talk.displayStatus,"Declined")
        let (next,w)=try connected();next.client.receive(.init(.stream,requestID:w.id,frame:.init(sequence:999,values:PluginSpeechConversation.values("final",text:"Forged",turn:1))))
        XCTAssertFalse(next.active);XCTAssertNil(next.ticket)
    }
    @MainActor func testDuplexRequiresProviderAckAndSettingsDoNotStartMic() throws {
        let (talk,wire)=try connected()
        try talk.chooseMode("full");XCTAssertEqual(talk.mode,"half")
        wire.output("mode",mode:"full");XCTAssertEqual(talk.mode,"full")
        XCTAssertThrowsError(try talk.chooseMode("random"))
        try talk.client.openSettings(mode:talk.mode)
        XCTAssertFalse(talk.active)
        XCTAssertEqual(wire.sent.last?.values?["settings"],.boolean(true))
        XCTAssertFalse(wire.sent.last?.frame != nil)
    }
    @MainActor func testLongUnicodeReplyIsBoundedAndOrdered() throws {
        let (talk,wire)=try connected()
        wire.output("final",text:"What needs attention?",turn:1);let id=try XCTUnwrap(talk.ticket)
        let reply=String(repeating:"Weather is ready. 🫧 ",count:140)
        talk.answer(reply,for:id)
        for _ in 0..<10 where talk.ticket != nil { wire.output("played",turn:1) }
        let parts=wire.sent.compactMap { message -> String? in
            guard message.frame?.values["kind"] == .string("speak"),case .string(let text)=message.frame?.values["text"] else{return nil};return text
        }
        XCTAssertGreaterThan(parts.count,1);XCTAssertTrue(parts.allSatisfy{$0.utf8.count<=2048})
        XCTAssertEqual(parts.joined(separator:" ").split(whereSeparator:{$0.isWhitespace}),reply.split(whereSeparator:{$0.isWhitespace}))
        XCTAssertNil(talk.ticket);XCTAssertEqual(wire.kinds.last,"listen")
    }
    @MainActor func testOversizeQuestionNeverInvokesReasoningAndDuplicateFinalIsIgnored() throws {
        let (talk,wire)=try connected();var questions=0;talk.question={_,_ in questions+=1}
        wire.output("final",text:String(repeating:"a",count:601),turn:1)
        XCTAssertEqual(questions,0);XCTAssertEqual(wire.kinds.last,"speak")
        wire.output("final",text:"Duplicate",turn:1);XCTAssertEqual(questions,0)
    }
    func testOldActionEncodingRemainsUnchangedWithOptionalStreamFieldsAbsent() throws {
        struct Old:Encodable {let id="read_status",title="Read",input=PluginValueSchema(),output=PluginValueSchema(),effect="readOnly",cancellable=false,timeoutSeconds=30.0}
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(Old()),try encoder.encode(PluginRegisteredAction("read_status",title:"Read")))
        try PluginSpeechConversation.action.validate()
    }
}
@MainActor private final class SpeechWire {
    var sent:[PluginBusMessage]=[]
    var id=UUID(),sequence:UInt64=0
    weak var talk:EmberTalk?
    init(_ talk:EmberTalk) { self.talk=talk;talk.client.send={ [weak self] in self?.sent.append($0) } }
    var kinds:[String] {sent.compactMap {if case .string(let value)=$0.frame?.values["kind"]{return value};return nil}}
    func output(_ kind:String,text:String?=nil,mode:String?=nil,turn:Int?=nil,level:Double?=nil) {
        var values=PluginSpeechConversation.values(kind,text:text,mode:mode,turn:turn)
        if let level {values["level"] = .number(level)}
        let frame=PluginRunFrame(sequence:sequence,values:values);sequence+=1
        talk?.client.receive(.init(.stream,requestID:id,frame:frame))
    }
}
