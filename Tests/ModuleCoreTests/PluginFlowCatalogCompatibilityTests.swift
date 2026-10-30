import Foundation
import XCTest
import NookPluginSDK

final class PluginFlowCatalogCompatibilityTests: XCTestCase {
    // Fixed JSON authored from accepted PROTOCOL-PROPOSAL-v2 section3, SHA
    // 37ff5dfe7e6fb0969dc3ee2bbe63b472217db4f97ea2b0c6d4bb253076de76cd.
    // Never generated from PluginFlowCatalog or its encoded output.
    private let golden = #"""
{"actions":[{"cancellable":true,"effect":"readOnly","id":"flow_catalog_discover","input":{"fields":[{"kind":"number","maximum":1,"minimum":1,"name":"version","required":true},{"kind":"string","name":"kind","required":true},{"kind":"string","name":"query","required":false},{"kind":"string","name":"cursor","required":false},{"kind":"number","maximum":8,"minimum":1,"name":"limit","required":false}]},"output":{"fields":[{"kind":"string","name":"result","required":true}]},"timeoutSeconds":30,"title":"Discover local flows"},{"cancellable":true,"completionTimeoutSeconds":120,"effect":"readOnly","id":"flow_catalog_inspect","input":{"fields":[{"kind":"number","maximum":1,"minimum":1,"name":"version","required":true},{"kind":"string","name":"kind","required":true},{"kind":"string","name":"flow","required":false},{"kind":"string","name":"revision","required":false},{"kind":"string","name":"storage","required":false},{"kind":"string","name":"capability","required":false}]},"output":{"fields":[{"kind":"string","name":"result","required":true}]},"streamInput":{"fields":[{"kind":"string","name":"kind","required":true},{"kind":"number","maximum":170,"minimum":0,"name":"index","required":false},{"kind":"string","name":"data","required":false},{"kind":"number","maximum":262144,"minimum":0,"name":"bytes","required":false},{"kind":"string","name":"sha256","required":false},{"kind":"string","name":"meta","required":false}]},"streamOutput":{"fields":[{"kind":"string","name":"kind","required":true},{"kind":"number","maximum":170,"minimum":0,"name":"index","required":false},{"kind":"string","name":"data","required":false},{"kind":"number","maximum":262144,"minimum":0,"name":"bytes","required":false},{"kind":"string","name":"sha256","required":false},{"kind":"string","name":"meta","required":false}]},"timeoutSeconds":30,"title":"Inspect local flow source"},{"cancellable":true,"completionTimeoutSeconds":600,"effect":"localChange","id":"flow_catalog_author","input":{"fields":[{"kind":"number","maximum":1,"minimum":1,"name":"version","required":true},{"kind":"string","name":"profile","required":true},{"kind":"string","name":"mode","required":true},{"kind":"string","name":"flow","required":true},{"kind":"string","name":"base","required":false},{"kind":"string","name":"base_storage","required":false},{"kind":"number","maximum":262144,"minimum":1,"name":"bytes","required":true},{"kind":"string","name":"sha256","required":true}]},"output":{"fields":[{"kind":"string","name":"result","required":true}]},"streamInput":{"fields":[{"kind":"string","name":"kind","required":true},{"kind":"number","maximum":170,"minimum":0,"name":"index","required":false},{"kind":"string","name":"data","required":false},{"kind":"number","maximum":262144,"minimum":0,"name":"bytes","required":false},{"kind":"string","name":"sha256","required":false},{"kind":"string","name":"meta","required":false}]},"streamOutput":{"fields":[{"kind":"string","name":"kind","required":true},{"kind":"number","maximum":170,"minimum":0,"name":"index","required":false},{"kind":"string","name":"data","required":false},{"kind":"number","maximum":262144,"minimum":0,"name":"bytes","required":false},{"kind":"string","name":"sha256","required":false},{"kind":"string","name":"meta","required":false}]},"timeoutSeconds":30,"title":"Author a local flow draft"},{"cancellable":true,"completionTimeoutSeconds":300,"effect":"readOnly","id":"flow_catalog_test","input":{"fields":[{"kind":"number","maximum":1,"minimum":1,"name":"version","required":true},{"kind":"string","name":"profile","required":true},{"kind":"string","name":"mode","required":true},{"kind":"string","name":"flow","required":true},{"kind":"string","name":"revision","required":true},{"kind":"string","name":"storage","required":true},{"kind":"number","maximum":262144,"minimum":1,"name":"bytes","required":true},{"kind":"string","name":"sha256","required":true}]},"output":{"fields":[{"kind":"string","name":"result","required":true}]},"streamInput":{"fields":[{"kind":"string","name":"kind","required":true},{"kind":"number","maximum":170,"minimum":0,"name":"index","required":false},{"kind":"string","name":"data","required":false},{"kind":"number","maximum":262144,"minimum":0,"name":"bytes","required":false},{"kind":"string","name":"sha256","required":false},{"kind":"string","name":"meta","required":false}]},"streamOutput":{"fields":[{"kind":"string","name":"kind","required":true},{"kind":"number","maximum":170,"minimum":0,"name":"index","required":false},{"kind":"string","name":"data","required":false},{"kind":"number","maximum":262144,"minimum":0,"name":"bytes","required":false},{"kind":"string","name":"sha256","required":false},{"kind":"string","name":"meta","required":false}]},"timeoutSeconds":30,"title":"Test a flow with fixtures"},{"cancellable":true,"completionTimeoutSeconds":300,"effect":"localChange","id":"flow_catalog_publish","input":{"fields":[{"kind":"number","maximum":1,"minimum":1,"name":"version","required":true},{"kind":"string","name":"profile","required":true},{"kind":"string","name":"flow","required":true},{"kind":"string","name":"base","required":true},{"kind":"string","name":"base_storage","required":true}]},"output":{"fields":[{"kind":"string","name":"result","required":true}]},"timeoutSeconds":30,"title":"Publish a local flow"},{"cancellable":true,"effect":"readOnly","id":"flow_catalog_observe","input":{"fields":[{"kind":"number","maximum":1,"minimum":1,"name":"version","required":true},{"kind":"string","name":"request","required":true}]},"output":{"fields":[{"kind":"string","name":"result","required":true}]},"timeoutSeconds":30,"title":"Observe an owned flow request"}],"channels":[]}
"""#
    private let features: Set<String> = ["actions-v1", "action-stream-v1", "actions-long-running-v1"]
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func expected() throws -> PluginRegistration {
        try JSONDecoder().decode(PluginRegistration.self, from: Data(golden.utf8))
    }
    private func refusesValid(_ index: Int, _ label: String,
                              _ change: (inout PluginRegisteredAction) -> Void,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        var registration = try expected()
        change(&registration.actions[index])
        // A failed validity assertion cannot masquerade as exact-match coverage.
        try registration.validate()
        XCTAssertFalse(PluginFlowCatalog.matches(registration, features: features), label, file: file, line: line)
    }
    func testFullSortedDescriptorGoldenMatchesPacketExactly() throws {
        let authored = try expected(); try authored.validate()
        XCTAssertEqual(try encode(authored), Data(golden.utf8))
        XCTAssertEqual(try encode(PluginFlowCatalog.registration), Data(golden.utf8))
        XCTAssertEqual(PluginFlowCatalog.actions.count, 6)
        XCTAssertTrue(PluginFlowCatalog.matches(authored, features: features))
    }
    func testFixedConstantsFrameAndNilPolicyRemainUnknownWithOptionalFeatures() throws {
        XCTAssertEqual(PluginFlowCatalog.convention, "flow-catalog-v1")
        XCTAssertEqual(PluginFlowCatalog.version, 1)
        XCTAssertEqual(PluginFlowCatalog.nativeProfile, "nero-native-finiteDouble-v3")
        XCTAssertEqual(PluginFlowCatalog.bodyBytes, 262144)
        XCTAssertEqual(PluginFlowCatalog.chunkBytes, 1536)
        XCTAssertEqual(PluginFlowCatalog.requiredFeatures, features)
        let authored = try expected()
        XCTAssertEqual(try encode(PluginFlowCatalog.frame), try encode(XCTUnwrap(authored.actions[1].streamInput)))
        for action in PluginFlowCatalog.actions { XCTAssertNil(action.executionPolicy) }
        let optional = features.union(["action-policy-v1", "action-access-v1", "unknown-future-feature"])
        XCTAssertTrue(PluginFlowCatalog.matches(authored, features: optional))
        XCTAssertEqual(try encode(PluginFlowCatalog.registration), Data(golden.utf8))
    }
    func testEveryRequiredFeatureSubsetAndUnknownSubstitution() throws {
        let authored = try expected()
        let required = ["actions-v1", "action-stream-v1", "actions-long-running-v1"]
        for mask in 0..<8 {
            let subset = Set(required.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
            XCTAssertEqual(PluginFlowCatalog.matches(authored, features: subset), mask == 7)
            XCTAssertEqual(PluginFlowCatalog.matches(authored, features: subset.union(["flow-catalog-v1", "action-policy-v1", "action-access-v1"])), mask == 7)
        }
        for missing in required {
            for replacement in [missing.uppercased(), missing + " ", missing.replacingOccurrences(of: "1", with: "１"), "flow-catalog-v1"] {
                var changed = features; changed.remove(missing); changed.insert(replacement)
                XCTAssertFalse(PluginFlowCatalog.matches(authored, features: changed))
            }
        }
    }
    func testValidCompleteDescriptorMetadataPolicyAndTimeoutMutationsRefuse() throws {
        for index in 0..<6 {
            try refusesValid(index, "title") { $0.title += " changed" }
            try refusesValid(index, "effect") { $0.effect = $0.effect == .readOnly ? .localChange : .readOnly }
            try refusesValid(index, "inactivity") { $0.timeoutSeconds = 31 }
            try refusesValid(index, "completion") { $0.completionTimeoutSeconds = ($0.completionTimeoutSeconds ?? 59) + 1 }
            try refusesValid(index, "valid policy is different from nil") { $0.executionPolicy = .init() }
            try refusesValid(index, "required version minimum") { $0.input.fields[0].minimum = 0 }
            try refusesValid(index, "required version maximum") { $0.input.fields[0].maximum = 2 }
            try refusesValid(index, "input field order") { $0.input.fields.reverse() }
            try refusesValid(index, "output requirement") { $0.output.fields[0].required = false }
            try refusesValid(index, "output type") { $0.output.fields[0].kind = .boolean }
            try refusesValid(index, "output structured schema") { $0.output.fields[0].structured = .string }
            try refusesValid(index, "extra output") { $0.output.fields.append(.init("extra", .string, required: false)) }
            let fields = try expected().actions[index].input.fields
            for fieldIndex in fields.indices {
                try refusesValid(index, "input requirement \(fieldIndex)") { $0.input.fields[fieldIndex].required.toggle() }
                try refusesValid(index, "input name \(fieldIndex)") { $0.input.fields[fieldIndex].name += "_changed" }
            }
            let text = try XCTUnwrap(fields.firstIndex(where: { $0.kind == .string }))
            try refusesValid(index, "input type") { $0.input.fields[text].kind = .boolean }
            try refusesValid(index, "input structured schema") { $0.input.fields[text].structured = .string }
        }
        for index in [0, 4, 5] { try refusesValid(index, "cancellation") { $0.cancellable = false } }
        try refusesValid(0, "discover bound") { $0.input.fields[4].maximum = 9 }
        for index in [2, 3] {
            try refusesValid(index, "body byte bound") { action in
                let position = action.input.fields.firstIndex(where: { $0.name == "bytes" })!
                action.input.fields[position].maximum = 262143
            }
        }
    }
    func testValidStreamDescriptorBoundsOrderAndRequirementsRefuse() throws {
        for index in [1, 2, 3] {
            try refusesValid(index, "remove both streams") { $0.streamInput = nil; $0.streamOutput = nil }
            try refusesValid(index, "frame field order") { $0.streamInput!.fields.reverse() }
            try refusesValid(index, "frame kind requirement") { $0.streamInput!.fields[0].required = false }
            try refusesValid(index, "frame index bound") { $0.streamInput!.fields[1].maximum = 171 }
            try refusesValid(index, "output frame byte bound") { $0.streamOutput!.fields[3].maximum = 262143 }
            try refusesValid(index, "output frame data requirement") { $0.streamOutput!.fields[2].required = true }
            try refusesValid(index, "output frame structured metadata") { $0.streamOutput!.fields[5].structured = .string }
        }
    }
    func testMissingRenamedDuplicateAndInvalidRegistrationsRefuse() throws {
        for index in 0..<6 {
            var missing = try expected(); missing.actions.remove(at: index)
            try missing.validate(); XCTAssertFalse(PluginFlowCatalog.matches(missing, features: features))
            try refusesValid(index, "renamed action") { $0.id += "_changed" }
            var duplicate = try expected(); duplicate.actions.append(duplicate.actions[index])
            XCTAssertThrowsError(try duplicate.validate())
            XCTAssertFalse(PluginFlowCatalog.matches(duplicate, features: features))
        }
        var invalid = try expected(); invalid.actions[0].input.fields.append(invalid.actions[0].input.fields[0])
        XCTAssertThrowsError(try invalid.validate()); XCTAssertFalse(PluginFlowCatalog.matches(invalid, features: features))
        invalid = try expected(); invalid.actions[1].streamOutput = nil
        XCTAssertThrowsError(try invalid.validate()); XCTAssertFalse(PluginFlowCatalog.matches(invalid, features: features))
        invalid = try expected(); invalid.actions[0].executionPolicy = .init(maxModelCalls: 1)
        XCTAssertThrowsError(try invalid.validate()); XCTAssertFalse(PluginFlowCatalog.matches(invalid, features: features))
    }
    func testValidExtraDescriptorsAndActionOrderingDoNotGrantOrReinterpretPolicy() throws {
        var registration = try expected(); registration.actions.reverse()
        registration.actions.append(.init("unrelated", title: "Unrelated optional action"))
        registration.channels.append(.init("metadata", title: "Metadata", kind: .state))
        try registration.validate()
        XCTAssertTrue(PluginFlowCatalog.matches(registration, features: features))
        XCTAssertTrue(registration.actions.allSatisfy { $0.executionPolicy == nil })
        XCTAssertEqual(try encode(PluginFlowCatalog.registration), Data(golden.utf8))
    }
    func testExplicitNullPolicyPreservesExactGoldenAndDoesNotDeclareAuthority() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(golden.utf8)) as? [String: Any])
        var actions = try XCTUnwrap(object["actions"] as? [[String: Any]])
        for index in actions.indices { actions[index]["executionPolicy"] = NSNull() }
        object["actions"] = actions
        let decoded = try JSONDecoder().decode(PluginRegistration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.actions.allSatisfy { $0.executionPolicy == nil })
        XCTAssertEqual(try encode(decoded), Data(golden.utf8))
        XCTAssertTrue(PluginFlowCatalog.matches(decoded, features: features.union(["action-policy-v1"])))
    }
}
