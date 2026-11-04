package cl.nndsk.medication.core

import cl.nndsk.medication.notifications.reminderDoses
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class ReminderPlanTest {
    @Test fun onlyFutureUndeclaredDosesWithoutLocalActionsAreScheduled() {
        val now = Instant.parse("2026-11-03T12:00:00Z")
        val future = Dose("future", "t", now.plusSeconds(60).toString(), "2026-11-03", "09:01", "America/Santiago", false, "0.500", "pending", 1)
        val snapshot = Snapshot(PatientContext("owner", "patient", "patient"), listOf(future, future.copy(id = "past", scheduledAt = now.minusSeconds(1).toString()), future.copy(id = "taken", state = "taken"), future.copy(id = "queued")))
        val pending = PendingOperation("op", "owner", "patient", "queued", "path", "{}", 1)
        assertEquals(listOf("future"), reminderDoses(snapshot, listOf(pending), now).map { it.id })
    }
}
