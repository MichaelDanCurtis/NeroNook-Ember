import Foundation
import CoreFoundation

/// A legacy display fallback is not a selected read origin. Only a saved valid
/// choice or the existing explicit human sign-in action qualifies it.
public struct EmberConversationReadOrigin {
    public let endpoint: FuegoServer
    public private(set) var qualified: Bool
    public init(saved: String?) {
        let configured = saved.flatMap { try? FuegoServer($0) }
        qualified = configured != nil
        endpoint = configured ?? (try! FuegoServer("https://fuego-bridge.curtishome.org"))
    }
    public mutating func selectDisplayed() { qualified = true }
}

/// Local lifecycle only. Neither this lease nor an auth projection is a device
/// grant or server login epoch. The actual session must supply qualified context.
@MainActor public final class EmberConversationReadOwner {
    public final class Ticket {
        public let requestID = UUID().uuidString.lowercased()
        public let started: Double
        fileprivate let generation: UInt64
        fileprivate let selection: UInt64
        fileprivate init(started: Double, generation: UInt64, selection: UInt64) {
            self.started = started; self.generation = generation; self.selection = selection
        }
    }
    private let lifetime = UUID().uuidString.lowercased()
    private var generation: UInt64 = 1
    private var closed = false
    private var active: Ticket?
    public init() {}
    public func retire() {
        active = nil
        generation = generation > 0 && generation < 9_007_199_254_740_991 ? generation + 1 : 0
    }
    public func close() { closed = true; retire() }
    public func begin(qualified: Bool, selection: UInt64?, now: Double) throws -> Ticket {
        guard !closed, qualified, generation > 0, let selection, selection > 0,
              now.isFinite, now >= 0 else { throw HandoffProblem.unavailable }
        let ticket = Ticket(started: now, generation: generation, selection: selection)
        active = ticket; return ticket
    }
    public func finish(_ ticket: Ticket) { if active === ticket { active = nil } }
    public func check(_ ticket: Ticket, qualified: Bool, selection: UInt64?, now: Double, cancelled: Bool) throws {
        if cancelled { throw CancellationError() }
        guard !closed, qualified, active === ticket, generation == ticket.generation,
              selection == ticket.selection else { throw HandoffProblem.unavailable }
        guard now.isFinite, now >= ticket.started, now - ticket.started < 12_000 else { throw HandoffProblem.unavailable }
    }
    /// The two subjects come only from the fixed script's independent auth reads.
    /// Preserve the original snapshot bytes and all downstream run/reply joins.
    public func accept(_ raw: Any?, ticket: Ticket, origin: String, company: UUID, agent: UUID,
                       qualified: Bool, selection: UInt64?, now: Double, cancelled: Bool) throws -> Data {
        try check(ticket, qualified: qualified, selection: selection, now: now, cancelled: cancelled)
        guard let value = raw as? [String: Any], Set(value.keys) == ["status", "contentType", "body", "beforeUser", "afterUser"],
              let status = value["status"] as? NSNumber, CFGetTypeID(status) != CFBooleanGetTypeID(),
              status.doubleValue.isFinite, status.doubleValue.rounded() == status.doubleValue,
              (0...599).contains(status.intValue) else { throw HandoffProblem.unavailable }
        if status.intValue == 401 { throw HandoffProblem.signIn }
        if status.intValue == 403 { throw HandoffProblem.forbidden }
        guard status.intValue == 200, let mime = value["contentType"] as? String,
              let body = value["body"] as? String, let data = body.data(using: .utf8),
              let before = value["beforeUser"] as? String, !before.isEmpty,
              let after = value["afterUser"] as? String, !after.isEmpty else { throw HandoffProblem.unavailable }
        func binding(_ user: String) throws -> EmberConversationReadContract.Binding {
            try .init(data: JSONSerialization.data(withJSONObject: ["origin": origin, "userId": user,
                "companyId": company.uuidString.lowercased(), "agentId": agent.uuidString.lowercased(),
                "clientBindingId": lifetime, "clientGeneration": ticket.generation]))
        }
        let snapshot = try EmberConversationReadContract.accept(body: data, status: status.intValue, contentType: mime,
            context: .init(expected: try binding(before), current: try binding(after), ownerAlive: true,
                aborted: cancelled, requestID: ticket.requestID, activeRequestID: active?.requestID,
                startMonotonicMs: ticket.started, finishMonotonicMs: now))
        return snapshot.data
    }
}

/// Runs in the existing profile's isolated WK client world. No raw session body,
/// credentials, profile fields or synthetic session ID crosses into native code.
public enum EmberConversationReadScript {
    public static let source = #"""
    const empty = status => ({status,contentType:'',body:'',beforeUser:'',afterUser:''});
    const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
    if(location.origin!==origin || typeof company!=='string' || !uuid.test(company)
      || typeof agent!=='string' || !uuid.test(agent)) return empty(0);
    const controller=new AbortController(), started=performance.now();
    const timer=setTimeout(()=>controller.abort(),12000);
    const current=()=>location.origin===origin && !controller.signal.aborted && performance.now()-started<12000;
    const object=x=>x!==null && typeof x==='object' && !Array.isArray(x);
    async function read(path,maximum) {
      if(!current()) return {status:0,mime:'',text:''};
      try {
        const response=await fetch(origin+path,{method:'GET',credentials:'same-origin',redirect:'error',cache:'no-store',
          signal:controller.signal,referrer:origin+'/',referrerPolicy:'same-origin',headers:{Accept:'application/json'}});
        const mime=response.headers.get('content-type')||'';
        if(!current() || mime.split(';')[0].trim().toLowerCase()!=='application/json' || !response.body)
          return {status:0,mime:'',text:''};
        const reader=response.body.getReader();let chunks=[],count=0;
        for(;;){const {done,value}=await reader.read();if(!current()){await reader.cancel();return {status:0,mime:'',text:''};}
          if(done)break;count+=value.length;if(count>maximum){await reader.cancel();return {status:0,mime:'',text:''};}chunks.push(value);}
        const bytes=new Uint8Array(count);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
        return {status:response.status,mime,text:new TextDecoder('utf-8',{fatal:true}).decode(bytes)};
      }catch{return {status:0,mime:'',text:''};}
    }
    async function human() {
      const response=await read('/api/auth/get-session',65536);
      if(response.status!==200)return {status:response.status,user:null};
      try {
        const value=JSON.parse(response.text), user=value?.session?.userId;
        if(!object(value)||!object(value.session)||!object(value.user)||typeof user!=='string'||user.length===0
          ||value.user.id!==user||value.session.id!=='paperclip:session:'+user)return {status:0,user:null};
        return {status:200,user};
      }catch{return {status:0,user:null};}
    }
    try {
      const before=await human();if(!before.user||!current())return empty(before.status===401?401:before.status===403?403:0);
      const snapshot=await read('/api/companies/'+company+'/ember/'+agent,524288);
      const after=await human();if(!after.user||!current())return empty(after.status===401?401:after.status===403?403:0);
      if(before.user!==after.user)return empty(0);
      return {status:snapshot.status,contentType:snapshot.mime,body:snapshot.text,beforeUser:before.user,afterUser:after.user};
    }finally{clearTimeout(timer);}
    """#
}
