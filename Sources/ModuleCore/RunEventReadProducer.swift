import Foundation
import CoreFoundation
import Dispatch

/// A saved job and immutable cursor, captured before any human proof. Local
/// generation/request IDs are lifetime fences, never server authority epochs.
public struct RunEventReadTarget: Sendable {
    private final class Identity: @unchecked Sendable {}
    private let identity = Identity()
    public let jobID, companyID, agentID, runID: UUID
    public let server: String
    public let afterSeq: Int
    public let generation: UInt64
    public let requestID: String
    public let started: Double
    public static func monotonicNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    public init(job: HandoffJob, generation: UInt64, now: Double, requestID: UUID = UUID()) throws {
        guard let run = job.run, job.eventSequence >= 0, job.eventSequence <= 9_007_199_254_740_991,
              generation > 0, generation <= 9_007_199_254_740_991, now.isFinite, now >= 0,
              let endpoint = try? FuegoServer(job.server), endpoint.origin.utf8.elementsEqual(job.server.utf8) else { throw HandoffProblem.unavailable }
        jobID = job.id; server = job.server; companyID = job.target.company; agentID = job.target.id; runID = run
        afterSeq = job.eventSequence; self.generation = generation; self.requestID = requestID.uuidString.lowercased(); started = now
    }
    public var path: String { "/api/heartbeat-runs/\(runID.uuidString.lowercased())/events?afterSeq=\(afterSeq)&limit=50" }
    public func sameInvocation(as other: Self) -> Bool { identity === other.identity }
    public func matches(_ job: HandoffJob) -> Bool {
        job.id == jobID && job.server.utf8.elementsEqual(server.utf8) && job.target.company == companyID
            && job.target.id == agentID && job.run == runID && job.eventSequence == afterSeq
    }
    public func checkTime(_ now: Double, previous: Double) throws {
        guard now.isFinite, now >= previous, previous >= started, now - started < 12_000 else { throw RunEventReadContract.Failure.expired }
    }
}

/// Actual Session uses this owner and the fixed script below. Neither caller
/// booleans nor the inert contract Reader manufacture a normal human identity.
@MainActor public final class RunEventReadProducerOwner {
    public final class Ticket {
        public let target: RunEventReadTarget
        fileprivate let epoch: UInt64
        fileprivate var lastClock: Double
        fileprivate init(_ target: RunEventReadTarget, epoch: UInt64) { self.target = target; self.epoch = epoch; lastClock = target.started }
    }
    private let lifetime = UUID().uuidString.lowercased()
    private var epoch: UInt64 = 1
    private var closed = false
    private var active: Ticket?
    public init() {}
    static func nextEpoch(_ value: UInt64) -> UInt64 {
        value > 0 && value < 9_007_199_254_740_991 ? value + 1 : 0
    }
    public func retire() { active = nil; epoch = Self.nextEpoch(epoch) }
    public func close() { closed = true; retire() }
    public func finish(_ ticket: Ticket) { if active === ticket { active = nil } }
    private func live(_ ticket: Ticket) throws {
        try Task.checkCancellation()
        guard !closed, epoch > 0, active === ticket, ticket.epoch == epoch else { throw RunEventReadContract.Failure.stale }
    }
    public func begin(_ target: RunEventReadTarget, current: () -> Bool, clock: () -> Double) throws -> Ticket {
        guard !closed, epoch > 0 else { throw HandoffProblem.unavailable }
        let ticket = Ticket(target, epoch: epoch); active = ticket
        do { _ = try check(ticket, current: current, clock: clock); return ticket }
        catch { finish(ticket); throw error }
    }
    /// The context callback consumes the same original deadline. Recheck lease
    /// after both callbacks, even when either re-enters close/retire/begin.
    @discardableResult public func check(_ ticket: Ticket, current: () -> Bool, clock: () -> Double) throws -> Double {
        try live(ticket)
        let valid = current(); try live(ticket)
        let now = clock(); try live(ticket)
        guard valid else { throw HandoffProblem.unavailable }
        try ticket.target.checkTime(now, previous: ticket.lastClock); ticket.lastClock = now
        return now
    }
    public func remaining(_ ticket: Ticket, current: () -> Bool, clock: () -> Double) throws -> Double {
        12_000 - (try check(ticket, current: current, clock: clock) - ticket.target.started)
    }
    public func accept(_ raw: Any?, ticket: Ticket, current: () -> Bool, clock: () -> Double) throws -> Data {
        _ = try check(ticket, current: current, clock: clock)
        guard let value = raw as? [String: Any], Set(value.keys) == Set(["status", "contentType", "body", "beforeUser", "afterUser", "eventGetCount", "normalProofReadCount"]) else { throw HandoffProblem.unavailable }
        func integer(_ key: String) -> Int? {
            guard let n = value[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= 0, n.doubleValue <= 599 else { return nil }
            return n.intValue
        }
        guard let status = integer("status") else { throw HandoffProblem.unavailable }
        if status == 401 { throw HandoffProblem.signIn }; if status == 403 { throw HandoffProblem.forbidden }
        guard let mime = value["contentType"] as? String, let body = value["body"] as? String, let data = body.data(using: .utf8),
              let before = value["beforeUser"] as? String, !before.isEmpty,
              let after = value["afterUser"] as? String, !after.isEmpty,
              integer("eventGetCount") == 1, integer("normalProofReadCount") == 2 else { throw HandoffProblem.unavailable }
        let target = ticket.target
        func binding(_ user: String) throws -> RunEventReadContract.Binding {
            try .init(data: JSONSerialization.data(withJSONObject: ["origin": target.server, "userId": user,
                "companyId": target.companyID.uuidString.lowercased(), "agentId": target.agentID.uuidString.lowercased(),
                "runId": target.runID.uuidString.lowercased(), "clientBindingId": lifetime, "clientGeneration": target.generation,
                "readRequestId": target.requestID, "afterSeq": target.afterSeq, "limit": 50]))
        }
        let expected = try binding(before), latest = try binding(after)
        let finish = try check(ticket, current: current, clock: clock)
        let page = try RunEventReadContract.accept(body: data, status: status, contentType: mime,
            context: .init(expected: expected, current: latest, producerAvailable: true, originQualified: true,
                ownerAlive: true, aborted: false, activeReadRequestId: target.requestID,
                preProof: .init(origin: target.server, userId: before, companyId: expected.companyId, normalHumanSession: true, source: "independent-normal-proof"),
                postProof: .init(origin: target.server, userId: after, companyId: latest.companyId, normalHumanSession: true, source: "independent-normal-proof"),
                eventGetCount: 1, normalProofReadCount: 2, startMonotonicMs: target.started, finishMonotonicMs: finish))
        _ = try check(ticket, current: current, clock: clock)
        return page.data
    }
}

public enum RunEventReadScript {
    public static let source = #"""
    let eventGetCount=0, normalProofReadCount=0;
    const empty=status=>({status,contentType:'',body:'',beforeUser:'',afterUser:'',eventGetCount,normalProofReadCount});
    const uuid=/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
    if(location.origin!==origin || typeof run!=='string' || !uuid.test(run) || run.length!==36
      || !Number.isSafeInteger(afterSeq) || afterSeq<0 || !Number.isFinite(remainingMs) || remainingMs<=0 || remainingMs>12000) return empty(0);
    const controller=new AbortController(), started=performance.now();
    const timer=setTimeout(()=>controller.abort(),remainingMs);
    const current=()=>location.origin===origin && !controller.signal.aborted && performance.now()>=started && performance.now()-started<remainingMs;
    const object=x=>x!==null && typeof x==='object' && !Array.isArray(x);
    async function read(path,maximum,event) {
      if(!current())return {status:0,mime:'',text:''};
      try {
        if(event)eventGetCount++;else normalProofReadCount++;
        const response=await fetch(origin+path,{method:'GET',credentials:'same-origin',redirect:'error',cache:'no-store',
          signal:controller.signal,referrer:origin+'/',referrerPolicy:'same-origin',headers:{Accept:'application/json'}});
        const mime=response.headers.get('content-type')||'';
        if(!current() || mime.split(';')[0].trim().toLowerCase()!=='application/json' || !response.body)return {status:0,mime:'',text:''};
        const reader=response.body.getReader();let chunks=[],count=0;
        for(;;){const {done,value}=await reader.read();if(!current()){await reader.cancel();return {status:0,mime:'',text:''};}
          if(done)break;count+=value.length;if(count>maximum){await reader.cancel();return {status:0,mime:'',text:''};}chunks.push(value);}
        const bytes=new Uint8Array(count);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
        return {status:response.status,mime,text:new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes)};
      }catch{return {status:0,mime:'',text:''};}
    }
    async function human(){
      const response=await read('/api/auth/get-session',65536,false);
      if(response.status!==200)return {status:response.status,user:null};
      try {
        const value=JSON.parse(response.text),user=value?.session?.userId;
        if(!object(value)||!object(value.session)||!object(value.user)||typeof user!=='string'||user.length===0
          ||value.user.id!==user||value.session.id!=='paperclip:session:'+user)return {status:0,user:null};
        return {status:200,user};
      }catch{return {status:0,user:null};}
    }
    try {
      const before=await human();if(!before.user||!current())return empty(before.status===401?401:before.status===403?403:0);
      const events=await read('/api/heartbeat-runs/'+run+'/events?afterSeq='+afterSeq+'&limit=50',524288,true);
      const after=await human();if(!after.user||!current())return empty(after.status===401?401:after.status===403?403:0);
      if(before.user!==after.user)return empty(0);
      return {status:events.status,contentType:events.mime,body:events.text,beforeUser:before.user,afterUser:after.user,eventGetCount,normalProofReadCount};
    }finally{clearTimeout(timer);}
    """#
}
