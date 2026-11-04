package cl.nndsk.medication.core

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.net.Uri
import android.os.Build
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import cl.nndsk.medication.notifications.Reminders
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.UUID

class ReminderTest {
    @Test fun deniedPermissionFallbackAndPrivateNotification() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val dbName = "reminder-${UUID.randomUUID()}.db"
        val db = Room.databaseBuilder(context, LocalDatabase::class.java, dbName).build()
        val secret = SecretStore(context, "test-reminder-session.enc")
        secret.save(Credentials("reminder-owner", "synthetic", "synthetic", Long.MAX_VALUE))
        val identity = Identity(secret)
        val scheduler = Reminders(context, db, identity)
        val c = PatientContext("reminder-owner", "patient", "patient")
        val now = Instant.now()
        val dose = Dose("dose", "treatment", now.minusSeconds(1).toString(), "2026-11-03", "12:00", "UTC", false, "0.500", "pending", 1)
        val snapshot = Snapshot(c, listOf(dose))
        db.local().save(StoredSnapshot(c.ownerUid, c.patientId, wireJson.encodeToString(snapshot)))
        val uri = Uri.Builder().scheme("medication").authority("dose").appendPath(c.ownerUid).appendPath(c.patientId).appendPath(dose.id).appendQueryParameter("at", dose.scheduledAt).build()
        val manager = context.getSystemService(NotificationManager::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                assertFalse("Use a fresh test package without notification permission", scheduler.permitted())
                scheduler.deliver(uri)
                assertTrue(manager.activeNotifications.isEmpty())
                automation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
            }
            assertTrue(scheduler.permitted())
            if (Build.VERSION.SDK_INT >= 31) {
                assertFalse("Revoke exact alarms for this test package first", scheduler.exact())
                assertTrue(scheduler.diagnostic().contains("Precisión limitada"))
            }
            db.local().save(StoredSnapshot(c.ownerUid, c.patientId, wireJson.encodeToString(snapshot.copy(context = c.copy(actorId = "caregiver")))))
            scheduler.deliver(uri)
            assertTrue("A previously scheduled foreign agenda must never notify", manager.activeNotifications.isEmpty())
            val future = dose.copy(scheduledAt = now.plusSeconds(120).toString())
            db.local().save(StoredSnapshot(c.ownerUid, c.patientId, wireJson.encodeToString(snapshot.copy(doses = listOf(future)))))
            scheduler.reconcile()
            scheduler.deliver(uri)
            assertTrue("Stale alarm must not notify a rescheduled dose", manager.activeNotifications.isEmpty())
            db.local().save(StoredSnapshot(c.ownerUid, c.patientId, wireJson.encodeToString(snapshot)))
            scheduler.deliver(uri)
            val posted = manager.activeNotifications.single().notification
            assertEquals("Abre la app para revisar tu agenda.", posted.extras.getCharSequence("android.text").toString())
            assertEquals(android.app.Notification.VISIBILITY_PRIVATE, posted.visibility)
            assertNotNull(posted.contentIntent)
            identity.clear(); scheduler.reconcile()
            assertTrue(manager.activeNotifications.isEmpty())
            scheduler.deliver(uri)
            assertTrue("A notification from a signed-out owner must not appear", manager.activeNotifications.isEmpty())
        } finally { secret.clear(); manager.cancelAll(); db.close(); context.deleteDatabase(dbName) }
    }
}
