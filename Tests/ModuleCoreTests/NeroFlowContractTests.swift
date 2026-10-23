import XCTest
import NookPluginSDK
@testable import ModuleCore
final class NeroFlowContractTests:XCTestCase {
    func testSharedAgentTaskSchemasMatchWithoutChangingLegacyPinnedTitles() {
        for (legacy,shared) in [(HandoffActions.prepare,PluginAgentTaskContract.prepare),(HandoffActions.list,PluginAgentTaskContract.list),(HandoffActions.wait,PluginAgentTaskContract.wait)] {
            XCTAssertTrue(PluginMailReplyContract.matches(.init(address:.init("cafe.example.agent",legacy.id),action:legacy),shared))
            XCTAssertTrue(legacy.title.contains("Fuego"))
            var comparison=shared;comparison.title=legacy.title
            XCTAssertEqual(legacy,comparison)
        }
    }
}
