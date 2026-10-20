import XCTest
@testable import ModuleCore

@MainActor final class HandoffAttentionTests: XCTestCase {
    func job() throws -> HandoffJob {
        let target=HandoffTarget(id:UUID(),company:UUID(),companyName:"Test",name:"Test agent",device:UUID(),provider:"codex",workspace:"fixture",account:"fixture",instructions:"Test only",configuration:"fixture",companyPrefix:"FIX")
        return try HandoffJob(server:"https://fuego.example.org",target:target,task:"Synthetic task")
    }
    func testHistoricalSuppressionCompletionRestartAndAcknowledge() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("attention.json"),ledger=HandoffAttentionLedger(url:url)
        var old=try job();old.phase = .succeeded
        var active=try job();active.phase = .running
        ledger.observe([old,active]);XCTAssertNil(ledger.attention)
        active.phase = .succeeded;ledger.observe([old,active]);XCTAssertEqual(ledger.attention?.count,1)
        ledger.observe([old,active]);XCTAssertEqual(ledger.attention?.count,1)
        let restored=HandoffAttentionLedger(url:url);restored.observe([old,active]);XCTAssertEqual(restored.attention?.count,1)
        restored.acknowledge();XCTAssertNil(restored.attention)
        restored.observe([old,active]);XCTAssertNil(restored.attention)
        XCTAssertFalse(restored.storageError)
        let data=String(decoding:try Data(contentsOf:url),as:UTF8.self)
        XCTAssertFalse(data.contains("Synthetic task"));XCTAssertFalse(data.contains("Test agent"))
    }
    func testCancellationIsNotAnUnsolicitedResultAndCorruptLedgerSeedsBaseline() throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:url)}
        try Data("broken".utf8).write(to:url)
        let ledger=HandoffAttentionLedger(url:url);XCTAssertTrue(ledger.storageError)
        var item=try job();item.phase = .running;ledger.observe([item]);XCTAssertNil(ledger.attention)
        item.phase = .cancelled;ledger.observe([item]);XCTAssertNil(ledger.attention)
        var failed=try job();failed.phase = .running;ledger.observe([item,failed]);failed.phase = .failed;ledger.observe([item,failed]);XCTAssertEqual(ledger.attention?.kind,.needsYou)
    }
}
