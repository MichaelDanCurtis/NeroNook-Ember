import Foundation
import NookPluginSDK

/// Optional, vendor-independent actions-v1 transport. Preparing a draft never
/// calls Fuego's message or run APIs; the plugin's own review still owns Send.
public enum HandoffActions {
    public static let prepare = PluginRegisteredAction("prepare_handoff", title: "Prepare a Fuego task for review",
        input: .init([.init("target_id", .string), .init("task", .string)]),
        output: .init([.init("review_id", .string), .init("message", .string)]), effect: .localChange, timeoutSeconds: 5)
    public static let list = PluginRegisteredAction("list_handoff_targets", title: "List Fuego handoff targets",
        output: .init([.init("targets", .string), .init("count", .number, minimum: 0, maximum: 12)]), effect: .readOnly, timeoutSeconds: 5)
    public static let read = PluginRegisteredAction("read_handoff_status", title: "Read one saved Fuego handoff",
        input: .init([.init("request_id", .string)]), output: statusSchema, effect: .readOnly, timeoutSeconds: 5)
    public static let wait = PluginRegisteredAction("wait_for_handoff", title: "Wait for a Fuego job to finish",
        input: .init([.init("request_id", .string)]),
        output: .init([.init("request_id", .string), .init("run_id", .string), .init("result", .string), .init("result_truncated", .boolean)]),
        effect: .externalChange, cancellable: true, timeoutSeconds: 30, completionTimeoutSeconds: 3600)
    public static var statusSchema: PluginValueSchema { .init([.init("available", .boolean), .init("phase", .string),
        .init("run_id", .string), .init("task_id", .string), .init("admitted", .boolean), .init("observed_at", .number, minimum: 0)]) }
    public static func targetValues(_ targets: [HandoffTarget]) -> [String: PluginValue] {
        var rows: [[String: String]] = []
        for target in targets.prefix(12) {
            let row = ["id": target.id.uuidString, "name": target.name, "organization": target.companyName, "workspace": target.workspace]
            guard let bytes = try? JSONSerialization.data(withJSONObject: rows + [row], options: [.sortedKeys]), bytes.count <= 2048 else { break }
            rows.append(row)
        }
        let bytes = (try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])) ?? Data("[]".utf8)
        return ["targets": .string(String(decoding: bytes, as: UTF8.self)), "count": .number(Double(rows.count))]
    }
    public static func statusValues(_ job: HandoffJob?, review: HandoffReview? = nil) -> [String: PluginValue] {
        ["available": .boolean(job != nil || review != nil), "phase": .string(job?.phase.title ?? (review == nil ? "Not found" : "Waiting for your review")),
         "run_id": .string(job?.run?.uuidString ?? ""), "task_id": .string(job?.issue?.uuidString ?? ""), "admitted": .boolean(job?.admitted ?? false),
         "observed_at": .number((job?.lastRead?.timeIntervalSince1970 ?? 0) * 1000)]
    }
    @MainActor public static func prepareDraft(_ values: [String: PluginValue], controller: HandoffController) throws -> [String: PluginValue] {
        try prepare.input.validate(values)
        guard case .string(let target) = values["target_id"], let id = UUID(uuidString: target),
              case .string(let task) = values["task"], controller.review == nil else { throw HandoffProblem.invalid }
        try controller.prepare(target: id, task: task)
        guard let review = controller.review else { throw HandoffProblem.invalid }
        return ["review_id": .string(review.id.uuidString), "message": .string("Draft ready in Ember. Review its target, instructions and task, then choose Send. No message or job has been submitted.")]
    }
}
