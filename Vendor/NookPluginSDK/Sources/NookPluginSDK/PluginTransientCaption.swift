import Foundation

/// Short-lived, display-only text near a Nook. A plugin never gains window or
/// keyboard focus through this channel. The host owns placement and lifetime.
public struct PluginTransientCaption: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case active, result, dismiss }
    public var phase: Phase
    public var title: String
    public var text: String
    public var detail: String
    public var symbol: String
    public var displayNumber: UInt32?

    public init(_ phase: Phase, title: String = "", text: String = "", detail: String = "", symbol: String = "text.bubble", displayNumber: UInt32? = nil) {
        self.phase = phase; self.title = title; self.text = text; self.detail = detail; self.symbol = symbol; self.displayNumber = displayNumber
    }
    public func validate() throws {
        guard title.count <= 80, text.utf8.count <= 1200, detail.count <= 160, symbol.count <= 50,
              (displayNumber == nil || displayNumber! > 0),
              phase == .dismiss || !title.isEmpty else { throw ModuleProblem("Invalid transient caption.") }
    }
}
