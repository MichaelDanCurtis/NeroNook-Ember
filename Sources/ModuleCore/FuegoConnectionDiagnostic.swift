import Foundation
import CoreFoundation

/// Observation only. Never an authorization object, owner proof or registration
/// receipt. No account/session identifier, response body or credential is retained.
public struct FuegoConnectionDiagnostic: Equatable, Sendable {
    public enum SessionKind: String, Sendable { case unknown, humanWebSession, boardKey, localImplicit, signedOut }
    public enum CatalogRead: String, Sendable { case unknown, eligible, denied, unavailable }
    public let selectedCompany: UUID?
    public let sessionKind: SessionKind
    public let sessionHTTPStatus: Int
    public let catalogRead: CatalogRead
    public let catalogHTTPStatus: Int

    public static func unknown(company: UUID?) -> Self {
        .init(selectedCompany: company, sessionKind: .unknown, sessionHTTPStatus: 0, catalogRead: .unknown, catalogHTTPStatus: 0)
    }
    public static func decode(_ raw: Any?, company: UUID?) -> Self {
        guard let value = raw as? [String: Any], Set(value.keys) == ["sessionKind", "sessionHTTPStatus", "catalogRead", "catalogHTTPStatus"],
              let kind = (value["sessionKind"] as? String).flatMap(SessionKind.init(rawValue:)),
              let catalog = (value["catalogRead"] as? String).flatMap(CatalogRead.init(rawValue:)),
              let sessionStatus = status(value["sessionHTTPStatus"]), let catalogStatus = status(value["catalogHTTPStatus"]),
              kind == .unknown || kind == .signedOut || sessionStatus == 200,
              kind != .signedOut || sessionStatus == 401 || catalogStatus == 401,
              company != nil || catalogStatus == 0 && catalog == .unknown,
              catalog != .eligible || kind == .humanWebSession && catalogStatus == 200,
              catalog != .denied || [401, 403].contains(catalogStatus),
              catalog != .unavailable || [404, 405, 503].contains(catalogStatus) else { return .unknown(company: company) }
        return .init(selectedCompany: company, sessionKind: kind, sessionHTTPStatus: sessionStatus,
                     catalogRead: catalog, catalogHTTPStatus: catalogStatus)
    }
    public func checked(company: UUID?, samePage: Bool) -> Self {
        samePage && selectedCompany == company ? self : .unknown(company: company)
    }
    private static func status(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue == 0 || (100...599).contains(number.doubleValue) else { return nil }
        return number.intValue
    }
}

/// Runs only in the already configured session's isolated WebKit client world.
/// All bodies and subject identifiers stay inside that client. The four-field
/// return is a content-free diagnostic projection, not server authority.
public enum FuegoConnectionDiagnosticScript {
    public static let source = #"""
    const result = {sessionKind:'unknown',sessionHTTPStatus:0,catalogRead:'unknown',catalogHTTPStatus:0};
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    if (location.origin !== origin || (company !== '' && !uuid.test(company))) return result;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12000);
    async function read(path) {
      try {
        if (location.origin !== origin) return {status:0,value:null};
        const response = await fetch(origin + path, {method:'GET',credentials:'same-origin',redirect:'error',cache:'no-store',
          signal:controller.signal,referrer:origin+'/',referrerPolicy:'same-origin',headers:{'Accept':'application/json'}});
        const status = response.status;
        if (!response.headers.get('content-type')?.toLowerCase().includes('application/json') || !response.body) return {status,value:null};
        const reader = response.body.getReader(); let chunks=[],count=0;
        for (;;) {
          const {done,value}=await reader.read(); if(done)break;count+=value.length;
          if(count>65536){await reader.cancel();return {status,value:null};} chunks.push(value);
        }
        if(location.origin!==origin)return {status:0,value:null};
        const bytes=new Uint8Array(count);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
        return {status,value:JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes))};
      } catch {return {status:0,value:null};}
    }
    function object(value) {return value!==null && typeof value==='object' && !Array.isArray(value);}
    function catalog(value) {
      if(!object(value)||Object.keys(value).sort().join(',')!=='items,nextAfterId'||!Array.isArray(value.items)||value.items.length>100
        ||!(value.nextAfterId===null||typeof value.nextAfterId==='string'&&uuid.test(value.nextAfterId)))return false;
      return value.items.every(row=>object(row)&&Object.keys(row).sort().join(',')==='availability,entryId,headRevisionId,publicationId,version'
        &&typeof row.entryId==='string'&&uuid.test(row.entryId)&&typeof row.headRevisionId==='string'&&uuid.test(row.headRevisionId)
        &&(row.publicationId===null||typeof row.publicationId==='string'&&uuid.test(row.publicationId))
        &&Number.isInteger(row.version)&&row.version>=1&&row.version<=2147483647&&['active','archived'].includes(row.availability));
    }
    try {
      const session=await read('/api/auth/get-session');result.sessionHTTPStatus=session.status;
      if(session.status===401){result.sessionKind='signedOut';return result;}
      const body=session.value;
      if(session.status!==200||!object(body)||!object(body.session)||!object(body.user))return result;
      const user=body.session.userId;
      if(typeof user!=='string'||user.length===0||user.length>512||body.user.id!==user||typeof body.session.id!=='string')return result;
      if(body.session.id==='paperclip:session:'+user)result.sessionKind='humanWebSession';
      else if(body.session.id==='paperclip:board_key:'+user)result.sessionKind='boardKey';
      else if(body.session.id==='paperclip:local_implicit:'+user)result.sessionKind='localImplicit';
      if(result.sessionKind!=='humanWebSession'||company==='')return result;
      const response=await read('/api/companies/'+company+'/flows');result.catalogHTTPStatus=response.status;
      if(response.status===401){result.sessionKind='signedOut';result.catalogRead='denied';}
      else if(response.status===403)result.catalogRead='denied';
      else if([404,405,503].includes(response.status))result.catalogRead='unavailable';
      else if(response.status===200&&catalog(response.value))result.catalogRead='eligible';
      return location.origin===origin ? result : {sessionKind:'unknown',sessionHTTPStatus:0,catalogRead:'unknown',catalogHTTPStatus:0};
    } finally {clearTimeout(timer);}
    """#
}
