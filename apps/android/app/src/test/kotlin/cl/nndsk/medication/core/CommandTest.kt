package cl.nndsk.medication.core

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import kotlinx.serialization.json.*

class CommandTest {
    private val now = Instant.parse("2026-09-06T04:30:00Z")
    private fun dose(state: String = "pending") = Dose("dose", "treatment", now.toString(), "2026-09-06", "01:30", "America/Santiago", false, "0.500", state, 3, if (state == "pending") null else "previous-event")
    @Test fun takenFixesTheOfflineTimeAndDoesNotSendCorrectionFields() {
        val command = declaration(dose(), "taken", null, null, now)
        assertEquals(now.toString(), command.occurredAt)
        val json = wireJson.parseToJsonElement(wireJson.encodeToString(command)).jsonObject
        assertFalse(json.containsKey("corrects_event_id"))
        assertFalse(json.containsKey("reason"))
        assertEquals(3, command.version)
    }
    @Test(expected = IllegalArgumentException::class) fun lateRequiresExplicitTime() { declaration(dose(), "taken_late", null, null, now) }
    @Test fun omittedDoesNotBecomeTakenAndHasNoTimestamp() {
        val command = declaration(dose(), "skipped", now, null, now)
        assertNull(command.occurredAt)
        assertEquals("skipped", command.eventType)
        assertEquals("Sin confirmar", stateLabel(dose(), now.plusSeconds(1)))
    }
    @Test fun correctionReferencesHistoryAndRequiresReason() {
        val command = declaration(dose("taken"), "skipped", null, "Error de registro", now)
        assertEquals("previous-event", command.corrects)
        assertEquals("Error de registro", command.reason)
    }
    @Test(expected = IllegalArgumentException::class) fun correctionRejectsMissingReason() { declaration(dose("taken"), "skipped", null, " ", now) }
    @Test fun todayUsesScheduleZoneAcrossDst() {
        assertFalse(dose().today(Instant.parse("2026-09-06T03:30:00Z")))
        assertTrue(dose().today(now))
    }
}
