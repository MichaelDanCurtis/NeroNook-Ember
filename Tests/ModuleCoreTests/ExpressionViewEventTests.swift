import Foundation
import XCTest
import JavaScriptCore
import NookPluginSDK
@testable import ModuleCore

final class ExpressionViewEventTests: XCTestCase {
    func testShippedCheckboxJavaScriptPassesTheActualSDKEventValidator() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Resources/Views/monitor/monitor.js"), encoding: .utf8)
        let context = try XCTUnwrap(JSContext())
        // Only DOM storage and callback registration are stubbed. Execute the
        // whole shipped script and capture its actual nero.emit payloads; the
        // real SDK validator below, not this bridge stub, admits the event.
        context.evaluateScript("""
        var captured=[];var nodes={};
        function node(id){return nodes[id]||(nodes[id]={dataset:{},addEventListener:function(){},querySelector:function(){return node(id+'summary')}})}
        var document={getElementById:node,querySelectorAll:function(){return []},addEventListener:function(){}};
        var nero={onState:function(){},emit:function(name,values){captured.push({name:name,values:values});return Promise.resolve()}};
        """)
        context.evaluateScript(source)
        XCTAssertNil(context.exception, "The full shipped script must initialize")
        context.evaluateScript("document.getElementById('emberExpression').checked=true;document.getElementById('emberExpression').onchange();document.getElementById('emberExpression').checked=false;document.getElementById('emberExpression').onchange();")
        XCTAssertNil(context.exception)
        let encoded = try XCTUnwrap(context.evaluateScript("JSON.stringify(captured)")?.toString())
        struct Emission: Decodable { let name: String; let values: [String: PluginValue] }
        let events = try JSONDecoder().decode([Emission].self, from: Data(encoded.utf8))
        XCTAssertEqual(events.count, 2)
        let view = PluginCustomView(entry: "fixture/index.html", revision: "expression1", events: [NookConversationViewControl.definition])
        for (index, emission) in events.enumerated() {
            let event = PluginViewEvent(panelID: "monitor", revision: view.revision, name: emission.name, values: emission.values)
            try view.validate(event)
            XCTAssertEqual(event.name, "nook")
            XCTAssertEqual(try NookConversationViewControl.expression(event.values), index == 0)
            XCTAssertEqual(event.values["text"], .string(index == 0 ? "true" : "false"))
        }
        // Preserve the real-bridge rejection that exposed the original bug.
        let rejected = PluginViewEvent(panelID: "monitor", revision: view.revision, name: "nook", values: ["command": .string("voice_expression"), "enabled": .boolean(true)])
        XCTAssertThrowsError(try view.validate(rejected))
    }
    func testExpressionHandlerRejectsMissingNoncanonicalAndWrongTypedValues() throws {
        for value in [PluginValue.string("TRUE"), .string("1"), .string(" true "), .boolean(true), .number(1)] {
            XCTAssertThrowsError(try NookConversationViewControl.expression(["command": .string("voice_expression"), "text": value]))
        }
        XCTAssertThrowsError(try NookConversationViewControl.expression(["command": .string("voice_expression")]))
        XCTAssertThrowsError(try NookConversationViewControl.expression(["command": .string("wrong"), "text": .string("true")]))
        XCTAssertTrue(try NookConversationViewControl.expression(["command": .string("voice_expression"), "text": .string("true")]))
        XCTAssertFalse(try NookConversationViewControl.expression(["command": .string("voice_expression"), "text": .string("false")]))
    }
}
