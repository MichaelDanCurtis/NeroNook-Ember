import Foundation
import NookPluginSDK

public struct DemoState: Codable, Equatable {
    public var count: Int
    public var available: Bool
    public var message: String
    public init(count: Int = 0, available: Bool = true, message: String = "Local demo · no devices connected") {
        self.count = count; self.available = available; self.message = message
    }
    public func validate() throws {
        guard (0...999).contains(count), message.count <= 100 else { throw ModuleProblem("Invalid demo state.") }
    }
    public mutating func apply(_ action: String) {
        guard available else { return }
        if action == "increment" { count = min(999, count + 1) }
        if action == "reset" { count = 0 }
    }
    public static var editAction: PluginRegisteredAction {
        .init("edit_demo", title: "Apply changes", input: .init([.init("count", .number, minimum: 0, maximum: 999), .init("message", .string)]), effect: .localChange)
    }
    public var editForm: PluginForm {
        .init("edit_demo", title: "Demo counter", revision: "\(count):\(available):\(message)", action: Self.editAction, inputs: [
            .init("count", label: "Count", style: .number, value: .number(Double(count))),
            .init("message", label: "Status message", style: .text, value: .string(message))
        ], enabled: available)
    }
    public mutating func applyEdit(_ values: [String: PluginValue]) throws {
        try editForm.validateValues(values)
        guard available, case .number(let count) = values["count"], count.rounded() == count,
              case .string(let message) = values["message"], message.count <= 100 else { throw ModuleProblem("Use a whole count and a status of at most 100 characters.") }
        self.count = Int(count); self.message = message
    }
    public func snapshot(title: String, cards: Bool) -> PluginSnapshot {
        let actions: [PluginAction] = [
            .init("increment", "Add one", enabled: available && count < 999, symbol: "plus"),
            .init("reset", "Reset", enabled: available && count > 0, symbol: "arrow.counterclockwise", confirmation: "Reset this module’s demo counter to zero?")
        ]
        return PluginSnapshot(title: title, status: message, activity: message,
            fields: [.init("Count", String(count))], actions: cards ? [] : actions,
            badge: available ? "Demo" : "Offline",
            panels: cards ? [.init("overview", "Overview", cards: [
                .init("counter", title: "Your first module", subtitle: "Local counter", value: String(count), detail: available ? "These buttons only change this demo. Real integrations own their connections and commands." : "Controls are disabled while this fixture is offline.", symbol: "square.stack.3d.up", actions: actions)
            ])] : nil)
    }
}
