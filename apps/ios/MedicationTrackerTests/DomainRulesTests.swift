import Foundation
import Testing
@testable import MedicationTracker

@Suite struct OperationFactoryTests {
    private let tap = Date(timeIntervalSince1970: 1_793_000_000)

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func takenFixesTheTapTimeInsteadOfTheSyncTime() throws {
        let operation = try OperationFactory.declaration(.taken, dose: Fixture.dose(version: 3), occurredAt: nil, now: tap, patient: Fixture.patient)
        let body = try json(operation.body)
        #expect(body["occurred_at"] as? String == Instant.format(tap))
        #expect(body["expected_version"] as? Int == 3)
        #expect(body["event_type"] as? String == "taken")
        #expect(body["client_operation_id"] as? String == operation.id)
        #expect(operation.id == operation.id.lowercased())
    }

    @Test func skippedNeverSendsATime() throws {
        let operation = try OperationFactory.declaration(.skipped, dose: Fixture.dose(), occurredAt: tap, now: tap, patient: Fixture.patient)
        #expect(try json(operation.body)["occurred_at"] == nil)
    }

    @Test func lateKeepsTheChosenTime() throws {
        let chosen = tap.addingTimeInterval(-3600)
        let operation = try OperationFactory.declaration(.takenLate, dose: Fixture.dose(), occurredAt: chosen, now: tap, patient: Fixture.patient)
        #expect(try json(operation.body)["occurred_at"] as? String == Instant.format(chosen))
    }

    @Test func correctionReferencesEventVersionAndReason() throws {
        let dose = Fixture.dose(state: .taken, version: 2, eventID: "00000000-0000-4000-8000-0000000000e1")
        let operation = try OperationFactory.correction(.skipped, dose: dose, eventID: "00000000-0000-4000-8000-0000000000e1", occurredAt: nil, reason: "Error al tocar", now: tap, patient: Fixture.patient)
        let body = try json(operation.body)
        #expect(operation.path == "/v1/doses/\(dose.id)/corrections")
        #expect(body["corrects_event_id"] as? String == "00000000-0000-4000-8000-0000000000e1")
        #expect(body["reason"] as? String == "Error al tocar")
        #expect(body["expected_version"] as? Int == 2)
        #expect(operation.previousStateConsumes)
    }
}

@Suite struct QuantityTests {
    @Test(arguments: [("0.500", "0,5"), ("10.000", "10"), ("1.250", "1,25"), ("100", "100"), ("-0.125", "-0,125"), ("0.000", "0")])
    func displayKeepsExactValues(raw: String, shown: String) {
        #expect(ExactQuantity.display(raw) == shown)
    }

    @Test func tenthsAddWithoutFloatError() throws {
        // 0,1 + 0,2 en Double produce 0,30000000000000004.
        let total = try #require(ExactQuantity.parse("0.100")) + (try #require(ExactQuantity.parse("0.200")))
        #expect(ExactQuantity.string(total) == "0.3")
    }

    @Test(arguments: ["1,5", "abc", "", "1.2345", "1e3"])
    func rejectsWhatTheContractForbids(text: String) {
        #expect(ExactQuantity.parse(text) == nil)
    }

    @Test func unitsAreWrittenInSpanish() {
        #expect(ExactQuantity.withUnit("1.000", unit: "tablet") == "1 comprimido")
        #expect(ExactQuantity.withUnit("0.500", unit: "tablet") == "0,5 comprimidos")
        #expect(ExactQuantity.withUnit("2.000", unit: "capsule") == "2 cápsulas")
        #expect(ExactQuantity.withUnit("2.500", unit: "ml") == "2,5 ml")
    }
}

@Suite struct StockEstimateTests {
    private let tap = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func noPendingMeansNoEstimate() {
        #expect(StockEstimate.estimated(account: Fixture.account(), doses: [Fixture.dose()], operations: []) == nil)
    }

    @Test func pendingTakenSubtractsTheExactQuantity() throws {
        let dose = Fixture.dose()
        let operation = try OperationFactory.declaration(.taken, dose: dose, occurredAt: nil, now: tap, patient: Fixture.patient)
        #expect(StockEstimate.estimated(account: Fixture.account(), doses: [dose], operations: [operation]) == "9.5")
    }

    @Test func pendingSkippedDoesNotChangeTheBalance() throws {
        let dose = Fixture.dose()
        let operation = try OperationFactory.declaration(.skipped, dose: dose, occurredAt: nil, now: tap, patient: Fixture.patient)
        #expect(StockEstimate.estimated(account: Fixture.account(), doses: [dose], operations: [operation]) == nil)
    }

    @Test func correctingTakenToSkippedRestoresTheQuantity() throws {
        let dose = Fixture.dose(state: .taken, version: 2, eventID: "00000000-0000-4000-8000-0000000000e1")
        let operation = try OperationFactory.correction(.skipped, dose: dose, eventID: "00000000-0000-4000-8000-0000000000e1", occurredAt: nil, reason: "x", now: tap, patient: Fixture.patient)
        #expect(StockEstimate.estimated(account: Fixture.account(), doses: [dose], operations: [operation]) == "10.5")
    }

    @Test func correctingBetweenConsumingStatesDoesNotChangeTheBalance() throws {
        let dose = Fixture.dose(state: .taken, version: 2, eventID: "00000000-0000-4000-8000-0000000000e1")
        let operation = try OperationFactory.correction(.takenLate, dose: dose, eventID: "00000000-0000-4000-8000-0000000000e1", occurredAt: tap, reason: "x", now: tap, patient: Fixture.patient)
        #expect(StockEstimate.estimated(account: Fixture.account(), doses: [dose], operations: [operation]) == nil)
    }

    @Test func unresolvedConflictIsNotCounted() throws {
        let dose = Fixture.dose()
        var operation = try OperationFactory.declaration(.taken, dose: dose, occurredAt: nil, now: tap, patient: Fixture.patient)
        operation.status = .conflict
        #expect(StockEstimate.estimated(account: Fixture.account(), doses: [dose], operations: [operation]) == nil)
    }
}

@Suite struct ReminderPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func dose(_ number: Int, offset: TimeInterval, state: DoseState = .pending) -> Dose {
        Fixture.dose(id: "dose-\(number)", at: Instant.format(now.addingTimeInterval(offset)), state: state)
    }

    @Test func onlyFutureUndeclaredDosesAreReminded() throws {
        let queued = dose(4, offset: 400)
        let plan = ReminderPlanner.plan(
            patient: Fixture.patient, actor: Fixture.patient,
            doses: [dose(1, offset: -60), dose(2, offset: 60), dose(3, offset: 120, state: .taken), queued],
            operations: [try OperationFactory.declaration(.taken, dose: queued, occurredAt: nil, now: now, patient: Fixture.patient)],
            now: now
        )
        #expect(plan.map(\.doseID) == ["dose-2"])
    }

    @Test func respectsThePendingNotificationLimitKeepingTheEarliest() {
        let doses = (0 ..< 200).map { dose($0, offset: TimeInterval(3600 * (200 - $0))) }
        let plan = ReminderPlanner.plan(patient: Fixture.patient, actor: Fixture.patient, doses: doses, operations: [], now: now)
        #expect(plan.count == ReminderPlanner.limit)
        #expect(plan.count <= 64)
        #expect(plan.first?.doseID == "dose-199")
        #expect(plan == plan.sorted { $0.fireAt < $1.fireAt })
    }

    @Test func reconcileRemovesStaleAndAddsOnlyMissing() {
        let plan = [PlannedReminder(doseID: "a", fireAt: now), PlannedReminder(doseID: "b", fireAt: now)]
        let keep = plan[0].identifier
        let changes = ReminderPlanner.reconcile(pending: [keep, "dose.gone.1", "ajena.1"], plan: plan)
        #expect(changes.remove == ["dose.gone.1"])
        #expect(changes.add.map(\.doseID) == ["b"])
    }

    @Test func changingTheHourReplacesTheRequest() {
        let old = PlannedReminder(doseID: "a", fireAt: now)
        let moved = PlannedReminder(doseID: "a", fireAt: now.addingTimeInterval(3600))
        let changes = ReminderPlanner.reconcile(pending: [old.identifier], plan: [moved])
        #expect(changes.remove == [old.identifier])
        #expect(changes.add == [moved])
    }
}

@Suite struct AppConfigTests {
    @Test func productionRequiresHTTPS() {
        #expect(throws: AppConfig.Failure.insecureEndpoint) {
            try AppConfig.make(apiBaseURL: "http://127.0.0.1:8080", firebaseAPIKey: "k", firebaseEmulatorOrigin: "", allowsLoopback: false)
        }
        #expect(throws: AppConfig.Failure.insecureEndpoint) {
            try AppConfig.make(apiBaseURL: "http://api.example.com", firebaseAPIKey: "k", firebaseEmulatorOrigin: "", allowsLoopback: true)
        }
    }

    @Test func productionRejectsTheEmulator() {
        #expect(throws: AppConfig.Failure.insecureEndpoint) {
            try AppConfig.make(apiBaseURL: "https://api.example.com", firebaseAPIKey: "k", firebaseEmulatorOrigin: "http://127.0.0.1:9099", allowsLoopback: false)
        }
    }

    @Test func missingValuesAreNotAccepted() {
        #expect(throws: AppConfig.Failure.missingValue) {
            try AppConfig.make(apiBaseURL: "", firebaseAPIKey: "k", firebaseEmulatorOrigin: "", allowsLoopback: true)
        }
        #expect(throws: AppConfig.Failure.missingValue) {
            try AppConfig.make(apiBaseURL: "https://api.example.com", firebaseAPIKey: "", firebaseEmulatorOrigin: "", allowsLoopback: false)
        }
    }

    @Test func localNetworkNameOnlyWorksInDevelopment() throws {
        _ = try AppConfig.make(apiBaseURL: "http://mi-mac.local:8080", firebaseAPIKey: "k", firebaseEmulatorOrigin: "", allowsLoopback: true)
        #expect(throws: AppConfig.Failure.insecureEndpoint) {
            try AppConfig.make(apiBaseURL: "http://mi-mac.local:8080", firebaseAPIKey: "k", firebaseEmulatorOrigin: "", allowsLoopback: false)
        }
    }

    @Test func developmentAcceptsLoopback() throws {
        let config = try AppConfig.make(apiBaseURL: "http://127.0.0.1:8080", firebaseAPIKey: "k", firebaseEmulatorOrigin: "http://127.0.0.1:9099", allowsLoopback: true)
        #expect(config.firebaseEmulatorOrigin != nil)
    }
}

@Suite struct InstantTests {
    @Test(arguments: ["2026-11-02T12:00:00Z", "2026-11-02T09:00:00-03:00", "2026-11-02T12:00:00.123456789Z"])
    func parsesWhatTheAPIEmits(text: String) throws {
        #expect(try #require(Instant.parse(text)).timeIntervalSince1970 == 1_793_620_800)
    }

    @Test func todayFollowsTheDoseTimezone() {
        let instant = Instant.parse("2026-11-03T01:30:00Z")!
        #expect(LocalDay.today(in: "America/Santiago", now: instant) == "2026-11-02")
        #expect(LocalDay.today(in: "UTC", now: instant) == "2026-11-03")
    }

    @Test func decodesTheContractDoseShape() throws {
        let json = #"{"dose_id":"d","treatment_id":"t","revision_id":"r","scheduled_at":"2026-11-02T12:00:00Z","local_date":"2026-11-02","local_time":"09:00","timezone":"America/Santiago","dst_adjusted":true,"quantity":"0.500","state":"unconfirmed","version":1,"event_id":null}"#
        let dose = try JSONDecoder().decode(Dose.self, from: Data(json.utf8))
        #expect(dose.state == .unconfirmed)
        #expect(!dose.state.isDeclared)
        #expect(!dose.state.consumes)
        #expect(dose.quantity == "0.500")
    }
}

@Suite struct DoseTextTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func unconfirmedIsNeverPresentedAsSkipped() {
        let past = now.addingTimeInterval(-60)
        #expect(DoseText.state(.pending, scheduledAt: past, now: now).text == "Sin confirmar")
        #expect(DoseText.state(.unconfirmed, scheduledAt: past, now: now).text == "Sin confirmar")
        #expect(DoseText.state(.skipped, scheduledAt: past, now: now).text == "No tomada")
        #expect(DoseText.state(.pending, scheduledAt: now.addingTimeInterval(60), now: now).text == "Programada")
    }

    @Test func lateIsDistinguishedFromOnTime() {
        #expect(DoseText.state(.takenLate, scheduledAt: now, now: now).text != DoseText.state(.taken, scheduledAt: now, now: now).text)
    }
}

@Suite struct IdentityStoreTests {
    private let config = try! AppConfig.make(apiBaseURL: "https://api.example.com", firebaseAPIKey: "public-key", firebaseEmulatorOrigin: "", allowsLoopback: false)
    private let signInBody = #"{"localId":"uid-1","idToken":"id-1","refreshToken":"refresh-1","expiresIn":"3600"}"#

    private func store(_ replies: [ScriptedTransport.Reply], secrets: MemorySecrets = MemorySecrets()) -> (IdentityStore, ScriptedTransport, MemorySecrets) {
        let transport = ScriptedTransport(replies)
        return (IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets), transport, secrets)
    }

    @Test func signInPersistsAndARestartRecoversTheSession() async throws {
        let (first, _, secrets) = store([.status(200, signInBody)])
        #expect(try await first.signIn(email: "a@example.com", password: "x") == "uid-1")
        let (second, transport, _) = store([], secrets: secrets)
        #expect(await second.uid == "uid-1")
        #expect(try await second.token(forceRefresh: false) == "id-1")
        #expect(transport.requests.isEmpty)
    }

    @Test func wrongPasswordDoesNotCreateASession() async {
        let (identity, _, secrets) = store([.status(400, #"{"error":{"message":"INVALID_LOGIN_CREDENTIALS"}}"#)])
        await #expect(throws: IdentityError.invalidCredentials) {
            try await identity.signIn(email: "a@example.com", password: "x")
        }
        #expect(secrets.read() == nil)
    }

    @Test func refreshRotatesTheStoredToken() async throws {
        let (identity, _, secrets) = store([.status(200, signInBody), .status(200, #"{"id_token":"id-2","refresh_token":"refresh-2","expires_in":"3600"}"#)])
        _ = try await identity.signIn(email: "a@example.com", password: "x")
        #expect(try await identity.token(forceRefresh: true) == "id-2")
        let saved = try JSONDecoder().decode(Credentials.self, from: try #require(secrets.read()))
        #expect(saved.refreshToken == "refresh-2")
    }

    @Test func rejectedRefreshExpiresTheSessionButNetworkFailureDoesNot() async throws {
        let (identity, _, _) = store([.status(200, signInBody), .failure(.notConnectedToInternet), .status(400, #"{"error":{"message":"TOKEN_EXPIRED"}}"#)])
        _ = try await identity.signIn(email: "a@example.com", password: "x")
        await #expect(throws: APIError.transport) { try await identity.token(forceRefresh: true) }
        #expect(await identity.uid == "uid-1")
        await #expect(throws: APIError.unauthenticated) { try await identity.token(forceRefresh: true) }
    }

    @Test func signOutErasesTheSecret() async throws {
        let (identity, _, secrets) = store([.status(200, signInBody)])
        _ = try await identity.signIn(email: "a@example.com", password: "x")
        await identity.signOut()
        #expect(secrets.read() == nil)
        await #expect(throws: APIError.unauthenticated) { try await identity.token(forceRefresh: false) }
    }

    @Test func productionEndpointsAreTheOfficialOnes() async throws {
        let (identity, transport, _) = store([.status(200, signInBody), .status(200, #"{"id_token":"i","refresh_token":"r","expires_in":"3600"}"#)])
        _ = try await identity.signIn(email: "a@example.com", password: "x")
        _ = try await identity.token(forceRefresh: true)
        #expect(transport.requests[0].url?.absoluteString == "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=public-key")
        #expect(transport.requests[1].url?.absoluteString == "https://securetoken.googleapis.com/v1/token?key=public-key")
    }
}

@Suite struct KeychainStoreTests {
    /// Prueba real contra el Keychain del simulador. La sesión de tests no comparte datos con la app.
    @Test func roundTripAndDelete() throws {
        let store = KeychainStore()
        let previous = store.read()
        defer {
            if let previous { try? store.write(previous) } else { try? store.delete() }
        }
        try store.write(Data("uno".utf8))
        try store.write(Data("dos".utf8))
        #expect(store.read() == Data("dos".utf8))
        try store.delete()
        #expect(store.read() == nil)
    }
}
