import Foundation
import Testing
@testable import MedicationTracker

@Suite @MainActor struct FamilySessionTests {
    @Test func formUnauthorizedWaitsForOldWritesBeforeAnotherAccountCanClaimStore() async throws {
        let (store, _) = try Fixture.temporaryStore()
        let transport = FamilySessionTransport()
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(Credentials(uid: "owner-a", idToken: "token", refreshToken: "refresh", expiresAt: .distantFuture)))
        let config = AppConfig(apiBaseURL: URL(string: "https://synthetic.invalid")!, firebaseAPIKey: "synthetic", firebaseEmulatorOrigin: nil)
        let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets)
        let api = APIClient(baseURL: config.apiBaseURL, transport: transport, tokens: FixedTokens())
        let engine = SyncEngine(api: api, store: store)
        let model = AppModel(identity: identity, store: store, api: api, sync: engine)
        await model.start()
        #expect(model.phase == .signedIn)
        let history = Task { await model.loadHistory(from: .now, to: .now) }
        await transport.waitForHistory()
        let form = Task { try await model.movements(patient: "owner-a", account: "account") }
        await transport.waitForUnauthorized()
        _ = await model.signIn(email: "b@example.invalid", password: "synthetic")
        #expect(await transport.signInCount == 0)
        await transport.releaseHistory()
        _ = await history.value
        await #expect(throws: APIError.unauthenticated) { try await form.value }
        #expect(model.phase == .expired)
        #expect(await model.signIn(email: "b@example.invalid", password: "synthetic") == nil)
        #expect(await transport.signInCount == 1)
        #expect(await identity.uid == "owner-b")
        #expect(try await store.snapshot(patient: "owner-a").doses.isEmpty)
        #expect(model.snapshot.doses.isEmpty)
        await model.signOut()
    }
}

private actor FamilySessionTransport: HTTPTransport {
    private var held: CheckedContinuation<Void, Never>?
    private var historyWaiter: CheckedContinuation<Void, Never>?
    private var unauthorizedWaiter: CheckedContinuation<Void, Never>?
    private var historyStarted = false
    private var unauthorizedCount = 0
    private(set) var signInCount = 0

    func waitForHistory() async {
        if historyStarted { return }
        await withCheckedContinuation { historyWaiter = $0 }
    }
    func waitForUnauthorized() async {
        if unauthorizedCount == 2 { return }
        await withCheckedContinuation { unauthorizedWaiter = $0 }
    }
    func releaseHistory() { held?.resume(); held = nil }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path()
        var status = 200
        let body: String
        if path.contains("signInWithPassword") {
            signInCount += 1
            body = #"{"localId":"owner-b","idToken":"token-b","refreshToken":"refresh-b","expiresIn":"3600"}"#
        } else if path.hasSuffix("/me") {
            body = #"{"user_id":"\#(signInCount == 0 ? "owner-a" : "owner-b")","display_name":"Persona sintética","profile_version":1,"profile_complete":true}"#
        } else if path.hasSuffix("/doses") {
            historyStarted = true
            await withCheckedContinuation { continuation in
                held = continuation
                historyWaiter?.resume(); historyWaiter = nil
            }
            body = "{\"items\":[" + String(decoding: try JSONEncoder().encode(Fixture.dose()), as: UTF8.self) + "],\"next_cursor\":\"\"}"
        } else if path.hasSuffix("/movements") {
            unauthorizedCount += 1
            if unauthorizedCount == 2 { unauthorizedWaiter?.resume(); unauthorizedWaiter = nil }
            status = 401
            body = "{}"
        } else {
            body = #"{"items":[],"next_cursor":""}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
