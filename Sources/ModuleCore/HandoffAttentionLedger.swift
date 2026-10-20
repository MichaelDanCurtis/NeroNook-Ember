import Foundation
import NookPluginSDK

/// Metadata only. Historical terminal jobs seed the baseline without alerts.
/// An observed completion remains unread across restarts until acknowledged.
@MainActor public final class HandoffAttentionLedger {
    private struct Saved: Codable, Equatable {
        var initialized = false
        var phases: [UUID:HandoffPhase] = [:]
        var unread: [UUID:HandoffPhase] = [:]
    }
    private var state = Saved()
    private let url: URL
    public private(set) var storageError = false
    public init(url: URL) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 32768 else { throw HandoffProblem.storage }
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                guard saved.phases.count <= 100, saved.unread.count <= 100,
                      saved.unread.values.allSatisfy(\.settled) else { throw HandoffProblem.storage }
                state = saved
            } catch { storageError = true }
        }
    }
    public var attention: PluginAttention? {
        guard !state.unread.isEmpty else { return nil }
        let ids = state.unread.keys.map(\.uuidString).sorted()
        // Bounded opaque identity; the count carries additional unread results.
        return .init(id: ids.first ?? "handoff", kind: state.unread.values.contains(.failed) ? .needsYou : .completed,
                     title: state.unread.count == 1 ? "Ember has a handoff result" : "Ember has handoff results", count: state.unread.count)
    }
    public func observe(_ jobs: [HandoffJob]) {
        let jobs = Array(jobs.prefix(100)), old = state
        if state.initialized {
            for job in jobs where job.phase.settled && ![.cancelled,.skipped].contains(job.phase) && state.phases[job.id] != job.phase {
                state.unread[job.id] = job.phase
            }
        }
        state.initialized = true
        state.phases = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id,$0.phase) })
        state.unread = state.unread.filter { id,_ in jobs.contains { $0.id == id } }
        if old != state { save() }
    }
    public func acknowledge() { state.unread = [:]; save() }
    private func save() {
        do { try JSONEncoder().encode(state).write(to: url, options: .atomic); storageError = false }
        catch { storageError = true }
    }
}
