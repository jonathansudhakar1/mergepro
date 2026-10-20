import Foundation
import XCTest
import MergeProCore

actor FixtureClock: DeviceFlowClock {
    var time: TimeInterval = 0
    var sleeps: [TimeInterval] = []
    var jump: TimeInterval = 0
    func elapsed() -> TimeInterval { time }
    func date() -> Date { Date(timeIntervalSince1970: time) }
    func sleep(seconds: TimeInterval) async throws { try Task.checkCancellation(); sleeps.append(seconds); time += seconds + jump }
    func recorded() -> [TimeInterval] { sleeps }
    func setJump(_ value: TimeInterval) { jump = value }
}
actor StateRecorder {
    var values: [DeviceFlowState] = []
    func add(_ value: DeviceFlowState) { values.append(value) }
    func all() -> [DeviceFlowState] { values }
}
let challenge = json(#"{"device_code":"private-device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":120,"interval":2}"#)
let token = json(#"{"access_token":"fixture-token","token_type":"bearer","scope":"repo,read:org,read:user,notifications","expires_in":3600,"refresh_token":"fixture-refresh","refresh_token_expires_in":7200}"#)
let user = json(#"{"id":42,"login":"renamed","email":null}"#)

@MainActor
final class DeviceFlowTests: XCTestCase {
    func testPendingRepeatedSlowDownUsesServerIntervalsAndPreservesExpiry() async throws {
        let transport = ScriptedTransport([challenge, json(#"{"error":"authorization_pending"}"#), json(#"{"error":"slow_down","interval":7}"#), json(#"{"error":"slow_down","interval":12}"#), token, user])
        let clock = FixtureClock(); let states = StateRecorder()
        let client = DeviceFlowClient(clientID: "public-id", transport: transport, clock: clock)
        let result = try await client.authorize { await states.add($0) }
        XCTAssertEqual(result.scope, AccountScope(host: "github.com", accountID: "42"))
        XCTAssertEqual(result.login, "renamed")
        XCTAssertEqual(result.credential.refreshToken, "fixture-refresh")
        let sleeps = await clock.recorded(); XCTAssertEqual(sleeps, [2, 2, 7, 12])
        XCTAssertEqual(result.credential.expiresAt, Date(timeIntervalSince1970: 3623))
        let requests = await transport.captured()
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertFalse(String(decoding: requests[1].httpBody!, as: UTF8.self).contains("client_secret"))
        let recorded = await states.all(); XCTAssertEqual(recorded.last, .authorized(accountID: "42"))
    }
    func testDeniedExpiredAndDisabledAreTerminalOAuthBodies() async {
        for (error, expected) in [("access_denied", DeviceFlowState.failed(message: "GitHub authorization was denied.")), ("expired_token", .expired), ("token_expired", .expired), ("device_flow_disabled", .failed(message: "Enable device flow in your GitHub OAuth App settings."))] {
            let transport = ScriptedTransport([challenge, json("{\"error\":\"\(error)\"}")]); let states = StateRecorder()
            let client = DeviceFlowClient(clientID: "id", transport: transport, clock: FixtureClock())
            do { _ = try await client.authorize { await states.add($0) }; XCTFail("must terminate") } catch {}
            let recorded = await states.all(); XCTAssertEqual(recorded.last, expected)
        }
    }
    func testExpiryAfterSleepDoesNotSendLatePoll() async {
        let transport = ScriptedTransport([challenge, token, user]); let clock = FixtureClock(); await clock.setJump(200)
        let client = DeviceFlowClient(clientID: "id", transport: transport, clock: clock); let states = StateRecorder()
        do { _ = try await client.authorize { await states.add($0) }; XCTFail("must expire") } catch {}
        let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
        let recorded = await states.all(); XCTAssertEqual(recorded.last, .expired)
    }
    func testCancellationDiscardsLateSuccess() async {
        let transport = ScriptedTransport([challenge, token, user]); let client = DeviceFlowClient(clientID: "id", transport: transport, clock: FixtureClock()); let states = StateRecorder()
        do {
            _ = try await client.authorize { state in
                await states.add(state)
                if case .polling = state { await client.cancel() }
            }; XCTFail("must cancel")
        } catch {}
        let recorded = await states.all(); XCTAssertEqual(recorded.last, .cancelled)
        let requests = await transport.captured(); XCTAssertEqual(requests.count, 1)
    }
    func testCancelInterruptsSleepingWorker() async throws {
        let clock = SleepingClock()
        let client = DeviceFlowClient(clientID: "id", transport: ScriptedTransport([challenge]), clock: clock)
        let task = Task { try await client.authorize { _ in } }
        while !(await clock.started) { await Task.yield() }
        await client.cancel()
        for _ in 0..<100 { if await clock.wasCancelled { break }; await Task.yield() }
        let interrupted = await clock.wasCancelled
        XCTAssertTrue(interrupted, "cancel must interrupt the active worker, not just discard its result")
        task.cancel()
        _ = try? await task.value
    }
    func testInFlightCancelledTokenNeverResolvesIdentity() async {
        // The challenge answers at once; the token poll stays in flight until released.
        let transport = ScriptedTransport([challenge, token])
        await transport.hold(where: { $0.url?.path == "/login/oauth/access_token" })
        let client = DeviceFlowClient(clientID: "id", transport: transport, clock: FixtureClock())
        let recorder = StateRecorder()
        let task = Task { try await client.authorize { await recorder.add($0) } }
        await transport.waitUntilHolding()
        await client.cancel()
        await transport.release()
        do { _ = try await task.value; XCTFail("late success must be discarded") } catch {}
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let states = await recorder.all(); XCTAssertEqual(states.last, .cancelled)
    }
    func testAbsurdProviderIntervalsAreClampedBeforeAnyDurationConversion() async throws {
        let absurd = json(#"{"device_code":"private-device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":1e300,"interval":1e300}"#)
        let transport = ScriptedTransport([absurd, json(#"{"error":"slow_down","interval":1e300}"#), token, user])
        let clock = FixtureClock()
        let result = try await DeviceFlowClient(clientID:"id", transport:transport, clock:clock).authorize { _ in }
        XCTAssertEqual(result.scope.accountID, "42")
        let sleeps = await clock.recorded()
        XCTAssertEqual(sleeps, [900, 900], "Intervals are bounded to the device-code lifetime")
        // The system clock itself never converts an unbounded value into a Duration (Int128 trap).
        let sleeping = Task { try await SystemDeviceFlowClock().sleep(seconds:1e300) }
        sleeping.cancel()
        do { try await sleeping.value; XCTFail("cancelled sleep must throw") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testInvalidRefreshRequiresReauthorization() async {
        let client = DeviceFlowClient(clientID: "id", transport: ScriptedTransport([json(#"{"error":"bad_refresh_token"}"#)]), clock: FixtureClock())
        do { _ = try await client.refresh(GitHubCredential(accessToken:"old", refreshToken:"old-refresh")); XCTFail("invalid refresh") } catch {}
    }
    func testRefreshRotatesTokensWithoutClientSecret() async throws {
        let transport = ScriptedTransport([token]); let client = DeviceFlowClient(clientID: "public& id", transport: transport, clock: FixtureClock())
        let result = try await client.refresh(GitHubCredential(accessToken: "old", refreshToken: "old-refresh"))
        XCTAssertEqual(result.refreshToken, "fixture-refresh")
        let requests = await transport.captured(); let form = String(decoding: requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token")); XCTAssertTrue(form.contains("client_id=public%26%20id")); XCTAssertFalse(form.contains("client_secret"))
    }
}

actor SleepingClock: DeviceFlowClock {
    var started = false
    var wasCancelled = false
    func elapsed() -> TimeInterval { 0 }
    func date() -> Date { Date(timeIntervalSince1970:0) }
    func sleep(seconds: TimeInterval) async throws {
        started = true
        do { try await Task.sleep(for:.seconds(600)) }
        catch { wasCancelled = true; throw error }
    }
}
