import XCTest
import Darwin
import NookPluginSDK
@testable import ModuleCore

final class DashboardTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000
    private let device = UUID()
    private func value(connection: BridgeConnection = .connected, ready: Bool = true, paused: Bool = false, observedAt: Int64? = nil, lastGatewayAt: Int64? = nil) -> BridgeStatus {
        let observed = observedAt ?? now
        return .init(observedAt: observed, validUntil: observed + 15_000, deviceId: device, connection: connection, sessionEpoch: connection == .connected ? 40 : nil, ready: ready, lastGatewayAt: lastGatewayAt ?? (connection == .connected ? now : nil), paused: paused, recentJobs: [.init(runId: UUID(), commandId: UUID(), state: .completed)])
    }
    private func response(_ value: BridgeStatus, id: UUID = UUID()) throws -> (Data, UUID) {
        struct Envelope: Encodable { let version: Int; let requestId: UUID; let snapshot: BridgeStatus }
        return (try JSONEncoder().encode(Envelope(version: 1, requestId: id, snapshot: value)), id)
    }
    func testResponseBindsRequestAndFreshRemoteReadiness() throws {
        let (data, id) = try response(value())
        XCTAssertEqual(try StatusCodec.decode(data, requestId: id, now: now).deviceId, device)
        XCTAssertThrowsError(try StatusCodec.decode(data, requestId: UUID(), now: now))
        XCTAssertThrowsError(try StatusCodec.decode(data, requestId: id, now: now + 15_000))
        XCTAssertThrowsError(try value(lastGatewayAt: now - 30_001).validate(now: now))
        XCTAssertThrowsError(try value(ready: true, paused: true).validate(now: now))
        XCTAssertThrowsError(try value(connection: .disconnected, ready: true).validate(now: now))
    }
    func testStrictSchemaRejectsUnknownAndInvalidFields() throws {
        let (data, id) = try response(value())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        snapshot["prompt"] = "private"; object["snapshot"] = snapshot
        XCTAssertThrowsError(try StatusCodec.decode(JSONSerialization.data(withJSONObject: object), requestId: id, now: now))
        snapshot["prompt"] = nil; snapshot["connection"] = "fake-ready"; object["snapshot"] = snapshot
        XCTAssertThrowsError(try StatusCodec.decode(JSONSerialization.data(withJSONObject: object), requestId: id, now: now))
        snapshot["connection"] = "connected"; snapshot["activeJobs"] = -1; object["snapshot"] = snapshot
        XCTAssertThrowsError(try StatusCodec.decode(JSONSerialization.data(withJSONObject: object), requestId: id, now: now))
        XCTAssertThrowsError(try StatusCodec.decode(Data(repeating: 65, count: 32_769), requestId: id, now: now))
    }
    func testCountsJobsDatesAndDuplicatesAreBounded() throws {
        let job = RecentJob(runId: UUID(), commandId: UUID(), state: .completed)
        let duplicated = BridgeStatus(observedAt: now, validUntil: now + 15_000, deviceId: device, connection: .disconnected, recentJobs: [job, job])
        XCTAssertThrowsError(try duplicated.validate(now: now))
        let future = value(observedAt: now + 2_001)
        XCTAssertThrowsError(try future.validate(now: now))
        let longLife = BridgeStatus(observedAt: now, validUntil: now + 15_001, deviceId: device, connection: .disconnected)
        XCTAssertThrowsError(try longLife.validate(now: now))
    }
    func testUnavailableFailureClearsJobsAndFreshReady() throws {
        var state = MonitorState(); try state.received(value(), now: now)
        XCTAssertEqual(state.title, "Ready")
        state.failed(BrokerProblem.unavailable)
        XCTAssertNil(state.status); XCTAssertEqual(state.title, "Unavailable")
        XCTAssertEqual(state.customView.state["jobs"], .string("[]"))
        XCTAssertEqual(state.values["connected"], .boolean(false))
        try state.received(value(), now: now); state.expire(now: now + 15_000)
        XCTAssertNil(state.status); XCTAssertFalse(state.detail.contains("Ready"))
    }
    func testDisconnectedAndPausedAreExplicitAndAllSDKViewsValidate() throws {
        var state = MonitorState()
        for status in [value(), value(ready: false), value(connection: .disconnected, ready: false), value(connection: .disconnected, ready: false, paused: true)] {
            try state.received(status, now: now)
            for custom in [false, true] { try state.snapshot(customViews: custom).validate() }
            try MonitorState.schema.validate(state.values)
            if !status.ready { XCTAssertNotEqual(state.title, "Ready") }
        }
        XCTAssertEqual(state.title, "Compute paused")
        XCTAssertTrue(state.detail.contains("requests active work to stop"))
        XCTAssertEqual(MonitorState.readAction.effect, .readOnly)
        try MonitorState.readAction.validate()
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(state.customView.state).count, 32768)
    }
    func testEventsBindExactPanelRevisionAndNoExtraArguments() throws {
        let state = MonitorState()
        XCTAssertEqual(try state.handle(.init(panelID: "monitor", revision: "monitor1", name: "refresh")), "refresh")
        for event in [PluginViewEvent(panelID: "other", revision: "monitor1", name: "refresh"), .init(panelID: "monitor", revision: "old", name: "refresh"), .init(panelID: "monitor", revision: "monitor1", name: "dispatch"), .init(panelID: "monitor", revision: "monitor1", name: "refresh", values: ["prompt": .string("no")])] {
            XCTAssertThrowsError(try state.handle(event))
        }
    }
    func testStateCanBeRecoveredOnlyByANewFreshReceipt() throws {
        var state = MonitorState(); try state.received(value(), now: now)
        state.failed(BrokerProblem.untrustedPeer)
        XCTAssertEqual(state.title, "Unavailable")
        XCTAssertThrowsError(try state.received(value(observedAt: now - 16_000), now: now))
        XCTAssertNil(state.status)
        try state.received(value(), now: now); XCTAssertEqual(state.title, "Ready")
    }
    func testPartialReadsNeverRenewTheMonotonicDeadline() throws {
        let deadline = ExchangeDeadline(expiresAt: 3_000_000_000)
        XCTAssertEqual(try deadline.remainingMilliseconds(at: 0), 3000)
        XCTAssertEqual(try deadline.remainingMilliseconds(at: 1_000_000_000), 2000)
        XCTAssertEqual(try deadline.remainingMilliseconds(at: 2_999_999_999), 1)
        XCTAssertThrowsError(try deadline.remainingMilliseconds(at: 3_000_000_000))
        XCTAssertThrowsError(try deadline.remainingMilliseconds(at: UInt64.max))
    }

    func testActualSocketTrickleCannotExtendWholeExchangeDeadline() async throws {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let reader = sockets[0], writer = sockets[1]
        defer { Darwin.close(reader); Darwin.close(writer) }
        for fd in sockets {
            XCTAssertEqual(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK), 0)
            var flag: Int32 = 1
            XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size)), 0)
        }
        let trickle = Task.detached {
            var byte: UInt8 = 120
            while !Task.isCancelled {
                _ = Darwin.send(writer, &byte, 1, 0)
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let result = await Task.detached { () -> BrokerProblem? in
            do { _ = try SocketIO.readFrame(from: reader, deadline: started + 3_000_000_000); return nil }
            catch { return error as? BrokerProblem }
        }.value
        trickle.cancel(); await trickle.value
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertEqual(result?.localizedDescription, BrokerProblem.timedOut.localizedDescription)
        XCTAssertGreaterThanOrEqual(elapsed, 2.9)
        XCTAssertLessThan(elapsed, 4.5)
    }
    func testActualFrameRejectsTrailingMessages() throws {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { Darwin.close(sockets[0]); Darwin.close(sockets[1]) }
        let data = Data("{}\n{}\n".utf8)
        _ = data.withUnsafeBytes { Darwin.send(sockets[1], $0.baseAddress, $0.count, 0) }
        XCTAssertThrowsError(try SocketIO.readFrame(from: sockets[0], deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
    }

}
