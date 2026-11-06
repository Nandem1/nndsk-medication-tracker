import Foundation
import Testing
@testable import MedicationTracker

@Suite struct SyncEngineTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let doseResult = #"{"dose_id":"00000000-0000-4000-8000-0000000000d1","event_id":"00000000-0000-4000-8000-0000000000e1","version":2,"state":"taken","balance":"9.500"}"#

    private func engine(_ replies: [ScriptedTransport.Reply]) throws -> (SyncEngine, LocalStore, ScriptedTransport) {
        let (store, _) = try Fixture.temporaryStore()
        let transport = ScriptedTransport(replies)
        let api = APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, transport: transport, tokens: FixedTokens())
        return (SyncEngine(api: api, store: store, now: { [now] in now }), store, transport)
    }

    private func enqueueDose(_ store: LocalStore) async throws -> PendingOperation {
        let dose = Fixture.dose()
        try await store.replaceAgenda([dose], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        return try await store.enqueue(try OperationFactory.declaration(.taken, dose: dose, occurredAt: nil, now: now, patient: Fixture.patient))
    }

    @Test func retryAfterLostResponseSendsIdenticalBytes() async throws {
        let (engine, store, transport) = try engine([.failure(.networkConnectionLost), .status(200, doseResult)])
        let operation = try await enqueueDose(store)

        #expect(await engine.drain() == .unavailable(.transport))
        #expect(try await store.operations().first?.status == .pending)
        #expect(await engine.drain() == .synced)

        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].httpBody == operation.body)
        #expect(transport.requests[1].httpBody == operation.body)
        #expect(try await store.operations().isEmpty)
    }

    @Test func offlineStopsTheQueueWithoutLosingAnything() async throws {
        let (engine, store, transport) = try engine([.failure(.notConnectedToInternet)])
        _ = try await enqueueDose(store)
        let second = Fixture.dose(id: "00000000-0000-4000-8000-0000000000d2")
        try await store.enqueue(try OperationFactory.declaration(.skipped, dose: second, occurredAt: nil, now: now, patient: Fixture.patient))

        #expect(await engine.drain() == .unavailable(.transport))
        #expect(transport.requests.count == 1)
        #expect(try await store.operations().count == 2)
    }

    @Test(arguments: [(409, OperationStatus.conflict), (422, .rejected), (400, .rejected), (403, .denied), (404, .denied)])
    func definitiveRejectionKeepsTheOperationForTheUser(code: Int, status: OperationStatus) async throws {
        let (engine, store, _) = try engine([.status(code)])
        _ = try await enqueueDose(store)

        #expect(await engine.drain() == (status == .denied ? .unavailable(.denied) : .synced))
        let stored = try await store.operations()
        #expect(stored.count == 1)
        #expect(stored.first?.status == status)
    }

    @Test func resolvedOperationsAreNotResentAutomatically() async throws {
        let (engine, store, transport) = try engine([.status(409)])
        _ = try await enqueueDose(store)
        _ = await engine.drain()
        _ = await engine.drain()
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [500, 502, 504, 429])
    func temporaryServerFailureKeepsItPendingAndContinues(code: Int) async throws {
        let (engine, store, transport) = try engine([.status(code), .status(200, doseResult.replacingOccurrences(of: "d1", with: "d2"))])
        _ = try await enqueueDose(store)
        let second = Fixture.dose(id: "00000000-0000-4000-8000-0000000000d2")
        try await store.enqueue(try OperationFactory.declaration(.taken, dose: second, occurredAt: nil, now: now, patient: Fixture.patient))

        #expect(await engine.drain() != .synced)
        #expect(transport.requests.count == 2)
        let left = try await store.operations()
        #expect(left.map(\.doseID) == [Fixture.dose().id])
        #expect(left.first?.status == .pending)
    }

    @Test func expiredSessionStopsAndKeepsTheQueue() async throws {
        let (engine, store, transport) = try engine([.status(401), .status(401)])
        _ = try await enqueueDose(store)

        #expect(await engine.drain() == .sessionExpired)
        #expect(transport.requests.count == 2)
        #expect(try await store.operations().first?.status == .pending)
    }

    @Test func unreadableSuccessStaysPendingForAnIdempotentRetry() async throws {
        let (engine, store, _) = try engine([.status(200, "no-json")])
        _ = try await enqueueDose(store)
        #expect(await engine.drain() == .unavailable(.decoding))
        #expect(try await store.operations().first?.status == .pending)
    }

    /// Los vínculos salen de la familia, que la app lee aparte: la sincronización ya no los pide.
    @Test func refreshNoLongerReadsCaregiverLinks() async throws {
        let (store, _) = try Fixture.temporaryStore()
        try await store.setPatientID(Fixture.patient)
        let engine = SyncEngine(api: APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, transport: RoutedTransport(), tokens: FixedTokens()), store: store, now: { [now] in now })
        #expect(await engine.sync() == .synced)
    }

    @Test func windowStaysWithinTheContractLimit() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Santiago")!
        let window = SyncEngine.window(now: now, calendar: calendar)
        #expect(SyncEngine.daysBack + SyncEngine.daysAhead <= 30)
        #expect(window.from < window.to)
    }
}

private struct RoutedTransport: HTTPTransport {

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path()
        let body: String
        if path.hasSuffix("caregiver-links") { throw URLError(.unsupportedURL) }
        else if path.hasSuffix("/me") { body = #"{"user_id":"\#(Fixture.patient)","timezone":"America/Santiago"}"# }
        else if path.hasSuffix("/patients") { body = #"{"items":[{"patient_id":"\#(Fixture.patient)","scopes":["read"],"profile_version":1,"timezone":"America/Santiago"}],"next_cursor":""}"# }
        else if path.contains("adherence") { body = #"{"from":"2026-11-01","to":"2026-11-02","summary":{"confirmed":0,"evaluable":0,"unconfirmed":0}}"# }
        else { body = #"{"items":[],"next_cursor":""}"# }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
