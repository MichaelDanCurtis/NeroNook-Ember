import Foundation
import CoreFoundation
import Dispatch

/// Internal retained-client candidate. No HTTP, credentials, SDK registration,
/// agent execution or default backend. A constructed Binding is data, not auth.
/// The real session/currentness producer and existing callsites remain separate.
public enum EmberConversationReadContract {
    public static let packetManifestSHA256 = "b61f91e79bb96189ed4c9d59f062f576e36959d36121b192ec0747020c41a76e"
    public static let maximumBodyBytes = 524_288
    public static let maximumDurationMs = 12_000.0

    public enum Failure: Error, LocalizedError, Equatable {
        case unavailable, invalidBinding, unsupportedResponse, stale, expired, httpStatus(Int)
        public var errorDescription: String? {
            switch self {
            case .unavailable, .invalidBinding: return "A current, qualified Fuego session is required."
            case .unsupportedResponse: return "Fuego returned an unsupported conversation response."
            case .stale: return "This conversation read is no longer current."
            case .expired: return "The conversation read timed out."
            case .httpStatus(let status): return "The conversation read failed (HTTP \(status))."
            }
        }
    }

    /// Shape-only caller-local context. Never decode a response into expected
    /// identity. Origin admission and authenticated human/lifetime proof belong
    /// to the independently qualified owner; a missing producer stays unavailable.
    public struct Binding: Equatable, Sendable {
        public let origin, userId, companyId, agentId, clientBindingId: String
        public let clientGeneration: Double
        public init(data: Data) throws {
            guard let value = try? Value.parse(data), let schema = bindingSchema,
                  schema.accepts(value), let object = value.object,
                  let origin = object["origin"]?.string, let user = object["userId"]?.string,
                  let company = object["companyId"]?.string, let agent = object["agentId"]?.string,
                  let lifetime = object["clientBindingId"]?.string,
                  let generation = object["clientGeneration"]?.number else { throw Failure.invalidBinding }
            self.origin = origin; userId = user; companyId = company; agentId = agent
            clientBindingId = lifetime; clientGeneration = generation
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            exact(lhs.origin, rhs.origin) && exact(lhs.userId, rhs.userId)
                && exact(lhs.companyId, rhs.companyId) && exact(lhs.agentId, rhs.agentId)
                && exact(lhs.clientBindingId, rhs.clientBindingId) && lhs.clientGeneration == rhs.clientGeneration
        }
    }
    public struct Snapshot: Sendable {
        /// Original bounded bytes, not a rewritten model or an effect receipt.
        public let data: Data
        fileprivate let value: Value
        fileprivate init(data: Data, value: Value) { self.data = data; self.value = value }
    }
    public struct Acceptance: Sendable {
        public let expected, current: Binding?
        public let ownerAlive, aborted: Bool
        public let requestID: String
        public let activeRequestID: String?
        public let startMonotonicMs, finishMonotonicMs: Double
        public init(expected: Binding?, current: Binding?, ownerAlive: Bool, aborted: Bool,
                    requestID: String, activeRequestID: String?, startMonotonicMs: Double, finishMonotonicMs: Double) {
            self.expected = expected; self.current = current; self.ownerAlive = ownerAlive; self.aborted = aborted
            self.requestID = requestID; self.activeRequestID = activeRequestID
            self.startMonotonicMs = startMonotonicMs; self.finishMonotonicMs = finishMonotonicMs
        }
    }
    public static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        guard data.count <= maximumBodyBytes, let value = try? Value.parse(data),
              let schema = snapshotSchema, schema.accepts(value) else { throw Failure.unsupportedResponse }
        return Snapshot(data: data, value: value)
    }
    public static func accept(body: Data, status: Int, contentType: String, context: Acceptance) throws -> Snapshot {
        if context.aborted { throw CancellationError() }
        guard let expected = context.expected else { throw Failure.unavailable }
        guard context.ownerAlive, let current = context.current, current == expected,
              !context.requestID.isEmpty, let active = context.activeRequestID,
              exact(active, context.requestID) else { throw Failure.stale }
        try checkTime(context.startMonotonicMs, context.finishMonotonicMs)
        guard status == 200 else { throw Failure.httpStatus(status) }
        guard contentType.split(separator: ";", omittingEmptySubsequences: false).first.map({
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "application/json"
        }) == true else { throw Failure.unsupportedResponse }
        let snapshot = try decodeSnapshot(body)
        if let conversation = snapshot.value.object?["conversation"]?.object {
            guard let company = conversation["companyId"]?.string, let agent = conversation["agentId"]?.string,
                  let user = conversation["userId"]?.string, exact(company, expected.companyId),
                  exact(agent, expected.agentId), exact(user, expected.userId) else { throw Failure.stale }
        }
        return snapshot
    }
    private static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    private static func checkTime(_ start: Double, _ finish: Double) throws {
        guard start.isFinite, finish.isFinite, start >= 0, finish >= start,
              finish - start < maximumDurationMs else { throw Failure.expired }
    }

    public struct CurrentContext: Sendable {
        public let binding: Binding?
        public let ownerAlive, originAllowed: Bool
        public init(binding: Binding?, ownerAlive: Bool, originAllowed: Bool) {
            self.binding = binding; self.ownerAlive = ownerAlive; self.originAllowed = originAllowed
        }
    }
    public struct Request: Sendable {
        public let id: String
        public let binding: Binding
        public let method = "GET"
        public let body: Data? = nil
        public let query: String? = nil
        public var path: String { "/api/companies/\(binding.companyId)/ember/\(binding.agentId)" }
        fileprivate init(id: String, binding: Binding) { self.id = id; self.binding = binding }
    }
    public struct Response: Sendable {
        public let status: Int
        public let contentType: String
        public let body: Data
        public init(status: Int, contentType: String, body: Data) {
            self.status = status; self.contentType = contentType; self.body = body
        }
    }

    /// Only an injected, independently qualified owner may supply current context.
    /// There is no built-in live producer or transport. Callbacks run on MainActor;
    /// the injected clock is read-only and monotonic. Context is rechecked after
    /// each await and decoding. Same textual request IDs cannot replace a lease.
    @MainActor public final class Reader {
        private final class Lease { let id: String; var aborted = false; init(_ id: String) { self.id = id } }
        private let context: @MainActor () -> CurrentContext
        private let clock: @MainActor () -> Double
        private var active: Lease?
        private var closed = false
        public var activeRequestID: String? { active?.id }
        public init(context: @escaping @MainActor () -> CurrentContext,
                    clock: @escaping @MainActor () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }) {
            self.context = context; self.clock = clock
        }
        public func cancelCurrent() { active?.aborted = true; active = nil }
        public func close() { closed = true; active = nil }
        public func read(requestID: String = UUID().uuidString,
                         using transport: @MainActor (Request) async throws -> Response) async throws -> Snapshot {
            try Task.checkCancellation()
            guard !closed else { throw Failure.stale }
            guard !requestID.isEmpty else { throw Failure.stale }
            let lease = Lease(requestID); active = lease
            defer { if active === lease { active = nil } }
            let before = context()
            try requireCurrent(lease)
            guard before.ownerAlive, before.originAllowed, let binding = before.binding else { throw Failure.unavailable }
            let start = clock()
            try requireCurrent(lease)
            try checkTime(start, start)
            // Exactly one callback, no mutation, retry, default origin or fallback.
            // Transport errors (including abort/HTTP classification) pass unchanged.
            let response = try await transport(Request(id: requestID, binding: binding))
            try requireCurrent(lease)
            let after = context()
            try requireCurrent(lease)
            guard after.originAllowed else { throw Failure.unavailable }
            let snapshot = try accept(body: response.body, status: response.status, contentType: response.contentType,
                context: Acceptance(expected: binding, current: after.binding, ownerAlive: after.ownerAlive,
                    aborted: lease.aborted, requestID: lease.id, activeRequestID: active?.id,
                    startMonotonicMs: start, finishMonotonicMs: clock()))
            // Decoding and the last context callback consume the same deadline.
            let final = context(); let finish = clock()
            try requireCurrent(lease)
            guard final.ownerAlive, final.originAllowed,
                  final.binding == binding else { throw Failure.stale }
            try checkTime(start, finish)
            return snapshot
        }
        private func requireCurrent(_ lease: Lease) throws {
            try Task.checkCancellation()
            if lease.aborted { throw CancellationError() }
            guard !closed, active === lease else { throw Failure.stale }
        }
    }

    // Canonical descriptors below are generated by copying the exact frozen JSON
    // bytes, not independently maintained TS/Swift DTO fields. The evaluator is
    // deliberately closed to the keywords used by this selected candidate.
    private static let snapshotSchema = try? Schema(Data(snapshotSchemaJSON.utf8))
    private static let bindingSchema = try? Schema(Data(bindingSchemaJSON.utf8))
    private static let snapshotSchemaJSON = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "conversation": {
      "anyOf": [
        {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
            },
            "companyId": {
              "type": "string",
              "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
            },
            "agentId": {
              "type": "string",
              "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
            },
            "userId": {
              "type": "string"
            },
            "state": {
              "type": "string"
            }
          },
          "required": [
            "id",
            "companyId",
            "agentId",
            "userId",
            "state"
          ],
          "additionalProperties": false
        },
        {
          "type": "null"
        }
      ]
    },
    "messages": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
          },
          "role": {
            "type": "string",
            "enum": [
              "user",
              "assistant"
            ]
          },
          "body": {
            "type": "string"
          },
          "createdAt": {
            "type": "string",
            "pattern": "^(?:(?:[0-9][0-9][2468][048]|[0-9][0-9][13579][26]|[0-9][0-9]0[48]|[02468][048]00|[13579][26]00)-02-29|[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)|(?:02)-(?:0[1-9]|1[0-9]|2[0-8])))T(?:(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9](?:\\.[0-9]+)?)?(?:Z|([+-](?:[01][0-9]|2[0-3]):[0-5][0-9])))$"
          },
          "clientRequestId": {
            "anyOf": [
              {
                "type": "string",
                "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
              },
              {
                "type": "null"
              }
            ]
          },
          "runId": {
            "anyOf": [
              {
                "type": "string",
                "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
              },
              {
                "type": "null"
              }
            ]
          }
        },
        "required": [
          "id",
          "role",
          "body",
          "createdAt",
          "clientRequestId",
          "runId"
        ],
        "additionalProperties": false
      }
    },
    "turns": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": {
            "type": "string",
            "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
          },
          "clientRequestId": {
            "type": "string",
            "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
          },
          "status": {
            "type": "string",
            "enum": [
              "pending",
              "running",
              "succeeded",
              "failed",
              "cancelled",
              "uncertain"
            ]
          },
          "runId": {
            "anyOf": [
              {
                "type": "string",
                "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
              },
              {
                "type": "null"
              }
            ]
          },
          "replyMessageId": {
            "anyOf": [
              {
                "type": "string",
                "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
              },
              {
                "type": "null"
              }
            ]
          },
          "error": {
            "anyOf": [
              {
                "type": "string"
              },
              {
                "type": "null"
              }
            ]
          }
        },
        "required": [
          "id",
          "clientRequestId",
          "status",
          "runId",
          "replyMessageId",
          "error"
        ],
        "additionalProperties": false
      }
    },
    "hasEarlierMessages": {
      "type": "boolean"
    },
    "limits": {
      "type": "object",
      "properties": {
        "maxTextBytes": {
          "type": "integer",
          "exclusiveMinimum": 0,
          "maximum": 9007199254740991
        },
        "maxEnvelopeBytes": {
          "type": "integer",
          "exclusiveMinimum": 0,
          "maximum": 9007199254740991
        },
        "maxContextBytes": {
          "type": "integer",
          "exclusiveMinimum": 0,
          "maximum": 9007199254740991
        }
      },
      "required": [
        "maxTextBytes",
        "maxEnvelopeBytes",
        "maxContextBytes"
      ],
      "additionalProperties": false
    }
  },
  "required": [
    "conversation",
    "messages",
    "turns",
    "hasEarlierMessages",
    "limits"
  ],
  "additionalProperties": false,
  "$id": "urn:fuego:client-candidate:ember-read:c1:snapshot",
  "allOf": [
    {
      "if": {
        "type": "object",
        "properties": {
          "conversation": {
            "type": "null"
          }
        },
        "required": [
          "conversation"
        ]
      },
      "then": {
        "type": "object",
        "properties": {
          "messages": {
            "type": "array",
            "maxItems": 0
          },
          "turns": {
            "type": "array",
            "maxItems": 0
          }
        }
      }
    }
  ],
  "$comment": "Parsed existing HTTP projection; no new wire version, auth, readiness, speech or effect authority. Format assertions are required."
}
"""# + "\n"
    private static let bindingSchemaJSON = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:fuego:client-candidate:ember-read:c1:local-binding",
  "$comment": "Caller-local trusted context, never a wire request or proof of authentication by itself.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "origin",
    "userId",
    "companyId",
    "agentId",
    "clientBindingId",
    "clientGeneration"
  ],
  "properties": {
    "origin": {
      "type": "string",
      "format": "uri"
    },
    "userId": {
      "type": "string",
      "minLength": 1
    },
    "companyId": {
      "type": "string",
      "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
    },
    "agentId": {
      "type": "string",
      "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
    },
    "clientBindingId": {
      "type": "string",
      "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
    },
    "clientGeneration": {
      "type": "integer",
      "minimum": 1,
      "maximum": 9007199254740991
    }
  }
}
"""# + "\n"

    fileprivate indirect enum Value: Sendable, Equatable {
        case object([String: Value]), array([Value]), string(String), number(Double), bool(Bool), null
        var object: [String: Value]? { if case .object(let v) = self { return v }; return nil }
        var array: [Value]? { if case .array(let v) = self { return v }; return nil }
        var string: String? { if case .string(let v) = self { return v }; return nil }
        var number: Double? { if case .number(let v) = self { return v }; return nil }
        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.string(let a), .string(let b)): return exact(a, b)
            case (.number(let a), .number(let b)): return a == b
            case (.bool(let a), .bool(let b)): return a == b
            case (.null, .null): return true
            case (.array(let a), .array(let b)): return a == b
            case (.object(let a), .object(let b)): return a == b
            default: return false
            }
        }
        static func parse(_ data: Data) throws -> Value {
            // JSONSerialization can autodetect UTF16; reject literal NUL (never
            // valid JSON) so a non-UTF8 byte stream cannot pass that fallback.
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw Failure.unsupportedResponse }
            return try convert(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), depth: 0)
        }
        private static func convert(_ item: Any, depth: Int) throws -> Value {
            guard depth <= 64 else { throw Failure.unsupportedResponse }
            if item is NSNull { return .null }
            if let n = item as? NSNumber {
                return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
            }
            if let s = item as? String { return .string(s) }
            if let a = item as? [Any] { return .array(try a.map { try convert($0, depth: depth + 1) }) }
            if let o = item as? [String: Any] { return .object(try o.mapValues { try convert($0, depth: depth + 1) }) }
            throw Failure.unsupportedResponse
        }
    }
    private struct Schema {
        let root: Value
        let patterns: [String: NSRegularExpression]
        init(_ data: Data) throws {
            root = try Value.parse(data)
            var found = Set<String>()
            func collect(_ value: Value) {
                if let o = value.object { if let p = o["pattern"]?.string { found.insert(p) }; o.values.forEach(collect) }
                if let a = value.array { a.forEach(collect) }
            }
            collect(root)
            patterns = try Dictionary(uniqueKeysWithValues: found.map { ($0, try NSRegularExpression(pattern: $0)) })
        }
        func accepts(_ value: Value) -> Bool { validate(value, against: root) }
        private func validate(_ value: Value, against schema: Value) -> Bool {
            guard let s = schema.object,
                  Set(s.keys).isSubset(of: ["$schema", "$id", "$comment", "type", "properties", "required", "additionalProperties", "anyOf", "allOf", "if", "then", "items", "maxItems", "enum", "pattern", "format", "minLength", "minimum", "maximum", "exclusiveMinimum"]) else { return false }
            if let t = s["type"]?.string {
                switch (t, value) {
                case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null): break
                case ("integer", .number(let n)): if !n.isFinite || n.rounded(.towardZero) != n { return false }
                default: return false
                }
            }
            if let alternatives = s["anyOf"]?.array, !alternatives.contains(where: { validate(value, against: $0) }) { return false }
            if let clauses = s["allOf"]?.array, !clauses.allSatisfy({ validate(value, against: $0) }) { return false }
            if let condition = s["if"], validate(value, against: condition), let then = s["then"], !validate(value, against: then) { return false }
            if let choices = s["enum"]?.array, !choices.contains(value) { return false }
            if let o = value.object {
                if let required = s["required"]?.array, !required.allSatisfy({ $0.string.map { o[$0] != nil } ?? false }) { return false }
                if let properties = s["properties"]?.object {
                    if s["additionalProperties"] == .bool(false), !Set(o.keys).isSubset(of: Set(properties.keys)) { return false }
                    for (key, child) in o { if let shape = properties[key], !validate(child, against: shape) { return false } }
                }
            }
            if let a = value.array {
                if let max = s["maxItems"]?.number, Double(a.count) > max { return false }
                if let items = s["items"], !a.allSatisfy({ validate($0, against: items) }) { return false }
            }
            if let text = value.string {
                if let min = s["minLength"]?.number, Double(text.unicodeScalars.count) < min { return false }
                if let p = s["pattern"]?.string {
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    // The frozen patterns are anchored. ICU may let $ precede
                    // a final newline; ECMAScript without /m rejects it. Require
                    // the complete match to preserve this selected JS domain.
                    guard let regex = patterns[p], let match = regex.firstMatch(in: text, range: range), match.range == range else { return false }
                }
                if let format = s["format"]?.string, format != "uri" || !validURI(text) { return false }
            }
            if let number = value.number {
                if !number.isFinite { return false }
                if let min = s["minimum"]?.number, number < min { return false }
                if let min = s["exclusiveMinimum"]?.number, number <= min { return false }
                if let max = s["maximum"]?.number, number > max { return false }
            }
            return true
        }
        private func validIPv6(_ literal: String) -> Bool {
            let sides = literal.components(separatedBy: "::")
            guard sides.count <= 2 else { return false }
            func groups(_ side: String) -> [String]? {
                if side.isEmpty { return [] }
                let values = side.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                return values.contains(where: { $0.isEmpty }) ? nil : values
            }
            guard let left = groups(sides[0]), let right = sides.count == 2 ? groups(sides[1]) : [] else { return false }
            let values = left + right
            var count = 0
            for (index, value) in values.enumerated() {
                if value.contains(".") {
                    guard index == values.count - 1, literal.hasSuffix(value) else { return false }
                    let octets = value.split(separator: ".", omittingEmptySubsequences: false)
                    guard octets.count == 4, octets.allSatisfy({ part in
                        !part.isEmpty && part.utf8.count <= 3
                            && part.utf8.allSatisfy { (48...57).contains($0) }
                            && Int(part).map { $0 <= 255 } == true
                    }) else { return false }
                    count += 2
                } else {
                    guard (1...4).contains(value.utf8.count), value.utf8.allSatisfy({
                        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    }) else { return false }
                    count += 1
                }
            }
            return sides.count == 2 ? count < 8 : count == 8
        }
        private func validURI(_ text: String) -> Bool {
            // Syntactic caller-local URI only. Actual allowed server-origin policy
            // is a separate required CurrentContext flag, never inferred here.
            let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
            let subdelims = "!$&'()*+,;="
            func allowed(_ value: String, _ chars: String) -> Bool {
                let set = CharacterSet(charactersIn: chars)
                return value.unicodeScalars.allSatisfy { set.contains($0) }
            }
            guard let colon = text.firstIndex(of: ":") else { return false }
            let scheme = String(text[..<colon])
            guard let first = scheme.unicodeScalars.first,
                  CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz").contains(first),
                  allowed(scheme, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+.-"),
                  text.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil else { return false }
            let remainder = String(text[text.index(after: colon)...])
            let fragmentParts = remainder.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let pchar = unreserved + subdelims + ":@%"
            if fragmentParts.count == 2 && !allowed(String(fragmentParts[1]), pchar + "/?") { return false }
            let queryParts = (fragmentParts.first.map(String.init) ?? "").split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            if queryParts.count == 2 && !allowed(String(queryParts[1]), pchar + "/?") { return false }
            var path = queryParts.first.map(String.init) ?? ""
            // Match the selected Ajv full-format URI assertion, which rejects a
            // bare scheme even with only a query/fragment suffix.
            guard !path.isEmpty else { return false }
            if path.hasPrefix("//") {
                let tail = path.dropFirst(2)
                let boundary = tail.firstIndex(of: "/") ?? tail.endIndex
                let authority = String(tail[..<boundary]); path = String(tail[boundary...])
                let userParts = authority.split(separator: "@", omittingEmptySubsequences: false)
                guard userParts.count <= 2 else { return false }
                if userParts.count == 2 && !allowed(String(userParts[0]), unreserved + subdelims + ":%") { return false }
                let hostPort = String(userParts.last ?? "")
                if hostPort.hasPrefix("[") {
                    guard let end = hostPort.firstIndex(of: "]") else { return false }
                    let literal = String(hostPort[hostPort.index(after: hostPort.startIndex)..<end])
                    let after = String(hostPort[hostPort.index(after: end)...])
                    if !after.isEmpty && (!after.hasPrefix(":") || !allowed(String(after.dropFirst()), "0123456789")) { return false }
                    let future = allowed(literal, unreserved + subdelims + ":") && literal.range(of: "^[vV][0-9A-Fa-f]+\\.[A-Za-z0-9._~!$&'()*+,;=:-]+$", options: .regularExpression) != nil
                    if !future {
                        guard validIPv6(literal) else { return false }
                    }
                } else {
                    let pieces = hostPort.split(separator: ":", omittingEmptySubsequences: false)
                    guard pieces.count <= 2, allowed(pieces.first.map(String.init) ?? "", unreserved + subdelims + "%") else { return false }
                    if pieces.count == 2 && !allowed(String(pieces[1]), "0123456789") { return false }
                }
            }
            return allowed(path, pchar + "/")
        }
    }
}
