import Foundation
import Testing
@testable import MedicationTracker

@Suite struct FamilyStoreTests {
    @Test func versionOneMigrationPreservesQueueAndOwnerAndRemovesLegacyLinks() async throws {
        let (store, directory) = try Fixture.temporaryStore()
        _ = try await store.claim(ownerUID: "owner")
        let doses = [Fixture.dose(), Fixture.dose(id: "second-dose")]
        try await store.replaceAgenda(doses, from: "2026-01-01", to: "2027-01-01", at: .now, patient: Fixture.patient)
        try await store.replaceInventory([Fixture.account()], patient: Fixture.patient)
        for dose in doses {
            let operation = try OperationFactory.declaration(.taken, dose: dose, occurredAt: nil, now: .now, patient: Fixture.patient)
            try await store.enqueue(operation)
            try await store.markAttempt(operation.id)
            if dose.id == "second-dose" { try await store.mark(operation.id, status: .conflict) }
        }
        let before = try await store.snapshot(patient: Fixture.patient)
        let database = try SQLiteConnection(path: directory.appending(path: "store.sqlite").path())
        try database.execute("CREATE TABLE links(id TEXT PRIMARY KEY, patient_id TEXT NOT NULL, payload BLOB NOT NULL)")
        try database.execute("INSERT INTO links VALUES('legacy', 'patient', X'00')")
        try database.execute("PRAGMA user_version=1")

        let migrated = try LocalStore(directory: directory)
        #expect(try await migrated.snapshot(patient: Fixture.patient) == before)
        #expect(try await migrated.claim(ownerUID: "other-owner") == .otherOwnerHasPending(2))
        #expect(try database.query("SELECT name FROM sqlite_master WHERE type='table' AND name='links'").isEmpty)
        #expect(try database.query("PRAGMA user_version").first?.int("user_version") == 2)
        let reopened = try LocalStore(directory: directory)
        #expect(try await reopened.snapshot(patient: Fixture.patient) == before)
        try await reopened.wipe()
        #expect(try await reopened.snapshot(patient: Fixture.patient) == LocalSnapshot())
    }

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
