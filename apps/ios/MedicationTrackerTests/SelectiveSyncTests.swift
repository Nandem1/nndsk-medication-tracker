import Foundation
import Testing
@testable import MedicationTracker

@Suite struct SelectiveSyncTests {
    private func setup(_ transport: SelectiveTransport, shared: Bool = false) async throws -> (SyncEngine, LocalStore) {
        let (store, _) = try Fixture.temporaryStore()
        try await store.saveProfile(Me(userID: Fixture.patient, displayName: "Anterior", profileVersion: 1, profileComplete: true))
        for patient in [Fixture.patient, "other", "unrelated"] {
            let access = PatientAccess(patientID: patient, linkID: nil, scopes: ["read", "doses"], displayName: "Anterior", profileVersion: 1, timezone: "America/Santiago")
            try await store.saveAccess(access, report: patient == Fixture.patient ? nil : DailyReport(from: "2026-11-06", to: "2026-11-07", summary: .init(confirmed: 0, evaluable: 1, unconfirmed: 1)))
            try await store.replaceAgenda([Fixture.dose(id: "\(patient)-dose")], from: "2026-01-01", to: "2027-01-01", at: .now, patient: patient)
            var stock = InventoryProjection(accountID: "\(patient)-account", treatmentID: Fixture.treatment, balance: "20.000", unit: "tablet", firstUncoveredAt: nil, scheduledQuantity: "1.000")
            if shared && patient != "unrelated" { stock.pool = InventoryPool(id: "shared", status: "active", members: []) }
            try await store.replaceInventory([stock], patient: patient)
        }
        return (SyncEngine(api: APIClient(baseURL: URL(string: "https://synthetic.invalid")!, transport: transport, tokens: FixedTokens()), store: store), store)
    }

    private func enqueue(_ patient: String, store: LocalStore) async throws {
        try await store.enqueue(try OperationFactory.declaration(.taken, dose: Fixture.dose(id: "\(patient)-dose"), occurredAt: nil, now: .now, patient: patient))
    }

    @Test func declarationsRefreshEveryAffectedPatientAndSharedInventoryWithoutAgenda() async throws {
        let transport = SelectiveTransport()
        let (engine, store) = try await setup(transport, shared: true)
        try await enqueue("other", store: store)
        #expect(await engine.refreshDeclarations().outcome == .synced)
        #expect(try await store.operations().isEmpty)
        #expect(try await store.snapshot(patient: "other").doses.first?.state == .taken)
        for patient in [Fixture.patient, "other"] {
            #expect(try await store.snapshot(patient: patient).inventory.first?.balance == "7.000")
            #expect(try await store.snapshot(patient: patient).inventory.first?.lowStock == true)
        }
        #expect(try await store.snapshot(patient: "other").report?.summary.confirmed == 1)
        #expect(try await store.snapshot(patient: "unrelated").inventory.first?.balance == "20.000")
        let paths = await transport.paths
        #expect(paths.filter { $0.hasSuffix("/inventory") }.count == 2)
        #expect(!paths.contains { $0.hasSuffix("/doses") || $0.hasSuffix("/treatments") })
        #expect(!paths.contains("/v1/patients/\(Fixture.patient)/adherence"))
    }

    @Test func uncertainDrainNeverReadsConfirmedInventory() async throws {
        let transport = SelectiveTransport(postFailure: true)
        let (engine, store) = try await setup(transport, shared: true)
        try await enqueue("other", store: store)
        #expect(await engine.refreshDeclarations().outcome == .unavailable(.server))
        #expect(try await store.operations().first?.status == .pending)
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "20.000")
        #expect(!(await transport.paths).contains { $0.hasSuffix("/inventory") })
    }

    @Test func oneDrainRefreshesBothPatientsWithConfirmedOperations() async throws {
        let transport = SelectiveTransport()
        let (engine, store) = try await setup(transport)
        try await enqueue("other", store: store)
        try await enqueue("unrelated", store: store)
        #expect(await engine.refreshDeclarations().outcome == .synced)
        for patient in ["other", "unrelated"] {
            #expect(try await store.snapshot(patient: patient).inventory.first?.balance == "7.000")
            #expect(try await store.snapshot(patient: patient).report?.summary.confirmed == 1)
        }
        #expect(try await store.operations().isEmpty)
    }

    @Test func newPendingOperationOfPoolMemberPreventsInventoryRead() async throws {
        let transport = SelectiveTransport(holdPost: true)
        let (engine, store) = try await setup(transport, shared: true)
        try await enqueue("other", store: store)
        let refresh = Task { await engine.refreshDeclarations() }
        try await transport.waitForPost()
        try await enqueue(Fixture.patient, store: store)
        await transport.releasePost()
        #expect(await refresh.value.outcome == .synced)
        #expect(try await store.operations().map(\.patientID) == [Fixture.patient])
        #expect(!(await transport.paths).contains { $0.hasSuffix("/inventory") })
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "20.000")
        #expect(await engine.refreshDeclarations().outcome == .synced)
        #expect(try await store.operations().isEmpty)
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "7.000")
    }

    @Test(arguments: [500, 429]) func laterDenialCannotHideAnUncertainEarlierSubmission(status: Int) async throws {
        let failures = ["/v1/doses/other-dose/events": status, "/v1/doses/unrelated-dose/events": 403]
        let transport = SelectiveTransport(resourceFailures: failures)
        let (engine, store) = try await setup(transport)
        let first = Date.now
        for (patient, created) in [("other", first), ("unrelated", first.addingTimeInterval(1))] {
            try await store.enqueue(try OperationFactory.declaration(.taken, dose: Fixture.dose(id: "\(patient)-dose"), occurredAt: nil, now: created, patient: patient))
        }
        #expect(await engine.sync() == .unavailable(status == 429 ? .rateLimited : .server))
        let remaining = try await store.operations()
        #expect(remaining.first(where: { $0.patientID == "other" })?.status == .pending)
        #expect(remaining.first(where: { $0.patientID == "unrelated" })?.status == .denied)
        #expect(!(await transport.paths).contains { $0.hasSuffix("/inventory") })
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "20.000")
    }

    @Test func membershipDefersPendingSnapshotsWithoutReportingServerFailure() async throws {
        let transport = SelectiveTransport(holdPost: true, scopeReduction: true)
        let (engine, store) = try await setup(transport, shared: true)
        try await enqueue("other", store: store)
        let refresh = Task { await engine.refreshMembership() }
        try await transport.waitForPost()
        try await enqueue(Fixture.patient, store: store)
        await transport.releasePost()
        #expect(await refresh.value.outcome == .synced)
        #expect(!(await transport.paths).contains { $0.hasSuffix("/inventory") })
        #expect(await engine.refreshMembership().outcome == .synced)
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "7.000")
    }

    @Test func failedInventoryRemainsDueAfterOperationWasApplied() async throws {
        let transport = SelectiveTransport(inventoryFailures: 1)
        let (engine, store) = try await setup(transport)
        try await enqueue("other", store: store)
        #expect(await engine.refreshDeclarations().outcome == .unavailable(.server))
        #expect(try await store.operations().isEmpty)
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "20.000")
        #expect(await engine.refreshDeclarations().outcome == .synced)
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "7.000")
        #expect((await transport.paths).filter { $0.hasSuffix("/events") }.count == 1)
    }

    @Test func expirationPreservesDueReadsButExplicitLogoutDiscardsThem() async throws {
        let transport = SelectiveTransport(inventoryFailures: 1)
        let (engine, store) = try await setup(transport)
        await engine.resume(ownerUID: "owner-a")
        try await enqueue("other", store: store)
        #expect(await engine.refreshDeclarations().outcome == .unavailable(.server))
        await engine.stop()
        await engine.resume(ownerUID: "owner-a")
        #expect(await engine.refreshDeclarations().outcome == .synced)
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "7.000")

        let anotherTransport = SelectiveTransport(inventoryFailures: 1)
        let (another, otherStore) = try await setup(anotherTransport)
        try await enqueue("other", store: otherStore)
        #expect(await another.refreshDeclarations().outcome == .unavailable(.server))
        await another.stop(discardRefreshes: true)
        await another.resume()
        let before = await anotherTransport.paths
        #expect(await another.refreshDeclarations().outcome == .synced)
        #expect(await anotherTransport.paths == before)
    }

    @Test func changingOwnerClearsDueReadsEvenWithoutExplicitLogout() async throws {
        let transport = SelectiveTransport(inventoryFailures: 1)
        let (engine, store) = try await setup(transport)
        await engine.resume(ownerUID: "owner-a")
        try await enqueue("other", store: store)
        #expect(await engine.refreshDeclarations().outcome == .unavailable(.server))
        await engine.stop()
        await engine.resume(ownerUID: "owner-b")
        let before = await transport.paths
        #expect(await engine.refreshDeclarations().outcome == .synced)
        #expect(await transport.paths == before)
    }

    @Test func profilesPreserveAgendaAndReportWithoutFetchingThem() async throws {
        let transport = SelectiveTransport()
        let (engine, store) = try await setup(transport)
        let previous = try await store.snapshot(patient: "other")
        #expect(await engine.refreshProfiles().outcome == .synced)
        let current = try await store.snapshot(patient: "other")
        #expect(current.access?.displayName == "Actualizado")
        #expect(current.doses == previous.doses)
        #expect(current.report == previous.report)
        #expect(Set(await transport.paths) == Set(["/v1/me", "/v1/patients", "/v1/families"]))
    }

    @Test func membershipInvalidatesRemovedPatientsAndLoadsOnlyNewAccesses() async throws {
        let transport = SelectiveTransport(patients: [Fixture.patient, "other", "new"])
        let (engine, store) = try await setup(transport)
        #expect(await engine.refreshMembership().outcome == .unavailable(.denied))
        #expect(try await store.snapshot(patient: "unrelated").access == nil)
        #expect(try await store.snapshot(patient: "new").lastSyncAt != nil)
        let paths = await transport.paths
        #expect(paths.contains("/v1/patients/new/doses"))
        #expect(!paths.contains("/v1/patients/other/doses"))
        #expect(!paths.contains("/v1/patients/\(Fixture.patient)/doses"))
    }

    @Test func leavingPoolRefreshesPreviousMembersWithoutAgenda() async throws {
        let transport = SelectiveTransport()
        let (engine, store) = try await setup(transport, shared: true)
        #expect(await engine.refreshInventory(accounts: ["other-account"], pools: ["shared"]).outcome == .synced)
        #expect(try await store.snapshot(patient: Fixture.patient).inventory.first?.balance == "7.000")
        #expect(try await store.snapshot(patient: "other").inventory.first?.balance == "7.000")
        #expect(Set(await transport.paths) == Set(["/v1/patients/\(Fixture.patient)/inventory", "/v1/patients/other/inventory"]))
    }

    @Test func failedNewPatientSnapshotIsRetriedAfterDirectoryWasSaved() async throws {
        let transport = SelectiveTransport(inventoryFailures: 1, patients: [Fixture.patient, "other", "unrelated", "new"])
        let (engine, store) = try await setup(transport)
        #expect(await engine.refreshMembership().outcome == .unavailable(.server))
        #expect(try await store.snapshot(patient: "new").access != nil)
        #expect(try await store.snapshot(patient: "new").lastSyncAt == nil)
        #expect(await engine.refreshMembership().outcome == .synced)
        #expect(try await store.snapshot(patient: "new").lastSyncAt != nil)
        #expect(try await store.snapshot(patient: "new").inventory.first?.balance == "7.000")
        #expect((await transport.paths).filter { $0 == "/v1/patients/new/doses" }.count == 2)
    }

    @Test func conflictRefreshesHistoricalDoseWithoutDiscardingOperation() async throws {
        let stale = Fixture.dose(id: "other-dose", at: "2026-01-05T12:00:00Z", localDate: "2026-01-05")
        let current = Fixture.dose(id: stale.id, at: stale.scheduledAt, state: .taken, version: 2, eventID: "server-event", localDate: stale.localDate)
        let transport = SelectiveTransport(postStatus: 409, refreshedDose: current)
        let (engine, store) = try await setup(transport)
        try await store.replaceAgenda([stale], from: "2026-01-01", to: "2027-01-01", at: .now, patient: "other")
        try await store.enqueue(try OperationFactory.declaration(.taken, dose: stale, occurredAt: nil, now: .now, patient: "other"))
        #expect(await engine.refreshDeclarations().outcome == .synced)
        let loaded = try await store.snapshot(patient: "other")
        #expect(loaded.doses.first?.version == 2)
        #expect(loaded.doses.first?.eventID == "server-event")
        #expect(loaded.operations.first?.status == .conflict)
        #expect(await transport.doseFrom == ["2026-01-05"])
        #expect(await transport.doseTo == ["2026-01-06"])
    }

    @Test func unknownPoolOrAccountRefreshesAllLocalInventories() async throws {
        let transport = SelectiveTransport()
        let (engine, store) = try await setup(transport)
        #expect(await engine.refreshInventory(accounts: ["uncached-account"], pools: ["uncached-pool"]).outcome == .synced)
        for patient in [Fixture.patient, "other", "unrelated"] {
            #expect(try await store.snapshot(patient: patient).inventory.first?.balance == "7.000")
        }
        #expect((await transport.paths).filter { $0.hasSuffix("/inventory") }.count == 3)
    }

    @Test func profileRefreshLoadsNewAccessInsteadOfSavingAnEmptySnapshot() async throws {
        let transport = SelectiveTransport(patients: [Fixture.patient, "other", "unrelated", "new"])
        let (engine, store) = try await setup(transport)
        #expect(await engine.refreshProfiles().outcome == .synced)
        #expect(try await store.snapshot(patient: "new").lastSyncAt != nil)
        #expect(try await store.snapshot(patient: "new").inventory.first?.balance == "7.000")
        #expect(!(await transport.paths).contains("/v1/patients/other/doses"))
    }

    @Test(arguments: [false, true]) func deniedPatientIsClearedEvenAfterEarlierServerError(selective: Bool) async throws {
        let failures = ["/v1/patients/other/inventory": 500, "/v1/patients/unrelated/inventory": 403]
        let transport = SelectiveTransport(resourceFailures: failures, scopeReduction: selective)
        let (engine, store) = try await setup(transport)
        let outcome = if selective { await engine.refreshMembership().outcome } else { await engine.sync() }
        #expect(outcome == .unavailable(.server))
        #expect(try await store.snapshot(patient: "unrelated").access == nil)
        #expect(try await store.snapshot(patient: "unrelated").inventory.isEmpty)
    }

    @Test(arguments: [false, true]) func unauthorizedPatientExpiresSessionBeforeEarlierServerError(selective: Bool) async throws {
        let failures = ["/v1/patients/other/inventory": 500, "/v1/patients/unrelated/inventory": 401]
        let transport = SelectiveTransport(resourceFailures: failures, scopeReduction: selective)
        let (engine, _) = try await setup(transport)
        let outcome = if selective { await engine.refreshMembership().outcome } else { await engine.sync() }
        #expect(outcome == .sessionExpired)
    }

    @Test func unauthorizedResourceIsNotHiddenBySiblingServerError() async throws {
        let failures = ["/v1/patients/other/treatments": 500, "/v1/patients/other/inventory": 401]
        let transport = SelectiveTransport(resourceFailures: failures)
        let (engine, _) = try await setup(transport)
        #expect(await engine.sync() == .sessionExpired)
    }

    @Test func failedConflictReadRetriesAfterEngineRestartWithoutResendingOperation() async throws {
        let current = Fixture.dose(id: "other-dose", state: .taken, version: 2, eventID: "server-event")
        let transport = SelectiveTransport(postStatus: 409, refreshedDose: current, doseFailures: 1)
        let (engine, store) = try await setup(transport)
        try await enqueue("other", store: store)
        #expect(await engine.refreshDeclarations().outcome == .unavailable(.server))
        #expect(try await store.operations().first?.status == .conflict)
        let restarted = SyncEngine(api: APIClient(baseURL: URL(string: "https://synthetic.invalid")!, transport: transport, tokens: FixedTokens()), store: store)
        #expect(await restarted.refreshDeclarations().outcome == .synced)
        #expect(try await store.snapshot(patient: "other").doses.first?.eventID == "server-event")
        #expect(try await store.operations().first?.status == .conflict)
        #expect((await transport.paths).filter { $0.hasSuffix("/events") }.count == 1)
    }
}

private actor SelectiveTransport: HTTPTransport {
    private let postFailure: Bool
    private var inventoryFailures: Int
    private let patients: [String]
    private var holdPost: Bool
    private var heldPost: CheckedContinuation<Void, Never>?
    private let postStatus: Int?
    private let refreshedDose: Dose?
    private let resourceFailures: [String: Int]
    private let scopeReduction: Bool
    private var doseFailures: Int
    private(set) var paths: [String] = []
    private(set) var doseFrom: [String] = []
    private(set) var doseTo: [String] = []

    init(postFailure: Bool = false, inventoryFailures: Int = 0, patients: [String] = [Fixture.patient, "other", "unrelated"], holdPost: Bool = false, postStatus: Int? = nil, refreshedDose: Dose? = nil, resourceFailures: [String: Int] = [:], scopeReduction: Bool = false, doseFailures: Int = 0) {
        self.postFailure = postFailure
        self.inventoryFailures = inventoryFailures
        self.patients = patients
        self.holdPost = holdPost
        self.postStatus = postStatus
        self.refreshedDose = refreshedDose
        self.resourceFailures = resourceFailures
        self.scopeReduction = scopeReduction
        self.doseFailures = doseFailures
    }

    func waitForPost() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while heldPost == nil {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func releasePost() { holdPost = false; heldPost?.resume(); heldPost = nil }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path()
        paths.append(path)
        var status = resourceFailures[path] ?? 200
        let body: String
        if request.httpMethod == "POST" {
            if holdPost { await withCheckedContinuation { heldPost = $0 } }
            status = resourceFailures[path] ?? postStatus ?? (postFailure ? 500 : 200)
            let dose = path.split(separator: "/")[2]
            body = #"{"dose_id":"\#(dose)","event_id":"synthetic-event","version":2,"state":"taken","balance":"9.500"}"#
        } else if path == "/v1/me" {
            body = #"{"user_id":"\#(Fixture.patient)","display_name":"Actualizado","profile_version":2,"profile_complete":true}"#
        } else if path == "/v1/patients" {
            let scopes = scopeReduction ? #"["read"]"# : #"["read","doses"]"#
            let items = patients.map { #"{"patient_id":"\#($0)","display_name":"Actualizado","scopes":\#(scopes),"profile_version":2,"timezone":"America/Santiago"}"# }.joined(separator: ",")
            body = "{\"items\":[\(items)],\"next_cursor\":\"\"}"
        } else if path.hasSuffix("/inventory") {
            if inventoryFailures > 0 { inventoryFailures -= 1; status = 500 }
            let patient = path.split(separator: "/")[2]
            body = #"{"items":[{"account_id":"\#(patient)-account","treatment_id":"\#(Fixture.treatment)","balance":"7.000","unit":"tablet","scheduled_quantity":"1.000","low_stock":true}],"next_cursor":""}"#
        } else if path.hasSuffix("/adherence") {
            body = #"{"from":"2026-11-06","to":"2026-11-07","summary":{"confirmed":1,"evaluable":1,"unconfirmed":0}}"#
        } else if path.hasSuffix("/doses"), let refreshedDose {
            if doseFailures > 0 { doseFailures -= 1; status = 500 }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            doseFrom.append(query.first { $0.name == "from" }?.value ?? "")
            doseTo.append(query.first { $0.name == "to" }?.value ?? "")
            body = "{\"items\":[\(String(decoding: try JSONEncoder().encode(refreshedDose), as: UTF8.self))],\"next_cursor\":\"\"}"
        } else { body = #"{"items":[],"next_cursor":""}"# }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
