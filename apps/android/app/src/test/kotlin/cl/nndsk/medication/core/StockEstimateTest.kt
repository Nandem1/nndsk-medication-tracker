package cl.nndsk.medication.core

import org.junit.Assert.*
import org.junit.Test

class StockEstimateTest {
    private val dose = Dose("dose", "t", "2026-11-03T12:00:00Z", "2026-11-03", "09:00", "America/Santiago", false, "0.500", "pending", 1)
    private val snapshot = Snapshot(PatientContext("owner", "actor", "patient"), listOf(dose), inventory = listOf(Inventory("t", "10.100", "tablet")))
    private fun operation(type: String) = PendingOperation("id", "owner", "patient", "dose", "path", wireJson.encodeToString(Command("id", 1, type)), 1)
    @Test fun quantitiesUseChileanDecimalNotationWithoutGroupingAmbiguity() {
        assertEquals("0,5", quantityText("0.500"))
        assertEquals("9,5", quantityText("9.500"))
        assertEquals("1000", quantityText("1000.000"))
        assertEquals("0,001", quantityText("0.001"))
    }
    @Test fun fractionalConsumptionIsExactAndOmissionDoesNotConsume() {
        assertEquals("9.600", estimatedBalance(snapshot, listOf(operation("taken")), "t"))
        assertEquals("10.100", estimatedBalance(snapshot, listOf(operation("skipped")), "t"))
    }
    @Test fun correctionReversesAndConflictDoesNotInventBalance() {
        assertEquals("10.600", estimatedBalance(snapshot.copy(doses = listOf(dose.copy(state = "taken"))), listOf(operation("skipped")), "t"))
        assertNull(estimatedBalance(snapshot, listOf(operation("taken").copy(status = "conflict")), "t"))
        assertNull(estimatedBalance(snapshot.copy(doses = listOf(dose.copy(version = 2))), listOf(operation("taken")), "t"))
    }
}
