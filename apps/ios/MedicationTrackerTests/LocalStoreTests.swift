import Foundation
import Testing
@testable import MedicationTracker

@Suite struct LocalStoreTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    /// La ubicación real, con su clase de protección y exclusión de copias, no sólo un directorio temporal.
    @Test func opensTwiceInTheRealLocationExcludedFromBackup() async throws {
        let directory = try LocalStore.defaultDirectory()
        _ = try LocalStore(directory: directory)
        _ = try LocalStore(directory: directory)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        // El simulador no implementa Data Protection: esta comprobación sólo corre en un iPhone.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #endif
    }

    @Test func declarationSurvivesReopeningTheDatabase() async throws {
        let (store, directory) = try Fixture.temporaryStore()
        let operation = try OperationFactory.declaration(.taken, dose: Fixture.dose(), occurredAt: nil, now: now, patient: Fixture.patient)
        try await store.enqueue(operation)

        let reopened = try LocalStore(directory: directory)
        let stored = try await reopened.operations()
        #expect(stored == [operation])
        #expect(stored.first?.body == operation.body)
    }

    @Test func secondTapKeepsTheFirstOperation() async throws {
        let (store, _) = try Fixture.temporaryStore()
        let first = try OperationFactory.declaration(.taken, dose: Fixture.dose(), occurredAt: nil, now: now, patient: Fixture.patient)
        let second = try OperationFactory.declaration(.skipped, dose: Fixture.dose(), occurredAt: nil, now: now, patient: Fixture.patient)
        try await store.enqueue(first)
        let returned = try await store.enqueue(second)

        #expect(returned.id == first.id)
        #expect(try await store.operations().map(\.id) == [first.id])
    }

    @Test func operationsKeepTheirOrder() async throws {
        let (store, _) = try Fixture.temporaryStore()
        let doses = (1 ... 5).map { Fixture.dose(id: "00000000-0000-4000-8000-00000000000\($0)") }
        var ids: [String] = []
        for dose in doses {
            let operation = try OperationFactory.declaration(.taken, dose: dose, occurredAt: nil, now: now, patient: Fixture.patient)
            ids.append(operation.id)
            try await store.enqueue(operation)
        }
        #expect(try await store.operations().map(\.id) == ids)
    }

    @Test func appliedResultUpdatesDoseAndKeepsConfirmedBalanceUntilRefresh() async throws {
        let (store, _) = try Fixture.temporaryStore()
        let dose = Fixture.dose()
        try await store.replaceAgenda([dose], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        try await store.replaceInventory([Fixture.account()], patient: Fixture.patient)
        let operation = try OperationFactory.declaration(.taken, dose: dose, occurredAt: nil, now: now, patient: Fixture.patient)
        try await store.enqueue(operation)

        try await store.apply(DoseResult(doseID: dose.id, eventID: "00000000-0000-4000-8000-0000000000e1", version: 2, state: .taken, balance: "9.500"), for: operation)

        let snapshot = try await store.snapshot(patient: Fixture.patient)
        #expect(snapshot.operations.isEmpty)
        #expect(snapshot.doses.first?.state == .taken)
        #expect(snapshot.doses.first?.version == 2)
        #expect(snapshot.inventory.first?.balance == "10.000")
    }

    @Test func staleAgendaNeverLowersAVersion() async throws {
        let (store, _) = try Fixture.temporaryStore()
        try await store.replaceAgenda([Fixture.dose(state: .taken, version: 2)], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        try await store.replaceAgenda([Fixture.dose(state: .pending, version: 1)], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        #expect(try await store.snapshot(patient: Fixture.patient).doses.first?.state == .taken)
    }

    @Test func cancelledDoseLeavesTheAgendaButItsOperationRemains() async throws {
        let (store, _) = try Fixture.temporaryStore()
        let dose = Fixture.dose()
        try await store.replaceAgenda([dose], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        try await store.enqueue(try OperationFactory.declaration(.taken, dose: dose, occurredAt: nil, now: now, patient: Fixture.patient))
        try await store.replaceAgenda([], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)

        let snapshot = try await store.snapshot(patient: Fixture.patient)
        #expect(snapshot.doses.isEmpty)
        #expect(snapshot.operations.count == 1)
    }

    @Test func refreshOutsideTheWindowKeepsLoadedHistory() async throws {
        let (store, _) = try Fixture.temporaryStore()
        let old = Fixture.dose(id: "00000000-0000-4000-8000-0000000000a1", at: "2026-09-02T12:00:00Z", localDate: "2026-09-02")
        try await store.mergeDoses([old], patient: Fixture.patient)
        try await store.replaceAgenda([], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        #expect(try await store.snapshot(patient: Fixture.patient).doses.map(\.id) == [old.id])
    }

    @Test func otherAccountCannotInheritPendingOperationsWithoutADecision() async throws {
        let (store, _) = try Fixture.temporaryStore()
        #expect(try await store.claim(ownerUID: "persona-a") == .ready)
        try await store.replaceAgenda([Fixture.dose()], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        try await store.enqueue(try OperationFactory.declaration(.taken, dose: Fixture.dose(), occurredAt: nil, now: now, patient: Fixture.patient))

        #expect(try await store.claim(ownerUID: "persona-b") == .otherOwnerHasPending(1))
        #expect(try await store.operations().count == 1)
        #expect(try await store.claim(ownerUID: "persona-a") == .ready)
        #expect(try await store.operations().count == 1)

        #expect(try await store.claim(ownerUID: "persona-b", discardingOtherOwner: true) == .ready)
        let snapshot = try await store.snapshot(patient: Fixture.patient)
        #expect(snapshot.operations.isEmpty)
        #expect(snapshot.doses.isEmpty)
    }

    @Test func otherAccountWithoutPendingStartsClean() async throws {
        let (store, _) = try Fixture.temporaryStore()
        _ = try await store.claim(ownerUID: "persona-a")
        try await store.setPatientID(Fixture.patient)
        try await store.replaceAgenda([Fixture.dose()], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        #expect(try await store.claim(ownerUID: "persona-b") == .ready)
        #expect(try await store.snapshot(patient: Fixture.patient).doses.isEmpty)
        #expect(try await store.patientID() == nil)
    }

    @Test func wipeRemovesEverything() async throws {
        let (store, _) = try Fixture.temporaryStore()
        _ = try await store.claim(ownerUID: "persona-a")
        try await store.replaceAgenda([Fixture.dose()], from: "2026-11-01", to: "2026-11-03", at: now, patient: Fixture.patient)
        try await store.enqueue(try OperationFactory.declaration(.taken, dose: Fixture.dose(), occurredAt: nil, now: now, patient: Fixture.patient))
        try await store.wipe()
        #expect(try await store.snapshot(patient: Fixture.patient) == LocalSnapshot())
    }
}
