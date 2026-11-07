import Foundation
import Testing
@testable import MedicationTracker

@Suite struct SyncCoordinationTests {
    private func setup(_ transport: SyncBarrierTransport) throws -> (SyncEngine, LocalStore) {
        let (store, _) = try Fixture.temporaryStore()
        let api = APIClient(baseURL: URL(string: "https://synthetic.invalid")!, transport: transport, tokens: FixedTokens())
        return (SyncEngine(api: api, store: store), store)
    }

    @Test func overlappingCallsShareOnlyTheNextCycle() async throws {
        let transport = SyncBarrierTransport(holds: ["/v1/me#1", "/v1/me#2"])
        let (engine, _) = try setup(transport)
        let first = Task { await engine.sync() }
        try await transport.waitFor("/v1/me", count: 1)
        let second = Task { await engine.sync() }
        let third = Task { await engine.sync() }
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#1")
        #expect(await first.value == .synced)
        try await transport.waitFor("/v1/me", count: 2)
        await transport.release("/v1/me#2")
        #expect(await second.value == .synced)
        #expect(await third.value == .synced)
        #expect(await transport.count("/v1/me") == 2)
        #expect(await transport.count("/v1/families") == 2)
    }

    @Test func requestDuringSecondCycleNeedsThirdAndSendsNewOperation() async throws {
        let transport = SyncBarrierTransport(holds: ["/v1/me#1", "/v1/me#2"])
        let (engine, store) = try setup(transport)
        let first = Task { await engine.sync() }
        try await transport.waitFor("/v1/me", count: 1)
        let second = Task { await engine.sync() }
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#1")
        try await transport.waitFor("/v1/me", count: 2)
        let operation = try OperationFactory.declaration(.taken, dose: Fixture.dose(), occurredAt: nil, now: .now, patient: Fixture.patient)
        try await store.enqueue(operation)
        let third = Task { await engine.sync() }
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#2")
        #expect(await first.value == .synced)
        #expect(await second.value == .synced)
        #expect(await third.value == .synced)
        #expect(await transport.count("/v1/me") == 3)
        #expect(try await store.operations().isEmpty)
        #expect(await transport.postBodies == [operation.body])
    }

    @Test func cancellingOneWaiterDoesNotCancelSharedWork() async throws {
        let transport = SyncBarrierTransport(holds: ["/v1/me#1"])
        let (engine, _) = try setup(transport)
        let first = Task { await engine.sync() }
        try await transport.waitFor("/v1/me", count: 1)
        let cancelled = Task { await engine.sync() }
        let survivor = Task { await engine.sync() }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await transport.release("/v1/me#1")
        #expect(await first.value == .synced)
        #expect(await survivor.value == .synced)
        _ = await cancelled.value
        #expect(await transport.count("/v1/me") == 2)
    }

    @Test func historyAndDrainSeparatePendingRefreshes() async throws {
        let transport = SyncBarrierTransport(holds: ["/v1/me#1"])
        let (engine, _) = try setup(transport)
        let first = Task { await engine.sync() }
        try await transport.waitFor("/v1/me", count: 1)
        let second = Task { await engine.sync() }
        try await Task.sleep(for: .milliseconds(30))
        let history = Task { await engine.loadHistory(patient: "history-only", from: "2026-11-01", to: "2026-11-02") }
        try await Task.sleep(for: .milliseconds(30))
        let drain = Task { await engine.drain() }
        try await Task.sleep(for: .milliseconds(30))
        let third = Task { await engine.sync() }
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#1")
        #expect(await first.value == .synced)
        #expect(await second.value == .synced)
        #expect(await history.value == .synced)
        #expect(await drain.value == .synced)
        #expect(await third.value == .synced)
        let requests = await transport.paths
        let meIndices = requests.indices.filter { requests[$0] == "/v1/me" }
        let historyIndex = try #require(requests.firstIndex(of: "/v1/patients/history-only/doses"))
        #expect(meIndices.count == 3)
        #expect(meIndices[1] < historyIndex)
        #expect(historyIndex < meIndices[2])
    }

    @Test func stopRejectsPendingRefreshAndWaitsBeforeWipe() async throws {
        let transport = SyncBarrierTransport(holds: ["/v1/me#1"])
        let (engine, store) = try setup(transport)
        let first = Task { await engine.sync() }
        try await transport.waitFor("/v1/me", count: 1)
        let pending = Task { await engine.sync() }
        try await Task.sleep(for: .milliseconds(30))
        let stop = Task { await engine.stop(); try await store.wipe() }
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#1")
        _ = await first.value
        #expect(await pending.value == .sessionExpired)
        try await stop.value
        #expect(await transport.count("/v1/me") == 1)
        #expect(try await store.profile() == nil)
        #expect(try await store.accesses().isEmpty)
    }

    @Test func resourcesRunConcurrentlyAndOwnReportIsNotRequested() async throws {
        let own = "/v1/patients/\(Fixture.patient)"
        let transport = SyncBarrierTransport(holds: ["/v1/me#1", "\(own)/treatments#1"])
        let (engine, store) = try setup(transport)
        let refresh = Task { await engine.sync() }
        try await transport.waitFor("/v1/me", count: 1)
        try await transport.waitFor("/v1/patients", count: 1)
        try await transport.waitFor("/v1/families", count: 1)
        #expect(await transport.count("\(own)/doses") == 0)
        await transport.release("/v1/me#1")
        try await transport.waitFor("\(own)/treatments", count: 1)
        try await transport.waitFor("\(own)/inventory", count: 1)
        try await transport.waitFor("\(own)/doses", count: 1)
        await transport.release("\(own)/treatments#1")
        #expect(await refresh.value == .synced)
        #expect(await transport.count("\(own)/adherence") == 0)
        #expect(try await store.snapshot(patient: Fixture.patient).access != nil)
    }

    @Test func deniedPatientDoesNotDiscardOtherPatientsAndTheirReports() async throws {
        let transport = SyncBarrierTransport(patients: [Fixture.patient, "denied", "allowed"], denied: ["denied"])
        let (engine, store) = try setup(transport)
        #expect(await engine.sync() == .unavailable(.denied))
        #expect(try await store.snapshot(patient: "denied").access == nil)
        #expect(try await store.snapshot(patient: "allowed").report?.summary.confirmed == 1)
        #expect(try await store.snapshot(patient: Fixture.patient).report == nil)
    }

    @Test func paginatedDosesKeepCursorOrderWhileOtherResourcesRun() async throws {
        let dosesPath = "/v1/patients/\(Fixture.patient)/doses"
        let transport = SyncBarrierTransport(holds: ["\(dosesPath)#1"], pagedDoses: true)
        let (engine, store) = try setup(transport)
        let refresh = Task { await engine.sync() }
        try await transport.waitFor(dosesPath, count: 1)
        try await transport.waitFor("/v1/patients/\(Fixture.patient)/inventory", count: 1)
        #expect(await transport.doseCursors == [""])
        await transport.release("\(dosesPath)#1")
        #expect(await refresh.value == .synced)
        #expect(await transport.doseCursors == ["", "page-2"])
        #expect(try await store.snapshot(patient: Fixture.patient).doses.count == 2)
    }

    @Test func familiesSurviveRecoverablePatientReadFailure() async throws {
        let transport = SyncBarrierTransport(failures: ["/v1/patients/\(Fixture.patient)/inventory": 500])
        let (engine, _) = try setup(transport)
        let result = await engine.syncWithFamilies()
        #expect(result.outcome == .unavailable(.server))
        #expect(result.families?.map(\.id) == ["synthetic-family"])
        #expect(result.sequence > 0)
    }

    @MainActor private func model(_ transport: SyncBarrierTransport) throws -> AppModel {
        let (store, _) = try Fixture.temporaryStore()
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(Credentials(uid: "synthetic-owner", idToken: "token", refreshToken: "refresh", expiresAt: .distantFuture)))
        let config = AppConfig(apiBaseURL: URL(string: "https://synthetic.invalid")!, firebaseAPIKey: "synthetic", firebaseEmulatorOrigin: nil)
        let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets)
        let api = APIClient(baseURL: config.apiBaseURL, transport: transport, tokens: FixedTokens())
        return AppModel(identity: identity, store: store, api: api, sync: SyncEngine(api: api, store: store))
    }

    @Test @MainActor func busyCoversLastCycleAndFamiliesAreReadOncePerCycle() async throws {
        let transport = SyncBarrierTransport(holds: ["/v1/me#2", "/v1/me#3"])
        let model = try model(transport)
        await model.start()
        let first = Task { await model.syncNow() }
        try await transport.waitFor("/v1/me", count: 2)
        let second = Task { await model.syncNow() }
        let third = Task { await model.syncNow() }
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#2")
        await first.value
        try await transport.waitFor("/v1/me", count: 3)
        #expect(model.isSyncing)
        await transport.release("/v1/me#3")
        await second.value
        await third.value
        #expect(!model.isSyncing)
        #expect(await transport.count("/v1/families") == 3)
        await model.signOut()
    }

    @Test @MainActor func logoutCannotPublishJoinedRefreshOrFamilies() async throws {
        let transport = SyncBarrierTransport(holds: ["/v1/me#2"])
        let model = try model(transport)
        await model.start()
        let first = Task { await model.syncNow() }
        try await transport.waitFor("/v1/me", count: 2)
        let second = Task { await model.syncNow() }
        try await Task.sleep(for: .milliseconds(30))
        let logout = Task { await model.signOut() }
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#2")
        await first.value
        await second.value
        await logout.value
        #expect(model.phase == .signedOut)
        #expect(!model.isSyncing)
        #expect(model.profile == nil)
        #expect(model.families == nil)
        #expect(model.accesses.isEmpty)
        #expect(await transport.count("/v1/me") == 2)
    }

    @Test @MainActor func patientFailurePublishesFamiliesButExpiredSessionDoesNot() async throws {
        let inventory = "/v1/patients/\(Fixture.patient)/inventory"
        let recoverable = try model(SyncBarrierTransport(failures: [inventory: 500]))
        await recoverable.start()
        #expect(recoverable.phase == .signedIn)
        #expect(recoverable.families?.map(\.id) == ["synthetic-family"])
        await recoverable.signOut()

        let expired = try model(SyncBarrierTransport(failures: [inventory: 401]))
        await expired.start()
        #expect(expired.phase == .expired)
        #expect(expired.families == nil)
        await expired.signOut()
    }

    @Test @MainActor func profileWriteWaitsForRefreshStartedAfterItsResponse() async throws {
        let transport = SyncBarrierTransport(holds: ["/v1/me#2", "/v1/me#3"])
        let model = try model(transport)
        await model.start()
        let earlier = Task { await model.syncNow() }
        try await transport.waitFor("/v1/me", count: 2)
        let saving = Task { try await model.updateProfile(patient: Fixture.patient, name: "Nombre actualizado", version: 1, operation: UUID().uuidString) }
        try await transport.waitFor("/v1/me/profile", count: 1)
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#2")
        await earlier.value
        try await transport.waitFor("/v1/me", count: 3)
        #expect(model.profile?.displayName == "Persona sintética")
        await transport.release("/v1/me#3")
        try await saving.value
        #expect(model.profile?.displayName == "Nombre actualizado")
        #expect(await transport.count("/v1/me") == 3)
        await model.signOut()
    }

    @Test @MainActor func unauthorizedCycleExpiresSessionEvenWhenNextCycleSucceedsDuringStop() async throws {
        let inventory = "/v1/patients/\(Fixture.patient)/inventory"
        let transport = SyncBarrierTransport(holds: ["\(inventory)#2", "/v1/me#3"], failuresByOccurrence: ["\(inventory)#2": 401, "\(inventory)#3": 401])
        let (store, _) = try Fixture.temporaryStore()
        let secrets = MemorySecrets()
        try secrets.write(JSONEncoder().encode(Credentials(uid: "synthetic-owner", idToken: "token", refreshToken: "refresh", expiresAt: .distantFuture)))
        let config = AppConfig(apiBaseURL: URL(string: "https://synthetic.invalid")!, firebaseAPIKey: "synthetic", firebaseEmulatorOrigin: nil)
        let identity = IdentityStore(client: FirebaseIdentityClient(config: config, transport: transport), secrets: secrets)
        let api = APIClient(baseURL: config.apiBaseURL, transport: transport, tokens: FixedTokens())
        let engine = SyncEngine(api: api, store: store)
        let model = AppModel(identity: identity, store: store, api: api, sync: engine)
        await model.start()
        let first = Task(priority: .low) { await model.syncNow() }
        try await transport.waitFor(inventory, count: 2)
        let next = Task(priority: .high) { await model.syncNow() }
        try await Task.sleep(for: .milliseconds(30))

        let nextStarted = DispatchSemaphore(value: 0)
        let advance = Task.detached {
            defer { nextStarted.signal() }
            await transport.release("\(inventory)#2")
            try await transport.waitFor("/v1/me", count: 3)
        }
        // Retiene la publicación del 401 en MainActor hasta que el motor inicia el ciclo siguiente.
        func waitForNextStart() -> Bool { nextStarted.wait(timeout: .now() + 3) == .success }
        #expect(waitForNextStart())
        try await advance.value
        try await Task.sleep(for: .milliseconds(30))
        await transport.release("/v1/me#3")
        await next.value
        await first.value
        #expect(model.phase == .expired)
        #expect(model.syncProblem == .unauthenticated)
        #expect(await engine.sync() == .sessionExpired)
        await model.signOut()
    }
}

actor SyncBarrierTransport: HTTPTransport {
    private var holds: Set<String>
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private let patients: [String]
    private let denied: Set<String>
    private let failures: [String: Int]
    private let failuresByOccurrence: [String: Int]
    private let pagedDoses: Bool
    private var displayName = "Persona sintética"
    private(set) var paths: [String] = []
    private(set) var postBodies: [Data] = []
    private(set) var doseCursors: [String] = []

    init(holds: Set<String> = [], patients: [String] = [Fixture.patient], denied: Set<String> = [], failures: [String: Int] = [:], pagedDoses: Bool = false, failuresByOccurrence: [String: Int] = [:]) {
        self.holds = holds
        self.patients = patients
        self.denied = denied
        self.failures = failures
        self.failuresByOccurrence = failuresByOccurrence
        self.pagedDoses = pagedDoses
    }

    func count(_ path: String) -> Int { paths.filter { $0 == path }.count }

    func waitFor(_ path: String, count target: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while count(path) < target {
            if ContinuousClock.now >= deadline {
                for continuation in continuations.values { continuation.resume() }
                continuations = [:]; holds = []
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func release(_ key: String) {
        holds.remove(key)
        continuations.removeValue(forKey: key)?.resume()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path()
        paths.append(path)
        let capturedName = displayName
        let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value ?? ""
        if path.hasSuffix("/doses") { doseCursors.append(cursor) }
        let key = "\(path)#\(count(path))"
        if holds.contains(key) { await withCheckedContinuation { continuations[key] = $0 } }
        let status = failuresByOccurrence[key] ?? failures[path] ?? (denied.contains(where: { path.contains("/patients/\($0)/") }) ? 403 : 200)
        let body: String
        if request.httpMethod == "PUT", path == "/v1/me/profile" {
            let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            displayName = payload?["display_name"] as? String ?? displayName
            body = "{}"
        } else if request.httpMethod == "POST" {
            postBodies.append(request.httpBody ?? Data())
            body = #"{"dose_id":"00000000-0000-4000-8000-0000000000d1","event_id":"00000000-0000-4000-8000-0000000000e1","version":2,"state":"taken","balance":"9.500"}"#
        } else if path == "/v1/me" {
            body = #"{"user_id":"\#(Fixture.patient)","display_name":"\#(capturedName)","profile_complete":true,"profile_version":1,"timezone":"America/Santiago"}"#
        } else if path == "/v1/families" {
            body = #"{"items":[{"family_id":"synthetic-family","name":"Familia sintética","role":"admin","members":[]}],"next_cursor":""}"#
        } else if path == "/v1/patients" {
            let items = patients.map { #"{"patient_id":"\#($0)","scopes":["read","doses"],"profile_version":1,"timezone":"America/Santiago"}"# }.joined(separator: ",")
            body = "{\"items\":[\(items)],\"next_cursor\":\"\"}"
        } else if path.hasSuffix("/adherence") {
            body = #"{"from":"2026-11-06","to":"2026-11-07","summary":{"confirmed":1,"evaluable":2,"unconfirmed":1}}"#
        } else if pagedDoses, path.hasSuffix("/doses") {
            let dose = Fixture.dose(id: cursor.isEmpty ? "first-page-dose" : "second-page-dose")
            let encoded = String(decoding: try JSONEncoder().encode(dose), as: UTF8.self)
            body = "{\"items\":[\(encoded)],\"next_cursor\":\"\(cursor.isEmpty ? "page-2" : "")\"}"
        } else {
            body = #"{"items":[],"next_cursor":""}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
