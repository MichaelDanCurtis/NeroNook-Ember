import Foundation
import CryptoKit
import XCTest
@testable import ModuleCore

/// Authored-data conformance only. The packet directory must be supplied by the
/// local qualification runner; this test never discovers a real account/profile.
@MainActor final class EmberConversationReadContractTests: XCTestCase {
    private typealias Contract = EmberConversationReadContract
    private var packet: Packet!

    override func setUpWithError() throws { packet = try Packet.load() }

    func testAllFrozenDTOCasesPreserveTheSelectedProjection() throws {
        XCTAssertEqual(packet.dto.count, 29)
        for item in packet.dto {
            let name = try text(item, "name"), expected = try boolean(item, "valid")
            let bytes = try json(try field(item, "value"))
            do {
                let snapshot = try Contract.decodeSnapshot(bytes)
                XCTAssertTrue(expected, name)
                XCTAssertEqual(snapshot.data, bytes, "The read must preserve original bytes: " + name)
            } catch {
                XCTAssertFalse(expected, name)
                XCTAssertEqual(error as? Contract.Failure, .unsupportedResponse, name)
            }
        }
    }

    func testAllFrozenLifecycleCasesUseActualPaddedBodyBytes() throws {
        XCTAssertEqual(packet.lifecycle.count, 25)
        for item in packet.lifecycle {
            let name = try text(item, "name"), expected = try boolean(item, "accepted")
            let bytes = try paddedBody(item)
            do {
                let before = try binding(try object(item, "before"))
                let after = try binding(try object(item, "after"))
                let context = Contract.Acceptance(expected: before, current: after,
                    ownerAlive: try boolean(item, "ownerAlive"), aborted: try boolean(item, "aborted"),
                    requestID: try text(item, "requestId"), activeRequestID: try text(item, "activeReadRequestId"),
                    startMonotonicMs: try number(item, "startMonotonicMs"), finishMonotonicMs: try number(item, "finishMonotonicMs"))
                let result = try Contract.accept(body: bytes, status: try integer(item, "status"),
                    contentType: try text(item, "contentType"), context: context)
                XCTAssertTrue(expected, name)
                XCTAssertEqual(result.data, bytes, name)
            } catch { XCTAssertFalse(expected, name) }
        }
    }

    func testBindingRejectsMissingNullBooleanAndUnsafeGenerationWithoutInventingUUIDUsers() throws {
        var value = try baseBinding()
        value["userId"] = "人:external/opaque-user"
        XCTAssertNoThrow(try binding(value))
        for bad in [NSNull(), true, 0, -1, 1.5, 9_007_199_254_740_992.0, "1"] as [Any] {
            var changed = value; changed["clientGeneration"] = bad
            XCTAssertThrowsError(try binding(changed)) {
                XCTAssertEqual($0 as? Contract.Failure, .invalidBinding)
            }
        }
        for key in value.keys {
            var changed = value; changed.removeValue(forKey: key)
            XCTAssertThrowsError(try binding(changed), key)
        }
        value["userId"] = ""
        XCTAssertThrowsError(try binding(value))
        value = try baseBinding(); value["extra"] = "not allowed"
        XCTAssertThrowsError(try binding(value))
    }

    func testBindingURIShapeMatchesTheFrozenAjvFormatWithoutBecomingOriginAdmission() throws {
        let original = try baseBinding()
        for uri in ["x:", "x:?q", "x:#f", "https://[:::]", "https://h/path[bad]", "https://h/%GG", "https://h/#one#two", "https://[::ffff:192.168.256.1]", "https://[192.0.2.1::]"] {
            var value = original; value["origin"] = uri
            XCTAssertThrowsError(try binding(value), uri) {
                XCTAssertEqual($0 as? Contract.Failure, .invalidBinding, uri)
            }
        }
        // Schema-valid URI shape is not the trusted caller's origin policy.
        // These values are never passed to a URLSession or a real producer.
        for uri in ["x:/", "urn:example:abc", "https://[::1]", "https://[v1.a]", "x://", "x:///", "https://[::ffff:192.168.001.1]", "https://[::ffff:192.168.01.1]", "https://[::ffff:192.168.000.1]"] {
            var value = original; value["origin"] = uri
            XCTAssertNoThrow(try binding(value), uri)
        }
    }

    func testUUIDSchemaPatternsRejectEveryTerminalLineSeparator() throws {
        let terminators = ["\n", "\r", "\r\n", "\u{2028}", "\u{0085}"]
        let original = try baseBinding(), fallback = try text(original, "companyId")
        for ending in terminators {
            for key in ["companyId", "agentId", "clientBindingId"] {
                var changed = original; changed[key] = try text(original, key) + ending
                XCTAssertThrowsError(try binding(changed), "Binding UUID field: " + key) {
                    XCTAssertEqual($0 as? Contract.Failure, .invalidBinding)
                }
            }
            let groups = [("conversation", ["id", "companyId", "agentId"]),
                          ("messages", ["id", "clientRequestId", "runId"]),
                          ("turns", ["id", "clientRequestId", "runId", "replyMessageId"])]
            for (group, keys) in groups {
                for key in keys {
                    var value = try activeResponse()
                    if group == "conversation" {
                        var record = try object(value, group)
                        record[key] = (record[key] as? String ?? fallback) + ending
                        value[group] = record
                    } else {
                        var rows = try array(value, group)
                        let validUUID = rows[0][key] as? String ?? fallback
                        rows[0][key] = validUUID; value[group] = rows
                        XCTAssertNoThrow(try Contract.decodeSnapshot(json(value)), "Baseline nullable UUID shape: " + group + "." + key)
                        rows[0][key] = validUUID + ending; value[group] = rows
                    }
                    XCTAssertThrowsError(try Contract.decodeSnapshot(json(value)), "UUID field: " + group + "." + key) {
                        XCTAssertEqual($0 as? Contract.Failure, .unsupportedResponse)
                    }
                }
            }
        }
    }

    func testOpaqueUserBindingAndResponseUseExactUnicodeBytes() throws {
        let nfc = "human:caf\u{00E9}", nfd = "human:cafe\u{0301}"
        XCTAssertEqual(nfc, nfd, "Swift equality is not the contract's exact account equality")
        XCTAssertFalse(nfc.utf8.elementsEqual(nfd.utf8))
        var original = try baseBinding(); original["userId"] = nfc
        var changed = original; changed["userId"] = nfd
        let expected = try binding(original), current = try binding(changed)
        let matching = try response(user: nfc)
        XCTAssertNoThrow(try Contract.accept(body: matching, status: 200, contentType: "application/json",
            context: context(expected: expected, current: expected)))
        XCTAssertThrowsError(try Contract.accept(body: matching, status: 200, contentType: "application/json",
            context: context(expected: expected, current: current))) {
            XCTAssertEqual($0 as? Contract.Failure, .stale)
        }
        XCTAssertThrowsError(try Contract.accept(body: response(user: nfd), status: 200, contentType: "application/json",
            context: context(expected: expected, current: expected))) {
            XCTAssertEqual($0 as? Contract.Failure, .stale)
        }
    }

    func testUppercaseUUIDIsStructurallyValidButDoesNotNormalizeIntoActorScope() throws {
        let original = try baseBinding(), expected = try binding(original)
        var upper = original; upper["companyId"] = try text(original, "companyId").uppercased()
        XCTAssertNoThrow(try binding(upper))
        let bytes = try response(company: try text(upper, "companyId"))
        XCTAssertNoThrow(try Contract.decodeSnapshot(bytes))
        XCTAssertThrowsError(try Contract.accept(body: bytes, status: 200, contentType: "application/json",
            context: context(expected: expected, current: expected))) {
            XCTAssertEqual($0 as? Contract.Failure, .stale)
        }
        XCTAssertThrowsError(try Contract.accept(body: response(), status: 200, contentType: "application/json",
            context: context(expected: expected, current: binding(upper)))) {
            XCTAssertEqual($0 as? Contract.Failure, .stale)
        }
    }

    func testSnapshotRejectsMalformedUTF8UnknownMembersAndMissingNullableFields() throws {
        for bytes in [Data([0xff, 0xfe]), Data("{\"bad\":".utf8), Data("null".utf8), Data("[]".utf8)] {
            XCTAssertThrowsError(try Contract.decodeSnapshot(bytes)) {
                XCTAssertEqual($0 as? Contract.Failure, .unsupportedResponse)
            }
        }
        var value = try activeResponse(); value["extra"] = "sensitive payload must not escape"
        XCTAssertThrowsError(try Contract.decodeSnapshot(json(value)))
        var turns = try array(value, "turns"); value.removeValue(forKey: "extra")
        turns[0].removeValue(forKey: "replyMessageId"); value["turns"] = turns
        XCTAssertThrowsError(try Contract.decodeSnapshot(json(value)))
        turns = try array(try activeResponse(), "turns"); turns[0]["runId"] = true; value["turns"] = turns
        XCTAssertThrowsError(try Contract.decodeSnapshot(json(value)))
    }

    func testNumericAndTimestampRulesMatchTheFrozenSchemaRatherThanAPlatformDateFormatter() throws {
        let allowedDates = ["2026-10-30T12:00Z", "2026-10-30T12:00:00.000Z", "2024-02-29T23:59:59+23:59"]
        for date in allowedDates {
            var value = try activeResponse(), messages = try array(value, "messages")
            messages[0]["createdAt"] = date; value["messages"] = messages
            XCTAssertNoThrow(try Contract.decodeSnapshot(json(value)), date)
        }
        for date in ["2026-02-29T12:00Z", "2026-10-30T24:00Z", "2026-10-30T12:60Z", "2026-10-30T12:00:00", "٢٠٢٦-10-30T12:00Z"] {
            var value = try activeResponse(), messages = try array(value, "messages")
            messages[0]["createdAt"] = date; value["messages"] = messages
            XCTAssertThrowsError(try Contract.decodeSnapshot(json(value)), date)
        }
        var value = try activeResponse(), limits = try object(value, "limits")
        limits["maxTextBytes"] = 1.0; value["limits"] = limits
        XCTAssertNoThrow(try Contract.decodeSnapshot(json(value)))
        limits["maxTextBytes"] = 9_007_199_254_740_991.0; value["limits"] = limits
        XCTAssertNoThrow(try Contract.decodeSnapshot(json(value)))
        for bad in [true, 0, -1, 1.5, 9_007_199_254_740_992.0] as [Any] {
            limits["maxTextBytes"] = bad; value["limits"] = limits
            XCTAssertThrowsError(try Contract.decodeSnapshot(json(value)))
        }
        let raw = try XCTUnwrap(String(data: json(try activeResponse()), encoding: .utf8))
        XCTAssertTrue(raw.contains("\"maxTextBytes\":4096"))
        for token in ["1.0", "1e0", "9007199254740991.0"] {
            let numeric = raw.replacingOccurrences(of: "\"maxTextBytes\":4096", with: "\"maxTextBytes\":" + token)
            XCTAssertNoThrow(try Contract.decodeSnapshot(Data(numeric.utf8)), token)
        }
    }

    func testStructuralDecoderDoesNotInventUserStateArrayOrUniquenessRestrictions() throws {
        var value = try activeResponse(), conversation = try object(value, "conversation")
        conversation["userId"] = ""; conversation["state"] = ""; value["conversation"] = conversation
        let message = try XCTUnwrap(array(value, "messages").first), turn = try XCTUnwrap(array(value, "turns").first)
        // These are structurally valid projection values, not valid original-work
        // evidence. Later HandoffJob joins remain a separate unchanged guard.
        value["messages"] = Array(repeating: message, count: 201)
        value["turns"] = Array(repeating: turn, count: 101)
        let bytes = try json(value)
        XCTAssertLessThan(bytes.count, 524_288)
        XCTAssertNoThrow(try Contract.decodeSnapshot(bytes))
        let expected = try binding(baseBinding())
        XCTAssertThrowsError(try Contract.accept(body: bytes, status: 200, contentType: "application/json",
            context: context(expected: expected, current: expected))) {
            XCTAssertEqual($0 as? Contract.Failure, .stale)
        }
    }

    func testLocalRequestIdentityMustExistAndMatchExactBytes() throws {
        let expected = try binding(baseBinding()), raw = try response()
        let cases: [(String, String?)] = [("", ""), ("known-read", nil), ("read:caf\u{00E9}", "read:cafe\u{0301}")]
        for (id, active) in cases {
            let review = Contract.Acceptance(expected: expected, current: expected, ownerAlive: true, aborted: false,
                requestID: id, activeRequestID: active, startMonotonicMs: 100, finishMonotonicMs: 200)
            XCTAssertThrowsError(try Contract.accept(body: raw, status: 200, contentType: "application/json", context: review)) {
                XCTAssertEqual($0 as? Contract.Failure, .stale)
            }
        }
    }

    func testActualByteLimitIsInclusiveAndNeverTruncates() throws {
        let expected = try binding(baseBinding()), raw = try response()
        let exact = try pad(raw, to: 524_288)
        XCTAssertNoThrow(try Contract.accept(body: exact, status: 200, contentType: "application/json",
            context: context(expected: expected, current: expected)))
        var oversized = exact; oversized.append(32)
        XCTAssertThrowsError(try Contract.decodeSnapshot(oversized)) {
            XCTAssertEqual($0 as? Contract.Failure, .unsupportedResponse)
        }
        XCTAssertThrowsError(try Contract.accept(body: oversized, status: 200, contentType: "application/json",
            context: context(expected: expected, current: expected)))
    }

    func testDeadlineMIMEHTTPAndMissingProducerRemainDistinct() throws {
        let expected = try binding(baseBinding()), raw = try response()
        XCTAssertNoThrow(try Contract.accept(body: raw, status: 200, contentType: " Application/JSON ; charset=utf-8 ",
            context: context(expected: expected, current: expected)))
        for mime in ["text/html", "application/jsonp", "", "text/json"] {
            XCTAssertThrowsError(try Contract.accept(body: raw, status: 200, contentType: mime,
                context: context(expected: expected, current: expected))) {
                XCTAssertEqual($0 as? Contract.Failure, .unsupportedResponse)
            }
        }
        for status in [201, 302, 401, 403, 503] {
            XCTAssertThrowsError(try Contract.accept(body: raw, status: status, contentType: "application/json",
                context: context(expected: expected, current: expected))) {
                XCTAssertEqual($0 as? Contract.Failure, .httpStatus(status))
            }
        }
        for (start, finish) in [(100.0, 12_100.0), (100, 12_101), (100, 99), (Double.nan, 200), (100, Double.infinity)] {
            XCTAssertThrowsError(try Contract.accept(body: raw, status: 200, contentType: "application/json",
                context: context(expected: expected, current: expected, start: start, finish: finish))) {
                XCTAssertEqual($0 as? Contract.Failure, .expired)
            }
        }
        XCTAssertNoThrow(try Contract.accept(body: raw, status: 200, contentType: "application/json",
            context: context(expected: expected, current: expected, start: 100, finish: 12_099.999)))
        XCTAssertThrowsError(try Contract.accept(body: raw, status: 200, contentType: "application/json",
            context: context(expected: nil, current: nil))) {
            XCTAssertEqual($0 as? Contract.Failure, .unavailable)
        }
    }

    func testMalformedResponseErrorsDoNotReflectAnyInput() throws {
        let sentinel = "private-input-DO-NOT-REFLECT-cafe-\u{1F33F}"
        var value = try activeResponse(); value[sentinel] = sentinel
        do { _ = try Contract.decodeSnapshot(json(value)); XCTFail("Malformed response accepted") }
        catch {
            XCTAssertEqual(error as? Contract.Failure, .unsupportedResponse)
            XCTAssertFalse(error.localizedDescription.contains(sentinel))
            XCTAssertFalse(String(reflecting: error).contains(sentinel))
        }
    }

    func testReaderWithoutEligibleProducerIssuesNoRequest() async throws {
        let valid = try binding(baseBinding()), raw = try response()
        let cases: [(Contract.Binding?, Bool, Bool)] = [(nil, true, true), (valid, false, true), (valid, true, false)]
        for item in cases {
            var calls = 0
            let reader = Contract.Reader(context: { .init(binding: item.0, ownerAlive: item.1, originAllowed: item.2) }, clock: { 100 })
            do {
                _ = try await reader.read { _ in calls += 1; return .init(status: 200, contentType: "application/json", body: raw) }
                XCTFail("Missing or ineligible producer was admitted")
            } catch {}
            XCTAssertEqual(calls, 0)
            XCTAssertNil(reader.activeRequestID)
        }
    }

    func testReentrantContextCloseOrCancelPreventsEvenTheFirstTransportCall() async throws {
        let valid = try binding(baseBinding()), raw = try response()
        for cancel in [false, true] {
            var reader: Contract.Reader!
            var contextCalls = 0, transportCalls = 0
            reader = Contract.Reader(context: {
                contextCalls += 1
                if cancel { reader.cancelCurrent() } else { reader.close() }
                return .init(binding: valid, ownerAlive: true, originAllowed: true)
            }, clock: { 100 })
            do {
                _ = try await reader.read { _ in
                    transportCalls += 1
                    return .init(status: 200, contentType: "application/json", body: raw)
                }
                XCTFail("A context callback retired the owner but its request was still accepted")
            } catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? Contract.Failure, .stale) }
            }
            XCTAssertGreaterThanOrEqual(contextCalls, 1)
            XCTAssertEqual(transportCalls, 0, "Reentrant owner retirement must precede transport admission")
            XCTAssertNil(reader.activeRequestID)
            reader = nil // Break the deliberately reentrant test closure's capture.
        }
    }

    func testReentrantClockCloseOrCancelPreventsEvenTheFirstTransportCall() async throws {
        let valid = try binding(baseBinding()), raw = try response()
        for cancel in [false, true] {
            var reader: Contract.Reader!
            var clockCalls = 0, transportCalls = 0
            reader = Contract.Reader(context: {
                .init(binding: valid, ownerAlive: true, originAllowed: true)
            }, clock: {
                clockCalls += 1
                if cancel { reader.cancelCurrent() } else { reader.close() }
                return 100
            })
            do {
                _ = try await reader.read { _ in
                    transportCalls += 1
                    return .init(status: 200, contentType: "application/json", body: raw)
                }
                XCTFail("A clock callback retired the owner but its request was still accepted")
            } catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? Contract.Failure, .stale) }
            }
            XCTAssertGreaterThanOrEqual(clockCalls, 1)
            XCTAssertEqual(transportCalls, 0, "Reentrant owner retirement must precede transport admission")
            XCTAssertNil(reader.activeRequestID)
            reader = nil // Break the deliberately reentrant test closure's capture.
        }
    }

    func testReaderIssuesOneBoundGETAndClearsItsLeaseOnSuccess() async throws {
        let values = try baseBinding(), valid = try binding(values), raw = try response()
        var calls = 0, now = 100.0
        let id = "a5000000-0000-4000-8000-000000000001"
        let reader = Contract.Reader(context: { .init(binding: valid, ownerAlive: true, originAllowed: true) }, clock: { now })
        let result = try await reader.read(requestID: id) { request in
            calls += 1
            XCTAssertEqual(request.id, id); XCTAssertEqual(reader.activeRequestID, id)
            XCTAssertEqual(request.method, "GET"); XCTAssertNil(request.body); XCTAssertNil(request.query)
            XCTAssertEqual(request.path, "/api/companies/" + (try self.text(values, "companyId")) + "/ember/" + (try self.text(values, "agentId")))
            now = 200
            return .init(status: 200, contentType: "application/json", body: raw)
        }
        XCTAssertEqual(result.data, raw); XCTAssertEqual(calls, 1); XCTAssertNil(reader.activeRequestID)
    }

    func testTransportErrorIsPreservedWithoutRetry() async throws {
        let valid = try binding(baseBinding())
        var calls = 0
        let reader = Contract.Reader(context: { .init(binding: valid, ownerAlive: true, originAllowed: true) }, clock: { 100 })
        do {
            _ = try await reader.read { _ in calls += 1; throw AuthoredTransportError.failed }
            XCTFail("Transport failure was swallowed")
        } catch { XCTAssertEqual(error as? AuthoredTransportError, .failed) }
        XCTAssertEqual(calls, 1); XCTAssertNil(reader.activeRequestID)
    }

    func testSuspendedReadCancellationAndTaskCancellationCannotAcceptLateData() async throws {
        let valid = try binding(baseBinding()), raw = try response()
        for cancelTask in [false, true] {
            let held = HeldTransport()
            let reader = Contract.Reader(context: { .init(binding: valid, ownerAlive: true, originAllowed: true) }, clock: { 100 })
            let task = Task { @MainActor in try await reader.read(using: held.read) }
            await held.waitUntilStarted()
            if cancelTask { task.cancel() } else { reader.cancelCurrent() }
            held.finish(.success(.init(status: 200, contentType: "application/json", body: raw)))
            do { _ = try await task.value; XCTFail("Cancelled read accepted its late body") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(held.calls, 1); XCTAssertNil(reader.activeRequestID)
        }
    }

    func testClosingReaderRetiresHeldReadAndPreventsAnotherRequest() async throws {
        let valid = try binding(baseBinding()), raw = try response(), held = HeldTransport()
        let reader = Contract.Reader(context: { .init(binding: valid, ownerAlive: true, originAllowed: true) }, clock: { 100 })
        let task = Task { @MainActor in try await reader.read(using: held.read) }
        await held.waitUntilStarted(); reader.close()
        held.finish(.success(.init(status: 200, contentType: "application/json", body: raw)))
        do { _ = try await task.value; XCTFail("Closed owner accepted a late result") }
        catch { XCTAssertEqual(error as? Contract.Failure, .stale) }
        var laterCalls = 0
        do {
            _ = try await reader.read { _ in laterCalls += 1; return .init(status: 200, contentType: "application/json", body: raw) }
            XCTFail("Closed reader was revived")
        } catch {}
        XCTAssertEqual(laterCalls, 0); XCTAssertNil(reader.activeRequestID)
    }

    func testEachCurrentBindingFieldAndOwnerPolicyIsRecheckedAfterAwait() async throws {
        let original = try baseBinding(), raw = try response()
        let changedValues: [String: Any] = ["origin": "https://other.example.test", "userId": "other-human", "companyId": "b1000000-0000-4000-8000-000000000001", "agentId": "b2000000-0000-4000-8000-000000000001", "clientBindingId": "b6000000-0000-4000-8000-000000000001", "clientGeneration": 2]
        for key in Array(changedValues.keys.sorted()) + ["ownerAlive", "originAllowed", "bindingMissing"] {
            var current: Contract.Binding? = try binding(original), alive = true, allowed = true
            let held = HeldTransport()
            let reader = Contract.Reader(context: { .init(binding: current, ownerAlive: alive, originAllowed: allowed) }, clock: { 100 })
            let task = Task { @MainActor in try await reader.read(using: held.read) }
            await held.waitUntilStarted()
            switch key {
            case "ownerAlive": alive = false
            case "originAllowed": allowed = false
            case "bindingMissing": current = nil
            default: var changed = original; changed[key] = changedValues[key]; current = try binding(changed)
            }
            held.finish(.success(.init(status: 200, contentType: "application/json", body: raw)))
            do { _ = try await task.value; XCTFail("Changed context accepted: " + key) }
            catch { XCTAssertEqual(error as? Contract.Failure, key == "originAllowed" ? .unavailable : .stale, key) }
            XCTAssertEqual(held.calls, 1); XCTAssertNil(reader.activeRequestID)
        }
    }

    func testLatestLeaseAndSameRequestIDReplacementRejectOldCompletionWithoutClearingNewRead() async throws {
        let valid = try binding(baseBinding()), raw = try response()
        for sameID in [false, true] {
            let first = HeldTransport(), latest = HeldTransport()
            let firstID = "a5000000-0000-4000-8000-000000000001"
            let latestID = sameID ? firstID : "b5000000-0000-4000-8000-000000000001"
            let reader = Contract.Reader(context: { .init(binding: valid, ownerAlive: true, originAllowed: true) }, clock: { 100 })
            let oldTask = Task { @MainActor in try await reader.read(requestID: firstID, using: first.read) }
            await first.waitUntilStarted()
            let latestTask = Task { @MainActor in try await reader.read(requestID: latestID, using: latest.read) }
            await latest.waitUntilStarted()
            first.finish(.success(.init(status: 200, contentType: "application/json", body: raw)))
            do { _ = try await oldTask.value; XCTFail("Superseded lease accepted") }
            catch { XCTAssertEqual(error as? Contract.Failure, .stale) }
            XCTAssertEqual(reader.activeRequestID, latestID, "Old completion must not clear the new actual lease")
            latest.finish(.success(.init(status: 200, contentType: "application/json", body: raw)))
            let result = try await latestTask.value
            XCTAssertEqual(result.data, raw)
            XCTAssertEqual(first.calls, 1); XCTAssertEqual(latest.calls, 1); XCTAssertNil(reader.activeRequestID)
        }
    }

    func testReaderRechecksMonotonicDeadlineAfterHeldTransport() async throws {
        let valid = try binding(baseBinding()), raw = try response()
        for finish in [12_100.0, 99.0, Double.infinity] {
            var now = 100.0
            let held = HeldTransport()
            let reader = Contract.Reader(context: { .init(binding: valid, ownerAlive: true, originAllowed: true) }, clock: { now })
            let task = Task { @MainActor in try await reader.read(using: held.read) }
            await held.waitUntilStarted(); now = finish
            held.finish(.success(.init(status: 200, contentType: "application/json", body: raw)))
            do { _ = try await task.value; XCTFail("Invalid completion clock accepted") }
            catch { XCTAssertEqual(error as? Contract.Failure, .expired) }
            XCTAssertEqual(held.calls, 1); XCTAssertNil(reader.activeRequestID)
        }
    }

    // MARK: Authored packet data and synthetic transport helpers

    private enum FixtureProblem: Error { case invalidPacket, invalidFixture, paddingTooShort }
    private enum AuthoredTransportError: Error, Equatable { case failed }
    private struct Packet {
        let dto: [[String: Any]]
        let lifecycle: [[String: Any]]
        static func load() throws -> Self {
            guard let path = ProcessInfo.processInfo.environment["NERO_EMBER_READ_C1_PACKET_DIR"], !path.isEmpty else {
                throw XCTSkip("NERO_EMBER_READ_C1_PACKET_DIR is required to qualify the frozen Ember read candidate; no repository or account discovery is attempted.")
            }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let manifestData = try Data(contentsOf: root.appendingPathComponent("MANIFEST.json"))
            guard hash(manifestData) == "b61f91e79bb96189ed4c9d59f062f576e36959d36121b192ec0747020c41a76e",
                  let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  let files = manifest["files"] as? [[String: Any]],
                  let support = manifest["supportingFiles"] as? [[String: Any]],
                  let generator = manifest["generator"] as? [String: Any] else { throw FixtureProblem.invalidPacket }
            for row in files + support + [generator] {
                guard let name = row["file"] as? String, !name.contains("/"), !name.contains(".."),
                      let expected = row["sha256"] as? String else { throw FixtureProblem.invalidPacket }
                let data = try Data(contentsOf: root.appendingPathComponent(name))
                guard hash(data) == expected else { throw FixtureProblem.invalidPacket }
                if let count = row["bytes"] as? Int, data.count != count { throw FixtureProblem.invalidPacket }
            }
            let fixturesData = try Data(contentsOf: root.appendingPathComponent("fixtures.json"))
            guard let fixtures = try JSONSerialization.jsonObject(with: fixturesData) as? [String: Any],
                  let dto = fixtures["dto"] as? [[String: Any]],
                  let lifecycle = fixtures["lifecycle"] as? [[String: Any]] else { throw FixtureProblem.invalidFixture }
            return .init(dto: dto, lifecycle: lifecycle)
        }
        private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }

    private func field(_ value: [String: Any], _ key: String) throws -> Any {
        guard let value = value[key] else { throw FixtureProblem.invalidFixture }; return value
    }
    private func text(_ value: [String: Any], _ key: String) throws -> String {
        guard let result = value[key] as? String else { throw FixtureProblem.invalidFixture }; return result
    }
    private func boolean(_ value: [String: Any], _ key: String) throws -> Bool {
        guard let result = value[key] as? Bool else { throw FixtureProblem.invalidFixture }; return result
    }
    private func number(_ value: [String: Any], _ key: String) throws -> Double {
        guard let result = value[key] as? NSNumber else { throw FixtureProblem.invalidFixture }; return result.doubleValue
    }
    private func integer(_ value: [String: Any], _ key: String) throws -> Int {
        guard let result = value[key] as? Int else { throw FixtureProblem.invalidFixture }; return result
    }
    private func object(_ value: [String: Any], _ key: String) throws -> [String: Any] {
        guard let result = value[key] as? [String: Any] else { throw FixtureProblem.invalidFixture }; return result
    }
    private func array(_ value: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let result = value[key] as? [[String: Any]] else { throw FixtureProblem.invalidFixture }; return result
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    private func binding(_ value: [String: Any]) throws -> Contract.Binding { try .init(data: json(value)) }
    private func baseBinding() throws -> [String: Any] { try object(XCTUnwrap(packet.lifecycle.first), "before") }
    private func activeResponse() throws -> [String: Any] { try object(XCTUnwrap(packet.lifecycle.first), "response") }
    private func response(user: String? = nil, company: String? = nil) throws -> Data {
        var value = try activeResponse(), conversation = try object(value, "conversation")
        if let user { conversation["userId"] = user }; if let company { conversation["companyId"] = company }
        value["conversation"] = conversation; return try json(value)
    }
    private func context(expected: Contract.Binding?, current: Contract.Binding?, start: Double = 100, finish: Double = 200) -> Contract.Acceptance {
        .init(expected: expected, current: current, ownerAlive: true, aborted: false,
              requestID: "a5000000-0000-4000-8000-000000000001", activeRequestID: "a5000000-0000-4000-8000-000000000001",
              startMonotonicMs: start, finishMonotonicMs: finish)
    }
    private func pad(_ data: Data, to count: Int) throws -> Data {
        guard data.count <= count else { throw FixtureProblem.paddingTooShort }
        var padded = data; padded.append(contentsOf: repeatElement(UInt8(32), count: count - data.count)); return padded
    }
    private func paddedBody(_ item: [String: Any]) throws -> Data { try pad(json(field(item, "response")), to: integer(item, "measuredBodyBytes")) }

    @MainActor private final class HeldTransport {
        private var continuation: CheckedContinuation<Contract.Response, Error>?
        private let started = XCTestExpectation(description: "Authored read transport reached its controlled suspension")
        private(set) var calls = 0
        func read(_ request: Contract.Request) async throws -> Contract.Response {
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; started.fulfill()
            }
        }
        func waitUntilStarted() async {
            let result = await XCTWaiter.fulfillment(of: [started], timeout: 3)
            XCTAssertEqual(result, .completed, "The read did not reach the authored transport")
        }
        func finish(_ result: Result<Contract.Response, Error>) {
            guard let continuation else { XCTFail("No authored transport is suspended"); return }
            self.continuation = nil; continuation.resume(with: result)
        }
    }
}
