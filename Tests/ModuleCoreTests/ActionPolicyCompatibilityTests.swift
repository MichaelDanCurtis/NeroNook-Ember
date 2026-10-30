import XCTest
import NookPluginSDK

final class ActionPolicyCompatibilityTests: XCTestCase {
    // Authored fixed pre-policy bytes; this test also runs against the old SDK.
    private let legacyDescriptor = #"{"cancellable":false,"effect":"readOnly","id":"echo","input":{"fields":[]},"output":{"fields":[]},"timeoutSeconds":30,"title":"Authored echo"}"#
    private let legacyCatalog = #"{"action":{"cancellable":false,"effect":"readOnly","id":"echo","input":{"fields":[]},"output":{"fields":[]},"timeoutSeconds":30,"title":"Authored echo"},"address":{"name":"echo","plugin":"example.policyprovider"}}"#

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testLegacyDescriptorAndCatalogBytesRemainExactWithOmittedOrNullPolicy() throws {
        let action = PluginRegisteredAction("echo", title: "Authored echo")
        XCTAssertEqual(try encode(action), Data(legacyDescriptor.utf8))
        let descriptor = try JSONDecoder().decode(PluginRegisteredAction.self, from: Data(legacyDescriptor.utf8))
        XCTAssertEqual(try encode(descriptor), Data(legacyDescriptor.utf8))
        let nullDescriptor = String(legacyDescriptor.dropLast()) + #", "executionPolicy":null}"#
        let nullAction = try JSONDecoder().decode(PluginRegisteredAction.self, from: Data(nullDescriptor.utf8))
        XCTAssertEqual(try encode(nullAction), Data(legacyDescriptor.utf8))
        let entry = PluginCatalogEntry(address: .init("example.policyprovider", "echo"), action: action)
        XCTAssertEqual(try encode(entry), Data(legacyCatalog.utf8))
        let decoded = try JSONDecoder().decode(PluginCatalogEntry.self, from: Data(legacyCatalog.utf8))
        XCTAssertEqual(try encode(decoded), Data(legacyCatalog.utf8))
        let nullCatalog = legacyCatalog.replacingOccurrences(of: legacyDescriptor, with: nullDescriptor)
        let nullEntry = try JSONDecoder().decode(PluginCatalogEntry.self, from: Data(nullCatalog.utf8))
        XCTAssertEqual(try encode(nullEntry), Data(legacyCatalog.utf8))
    }

    func testOmittedAndExplicitNullPolicyRemainUnknown() throws {
        let omitted = try JSONDecoder().decode(PluginRegisteredAction.self, from: Data(legacyDescriptor.utf8))
        let raw = String(legacyDescriptor.dropLast()) + #", "executionPolicy":null}"#
        let explicitNull = try JSONDecoder().decode(PluginRegisteredAction.self, from: Data(raw.utf8))
        XCTAssertNil(omitted.executionPolicy)
        XCTAssertNil(explicitNull.executionPolicy)
        XCTAssertEqual(omitted, explicitNull)
        XCTAssertNil(PluginRegisteredAction("echo", title: "Authored echo").executionPolicy)
    }

    func testFixedFourMemberPolicyRoundTripsThroughActualSDK() throws {
        let raw = #"{"maxModelCalls":0,"maxNestedInvocations":0,"profile":"programmatic","version":1}"#
        let policy = try JSONDecoder().decode(PluginActionExecutionPolicy.self, from: Data(raw.utf8))
        XCTAssertEqual(policy, PluginActionExecutionPolicy())
        try policy.validate()
        XCTAssertEqual(try encode(policy), Data(raw.utf8))
        let action = PluginRegisteredAction("echo", title: "Authored echo", executionPolicy: policy)
        try action.validate()
        let decoded = try JSONDecoder().decode(PluginRegisteredAction.self, from: encode(action))
        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.executionPolicy, policy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(policy)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "profile", "maxModelCalls", "maxNestedInvocations"]))
    }

    func testPolicyRefusesMissingNullExtraWrongTypeAndUnsupportedValues() throws {
        let valid: [String: Any] = ["version": 1, "profile": "programmatic", "maxModelCalls": 0, "maxNestedInvocations": 0]
        var invalid: [(String, [String: Any])] = []
        for key in valid.keys.sorted() {
            var missing = valid; missing.removeValue(forKey: key)
            invalid.append(("missing \(key)", missing))
            var null = valid; null[key] = NSNull()
            invalid.append(("null \(key)", null))
        }
        let badValues: [(String, [Any])] = [
            ("version", [0, 2, -1, true, "1", 1.5, [], [:]]),
            ("profile", ["Programmatic", "programmatic ", "agent", "programmatıc", 1, true, [], [:]]),
            ("maxModelCalls", [1, -1, true, "0", 0.5, [], [:]]),
            ("maxNestedInvocations", [1, -1, true, "0", 0.5, [], [:]])
        ]
        for (key, values) in badValues {
            for (index, value) in values.enumerated() {
                var changed = valid; changed[key] = value
                invalid.append(("invalid \(key) case \(index)", changed))
            }
        }
        for key in ["qualified", "trusted", "callerApproved", "sourceDigest"] {
            var extra = valid; extra[key] = true
            invalid.append(("extra \(key)", extra))
        }
        for (label, object) in invalid {
            let raw = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(PluginActionExecutionPolicy.self, from: raw), label)
            var action = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(legacyDescriptor.utf8)) as? [String: Any])
            action["executionPolicy"] = object
            XCTAssertThrowsError(try JSONDecoder().decode(PluginRegisteredAction.self, from: JSONSerialization.data(withJSONObject: action)), label)
        }
        for raw in ["null", "true", "0", "[]", #""programmatic""#] {
            XCTAssertThrowsError(try JSONDecoder().decode(PluginActionExecutionPolicy.self, from: Data(raw.utf8)))
        }
    }

    func testInvalidDirectPoliciesCannotValidateOrEncodeInsideActions() throws {
        let invalid: [PluginActionExecutionPolicy] = [
            .init(version: 0), .init(version: 2), .init(profile: "agent"),
            .init(maxModelCalls: 1), .init(maxModelCalls: -1),
            .init(maxNestedInvocations: 1), .init(maxNestedInvocations: -1)
        ]
        for policy in invalid {
            XCTAssertThrowsError(try policy.validate())
            XCTAssertThrowsError(try encode(policy))
            let action = PluginRegisteredAction("echo", title: "Authored echo", executionPolicy: policy)
            XCTAssertThrowsError(try action.validate())
            XCTAssertThrowsError(try encode(action))
            let entry = PluginCatalogEntry(address: .init("example.policyprovider", "echo"), action: action)
            XCTAssertThrowsError(try encode(entry))
        }
    }

    func testAddingAndRemovingPolicyChangesCompleteDescriptorAndCatalogIdentity() throws {
        let legacy = PluginRegisteredAction("echo", title: "Authored echo")
        var declared = legacy
        declared.executionPolicy = .init()
        XCTAssertNotEqual(legacy, declared)
        XCTAssertNotEqual(try encode(legacy), try encode(declared))
        let address = PluginActionAddress("example.policyprovider", "echo")
        let oldEntry = PluginCatalogEntry(address: address, action: legacy)
        let newEntry = PluginCatalogEntry(address: address, action: declared)
        XCTAssertNotEqual(oldEntry, newEntry)
        XCTAssertNotEqual(try encode(oldEntry), try encode(newEntry))
        let recovered = try JSONDecoder().decode(PluginCatalogEntry.self, from: encode(newEntry))
        XCTAssertEqual(recovered, newEntry)
        declared.executionPolicy = nil
        XCTAssertEqual(declared, legacy)
        XCTAssertEqual(try encode(declared), Data(legacyDescriptor.utf8))
        XCTAssertEqual(try encode(PluginCatalogEntry(address: address, action: declared)), Data(legacyCatalog.utf8))
    }
}
