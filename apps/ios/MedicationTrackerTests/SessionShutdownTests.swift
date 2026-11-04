import Foundation
import Testing
@testable import MedicationTracker

@Suite struct SessionShutdownTests {
    @Test func failedSecretDeletionClearsMemoryAndReportsFailure() async throws {
        let secrets = UndeletableSecrets()
        let config = AppConfig(apiBaseURL: URL(string: "https://synthetic.invalid")!, firebaseAPIKey: "synthetic", firebaseEmulatorOrigin: nil)
        let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: ScriptedTransport([])), secrets: secrets)
        #expect(await identity.uid == "synthetic-owner")
        #expect(await identity.signOut() == false)
        #expect(await identity.uid == nil)
    }

    @Test func interruptedKeychainDeletionCannotRestoreCredentials() throws {
        let service = "synthetic-session-" + UUID().uuidString
        let secrets = KeychainStore(service: service)
        defer { try? secrets.delete() }
        let data = Data("synthetic-credentials".utf8)
        try secrets.write(data)
        #expect(secrets.read() == data)
        UserDefaults.standard.set(true, forKey: service + ".deleting")
        #expect(KeychainStore(service: service).read() == nil)
        try secrets.delete()
        #expect(secrets.read() == nil)
        #expect(!UserDefaults.standard.bool(forKey: service + ".deleting"))
    }

    @Test func logoutRejectsLateSignInResponse() async throws {
        let transport = HeldHistoryTransport(body: #"{"localId":"synthetic-owner","idToken":"token","refreshToken":"refresh","expiresIn":"3600"}"#)
        let secrets = MemorySecrets()
        let config = AppConfig(apiBaseURL: URL(string: "https://synthetic.invalid")!, firebaseAPIKey: "synthetic", firebaseEmulatorOrigin: nil)
        let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets)
        let signing = Task { try await identity.signIn(email: "synthetic@example.invalid", password: "synthetic") }
        await transport.waitForRequest()
        #expect(await identity.signOut())
        await transport.release()
        await #expect(throws: IdentityError.sessionExpired) { try await signing.value }
        #expect(await identity.uid == nil)
        #expect(secrets.read() == nil)
    }

    @Test func logoutRejectsEveryWaiterOfSharedRefresh() async throws {
        let transport = HeldHistoryTransport(body: #"{"id_token":"late-token","refresh_token":"late-refresh","expires_in":"3600"}"#)
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(Credentials(uid: "synthetic-owner", idToken: "expired", refreshToken: "refresh", expiresAt: .distantPast)))
        let config = AppConfig(apiBaseURL: URL(string: "https://synthetic.invalid")!, firebaseAPIKey: "synthetic", firebaseEmulatorOrigin: nil)
        let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets)
        let first = Task { try await identity.token(forceRefresh: true) }
        await transport.waitForRequest()
        let second = Task { try await identity.token(forceRefresh: true) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await identity.signOut())
        await transport.release()
        await #expect(throws: APIError.unauthenticated) { try await first.value }
        await #expect(throws: APIError.unauthenticated) { try await second.value }
        #expect(await transport.requestCount == 1)
        #expect(secrets.read() == nil)
    }

    @Test func refreshPreservesPreferenceChangedWhileRequestIsInFlight() async throws {
        let transport = HeldHistoryTransport(body: #"{"id_token":"new-token","refresh_token":"new-refresh","expires_in":"3600"}"#)
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(Credentials(uid: "owner", idToken: "expired", refreshToken: "refresh", expiresAt: .distantPast, email: "synthetic@example.invalid", caregiverPreference: false)))
        let config = AppConfig(apiBaseURL: URL(string: "https://synthetic.invalid")!, firebaseAPIKey: "synthetic", firebaseEmulatorOrigin: nil)
        let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets)
        let renewal = Task { try await identity.token(forceRefresh: true) }
        await transport.waitForRequest()
        try await identity.setUse(caregiver: true)
        await transport.release()
        #expect(try await renewal.value == "new-token")
        let restored = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets)
        #expect(await restored.caregiverPreference == true)
        #expect(await restored.email == "synthetic@example.invalid")
    }

    @Test func oldCredentialsDecodeWithoutNewProfileFields() throws {
        let data = Data(#"{"uid":"owner","idToken":"token","refreshToken":"refresh","expiresAt":0}"#.utf8)
        let credentials = try JSONDecoder().decode(Credentials.self, from: data)
        #expect(credentials.email == nil)
        #expect(credentials.caregiverPreference == nil)
    }

    @Test func patientInvalidationWaitsForEarlierHistoryAndDoesNotDeleteAnotherPatient() async throws {
        let (store, _) = try Fixture.temporaryStore()
        let other = Fixture.dose(id: "other-dose")
        try await store.replaceAgenda([other], from: "2026-11-01", to: "2026-11-03", at: .now, patient: "other")
        let encoded = String(decoding: try JSONEncoder().encode(Fixture.dose()), as: UTF8.self)
        let transport = HeldHistoryTransport(body: "{\"items\":[" + encoded + "],\"next_cursor\":\"\"}")
        let engine = SyncEngine(api: APIClient(baseURL: URL(string: "https://synthetic.invalid")!, transport: transport, tokens: FixedTokens()), store: store)
        let history = Task { await engine.loadHistory(patient: Fixture.patient, from: "2026-11-01", to: "2026-11-03") }
        await transport.waitForRequest()
        let denial = Task { await engine.deny(patient: Fixture.patient) }
        let operation = try OperationFactory.declaration(.taken, dose: other, occurredAt: nil, now: .now, patient: "other")
        try await store.enqueue(operation)
        #expect(try await store.operations().count == 1)
        await transport.release()
        #expect(await history.value == .synced)
        #expect(await denial.value == .unavailable(.denied))
        #expect(try await store.snapshot(patient: Fixture.patient).doses.isEmpty)
        #expect(try await store.snapshot(patient: "other").doses == [other])
        #expect(try await store.operations().first?.body == operation.body)
    }

    @Test func shutdownWaitsForHistoryAndRejectsFurtherWork() async throws {
        let (store, directory) = try Fixture.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.claim(ownerUID: "old-owner")
        try await store.setPatientID(Fixture.patient)
        let transport = HeldHistoryTransport(body: "{\"items\":[" + String(decoding: try JSONEncoder().encode(Fixture.dose()), as: UTF8.self) + "],\"next_cursor\":\"\"}")
        let api = APIClient(baseURL: URL(string: "https://synthetic.invalid")!, transport: transport, tokens: FixedTokens())
        let engine = SyncEngine(api: api, store: store)
        let history = Task { await engine.loadHistory(patient: Fixture.patient, from: "2026-11-01", to: "2026-11-03") }
        await transport.waitForRequest()
        let closing = Task {
            await engine.stop()
            try await store.wipe()
        }
        await transport.release()
        #expect(await history.value == .synced)
        try await closing.value
        #expect(try await store.snapshot(patient: Fixture.patient).doses.isEmpty)
        #expect(await engine.loadHistory(patient: Fixture.patient, from: "2026-11-01", to: "2026-11-03") == .sessionExpired)
        #expect(await engine.sync() == .sessionExpired)
        #expect(await engine.drain() == .sessionExpired)
        #expect(await transport.requestCount == 1)
        _ = try await store.claim(ownerUID: "new-owner")
        #expect(try await store.snapshot(patient: Fixture.patient).doses.isEmpty)
        await engine.resume()
        #expect(await engine.drain() == .synced)
    }
}

private actor HeldHistoryTransport: HTTPTransport {
    let body: String
    private var response: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    init(body: String) { self.body = body }

    func waitForRequest() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { response?.resume(); response = nil }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        await withCheckedContinuation { continuation in
            response = continuation
            started?.resume()
            started = nil
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct UndeletableSecrets: SecretStore {
    func read() -> Data? {
        try? JSONEncoder().encode(Credentials(uid: "synthetic-owner", idToken: "token", refreshToken: "refresh", expiresAt: .distantFuture))
    }
    func write(_ data: Data) throws {}
    func delete() throws { throw IdentityError.storage }
}
