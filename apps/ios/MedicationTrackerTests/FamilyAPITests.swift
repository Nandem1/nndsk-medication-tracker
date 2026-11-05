import Foundation
import Testing
@testable import MedicationTracker

@Suite struct FamilyAPITests {
    @Test func reportOnlyCallsTodayWhatIsToday() {
        let now = Date(timeIntervalSince1970: 1_793_880_000) // 2026-11-05T12:00:00Z
        #expect(FamilyText.period(from: "2026-11-05", timezone: "America/Santiago", now: now) == "Hoy hasta ahora")
        #expect(FamilyText.period(from: "2026-11-06", timezone: "Pacific/Auckland", now: now.addingTimeInterval(12 * 3600)) == "Hoy hasta ahora")
        #expect(FamilyText.period(from: "2026-11-04", timezone: "America/Santiago", now: now).hasPrefix("Datos del "))
    }
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

struct SharedInventoryTextTests {
    @Test func namesOnlyOtherMembersAndHidesForeignTime() throws {
        let data = Data(#"{"pool_id":"p","status":"active","members":[{"patient_display_name":"Mamá","you":false,"current":true,"status":"accepted"},{"patient_display_name":"Papá","you":false,"current":false,"status":"accepted"},{"patient_display_name":null,"you":false,"current":false,"status":"pending"}]}"#.utf8)
        let pool = try JSONDecoder().decode(InventoryPool.self, from: data)
        #expect(pool.others() == "Papá, Paciente sin nombre")
        #expect(pool.others(status: "pending") == "Paciente sin nombre")
        let pending = PendingPool(id: "p", proposer: "Hermana", medication: "Losartán", strength: "50 mg", others: ["Papá"])
        #expect(pending.text == "Hermana propone compartir Losartán 50 mg con Papá. Compartirán el mismo saldo y podrán ver cuánto queda.")
        let shared = InventoryMovement(id: "m", quantity: "-0.500", reason: "shared_activity", createdAt: "2026-11-02T00:00:00Z")
        #expect(shared.sharedDate == "02-11-2026")
        #expect(shared.label == "Actividad compartida")
        let own = InventoryMovement(id: "m", quantity: "2.000", reason: "pool_transfer", createdAt: "2026-11-02T10:11:12Z")
        #expect(own.sharedDate == nil)
        #expect(own.label == "Traspaso por inventario compartido")
    }
}
