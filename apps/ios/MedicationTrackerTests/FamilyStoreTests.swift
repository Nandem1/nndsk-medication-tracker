import Foundation
import Testing
@testable import MedicationTracker

@Suite struct FamilyStoreTests {
    @Test func notificationsRejectAnotherPatientEvenWithFutureDoses() {
        let dose = Fixture.dose()
        #expect(ReminderPlanner.plan(patient: "other", actor: Fixture.patient, doses: [dose], operations: [], now: .distantPast).isEmpty)
        #expect(ReminderPlanner.plan(patient: Fixture.patient, actor: Fixture.patient, doses: [dose], operations: [], now: .distantPast).count == 1)
    }

    @Test func legacySchemaIsRecreatedAndNewSchemaSurvivesReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SQLiteConnection(path: directory.appending(path: "store.sqlite").path())
        try database.execute("CREATE TABLE doses(id TEXT PRIMARY KEY, payload BLOB)")
        try database.execute("INSERT INTO doses VALUES('old', X'00')")
        let store = try LocalStore(directory: directory)
        #expect(try await store.snapshot(patient: "patient").doses.isEmpty)
        let operation = try OperationFactory.declaration(.skipped, dose: Fixture.dose(), occurredAt: nil, now: .now, patient: "patient")
        try await store.enqueue(operation)
        let reopened = try LocalStore(directory: directory)
        #expect(try await reopened.operations().first?.body == operation.body)
    }

    @Test func revocationKeepsOtherPatientAndDeniedOperationAfterReopening() async throws {
        let (store, directory) = try Fixture.temporaryStore()
        _ = try await store.claim(ownerUID: "cuidador")
        let one = Fixture.dose()
        let two = Fixture.dose(id: "segunda-dosis")
        try await store.replaceAgenda([one], from: "2026-01-01", to: "2027-01-01", at: .now, patient: "uno")
        try await store.replaceAgenda([two], from: "2026-01-01", to: "2027-01-01", at: .now, patient: "dos")
        let operation = try OperationFactory.declaration(.taken, dose: one, occurredAt: nil, now: .now, patient: "uno")
        try await store.enqueue(operation)
        try await store.deny(patient: "uno")
        let reopened = try LocalStore(directory: directory)
        #expect(try await reopened.snapshot(patient: "uno").doses.isEmpty)
        #expect(try await reopened.snapshot(patient: "dos").doses == [two])
        #expect(try await reopened.operations().first?.status == .denied)
        #expect(try await reopened.operations().first?.body == operation.body)
    }

    @Test func oldReplayCannotReplaceNewerConfirmedStock() async throws {
        let (store, _) = try Fixture.temporaryStore()
        let dose = Fixture.dose()
        try await store.replaceAgenda([dose], from: "2026-01-01", to: "2027-01-01", at: .now, patient: "uno")
        var replenished = Fixture.account()
        replenished.balance = "20.000"
        try await store.replaceInventory([replenished], patient: "uno")
        let operation = try OperationFactory.declaration(.taken, dose: dose, occurredAt: nil, now: .now, patient: "uno")
        try await store.enqueue(operation)
        try await store.apply(DoseResult(doseID: dose.id, eventID: "evento", version: 2, state: .taken, balance: "9.500"), for: operation)
        #expect(try await store.snapshot(patient: "uno").inventory.first?.balance == "20.000")
        #expect(try await store.operations().isEmpty)
    }
}
