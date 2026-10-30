import Foundation
import NookPluginSDK

public struct MonitorState: Equatable, Sendable {
    public private(set) var status: BridgeStatus?
    public private(set) var problem: String = "Connecting to local Fuego Compute…"
    public init() {}
    public mutating func received(_ value: BridgeStatus, now: Int64) throws { try value.validate(now: now); status = value; problem = "" }
    public mutating func failed(_ error: Error) { status = nil; problem = (error as? BrokerProblem)?.localizedDescription ?? BrokerProblem.unavailable.localizedDescription }
    public mutating func expire(now: Int64) { if let status, !status.fresh(at: now) { self.status = nil; problem = "Local status expired. Waiting for Fuego Compute." } }
    public var title: String {
        guard let status else { return "Unavailable" }
        if status.paused { return "Compute paused" }
        switch status.connection { case .connected: return status.ready ? "Ready" : "Connected"; case .connecting: return "Connecting"; case .disconnected: return "Gateway disconnected" }
    }
    public var detail: String {
        guard let status else { return problem }
        if status.paused { return "Local pause blocks new work and requests active work to stop. Pending and uncertain jobs remain visible." }
        switch status.connection {
        case .connected: return status.ready ? "This Mac is connected to Fuego and has reported Codex readiness. Admission remains controlled by Fuego." : "The local runtime is connected to Fuego. Codex readiness has not been confirmed."
        case .connecting: return "The local runtime is connecting to the Fuego gateway."
        case .disconnected: return "The local runtime is available, but its gateway connection is down."
        }
    }
    public var values: [String: PluginValue] {
        ["available": .boolean(status != nil), "connected": .boolean(status?.connection == .connected), "ready": .boolean(status?.ready ?? false), "phase": .string(title), "active_jobs": .number(Double(status?.activeJobs ?? 0)), "uncertain_jobs": .number(Double(status?.uncertainJobs ?? 0)), "paused": .boolean(status?.paused ?? false), "observed_at": .number(Double(status?.observedAt ?? 0))]
    }
    public static var schema: PluginValueSchema {
        .init([.init("available", .boolean), .init("connected", .boolean), .init("ready", .boolean), .init("phase", .string), .init("active_jobs", .number, minimum: 0), .init("uncertain_jobs", .number, minimum: 0), .init("paused", .boolean), .init("observed_at", .number, minimum: 0)])
    }
    public static var readAction: PluginRegisteredAction { .init("read_status", title: "Read Fuego compute status", output: schema, effect: .readOnly, timeoutSeconds: 5) }
    /// Declaration for this cached metadata action only. Negotiation never grants invocation authority.
    public static func readAction(negotiatedFeatures: Set<String>) -> PluginRegisteredAction {
        var action = readAction
        if negotiatedFeatures.isSuperset(of: ["actions-v1", "action-policy-v1"]) {
            action.executionPolicy = .init()
        }
        return action
    }
    public var customView: PluginCustomView {
        let data = (try? JSONEncoder().encode(status?.recentJobs ?? [])) ?? Data("[]".utf8)
        var viewState = values
        viewState["detail"] = .string(detail)
        viewState["jobs"] = .string(String(data: data, encoding: .utf8) ?? "[]")
        viewState["device"] = .string(status?.deviceId.uuidString ?? "")
        viewState["epoch"] = .string(status?.sessionEpoch.map(String.init) ?? "")
        viewState["provider"] = .string(status?.provider ?? "")
        return .init(entry: "monitor/index.html", revision: "monitor1", state: viewState, events: [.init("refresh"), .init("open_window")])
    }
    public func handle(_ event: PluginViewEvent) throws -> String {
        guard event.panelID == "monitor" else { throw ModuleProblem("Unknown Fuego view.") }
        try customView.validate(event); return event.name
    }
    public func snapshot(customViews: Bool) -> PluginSnapshot {
        let jobs = status?.recentJobs ?? []
        let actions: [PluginAction] = [.init("refresh", "Refresh", symbol: "arrow.clockwise", placement: .menu), .init("open_window", "Open Fuego", symbol: "macwindow", placement: .menu)]
        let panels: [PluginPanel]
        if customViews { panels = [.init("monitor", "Compute", customView: customView)] }
        else { panels = [.init("monitor", "Compute", sections: [.init("Connection", detail)] + jobs.prefix(8).map { .init(String($0.runId.uuidString.prefix(8)), "Codex · \($0.state.rawValue)") })] }
        return .init(title: "Ember", status: detail, activity: "\(title) · \(status?.activeJobs ?? 0) active", fields: [.init("Compute", title), .init("Active jobs", String(status?.activeJobs ?? 0)), .init("Uncertain jobs", String(status?.uncertainJobs ?? 0))], actions: actions, badge: title, panels: panels)
    }
}
