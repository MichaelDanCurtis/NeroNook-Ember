import NookPluginSDK

/// The exact existing Nook event definition remains authoritative for the real
/// view and for tests that execute the shipped JavaScript control handlers.
public enum NookConversationViewControl {
    public static let definition = PluginViewEventDefinition("nook", input: .init([
        .init("command", .string), .init("id", .string, required: false), .init("text", .string, required: false)
    ]))
    public static func expression(_ values: [String: PluginValue]) throws -> Bool {
        try definition.input.validate(values)
        guard values["command"] == .string("voice_expression"), case .string(let value) = values["text"], ["true", "false"].contains(value) else {
            throw ModuleProblem("Choose whether expressive delivery is enabled.")
        }
        return value == "true"
    }
}
