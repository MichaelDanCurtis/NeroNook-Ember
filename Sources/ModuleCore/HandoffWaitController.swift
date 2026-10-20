import Foundation
import NookPluginSDK

/// Observes an exact existing draft/job. It cannot Send, invoke or retry a job.
/// Bindings are session-local; persisted handoffs remain the recovery authority.
@MainActor public final class HandoffWaitController {
    private struct Wait {
        let handoffID: UUID
        let server: String
        let deadline: Date
        var stop = false
    }
    private let controller: HandoffController
    private var waits: [UUID: Wait] = [:]
    private var updating = false
    public var send: ((UUID, PluginRunUpdate) -> Void)?
    public init(controller: HandoffController) { self.controller = controller }
    public func start(_ request: UUID, values: [String: PluginValue], now: Date = Date()) throws {
        try HandoffActions.wait.input.validate(values)
        guard case .string(let raw) = values["request_id"], let id = UUID(uuidString: raw),
              waits.count < 8, waits[request] == nil, !waits.values.contains(where: { $0.handoffID == id }),
              !controller.storageFailed,
              controller.jobs.contains(where: { $0.id == id && $0.server == controller.api.server }) ||
                (controller.review?.id == id && controller.review?.server == controller.api.server) else { throw HandoffProblem.invalid }
        waits[request] = .init(handoffID: id, server: controller.api.server, deadline: now.addingTimeInterval(3600))
        send?(request, .init(.running, message: "Waiting for this exact Fuego handoff. Review and Send remain in Fuego Agent."))
    }
    public func requestCancel(_ request: UUID) { waits[request]?.stop = true }
    public func tick(now: Date = Date()) async {
        guard !updating else { return }; updating = true; defer { updating = false }
        for (request, wait) in waits {
            guard controller.api.server == wait.server, !controller.storageFailed else {
                finish(request, .init(.interrupted, message: "Fuego connection or local storage changed. The original job may still run; nothing was resent.")); continue
            }
            guard now < wait.deadline else {
                finish(request, .init(.interrupted, message: "The one-hour wait ended. Inspect the original Fuego handoff; its outcome may be unknown.")); continue
            }
            if let review = controller.review, review.id == wait.handoffID {
                if wait.stop || now >= review.expires {
                    controller.dismissReview()
                    finish(request, .init(.cancelled, message: "Fuego draft closed before Send. No remote job was started."))
                } else { send?(request, .init(.running, message: "Waiting for your Fuego review · " + String(review.target.name.prefix(80)) + ". Choose Send to Fuego or Back.")) }
                continue
            }
            guard let original = controller.jobs.first(where: { $0.id == wait.handoffID && $0.server == wait.server }) else {
                if controller.busy { send?(request, .init(wait.stop ? .cancelling : .running, message: "Checking this exact handoff before sending; waiting for its saved receipt.")) }
                else { finish(request, .init(.cancelled, message: "Fuego review closed without a saved handoff. No job was submitted by this wait action.")) }
                continue
            }
            if wait.stop, !original.phase.settled, !original.cancelSent, original.run != nil, !controller.busy { await controller.cancel(original.id) }
            guard let job = controller.jobs.first(where: { $0.id == wait.handoffID && $0.server == wait.server }) else {
                finish(request, .init(.interrupted, message: "The original handoff receipt is unavailable. Nothing was resent.")); continue
            }
            switch job.phase {
            case .succeeded:
                let result = HandoffJob.bounded(job.result, bytes: 2048)
                finish(request, .init(.succeeded, message: "Fuego completed this exact request. Its answer is in Result; the full answer remains in Fuego Agent.", values: ["request_id": .string(job.id.uuidString), "run_id": .string(job.run?.uuidString ?? ""), "result": .string(result), "result_truncated": .boolean(result != job.result)]))
            case .cancelled:
                finish(request, .init(.cancelled, message: "Fuego confirmed this exact turn stopped. Completed effects were not undone."))
            case .failed, .skipped:
                finish(request, .init(.failed, message: String(("Fuego " + job.phase.title + ": " + job.detail).prefix(300))))
            default:
                let stopping = wait.stop || job.cancelSent
                let age = job.lastRead.map { max(0, Int(now.timeIntervalSince($0))) }
                var detail = stopping && job.run == nil ? "Stop requested; waiting for this saved request's run ID. Remote stop is not yet confirmed." : job.detail
                if let age { detail += " Last confirmed read \(age)s ago." }
                else { detail += " No confirmed remote read yet." }
                if !stopping, let event = job.events.last { detail = job.phase.title + " · " + event + " · " + detail }
                send?(request, .init(stopping ? .cancelling : .running, message: String(detail.prefix(300))))
            }
        }
    }
    private func finish(_ request: UUID, _ update: PluginRunUpdate) { waits[request] = nil; send?(request, update) }
}
