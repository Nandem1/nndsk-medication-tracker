package cl.nndsk.medication.core

import cl.nndsk.medication.notifications.reminderDoses
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class FamilyTest {
    private val own = Snapshot(PatientContext("firebase", "self", "self"))
    private val access = PatientAccess("other", "link", listOf("read"))
    @Test fun tabsFollowEffectiveAccessAndOwnTreatments() {
        assertEquals(listOf("Hoy", "Historial", "Ajustes"), appTabs(emptyList(), own, false))
        assertEquals(listOf("Pacientes", "Ajustes"), appTabs(listOf(access), own, false))
        assertEquals(listOf("Pacientes", "Ajustes"), appTabs(emptyList(), own, true))
        val both = own.copy(treatments = listOf(Treatment("t", "Sintético", "", "", "tablet")))
        assertEquals(listOf("Hoy", "Historial", "Pacientes", "Ajustes"), appTabs(listOf(access), both, false))
    }
    @Test fun scopeOnlyAllowsTheRequestedAction() {
        val other = own.copy(context = own.context.copy(patientId = "other"), access = access)
        assertFalse(PatientScreen(other, emptyList()).permits("doses"))
        assertFalse(PatientScreen(other, emptyList()).permits("inventory"))
        assertTrue(PatientScreen(other.copy(access = access.copy(scopes = listOf("read", "doses"))), emptyList()).permits("doses"))
        assertTrue(PatientScreen(own, emptyList()).permits("doses"))
        assertFalse(PatientScreen(null, emptyList()).permits("doses"))
    }
    @Test fun acceptsFullInvitationMessage() {
        val token = "a".repeat(41) + "_-"
        assertEquals(token, invitationToken(invitationMessage(token)))
        assertThrows(IllegalArgumentException::class.java) { invitationToken("mensaje sin código") }
    }
    @Test fun foreignFutureDosesNeverScheduleLocalReminders() {
        val now = Instant.now()
        val dose = Dose("d", "t", now.plusSeconds(60).toString(), "2026-11-03", "12:00", "UTC", false, "0.500", "pending", 1)
        val snapshot = own.copy(doses = listOf(dose), context = own.context.copy(patientId = "other"))
        assertTrue(reminderDoses(snapshot, emptyList(), now).isEmpty())
        assertEquals(listOf(dose), reminderDoses(own.copy(doses = listOf(dose)), emptyList(), now))
    }
}
