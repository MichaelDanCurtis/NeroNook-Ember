import Combine
import Foundation
import NookPluginSDK

/// Ephemeral shared speech adapter. No capture, credentials or model ownership.
/// A fresh local ticket binds each spoken reply to its still-active input turn.
@MainActor public final class EmberTalk: ObservableObject {
    public let client = PluginSpeechConversationClient()
    public var question: ((String, UUID) -> Void)?
    public var interrupted: ((UUID) -> Void)?
    public var changed: (() -> Void)?
    public private(set) var mode = "half"
    public private(set) var phase = "idle"
    public private(set) var partial = ""
    public private(set) var status = "Talk with Ember"
    public private(set) var level = 0.0
    public private(set) var outputLevel = 0.0
    public private(set) var ticket: UUID?
    private var turn = 0
    private var chunks: [String] = []
    private var playing = false
    private var observation: AnyCancellable?
    public init() {
        client.event = { [weak self] in self?.receive($0) }
        client.ended = { [weak self] in self?.retire() }
        observation = client.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.changed?() } }
    }
    public var active: Bool { client.active }
    public var displayStatus: String { !active || !client.ready ? client.status : status }
    public func chooseMode(_ value: String) throws {
        let next = try PluginSpeechConversation.mode(value)
        if client.ready { try client.input(PluginSpeechConversation.values("mode", mode: next)) }
        else { mode = next }
        changed?()
    }
    public func start() throws {
        guard !active else { throw ModuleProblem("Talk is already active.") }
        turn = 0; ticket = nil; chunks = []; playing = false; partial = ""; level = 0
        phase = "preparing"; status = "Starting local speech…"
        try client.start(mode: mode); changed?()
    }
    public func stop() { client.stop(); retire(); changed?() }
    private func retire() {
        let old = ticket; ticket = nil; chunks = []; playing = false
        phase = "idle"; partial = ""; level = 0; outputLevel = 0; status = "Talk stopped"
        if let old { interrupted?(old) }; changed?()
    }
    private func interrupt() {
        outputLevel = 0
        let old = ticket; ticket = nil; chunks = []; playing = false
        // speechStarted/final are provider-originated boundaries. Voice has
        // already stopped its output. Echoing "interrupt" would switch the
        // provider to thinking and mute a half-duplex utterance mid-sentence.
        if let old { interrupted?(old) }
    }
    public func answer(_ text: String, for expected: UUID) {
        guard active, client.ready, ticket == expected, !playing, chunks.isEmpty else { return }
        do { chunks = try Self.segments(text); advance() }
        catch { stop(); status = error.localizedDescription }
        changed?()
    }
    private static func segments(_ text: String) throws -> [String] {
        _ = try PluginSpeechContract.segments(text) // Shared byte/character/total bounds.
        var result: [String] = [], pending = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let next = pending.isEmpty ? word : pending + " " + word
            if next.utf8.count <= 2048 { pending = next; continue }
            if !pending.isEmpty { result.append(pending); pending = "" }
            let pieces = try PluginSpeechContract.segments(word)
            result += pieces.dropLast(); pending = pieces.last ?? ""
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }
    private func advance() {
        guard active, client.ready, !playing else { return }
        do {
            if !chunks.isEmpty {
                let text = chunks.removeFirst(); playing = true; phase = "speaking"; status = "Preparing speech…"
                try client.input(PluginSpeechConversation.values("speak", text: text, turn: turn))
            } else {
                ticket = nil; phase = "listening"; status = "Listening"
                try client.input(PluginSpeechConversation.values("listen", turn: turn))
            }
        } catch { stop(); status = error.localizedDescription }
    }
    private func receive(_ values: [String: PluginValue]) {
        guard case .string(let kind) = values["kind"] else { return }
        func text(_ key: String) -> String { if case .string(let value) = values[key] { return value }; return "" }
        switch kind {
        case "ready", "listening":
            if ["full", "half"].contains(text("mode")) { mode = text("mode") }
            phase = "listening"; status = text("text").isEmpty ? "Listening" : text("text"); partial = ""
        case "mode":
            if ["full", "half"].contains(text("mode")) { mode = text("mode") }
            if !text("text").isEmpty { status = text("text") }
        case "meter":
            if case .number(let value) = values["level"] { level = value }
            if phase == "listening", !text("text").isEmpty { status = text("text") }
        case "playbackMeter":
            if case .number(let n)=values["turn"],n==Double(turn),phase=="speaking",case .number(let x)=values["level"] { outputLevel=PluginAvatarSpeech.weight(x,speaking:true) } else { outputLevel=0 }
        case "partial": partial = text("text")
        case "speechStarted": interrupt(); phase = "listening"; status = "Listening"
        case "final":
            guard case .number(let number) = values["turn"], number.rounded() == number, number > Double(turn) else { return }
            interrupt(); turn = Int(number); partial = ""
            let words = text("text").trimmingCharacters(in: .whitespacesAndNewlines)
            let id = UUID(); ticket = id; phase = "thinking"; status = "Ember is thinking…"
            guard !words.isEmpty, words.utf8.count <= 600, HandoffTarget.printable(words) else {
                answer("Please ask a shorter question, under six hundred bytes.", for: id); return
            }
            question?(words, id)
        case "speaking": if playing { phase = "speaking"; status = "Speaking" }
        case "played":
            guard case .number(let number) = values["turn"], number == Double(turn), playing else { return }
            outputLevel = 0; playing = false; advance()
        default: break
        }
        changed?()
    }
}
