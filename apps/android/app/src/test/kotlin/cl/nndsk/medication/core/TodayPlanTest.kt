package cl.nndsk.medication.core

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

class TodayPlanTest {
    private val day = "2026-11-02"
    private val now = Instant.parse("2026-11-02T21:00:00Z")
    private fun dose(id: String, at: String, state: String = "pending", date: String = day) =
        Dose(id, "t", at, date, "09:00", "America/Santiago", false, "0.500", state, 1)
    private fun operation(dose: String, status: String = "pending") =
        PendingOperation("op-$dose", "o", "p", dose, "v1/doses/$dose/events", "{}", 0, status)

    @Test fun everyDeclarationCountsIncludingSkippedAndUnsent() {
        val skipped = dose("a", "2026-11-02T11:00:00Z", "skipped")
        val unsent = dose("b", "2026-11-02T12:00:00Z")
        val open = dose("c", "2026-11-02T20:00:00Z")
        val plan = todayPlan(listOf(open, skipped, unsent), listOf(operation("b")), now)
        assertEquals(2, plan.registeredCount)
        assertEquals(3, plan.total)
        assertEquals(open, plan.current)
        assertEquals(listOf("a", "b"), plan.registered.map { it.id })
    }
    @Test fun unconfirmedIsNotRegistered() {
        val plan = todayPlan(listOf(dose("a", "2026-11-02T20:00:00Z", "unconfirmed")), emptyList(), now)
        assertEquals(0, plan.registeredCount)
        assertNotNull(plan.current)
    }
    @Test fun conflictsGoToReviewEvenFromAnotherDay() {
        val yesterday = dose("a", "2026-11-01T11:00:00Z", date = "2026-11-01")
        val today = dose("b", "2026-11-02T20:00:00Z")
        val plan = todayPlan(listOf(yesterday, today), listOf(operation("a", "conflict")), now)
        assertEquals(listOf(yesterday), plan.review)
        assertEquals(1, plan.total)
        assertEquals(today, plan.current)
    }
    @Test fun conflictOnDeclaredDoseStillCountsItsServerDeclaration() {
        val plan = todayPlan(listOf(dose("a", "2026-11-02T11:00:00Z", "taken")), listOf(operation("a", "conflict")), now)
        assertEquals(1, plan.registeredCount)
        assertTrue(plan.registered.isEmpty())
    }
    @Test fun remainingOpenDosesGoLaterInOrder() {
        val first = dose("a", "2026-11-02T20:00:00Z"); val second = dose("b", "2026-11-02T22:00:00Z"); val third = dose("c", "2026-11-02T23:00:00Z")
        val plan = todayPlan(listOf(third, first, second), emptyList(), now)
        assertEquals(first, plan.current)
        assertEquals(listOf(second, third), plan.later)
    }
    @Test fun aLongOverdueDoseLeavesTheCardWithoutBecomingSkipped() {
        val old = dose("a", "2026-11-02T16:59:00Z", "unconfirmed")
        val edge = dose("b", "2026-11-02T17:00:00Z", "unconfirmed")
        val plan = todayPlan(listOf(old, edge), emptyList(), now)
        assertEquals(listOf(old), plan.overdue)
        assertEquals(edge, plan.current)
        assertEquals(0, plan.registeredCount)
        assertEquals(2, plan.total)
    }
    @Test fun onlyOverdueDosesLeaveNoCurrentCard() {
        val plan = todayPlan(listOf(dose("a", "2026-11-02T11:00:00Z", "unconfirmed")), emptyList(), now)
        assertNull(plan.current)
        assertEquals(1, plan.overdue.size)
    }
    @Test fun longDateUsesSpanishInTheDoseZone() {
        assertEquals("Lunes, 2 de noviembre", longDate(now, ZoneId.of("America/Santiago")))
    }
}

class LateTimeTest {
    private val now = Instant.parse("2026-11-02T21:00:37Z")
    @Test fun neverMovesIntoTheFuture() {
        val current = LateTime.floorToMinute(now)
        assertTrue(current <= now)
        assertEquals(current, LateTime.stepped(current, 5, now))
        assertFalse(LateTime.canAdvance(current, now))
        val earlier = LateTime.stepped(current, -5, now)
        assertTrue(LateTime.canAdvance(earlier, now))
        assertEquals(current, LateTime.stepped(earlier, 5, now))
        assertEquals(current, LateTime.stepped(current.minusSeconds(180), 5, now))
    }
    @Test fun shortcutsAreRelativeToNow() {
        assertEquals("20:30", LateTime.label(LateTime.ago(30, now), "UTC"))
        assertEquals("20:00", LateTime.label(LateTime.ago(60, now), "UTC"))
    }
    @Test fun labelUsesTheDoseZone() {
        assertEquals("18:00", LateTime.label(now, "America/Santiago"))
    }
    @Test fun detectsARepeatedLocalHour() {
        assertTrue(LateTime.isRepeated(Instant.parse("2026-04-05T02:30:00Z"), "America/Santiago"))
        assertFalse(LateTime.isRepeated(now, "America/Santiago"))
    }
}
