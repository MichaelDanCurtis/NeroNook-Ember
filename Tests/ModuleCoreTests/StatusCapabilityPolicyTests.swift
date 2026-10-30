import XCTest
import NookPluginSDK
@testable import ModuleCore

final class StatusCapabilityPolicyTests: XCTestCase {
    private func encoded(_ action: PluginRegisteredAction) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any])
    }

    func testLegacyOrPartialNegotiationDoesNotDeclareProgrammaticExecution() throws {
        let partial: [Set<String>] = [[], ["actions-v1"], ["action-policy-v1"],
            ["actions-v1", "action-policy-v2"], ["actions-v1", "ACTION-POLICY-V1"]]
        let legacy = MonitorState.readAction
        for features in partial {
            let action = MonitorState.readAction(negotiatedFeatures: features)
            try action.validate()
            XCTAssertEqual(action, legacy)
            XCTAssertNil(action.executionPolicy)
            let object = try encoded(action)
            XCTAssertEqual(Set(object.keys), ["id", "title", "input", "output", "effect", "cancellable", "timeoutSeconds"])
        }
    }

    func testNegotiatedPolicyHasExactExistingProgrammaticShapeAndPreservesDescriptor() throws {
        let action = MonitorState.readAction(negotiatedFeatures: ["actions-v1", "action-policy-v1", "panels-v1"])
        try action.validate()
        let object = try encoded(action)
        let policy = try XCTUnwrap(object["executionPolicy"] as? [String: Any])
        XCTAssertEqual(Set(policy.keys), ["version", "profile", "maxModelCalls", "maxNestedInvocations"])
        XCTAssertEqual(policy["version"] as? Int, 1)
        XCTAssertEqual(policy["profile"] as? String, "programmatic")
        XCTAssertEqual(policy["maxModelCalls"] as? Int, 0)
        XCTAssertEqual(policy["maxNestedInvocations"] as? Int, 0)
        var withoutPolicy = action
        withoutPolicy.executionPolicy = nil
        XCTAssertEqual(withoutPolicy, MonitorState.readAction)
        XCTAssertEqual(action.id, "read_status")
        XCTAssertEqual(action.effect, .readOnly)
        XCTAssertEqual(action.timeoutSeconds, 5)
        XCTAssertFalse(action.cancellable)
        XCTAssertTrue(action.input.fields.isEmpty)
        XCTAssertEqual(action.output.fields.map(\.name), ["available", "connected", "ready", "phase", "active_jobs", "uncertain_jobs", "paused", "observed_at"])
        let roundTrip = try JSONDecoder().decode(PluginRegisteredAction.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(roundTrip, action)
    }

    func testUnavailableCachedMetadataIsValidOutputWithoutClaimingReadiness() throws {
        var state = MonitorState()
        state.expire(now: 0)
        let action = MonitorState.readAction(negotiatedFeatures: ["actions-v1", "action-policy-v1"])
        try action.output.validate(state.values)
        XCTAssertEqual(state.values["available"], .boolean(false))
        XCTAssertEqual(state.values["connected"], .boolean(false))
        XCTAssertEqual(state.values["ready"], .boolean(false))
        XCTAssertEqual(state.values["phase"], .string("Unavailable"))
        XCTAssertEqual(state.values["observed_at"], .number(0))
    }
}
