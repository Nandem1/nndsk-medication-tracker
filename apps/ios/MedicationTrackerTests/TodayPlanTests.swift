import Foundation
import Testing
@testable import MedicationTracker

@Suite struct TodayPlanTests {
    private let day = "2026-11-02"
    /// 18:00 en America/Santiago.
    private let now = Instant.parse("2026-11-02T21:00:00Z")!

    private func dose(_ suffix: String, at: String, state: DoseState = .pending, date: String? = nil) -> Dose {
        Fixture.dose(id: "00000000-0000-4000-8000-0000000000\(suffix)", at: at, state: state, localDate: date ?? day)
    }

    private func operation(for dose: Dose, status: OperationStatus = .pending) throws -> PendingOperation {
        var value = try OperationFactory.declaration(.skipped, dose: dose, occurredAt: nil, now: now, patient: Fixture.patient)
        value.status = status
        return value
    }

    @Test func everyDeclarationCountsIncludingSkippedAndUnsent() throws {
        let skipped = dose("a1", at: "2026-11-02T11:00:00Z", state: .skipped)
        let unsent = dose("a2", at: "2026-11-02T12:00:00Z")
        let open = dose("a3", at: "2026-11-02T20:00:00Z")
        let plan = TodayPlan(doses: [open, skipped, unsent], operations: [try operation(for: unsent)], now: now)
        #expect(plan.registeredCount == 2)
        #expect(plan.total == 3)
        #expect(plan.current == open)
        #expect(plan.registered.map(\.id) == [skipped.id, unsent.id])
    }

    @Test func unconfirmedIsNotRegistered() {
        let plan = TodayPlan(doses: [dose("a1", at: "2026-11-02T20:00:00Z", state: .unconfirmed)], operations: [], now: now)
        #expect(plan.registeredCount == 0)
        #expect(plan.current != nil)
    }

    @Test func conflictsGoToReviewEvenFromAnotherDay() throws {
        let yesterday = dose("a1", at: "2026-11-01T11:00:00Z", date: "2026-11-01")
        let today = dose("a2", at: "2026-11-02T20:00:00Z")
        let plan = TodayPlan(doses: [yesterday, today], operations: [try operation(for: yesterday, status: .conflict)], now: now)
        #expect(plan.review == [yesterday])
        #expect(plan.total == 1)
        #expect(plan.current == today)
    }

    @Test func aConflictOnADeclaredDoseStillCountsItsServerDeclaration() throws {
        let declared = dose("a1", at: "2026-11-02T11:00:00Z", state: .taken)
        let plan = TodayPlan(doses: [declared], operations: [try operation(for: declared, status: .conflict)], now: now)
        #expect(plan.registeredCount == 1)
        #expect(plan.registered.isEmpty)
    }

    @Test func aLongOverdueDoseLeavesTheCardWithoutBecomingSkipped() {
        let old = dose("a1", at: "2026-11-02T16:59:00Z", state: .unconfirmed)
        let edge = dose("a2", at: "2026-11-02T17:00:00Z", state: .unconfirmed)
        let plan = TodayPlan(doses: [old, edge], operations: [], now: now)
        #expect(plan.overdue == [old])
        #expect(plan.current == edge)
        #expect(plan.registeredCount == 0)
        #expect(plan.total == 2)
    }

    @Test func onlyOverdueDosesLeaveNoCurrentCard() {
        let plan = TodayPlan(doses: [dose("a1", at: "2026-11-02T11:00:00Z", state: .unconfirmed)], operations: [], now: now)
        #expect(plan.current == nil)
        #expect(plan.overdue.count == 1)
    }

    @Test func remainingOpenDosesGoLaterInOrder() {
        let first = dose("a1", at: "2026-11-02T20:00:00Z")
        let second = dose("a2", at: "2026-11-02T22:00:00Z")
        let third = dose("a3", at: "2026-11-02T23:00:00Z")
        let plan = TodayPlan(doses: [third, first, second], operations: [], now: now)
        #expect(plan.current == first)
        #expect(plan.later == [second, third])
    }
}

@Suite struct LateTimeTests {
    private let now = Instant.parse("2026-11-02T21:00:37Z")!

    @Test func neverMovesIntoTheFuture() {
        let current = LateTime.floorToMinute(now)
        #expect(current <= now)
        #expect(LateTime.stepped(current, minutes: 5, now: now) == current)
        #expect(!LateTime.canAdvance(current, now: now))
        let earlier = LateTime.stepped(current, minutes: -5, now: now)
        #expect(LateTime.canAdvance(earlier, now: now))
        #expect(LateTime.stepped(earlier, minutes: 5, now: now) == current)
        // Desde hace 3 minutos, +5 se detiene en el minuto actual.
        #expect(LateTime.stepped(current.addingTimeInterval(-180), minutes: 5, now: now) == current)
    }

    @Test func shortcutsAreRelativeToNow() {
        #expect(LateTime.label(LateTime.ago(minutes: 30, now: now), timezone: "UTC") == "20:30")
        #expect(LateTime.label(LateTime.ago(minutes: 60, now: now), timezone: "UTC") == "20:00")
    }

    @Test func labelUsesTheDoseZoneIn24Hours() {
        #expect(LateTime.label(now, timezone: "America/Santiago") == "18:00")
        #expect(LateTime.label(Instant.parse("2026-11-02T03:05:00Z")!, timezone: "UTC") == "03:05")
    }

    /// El 2026-04-05 a las 00:00 Santiago atrasa a las 23:00 del día anterior.
    @Test func detectsARepeatedLocalHour() {
        #expect(LateTime.isRepeated(Instant.parse("2026-04-05T02:30:00Z")!, timezone: "America/Santiago"))
        #expect(!LateTime.isRepeated(Instant.parse("2026-11-02T21:00:00Z")!, timezone: "America/Santiago"))
    }
}
