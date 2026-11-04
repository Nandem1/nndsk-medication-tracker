import Foundation
import Testing
@testable import MedicationTracker

@Suite struct FamilyAPITests {
    @Test func lateUnauthorizedProfileWriteCannotRetryWithAnotherAccount() async throws {
        let transport = HeldProfileTransport()
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(Credentials(uid: "owner-a", idToken: "token-a", refreshToken: "refresh-a", expiresAt: .distantFuture)))
        let config = AppConfig(apiBaseURL: URL(string: "https://synthetic.invalid")!, firebaseAPIKey: "synthetic", firebaseEmulatorOrigin: nil)
        let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets)
        let api = APIClient(baseURL: config.apiBaseURL, transport: transport, tokens: identity)
        let mutation = Task { try await api.updateProfile(patient: nil, name: "Persona A", version: 1, operation: "operation-a") }
        await transport.waitForProfile()
        #expect(await identity.signOut())
        _ = try await identity.signIn(email: "b@example.invalid", password: "synthetic")
        await transport.releaseProfile()
        await #expect(throws: APIError.unauthenticated) { try await mutation.value }
        #expect(await transport.profileWrites == 1)
        #expect(await transport.profileTokens == ["Bearer token-a"])
        #expect(try await identity.token(forceRefresh: true) == "renewed-b")
        #expect(await identity.uid == "owner-b")
    }

    @Test func invitationAcceptsCompleteMessageAndRejectsLongerIdentifiers() throws {
        let token = String(repeating: "a", count: 43)
        #expect(try FamilyText.token(FamilyText.invitation(token)) == token)
        #expect(throws: APIError.invalid) { try FamilyText.token(token + "a") }
    }

    @Test func inventoryRetryKeepsExactQuantityExpectedBalanceAndOperation() async throws {
        let transport = ScriptedTransport([.failure(.networkConnectionLost), .status(200)])
        let api = APIClient(baseURL: URL(string: "https://synthetic.invalid")!, transport: transport, tokens: FixedTokens())
        await #expect(throws: APIError.transport) {
            try await api.inventoryMutation(account: "account", quantity: "12.125", count: true, reason: "Conteo sintético", expected: "10.500", operation: "stable-operation")
        }
        try await api.inventoryMutation(account: "account", quantity: "12.125", count: true, reason: "Conteo sintético", expected: "10.500", operation: "stable-operation")
        #expect(transport.requests.count == 2)
        let bodies = try transport.requests.map { try JSONDecoder().decode([String: String].self, from: #require($0.httpBody)) }
        #expect(bodies[0] == bodies[1])
        #expect(bodies[1]["counted_quantity"] == "12.125")
        #expect(bodies[1]["expected_balance"] == "10.500")
        #expect(bodies[1]["client_operation_id"] == "stable-operation")
    }
}

private actor HeldProfileTransport: HTTPTransport {
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var profileWrites = 0
    private(set) var profileTokens: [String] = []
    func waitForProfile() async {
        if profileWrites > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func releaseProfile() { held?.resume(); held = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path()
        let body: String
        var status = 200
        if path.hasSuffix("/profile") {
            profileWrites += 1
            profileTokens.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            await withCheckedContinuation { continuation in
                held = continuation
                waiter?.resume(); waiter = nil
            }
            body = "{}"; status = 401
        } else if path.contains("signInWithPassword") {
            body = #"{"localId":"owner-b","idToken":"token-b","refreshToken":"refresh-b","expiresIn":"3600"}"#
        } else {
            body = #"{"id_token":"renewed-b","refresh_token":"refresh-b2","expires_in":"3600"}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
