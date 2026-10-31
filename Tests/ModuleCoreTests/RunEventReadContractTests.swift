import Foundation
import CryptoKit
import XCTest
@testable import ModuleCore

/// Frozen authored data plus controlled callbacks; no account, URL, service,
/// credentials or network producer is discovered or constructed by these tests.
@MainActor final class RunEventReadContractTests: XCTestCase {
    private typealias C = RunEventReadContract
    private var packet: Packet!
    override func setUpWithError() throws { packet = try Packet.load() }

    func testAll72DTOFixturesPreserveOriginalBytes() throws {
        XCTAssertEqual(packet.dto.count,72)
        for item in packet.dto {
            let name=try text(item,"name"), expected=try flag(item,"valid"), bytes=try json(field(item,"value"))
            do {
                let decoded=try C.decodePage(bytes)
                XCTAssertTrue(expected,name);XCTAssertEqual(decoded.data,bytes,name)
            } catch {XCTAssertFalse(expected,name);XCTAssertEqual(error as? C.Failure,.unsupportedResponse,name)}
        }
    }
    func testAll64LocalPolicyFixturesAreAtomicAndPreserveBytes() throws {
        XCTAssertEqual(packet.lifecycle.count,64)
        for item in packet.lifecycle {
            let name=try text(item,"name"),expected=try flag(item,"accepted"),bytes=try json(field(item,"page"))
            let initial=try field(item,"initialMessages"),initialBytes=try json(initial)
            var committed: C.Page?
            do {
                let result=try C.accept(body:bytes,status:try integer(item,"status"),contentType:try text(item,"contentType"),context:try acceptance(item))
                committed=result;XCTAssertTrue(expected,name);XCTAssertEqual(result.data,bytes,name)
                let rows=try array(item,"page"),before=try object(item,"before")
                let cursor=try (rows.last?["seq"] as? NSNumber ?? XCTUnwrap(before["afterSeq"] as? NSNumber))
                XCTAssertEqual(result.nextCursor,cursor.int64Value,name);XCTAssertEqual(result.rowCount,rows.count,name)
            } catch {XCTAssertFalse(expected,name);XCTAssertNil(committed,name)}
            XCTAssertEqual(try json(initial),initialBytes,"Caller messages must not be mutated: "+name)
        }
    }
    func testAllSixRawFixturesUseActualMeasuredBytesAndDigests() throws {
        XCTAssertEqual(packet.raw.count,6)
        let context=try acceptance(base())
        for item in packet.raw {
            let name=try text(item,"name"),expected=try flag(item,"accepted"),bytes=try rawBytes(item)
            XCTAssertEqual(bytes.count,try integer(item,"actualBytes"),name)
            XCTAssertEqual(hash(bytes),try text(item,"sha256"),name)
            do {let page=try C.accept(body:bytes,status:200,contentType:"application/json",context:context)
                XCTAssertTrue(expected,name);XCTAssertEqual(page.data,bytes,name)
            } catch {XCTAssertFalse(expected,name)}
        }
    }
    func testBindingControlsRejectBooleansFractionsNullUnsafeAndUnknownKeys() throws {
        let original=try baseBinding()
        for key in ["clientGeneration","afterSeq","limit"] {
            for bad in [true,NSNull(),"1",1.5,9_007_199_254_740_992.0] as [Any] {
                var changed=original;changed[key]=bad
                XCTAssertThrowsError(try binding(changed),key){XCTAssertEqual($0 as? C.Failure,.invalidBinding)}
            }
        }
        for key in original.keys {var changed=original;changed.removeValue(forKey:key);XCTAssertThrowsError(try binding(changed),key)}
        var extra=original;extra["unexpected"]=false;XCTAssertThrowsError(try binding(extra))
        extra=original;extra["userId"]="";XCTAssertThrowsError(try binding(extra))
    }
    func testURIAndUUIDTerminalBoundariesRetainTheSelectedC1Rules() throws {
        let original=try baseBinding()
        for uri in ["x:","x:?q","x:#f","https://[:::]","https://h/path[bad]","https://h/%GG","https://h/#one#two"] {
            var changed=original;changed["origin"]=uri;XCTAssertThrowsError(try binding(changed),uri)
        }
        for uri in ["x:/","urn:example:abc","https://[::1]","https://[v1.a]","x://","x:///"] {
            var changed=original;changed["origin"]=uri;XCTAssertNoThrow(try binding(changed),uri)
        }
        for ending in ["\n","\r","\r\n","\u{2028}","\u{0085}"] {
            for key in ["companyId","agentId","runId","clientBindingId","readRequestId"] {
                var changed=original;changed[key]=try text(original,key)+ending;XCTAssertThrowsError(try binding(changed),key)
            }
            for key in ["companyId","agentId","runId"] {
                var row=try firstRow();row[key]=try text(row,key)+ending;XCTAssertThrowsError(try C.decodePage(json([row])),key)
            }
        }
    }
    func testOpaqueIdentitiesAndUUIDScopesUseExactUTF8NotSwiftEquality() throws {
        let nfc="human:caf\u{00e9}",nfd="human:cafe\u{0301}"
        XCTAssertEqual(nfc,nfd);XCTAssertFalse(nfc.utf8.elementsEqual(nfd.utf8))
        for key in ["userId","origin"] {
            var a=try baseBinding(),b=a
            // URI shape is ASCII-only; Unicode distinction is exercised in opaque human.
            if key=="origin" {a[key]="https://h/%c3%a9";b[key]="https://h/%C3%A9"} else {a[key]=nfc;b[key]=nfd}
            let expected=try binding(a),different=try binding(b)
            XCTAssertNotEqual(expected,different)
            let context=validContext(expected:expected,current:different)
            XCTAssertThrowsError(try C.accept(body:response(),status:200,contentType:"application/json",context:context)) {XCTAssertEqual($0 as? C.Failure,.stale)}
        }
        let valid=try binding(baseBinding());var row=try firstRow()
        row["companyId"]=try text(row,"companyId").uppercased()
        XCTAssertNoThrow(try C.decodePage(json([row])))
        XCTAssertThrowsError(try C.accept(body:json([row]),status:200,contentType:"application/json",context:validContext(expected:valid,current:valid))) {XCTAssertEqual($0 as? C.Failure,.stale)}
    }
    func testDistinctCanonicalEquivalentOpaqueMemberNamesAndNonfiniteExtensions() throws {
        let basic=try XCTUnwrap(String(data:json([firstRow()]),encoding:.utf8))
        let insert=try XCTUnwrap(basic.range(of:"[{"))
        var authored=basic;authored.replaceSubrange(insert,with:"[{\"caf\\u00e9\":false,\"cafe\\u0301\":0,")
        let bytes=Data(authored.utf8),page=try C.decodePage(bytes)
        XCTAssertEqual(page.data,bytes,"Only original bytes promise opaque member-name retention, not a Foundation dictionary projection.")
        for token in ["1e999","-1e999"] {
            var bad=basic;bad.replaceSubrange(try XCTUnwrap(bad.range(of:"[{")),with:"[{\"extension\":{\"nested\":[\(token)]},")
            XCTAssertThrowsError(try C.decodePage(Data(bad.utf8)))
        }
        // Deeper than the prior conversation adapter's undocumented depth64 cap.
        var row=try firstRow();var nested:Any=false
        for _ in 0..<80 {nested=[nested]};row["extension"]=nested
        XCTAssertNoThrow(try C.decodePage(json([row])))
    }
    func testLateInvalidRowDoesNotProduceAnyCursorOrPageCommit() throws {
        let valid=try binding(baseBinding()),body=try response()
        let accepted=try C.accept(body:body,status:200,contentType:"application/json",context:validContext(expected:valid,current:valid))
        var cursor=accepted.nextCursor,retained=accepted.data
        var second=try firstRow();second["id"]=2;second["seq"]=2;second["payload"]=[]
        let bytes=try json([firstRow(),second])
        do {let next=try C.accept(body:bytes,status:200,contentType:"application/json",context:validContext(expected:valid,current:valid));cursor=next.nextCursor;retained=next.data;XCTFail("Malformed final row admitted a partial page")}
        catch {XCTAssertEqual(cursor,accepted.nextCursor);XCTAssertEqual(retained,body)}
    }
    func testNullOptionalMetadataAndFiniteFractionalUnknownValuesRemainOpaque() throws {
        var row=try firstRow();row["sourceSeq"]=NSNull();row["protocolSchemaVersion"]=NSNull()
        row["extension"]=["number":0.125,"empty":"","false":false,"zero":0,"nul":"\u{0000}"] as [String:Any]
        let bytes=try json([row]);XCTAssertEqual(try C.decodePage(bytes).data,bytes)
        for key in ["sourceSeq","protocolSchemaVersion"] {row[key]=true;XCTAssertThrowsError(try C.decodePage(json([row])));row[key]=NSNull()}
    }
    func testReaderMakesTwoSeparateProofCallsAroundExactlyOneBoundGET() async throws {
        let valid=try binding(baseBinding()),raw=try response();var order:[String]=[]
        let reader=reader(valid)
        let page=try await reader.read(proof:{binding in order.append("proof");return self.proof(binding)}) { request in
            order.append("GET");XCTAssertEqual(request.id,valid.readRequestId);XCTAssertEqual(request.binding,valid)
            XCTAssertEqual(request.method,"GET");XCTAssertNil(request.body);XCTAssertEqual(request.path,"/api/heartbeat-runs/"+valid.runId+"/events")
            XCTAssertEqual(request.query,"afterSeq=0&limit=50");XCTAssertEqual(request.accept,"application/json")
            XCTAssertEqual(request.cache,"no-store");XCTAssertFalse(request.redirectsAllowed)
            return .init(status:200,contentType:"APPLICATION/JSON; charset=utf-8",body:raw)
        }
        XCTAssertEqual(order,["proof","GET","proof"]);XCTAssertEqual(page.data,raw);XCTAssertEqual(page.nextCursor,1);XCTAssertNil(reader.activeRequestID)
    }
    func testMissingProducerOrProofCallbackNeverMakesAnEventRequest() async throws {
        let valid=try binding(baseBinding()),raw=try response()
        for kind in ["binding","producer","origin","owner","callback"] {
            var gets=0,proofs=0
            let reader=C.Reader(context:{.init(binding:kind=="binding" ? nil:valid,ownerAlive:kind != "owner",originQualified:kind != "origin",producerAvailable:kind != "producer")},clock:{100})
            let callback: (@MainActor(C.Binding) async throws -> C.HumanProof?)? = kind=="callback" ? nil : { b in proofs+=1;return self.proof(b) }
            do {_ = try await reader.read(proof:callback){_ in gets+=1;return .init(status:200,contentType:"application/json",body:raw)};XCTFail(kind)}
            catch {XCTAssertEqual(error as? C.Failure,.unavailable,kind)}
            XCTAssertEqual(gets,0,kind);XCTAssertEqual(proofs,0,kind);XCTAssertNil(reader.activeRequestID)
        }
    }
    func testWrongPreProofAndWrongPostProofRefuseWithoutRetry() async throws {
        let valid=try binding(baseBinding()),raw=try response()
        for failAt in [1,2] {
            var proofs=0,gets=0
            do {_ = try await reader(valid).read(proof:{b in proofs+=1;return proofs==failAt ? nil:self.proof(b)}){_ in gets+=1;return .init(status:200,contentType:"application/json",body:raw)};XCTFail("Wrong proof admitted")}
            catch {XCTAssertEqual(error as? C.Failure,.unavailable)}
            XCTAssertEqual(proofs,failAt);XCTAssertEqual(gets,failAt==1 ? 0:1)
        }
    }
    func testHeldPreProofCancellationAndCloseIssueZeroGETs() async throws {
        let valid=try binding(baseBinding()),raw=try response()
        for mode in ["cancel","close","task"] {
            let held=Held<C.HumanProof?>();let reader=reader(valid);var gets=0
            let task=Task { @MainActor in try await reader.read(proof:held.call){_ in gets+=1;return .init(status:200,contentType:"application/json",body:raw)} }
            await held.started()
            if mode=="close"{reader.close()}else if mode=="task"{task.cancel()}else{reader.cancelCurrent()}
            held.finish(.success(proof(valid)))
            do {_ = try await task.value;XCTFail(mode)}catch{if mode=="close"{XCTAssertEqual(error as? C.Failure,.stale)}else{XCTAssertTrue(error is CancellationError)}}
            XCTAssertEqual(gets,0);XCTAssertEqual(held.calls,1);XCTAssertNil(reader.activeRequestID)
        }
    }
    func testHeldGETCancellationCloseAndTaskCancellationRejectLateBody() async throws {
        let valid=try binding(baseBinding()),raw=try response()
        for mode in ["cancel","close","task"] {
            let held=Held<C.Response>();let reader=reader(valid);var proofs=0
            let task=Task { @MainActor in try await reader.read(proof:{b in proofs+=1;return self.proof(b)},using:held.event) }
            await held.started()
            if mode=="close"{reader.close()}else if mode=="task"{task.cancel()}else{reader.cancelCurrent()}
            held.finish(.success(.init(status:200,contentType:"application/json",body:raw)))
            do {_ = try await task.value;XCTFail(mode)}catch{if mode=="close"{XCTAssertEqual(error as? C.Failure,.stale)}else{XCTAssertTrue(error is CancellationError)}}
            XCTAssertEqual(proofs,1);XCTAssertEqual(held.calls,1);XCTAssertNil(reader.activeRequestID)
        }
    }
    func testHeldPostProofCancellationRejectsAlreadyReceivedPage() async throws {
        let valid=try binding(baseBinding()),raw=try response(),held=Held<C.HumanProof?>(),reader=reader(try binding(baseBinding()))
        var proofs=0,gets=0
        let task=Task { @MainActor in try await reader.read(proof:{b in proofs+=1;if proofs==2{return try await held.call(b)};return self.proof(b)}){_ in gets+=1;return .init(status:200,contentType:"application/json",body:raw)} }
        await held.started();reader.cancelCurrent();held.finish(.success(proof(valid)))
        do {_ = try await task.value;XCTFail("Late proof accepted") }catch{XCTAssertTrue(error is CancellationError)}
        XCTAssertEqual(proofs,2);XCTAssertEqual(gets,1);XCTAssertNil(reader.activeRequestID)
    }
    func testSameIDReplacementUsesActualLeaseAndOldCompletionCannotClearLatest() async throws {
        let valid=try binding(baseBinding()),raw=try response(),old=Held<C.Response>(),latest=Held<C.Response>(),reader=reader(try binding(baseBinding()))
        let first=Task { @MainActor in try await reader.read(proof:{self.proof($0)},using:old.event) }
        await old.started()
        let second=Task { @MainActor in try await reader.read(proof:{self.proof($0)},using:latest.event) }
        await latest.started();XCTAssertEqual(reader.activeRequestID,valid.readRequestId)
        old.finish(.success(.init(status:200,contentType:"application/json",body:raw)))
        do {_ = try await first.value;XCTFail("Old same-ID lease accepted") }catch{XCTAssertEqual(error as? C.Failure,.stale)}
        XCTAssertEqual(reader.activeRequestID,valid.readRequestId)
        latest.finish(.success(.init(status:200,contentType:"application/json",body:raw)))
        let page=try await second.value;XCTAssertEqual(page.data,raw);XCTAssertNil(reader.activeRequestID)
    }
    func testChangedBindingOwnerAndOriginDuringHeldGETAreRechecked() async throws {
        let original=try baseBinding(),valid=try binding(original),raw=try response()
        let replacements:[String:Any] = ["origin":"https://other.example","userId":"other","companyId":"ffffffff-ffff-4fff-8fff-ffffffffffff","agentId":"ffffffff-ffff-4fff-8fff-ffffffffffff","runId":"ffffffff-ffff-4fff-8fff-ffffffffffff","clientBindingId":"ffffffff-ffff-4fff-8fff-ffffffffffff","readRequestId":"ffffffff-ffff-4fff-8fff-ffffffffffff","clientGeneration":2,"afterSeq":1]
        for key in replacements.keys.sorted()+["owner","originQualified","producer","missing"] {
            var current:C.Binding?=valid,alive=true,origin=true,producer=true;let held=Held<C.Response>()
            let reader=C.Reader(context:{.init(binding:current,ownerAlive:alive,originQualified:origin,producerAvailable:producer)},clock:{100})
            let task=Task { @MainActor in try await reader.read(proof:{self.proof($0)},using:held.event) }
            await held.started()
            switch key {
            case "owner":alive=false
            case "originQualified":origin=false
            case "producer":producer=false
            case "missing":current=nil
            default:var changed=original;changed[key]=replacements[key];current=try binding(changed)
            }
            held.finish(.success(.init(status:200,contentType:"application/json",body:raw)))
            do {_ = try await task.value;XCTFail(key)}catch{XCTAssertEqual(error as? C.Failure,["originQualified","producer"].contains(key) ? .unavailable:.stale,key)}
            XCTAssertEqual(held.calls,1);XCTAssertNil(reader.activeRequestID)
        }
    }
    func testReentrantContextCloseAndCancelAreCheckedAtEveryContextBoundary() async throws {
        let valid=try binding(baseBinding()),raw=try response()
        for cancel in [false,true] {for target in 1...7 {
            var reader:C.Reader!,contexts=0,gets=0
            reader=C.Reader(context:{contexts+=1;if contexts==target {if cancel{reader.cancelCurrent()}else{reader.close()}};return self.current(valid)},clock:{100})
            do {_ = try await reader.read(proof:{self.proof($0)}){_ in gets+=1;return .init(status:200,contentType:"application/json",body:raw)};XCTFail("Context retirement accepted")}
            catch{if cancel{XCTAssertTrue(error is CancellationError)}else{XCTAssertEqual(error as? C.Failure,.stale)}}
            XCTAssertGreaterThanOrEqual(contexts,target);XCTAssertEqual(gets,target<=3 ? 0:1);XCTAssertNil(reader.activeRequestID);reader=nil
        }}
    }
    func testReentrantClockCloseAndCancelAreCheckedAtEveryClockBoundary() async throws {
        let valid=try binding(baseBinding()),raw=try response()
        for cancel in [false,true] {for target in 1...8 {
            var reader:C.Reader!,clocks=0,gets=0
            reader=C.Reader(context:{self.current(valid)},clock:{clocks+=1;if clocks==target{if cancel{reader.cancelCurrent()}else{reader.close()}};return 100})
            do {_ = try await reader.read(proof:{self.proof($0)}){_ in gets+=1;return .init(status:200,contentType:"application/json",body:raw)};XCTFail("Clock retirement accepted")}
            catch{if cancel{XCTAssertTrue(error is CancellationError)}else{XCTAssertEqual(error as? C.Failure,.stale)}}
            XCTAssertGreaterThanOrEqual(clocks,target);XCTAssertEqual(gets,target<=3 ? 0:1);XCTAssertNil(reader.activeRequestID);reader=nil
        }}
    }
    func testContextCallbackElapsedTimePreventsTheNextProofOrGET() async throws {
        let valid=try binding(baseBinding()),raw=try response()
        // Initial capture, first preflight and the post-pre-proof checkpoint
        // must each charge context work before admitting the next operation.
        for target in 1...4 {
            var now=100.0,contexts=0,proofs=0,gets=0
            let reader=C.Reader(context:{
                contexts+=1
                if contexts==target {now=12_101}
                return self.current(valid)
            },clock:{now})
            do {
                _ = try await reader.read(proof:{binding in proofs+=1;return self.proof(binding)}){_ in
                    gets+=1;return .init(status:200,contentType:"application/json",body:raw)
                }
                XCTFail("Context work exceeded the shared deadline but the read accepted")
            } catch {XCTAssertEqual(error as? C.Failure,.expired,"Context boundary \(target)")}
            XCTAssertEqual(proofs,target<=2 ? 0:1,"No proof may start after context consumed the budget")
            XCTAssertEqual(gets,target<=3 ? 0:1,"In particular the pre-proof/GET boundary must admit zero GETs")
            XCTAssertNil(reader.activeRequestID)
        }
    }
    func testOneDeadlineIncludesHeldProofAndHeldGETAndFinalContext() async throws {
        let valid=try binding(baseBinding()),raw=try response()
        for stage in ["pre","GET","post"] {
            var now=100.0,proofs=0,gets=0
            let heldProof=Held<C.HumanProof?>(),heldGET=Held<C.Response>()
            let reader=C.Reader(context:{self.current(valid)},clock:{now})
            let task=Task { @MainActor in try await reader.read(proof:{b in proofs+=1;if (stage=="pre" && proofs==1)||(stage=="post" && proofs==2){return try await heldProof.call(b)};return self.proof(b)}){req in gets+=1;if stage=="GET"{return try await heldGET.event(req)};return .init(status:200,contentType:"application/json",body:raw)} }
            if stage=="GET"{await heldGET.started()}else{await heldProof.started()}
            now=12_100
            if stage=="GET"{heldGET.finish(.success(.init(status:200,contentType:"application/json",body:raw)))}else{heldProof.finish(.success(proof(valid)))}
            do {_ = try await task.value;XCTFail(stage)}catch{XCTAssertEqual(error as? C.Failure,.expired,stage)}
            XCTAssertEqual(gets,stage=="pre" ? 0:1)
        }
        var now=100.0,contexts=0
        let final=C.Reader(context:{contexts+=1;if contexts==7{now=12_100};return self.current(valid)},clock:{now})
        do {_ = try await final.read(proof:{self.proof($0)}){_ in .init(status:200,contentType:"application/json",body:raw)};XCTFail("Final context time was excluded")}
        catch{XCTAssertEqual(error as? C.Failure,.expired)}
        XCTAssertEqual(contexts,7)
    }
    func testTransportAndProofErrorsArePreservedWithoutRetry() async throws {
        let valid=try binding(baseBinding())
        for source in ["proof","GET"] {
            var proofs=0,gets=0
            do {_ = try await reader(valid).read(proof:{b in proofs+=1;if source=="proof"{throw AuthoredFailure.transport};return self.proof(b)}){_ in gets+=1;throw AuthoredFailure.transport};XCTFail(source)}
            catch{XCTAssertEqual(error as? AuthoredFailure,.transport)}
            XCTAssertEqual(proofs,1);XCTAssertEqual(gets,source=="proof" ? 0:1)
        }
    }
    func testClosedReaderNeverStartsAnotherProofOrGETAndErrorsStaySafe() async throws {
        let valid=try binding(baseBinding()),reader=reader(try binding(baseBinding()));reader.close();var calls=0
        do {_ = try await reader.read(proof:{b in calls+=1;return self.proof(b)}){_ in calls+=1;throw AuthoredFailure.transport};XCTFail("Closed reader revived")}
        catch{XCTAssertEqual(error as? C.Failure,.stale)}
        XCTAssertEqual(calls,0)
        for failure in [C.Failure.unavailable,.invalidBinding,.unsupportedResponse,.stale,.expired,.httpStatus(403)] {
            let text=failure.localizedDescription;XCTAssertFalse(text.contains(valid.userId));XCTAssertFalse(text.contains(valid.origin))
        }
    }

    private func base() throws -> [String:Any] {try XCTUnwrap(packet.lifecycle.first)}
    private func baseBinding() throws -> [String:Any] {try object(base(),"before")}
    private func firstRow() throws -> [String:Any] {try XCTUnwrap(array(base(),"page").first)}
    private func response() throws -> Data {try json(field(base(),"page"))}
    private func binding(_ value:[String:Any]) throws -> C.Binding {try .init(data:json(value))}
    private func current(_ b:C.Binding)->C.CurrentContext {.init(binding:b,ownerAlive:true,originQualified:true,producerAvailable:true)}
    private func reader(_ b:C.Binding)->C.Reader {C.Reader(context:{self.current(b)},clock:{100})}
    private func proof(_ b:C.Binding)->C.HumanProof {.init(origin:b.origin,userId:b.userId,companyId:b.companyId,normalHumanSession:true,source:"independent-normal-proof")}
    private func proof(_ value:Any?)->C.HumanProof? {
        guard let p=value as? [String:Any],let origin=p["origin"] as? String,let user=p["userId"] as? String,
              let company=p["companyId"] as? String,let normal=p["normalHumanSession"] as? Bool,let source=p["source"] as? String else{return nil}
        return .init(origin:origin,userId:user,companyId:company,normalHumanSession:normal,source:source)
    }
    private func validContext(expected:C.Binding,current:C.Binding)->C.Acceptance {
        .init(expected:expected,current:current,producerAvailable:true,originQualified:true,ownerAlive:true,aborted:false,activeReadRequestId:expected.readRequestId,preProof:proof(expected),postProof:proof(expected),eventGetCount:1,normalProofReadCount:2,startMonotonicMs:100,finishMonotonicMs:200)
    }
    private func acceptance(_ item:[String:Any]) throws -> C.Acceptance {
        .init(expected:try binding(object(item,"before")),current:try binding(object(item,"after")),producerAvailable:try flag(item,"producerAvailable"),originQualified:try flag(item,"originQualified"),ownerAlive:try flag(item,"ownerAlive"),aborted:try flag(item,"aborted"),activeReadRequestId:try text(item,"activeReadRequestId"),preProof:proof(item["preProof"]),postProof:proof(item["postProof"]),eventGetCount:try integer(item,"eventGetCount"),normalProofReadCount:try integer(item,"normalProofReadCount"),startMonotonicMs:try numeric(item,"startMonotonicMs"),finishMonotonicMs:(item["finishMonotonicMs"] as? NSNumber)?.doubleValue ?? .nan)
    }
    private func field(_ item:[String:Any],_ key:String)throws->Any {try XCTUnwrap(item[key],key)}
    private func text(_ item:[String:Any],_ key:String)throws->String {try XCTUnwrap(item[key] as? String,key)}
    private func flag(_ item:[String:Any],_ key:String)throws->Bool {try XCTUnwrap(item[key] as? Bool,key)}
    private func integer(_ item:[String:Any],_ key:String)throws->Int {try XCTUnwrap(item[key] as? Int,key)}
    private func numeric(_ item:[String:Any],_ key:String)throws->Double {try XCTUnwrap(item[key] as? NSNumber,key).doubleValue}
    private func object(_ item:[String:Any],_ key:String)throws->[String:Any] {try XCTUnwrap(item[key] as? [String:Any],key)}
    private func array(_ item:[String:Any],_ key:String)throws->[[String:Any]] {try XCTUnwrap(item[key] as? [[String:Any]],key)}
    private func json(_ value:Any)throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed,.withoutEscapingSlashes])}
    private func rawBytes(_ item:[String:Any])throws->Data {
        if try text(item,"recipe")=="hex" {
            let hex=try text(item,"hex");guard hex.count%2==0 else{throw AuthoredFailure.fixture}
            var data=Data();var index=hex.startIndex
            while index<hex.endIndex {let end=hex.index(index,offsetBy:2);guard let byte=UInt8(hex[index..<end],radix:16)else{throw AuthoredFailure.fixture};data.append(byte);index=end};return data
        }
        // The two frozen whitespace recipes use the generator's known JS order.
        // Their recorded SHA checks this reconstruction independently.
        let row=try XCTUnwrap(array(item,"page").first)
        let keys=["id","companyId","agentId","runId","seq","eventType","stream","level","color","message","payload","createdAt"]
        func encoded(_ value:Any)throws->String {String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.withoutEscapingSlashes]),as:UTF8.self)}
        let payload=try object(row,"payload")
        let payloadText=try "{"+["false","zero","empty","nil"].map{try encoded($0)+":"+encoded(field(payload,$0))}.joined(separator:",")+"}"
        let body=try "[{"+keys.map{key in try encoded(key)+":"+(key=="payload" ? payloadText:encoded(field(row,key)))}.joined(separator:",")+"}]"
        var data=Data(body.utf8);let target=try integer(item,"targetBytes");guard target>=data.count else{throw AuthoredFailure.fixture}
        data.append(contentsOf:repeatElement(UInt8(32),count:target-data.count));return data
    }
    private func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private enum AuthoredFailure:Error,Equatable {case fixture,transport}
    private struct Packet {
        let dto,lifecycle,raw:[[String:Any]]
        static func load()throws->Self {
            guard let path=ProcessInfo.processInfo.environment["NERO_RUN_EVENT_PACKET_DIR"],path.hasPrefix("/") else{throw XCTSkip("NERO_RUN_EVENT_PACKET_DIR must explicitly select the frozen event packet; no account/repository discovery.")}
            let root=URL(fileURLWithPath:path,isDirectory:true),data=try Data(contentsOf:root.appendingPathComponent("MANIFEST.json"))
            guard digest(data)==C.packetManifestSHA256,let manifest=try JSONSerialization.jsonObject(with:data) as? [String:Any],let files=manifest["files"] as? [[String:Any]],files.count==8 else{throw AuthoredFailure.fixture}
            for row in files {
                guard let name=row["file"] as? String,!name.contains("/"),!name.contains(".."),let expected=row["sha256"] as? String,let count=row["bytes"] as? Int else{throw AuthoredFailure.fixture}
                let bytes=try Data(contentsOf:root.appendingPathComponent(name));guard digest(bytes)==expected,bytes.count==count else{throw AuthoredFailure.fixture}
            }
            let f=try Data(contentsOf:root.appendingPathComponent("fixtures.json"))
            guard let value=try JSONSerialization.jsonObject(with:f) as? [String:Any],let dto=value["dto"] as? [[String:Any]],let lifecycle=value["lifecycle"] as? [[String:Any]],let raw=value["raw"] as? [[String:Any]] else{throw AuthoredFailure.fixture}
            return .init(dto:dto,lifecycle:lifecycle,raw:raw)
        }
        private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    }
    @MainActor private final class Held<T> {
        private var continuation:CheckedContinuation<T,Error>?
        private let began=XCTestExpectation(description:"Actual injected callback reached controlled suspension")
        private(set) var calls=0
        func call(_ binding:C.Binding)async throws->T {try await suspend()}
        func event(_ request:C.Request)async throws->T {try await suspend()}
        private func suspend()async throws->T {
            calls+=1;return try await withCheckedThrowingContinuation{self.continuation=$0;began.fulfill()}
        }
        func started()async {let result=await XCTWaiter.fulfillment(of:[began],timeout:3);XCTAssertEqual(result,.completed)}
        func finish(_ result:Result<T,Error>){guard let continuation else{XCTFail("No held callback");return};self.continuation=nil;continuation.resume(with:result)}
    }
}
