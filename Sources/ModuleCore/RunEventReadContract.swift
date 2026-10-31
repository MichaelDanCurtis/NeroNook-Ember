import Foundation
import CoreFoundation
import Dispatch

/// Inert original-run read adapter. Injected proof objects are caller data, never
/// proof of authentication by construction. No network, credentials or producer.
public enum RunEventReadContract {
    public static let packetManifestSHA256 = "66ae05816cd5148f157c10d7dd5341766eef4b3eb13cbedb2f0f5aee93f413d3"
    public static let maximumBodyBytes = 524_288
    public static let maximumDurationMs = 12_000.0
    public enum Failure: Error, LocalizedError, Equatable {
        case unavailable, invalidBinding, unsupportedResponse, stale, expired, httpStatus(Int)
        public var errorDescription: String? {
            switch self {
            case .unavailable, .invalidBinding: return "A current, qualified Fuego session is required."
            case .unsupportedResponse: return "Fuego returned an unsupported event response."
            case .stale: return "This event read is no longer current."
            case .expired: return "The event read timed out."
            case .httpStatus(let status): return "The event read failed (HTTP \(status))."
            }
        }
    }
    public struct Binding: Equatable, Sendable {
        public let origin, userId, companyId, agentId, runId, clientBindingId, readRequestId: String
        public let clientGeneration, afterSeq: Int64
        public let limit = 50
        public init(data: Data) throws {
            guard let value = try? Value.parse(data), let schema = bindingSchema, schema.accepts(value),
                  let origin = value.field("origin")?.string, let user = value.field("userId")?.string,
                  let company = value.field("companyId")?.string, let agent = value.field("agentId")?.string,
                  let run = value.field("runId")?.string, let lifetime = value.field("clientBindingId")?.string,
                  let request = value.field("readRequestId")?.string,
                  let generation = value.field("clientGeneration")?.number, let cursor = value.field("afterSeq")?.number else { throw Failure.invalidBinding }
            self.origin = origin; userId = user; companyId = company; agentId = agent; runId = run
            clientBindingId = lifetime; readRequestId = request; clientGeneration = Int64(generation); afterSeq = Int64(cursor)
        }
        public static func == (a: Self, b: Self) -> Bool {
            exact(a.origin,b.origin) && exact(a.userId,b.userId) && exact(a.companyId,b.companyId)
                && exact(a.agentId,b.agentId) && exact(a.runId,b.runId) && exact(a.clientBindingId,b.clientBindingId)
                && exact(a.readRequestId,b.readRequestId) && a.clientGeneration == b.clientGeneration && a.afterSeq == b.afterSeq
        }
    }
    /// Caller-supplied observation from a separately qualified producer. Company
    /// is local selection/currentness, NOT an auth-response membership claim.
    public struct HumanProof: Sendable {
        public let origin, userId, companyId, source: String
        public let normalHumanSession: Bool
        public init(origin: String, userId: String, companyId: String, normalHumanSession: Bool, source: String) {
            self.origin = origin; self.userId = userId; self.companyId = companyId
            self.normalHumanSession = normalHumanSession; self.source = source
        }
        fileprivate func matches(_ binding: Binding) -> Bool {
            normalHumanSession && exact(source,"independent-normal-proof") && exact(origin,binding.origin)
                && exact(userId,binding.userId) && exact(companyId,binding.companyId)
        }
    }
    public struct DecodedPage: Sendable {
        public let data: Data
        public let rowCount: Int
        fileprivate let rows: [Value]
    }
    /// Full original bytes and an atomic cursor proposal. No mutation, effect
    /// permission, watermark or history-complete flag is supplied by this type.
    public struct Page: Sendable {
        public let data: Data
        public let rowCount: Int
        public let nextCursor: Int64
    }
    public struct Acceptance: Sendable {
        public let expected, current: Binding?
        public let producerAvailable, originQualified, ownerAlive, aborted: Bool
        public let activeReadRequestId: String?
        public let preProof, postProof: HumanProof?
        public let eventGetCount, normalProofReadCount: Int
        public let startMonotonicMs, finishMonotonicMs: Double
        public init(expected: Binding?, current: Binding?, producerAvailable: Bool, originQualified: Bool,
                    ownerAlive: Bool, aborted: Bool, activeReadRequestId: String?, preProof: HumanProof?, postProof: HumanProof?,
                    eventGetCount: Int, normalProofReadCount: Int, startMonotonicMs: Double, finishMonotonicMs: Double) {
            self.expected = expected; self.current = current; self.producerAvailable = producerAvailable
            self.originQualified = originQualified; self.ownerAlive = ownerAlive; self.aborted = aborted
            self.activeReadRequestId = activeReadRequestId; self.preProof = preProof; self.postProof = postProof
            self.eventGetCount = eventGetCount; self.normalProofReadCount = normalProofReadCount
            self.startMonotonicMs = startMonotonicMs; self.finishMonotonicMs = finishMonotonicMs
        }
    }
    public static func decodePage(_ data: Data) throws -> DecodedPage {
        guard data.count <= maximumBodyBytes, let value = try? Value.parse(data),
              let schema = responseSchema, schema.accepts(value), let rows = value.array else { throw Failure.unsupportedResponse }
        return .init(data: data, rowCount: rows.count, rows: rows)
    }
    public static func accept(body: Data, status: Int, contentType: String, context: Acceptance) throws -> Page {
        if context.aborted { throw CancellationError() }
        guard context.producerAvailable, context.originQualified, let binding = context.expected else { throw Failure.unavailable }
        guard context.ownerAlive, context.current == binding, let active = context.activeReadRequestId,
              exact(active,binding.readRequestId) else { throw Failure.stale }
        guard context.eventGetCount == 1, context.normalProofReadCount == 2,
              context.preProof?.matches(binding) == true, context.postProof?.matches(binding) == true else { throw Failure.unavailable }
        try checkTime(context.startMonotonicMs,context.finishMonotonicMs)
        guard status == 200 else { throw Failure.httpStatus(status) }
        guard contentType.split(separator:";",omittingEmptySubsequences:false).first.map({
            $0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() == "application/json"
        }) == true else { throw Failure.unsupportedResponse }
        let decoded = try decodePage(body)
        var cursor = binding.afterSeq
        for row in decoded.rows {
            guard let company = row.field("companyId")?.string, let agent = row.field("agentId")?.string,
                  let run = row.field("runId")?.string, let number = row.field("seq")?.number,
                  exact(company,binding.companyId), exact(agent,binding.agentId), exact(run,binding.runId) else { throw Failure.stale }
            let seq = Int64(number)
            guard seq > cursor else { throw Failure.unsupportedResponse }
            cursor = seq
        }
        return .init(data: body, rowCount: decoded.rowCount, nextCursor: cursor)
    }
    public struct CurrentContext: Sendable {
        public let binding: Binding?
        public let ownerAlive, originQualified, producerAvailable: Bool
        public init(binding: Binding?, ownerAlive: Bool, originQualified: Bool, producerAvailable: Bool) {
            self.binding = binding; self.ownerAlive = ownerAlive; self.originQualified = originQualified; self.producerAvailable = producerAvailable
        }
    }
    public struct Request: Sendable {
        public let binding: Binding
        public var id: String { binding.readRequestId }
        public let method = "GET"
        public let body: Data? = nil
        public let accept = "application/json"
        public let cache = "no-store"
        public let redirectsAllowed = false
        public var path: String { "/api/heartbeat-runs/\(binding.runId)/events" }
        public var query: String { "afterSeq=\(binding.afterSeq)&limit=50" }
    }
    public struct Response: Sendable {
        public let status: Int
        public let contentType: String
        public let body: Data
        public init(status: Int, contentType: String, body: Data) { self.status = status; self.contentType = contentType; self.body = body }
    }
    /// One injected proof callback is invoked twice, with pre/post ordering around
    /// exactly one event transport. None is an actual network/auth producer here.
    @MainActor public final class Reader {
        private final class Lease { var id: String?; var aborted = false }
        private let context: @MainActor () -> CurrentContext
        private let clock: @MainActor () -> Double
        private var active: Lease?
        private var closed = false
        public var activeRequestID: String? { active?.id }
        public init(context: @escaping @MainActor () -> CurrentContext,
                    clock: @escaping @MainActor () -> Double = { Double(DispatchTime.now().uptimeNanoseconds)/1_000_000 }) {
            self.context = context; self.clock = clock
        }
        public func cancelCurrent() { active?.aborted = true; active = nil }
        public func close() { closed = true; active = nil }
        public func read(proof: (@MainActor (Binding) async throws -> HumanProof?)? = nil,
                         using transport: @MainActor (Request) async throws -> Response) async throws -> Page {
            try Task.checkCancellation()
            guard !closed else { throw Failure.stale }
            let lease = Lease(); active = lease
            defer { if active === lease { active = nil } }
            let start = clock(); try requireLease(lease); try checkTime(start,start)
            let before = context(); try requireLease(lease)
            guard before.producerAvailable, before.originQualified, before.ownerAlive,
                  let binding = before.binding, let proof else { throw Failure.unavailable }
            lease.id = binding.readRequestId
            try checkpoint(lease,binding:binding,start:start)
            let first = try await proof(binding)
            try checkpoint(lease,binding:binding,start:start)
            guard first?.matches(binding) == true else { throw Failure.unavailable }
            let response = try await transport(Request(binding:binding))
            try checkpoint(lease,binding:binding,start:start)
            let last = try await proof(binding)
            try checkpoint(lease,binding:binding,start:start)
            guard last?.matches(binding) == true else { throw Failure.unavailable }
            let current = context(); try requireLease(lease); try requireContext(current,binding:binding)
            let finish = clock(); try requireLease(lease)
            let page = try accept(body:response.body,status:response.status,contentType:response.contentType,
                context:.init(expected:binding,current:current.binding,producerAvailable:current.producerAvailable,
                    originQualified:current.originQualified,ownerAlive:current.ownerAlive,aborted:lease.aborted,
                    activeReadRequestId:active?.id,preProof:first,postProof:last,eventGetCount:1,normalProofReadCount:2,
                    startMonotonicMs:start,finishMonotonicMs:finish))
            // Include decoding and final currentness in the same acceptance budget.
            try checkpoint(lease,binding:binding,start:start)
            let end = clock(); try requireLease(lease); try checkTime(start,end)
            return page
        }
        private func requireLease(_ lease: Lease) throws {
            try Task.checkCancellation()
            if lease.aborted { throw CancellationError() }
            guard !closed, active === lease else { throw Failure.stale }
        }
        private func requireContext(_ value: CurrentContext, binding: Binding) throws {
            guard value.producerAvailable, value.originQualified else { throw Failure.unavailable }
            guard value.ownerAlive, value.binding == binding else { throw Failure.stale }
        }
        private func checkpoint(_ lease: Lease, binding: Binding, start: Double) throws {
            try requireLease(lease)
            let current = context(); try requireLease(lease)
            // The context callback itself consumes this same deadline. Sampling
            // before it could admit a new proof/GET after the budget expired.
            let now = clock(); try requireLease(lease)
            try requireContext(current,binding:binding); try checkTime(start,now)
        }
    }
    private static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    private static func checkTime(_ start: Double, _ finish: Double) throws {
        guard start.isFinite, finish.isFinite, start >= 0, finish >= start, finish-start < maximumDurationMs else { throw Failure.expired }
    }
    // Exact packet descriptors copied into this assigned file; no extraction or
    // edits to the private, frozen conversation evaluator or shared SDK.
    private static let responseSchema = try? Schema(Data(responseSchemaJSON.utf8))
    private static let bindingSchema = try? Schema(Data(bindingSchemaJSON.utf8))
    private static let responseSchemaJSON = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:fuego:client-candidate:run-event-read:c1:response",
  "$comment": "Existing bare-array GET projection. Local artifact identity only. Opaque extensions are retained; validation confers no authority.",
  "type": "array",
  "maxItems": 50,
  "items": {
    "type": "object",
    "required": [
      "id",
      "companyId",
      "runId",
      "agentId",
      "seq",
      "eventType",
      "stream",
      "level",
      "color",
      "message",
      "payload",
      "createdAt"
    ],
    "properties": {
      "id": {
        "type": "integer",
        "minimum": 1,
        "maximum": 9007199254740991
      },
      "companyId": {
        "type": "string",
        "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
      },
      "runId": {
        "type": "string",
        "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
      },
      "agentId": {
        "type": "string",
        "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
      },
      "seq": {
        "type": "integer",
        "minimum": 1,
        "maximum": 9007199254740991
      },
      "eventType": {
        "type": "string"
      },
      "stream": {
        "anyOf": [
          {
            "type": "string"
          },
          {
            "type": "null"
          }
        ]
      },
      "level": {
        "anyOf": [
          {
            "type": "string"
          },
          {
            "type": "null"
          }
        ]
      },
      "color": {
        "anyOf": [
          {
            "type": "string"
          },
          {
            "type": "null"
          }
        ]
      },
      "message": {
        "anyOf": [
          {
            "type": "string"
          },
          {
            "type": "null"
          }
        ]
      },
      "payload": {
        "anyOf": [
          {
            "type": "object",
            "additionalProperties": {
              "$ref": "#/$defs/jsonValue"
            }
          },
          {
            "type": "null"
          }
        ]
      },
      "createdAt": {
        "type": "string",
        "pattern": "^(?:(?:[0-9][0-9][2468][048]|[0-9][0-9][13579][26]|[0-9][0-9]0[48]|[02468][048]00|[13579][26]00)-02-29|[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)|(?:02)-(?:0[1-9]|1[0-9]|2[0-8])))T(?:(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9](?:\\.[0-9]+)?)?(?:Z|([+-](?:[01][0-9]|2[0-3]):[0-5][0-9])))$"
      },
      "sourceInstanceId": {
        "anyOf": [
          {
            "type": "string"
          },
          {
            "type": "null"
          }
        ]
      },
      "sourceEventId": {
        "anyOf": [
          {
            "type": "string"
          },
          {
            "type": "null"
          }
        ]
      },
      "sourceSeq": {
        "anyOf": [
          {
            "type": "integer",
            "minimum": -9007199254740991,
            "maximum": 9007199254740991
          },
          {
            "type": "null"
          }
        ]
      },
      "sourcePayloadSha256": {
        "anyOf": [
          {
            "type": "string"
          },
          {
            "type": "null"
          }
        ]
      },
      "protocolSchemaVersion": {
        "anyOf": [
          {
            "type": "integer",
            "minimum": -2147483648,
            "maximum": 2147483647
          },
          {
            "type": "null"
          }
        ]
      }
    },
    "additionalProperties": {
      "$ref": "#/$defs/jsonValue"
    }
  },
  "$defs": {
    "jsonValue": {
      "anyOf": [
        {
          "type": "null"
        },
        {
          "type": "boolean"
        },
        {
          "type": "number"
        },
        {
          "type": "string"
        },
        {
          "type": "array",
          "items": {
            "$ref": "#/$defs/jsonValue"
          }
        },
        {
          "type": "object",
          "additionalProperties": {
            "$ref": "#/$defs/jsonValue"
          }
        }
      ]
    }
  }
}
"""# + "\n"
    private static let bindingSchemaJSON = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:fuego:client-candidate:run-event-read:c1:local-binding",
  "$comment": "Independently captured caller context and immutable request controls, never an event-derived identity or wire body.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "origin",
    "userId",
    "companyId",
    "agentId",
    "runId",
    "clientBindingId",
    "clientGeneration",
    "readRequestId",
    "afterSeq",
    "limit"
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
    "runId": {
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
    },
    "readRequestId": {
      "type": "string",
      "pattern": "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"
    },
    "afterSeq": {
      "type": "integer",
      "minimum": 0,
      "maximum": 9007199254740991
    },
    "limit": {
      "const": 50
    }
  }
}
"""# + "\n"

    fileprivate indirect enum Value: Sendable, Equatable {
        case object([String: Value]), array([Value]), string(String), number(Double), bool(Bool), null
        var object: [String:Value]? { if case .object(let v)=self {return v};return nil }
        var array: [Value]? { if case .array(let v)=self {return v};return nil }
        var string: String? { if case .string(let v)=self {return v};return nil }
        var number: Double? { if case .number(let v)=self {return v};return nil }
        func field(_ key: String) -> Value? { object?.first(where:{exact($0.key,key)})?.value }
        static func == (a: Value,b: Value) -> Bool {
            switch(a,b) {
            case (.string(let a),.string(let b)):return exact(a,b)
            case (.number(let a),.number(let b)):return a==b
            case (.bool(let a),.bool(let b)):return a==b
            case (.null,.null):return true
            case (.array(let a),.array(let b)):return a==b
            case (.object(let a),.object(let b)):
                return a.count==b.count && a.allSatisfy { key,value in b.first(where:{exact($0.key,key)})?.value==value }
            default:return false
            }
        }
        static func parse(_ data: Data) throws -> Value {
            guard !data.contains(0),String(data:data,encoding:.utf8) != nil else {throw Failure.unsupportedResponse}
            let item=try JSONSerialization.jsonObject(with:data,options:[.fragmentsAllowed])
            // Inspect every raw numeric token, even if platform dictionary
            // bridging coalesces canonically equivalent unknown member names.
            // Only original Data, never this projection, promises opaque retention.
            let bytes=Array(data);var i=0,inString=false,escaped=false
            while i<bytes.count {
                let b=bytes[i]
                if inString {
                    if escaped {escaped=false} else if b==92 {escaped=true} else if b==34 {inString=false}
                    i+=1;continue
                }
                if b==34 {inString=true;i+=1;continue}
                if b==45 || (48...57).contains(b) {
                    let start=i
                    while i<bytes.count && ![UInt8(32),9,10,13,44,93,125].contains(bytes[i]) {i+=1}
                    guard let token=String(bytes:bytes[start..<i],encoding:.utf8),let n=Double(token),n.isFinite else {throw Failure.unsupportedResponse}
                } else {i+=1}
            }
            // Foundation's own JSON parser limits remain platform limits; no
            // invented depth64 restriction is added by this candidate.
            return try convert(item)
        }
        private static func convert(_ item:Any)throws->Value {
            if item is NSNull{return .null}
            if let n=item as? NSNumber {
                if CFGetTypeID(n)==CFBooleanGetTypeID(){return .bool(n.boolValue)}
                guard n.doubleValue.isFinite else{throw Failure.unsupportedResponse};return .number(n.doubleValue)
            }
            if let s=item as? String{return .string(s)}
            if let a=item as? [Any]{return .array(try a.map(convert))}
            if let o=item as? [String:Any]{return .object(try o.mapValues(convert))}
            throw Failure.unsupportedResponse
        }
    }
    private struct Schema {
        let root: Value
        let patterns: [String:NSRegularExpression]
        init(_ data:Data)throws {
            root=try Value.parse(data)
            var found=Set<String>()
            func collect(_ v:Value){if let o=v.object {if let p=v.field("pattern")?.string{found.insert(p)};o.values.forEach(collect)};v.array?.forEach(collect)}
            collect(root)
            patterns=try Dictionary(uniqueKeysWithValues:found.map{($0,try NSRegularExpression(pattern:$0))})
        }
        func accepts(_ value:Value)->Bool {validate(value,against:root)}
        private func validate(_ value:Value,against schema:Value)->Bool {
            guard let s=schema.object, s.keys.allSatisfy({ key in ["$schema","$id","$comment","$defs","$ref","type","properties","required","additionalProperties","anyOf","items","maxItems","const","pattern","format","minLength","minimum","maximum"].contains(where:{exact($0,key)})}) else{return false}
            if let ref=schema.field("$ref")?.string {
                guard ref=="#/$defs/jsonValue",let target=root.field("$defs")?.field("jsonValue") else{return false}
                return validate(value,against:target)
            }
            if let type=schema.field("type")?.string {
                switch(type,value){
                case ("object",.object),("array",.array),("string",.string),("boolean",.bool),("null",.null):break
                case ("number",.number(let n)):if !n.isFinite{return false}
                case ("integer",.number(let n)):if !n.isFinite || n.rounded(.towardZero) != n{return false}
                default:return false
                }
            }
            if let choices=schema.field("anyOf")?.array,!choices.contains(where:{validate(value,against:$0)}){return false}
            if let fixed=schema.field("const"),fixed != value{return false}
            if let o=value.object {
                if let required=schema.field("required")?.array,!required.allSatisfy({$0.string.map{value.field($0) != nil} ?? false}){return false}
                let properties=schema.field("properties")
                for (key,child) in o {
                    if let shape=properties?.field(key) {if !validate(child,against:shape){return false}}
                    else if let extra=schema.field("additionalProperties") {
                        if extra == .bool(false){return false}
                        if extra.object != nil && !validate(child,against:extra){return false}
                    }
                }
            }
            if let a=value.array {
                if let max=schema.field("maxItems")?.number,Double(a.count)>max{return false}
                if let shape=schema.field("items"),!a.allSatisfy({validate($0,against:shape)}){return false}
            }
            if let text=value.string {
                if let min=schema.field("minLength")?.number,Double(text.unicodeScalars.count)<min{return false}
                if let p=schema.field("pattern")?.string {
                    let range=NSRange(text.startIndex..<text.endIndex,in:text)
                    guard let match=patterns[p]?.firstMatch(in:text,range:range),match.range==range else{return false}
                }
                if let f=schema.field("format")?.string,f != "uri" || !validURI(text){return false}
            }
            if let n=value.number {
                if !n.isFinite{return false}
                if let min=schema.field("minimum")?.number,n<min{return false}
                if let max=schema.field("maximum")?.number,n>max{return false}
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
