package cl.nndsk.medication.core

import android.app.NotificationManager
import androidx.test.core.app.ApplicationProvider
import cl.nndsk.medication.BuildConfig
import cl.nndsk.medication.MedicationApplication
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class RebootReminderTest {
    private val app get() = ApplicationProvider.getApplicationContext<MedicationApplication>()
    @Test fun prepare() = runBlocking {
        assertEquals("e2e", BuildConfig.BUILD_TYPE)
        SecretStore(app).save(Credentials("synthetic-reboot-owner", "synthetic-token", "synthetic-refresh", Long.MAX_VALUE))
        val c = PatientContext("synthetic-reboot-owner", "synthetic-actor", "synthetic-patient")
        val scheduled = Instant.now().plusSeconds(120)
        val dose = Dose("synthetic-reboot-dose", "synthetic-treatment", scheduled.toString(), "2026-11-03", "12:00", "UTC", false, "0.500", "pending", 1)
        app.database.local().save(StoredSnapshot(c.ownerUid, c.patientId, wireJson.encodeToString(Snapshot(c, listOf(dose)))))
        assertTrue(app.reminders.exact())
        assertTrue(app.reminders.permitted())
        app.reminders.reconcile()
    }
}
