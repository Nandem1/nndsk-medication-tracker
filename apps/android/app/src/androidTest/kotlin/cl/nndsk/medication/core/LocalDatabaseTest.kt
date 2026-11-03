package cl.nndsk.medication.core

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import android.content.Context
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LocalDatabaseTest {
    @Test fun restartConcurrencyAndAccountIsolation() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val name = "test-${UUID.randomUUID()}.db"
        fun open() = Room.databaseBuilder(context, LocalDatabase::class.java, name).build()
        var db = open()
        try {
            val operation = PendingOperation("stable-id", "owner-a", "patient-a", "dose", "v1/doses/dose/events", "immutable-body", 1)
            val results = (1..10).map { async(Dispatchers.IO) { db.local().enqueue(operation.copy(id = "id-$it")) } }.awaitAll()
            assertEquals(1, results.count { it != -1L })
            val saved = db.local().operations("owner-a", "patient-a").single()
            db.close(); db = open()
            assertEquals(saved, db.local().operations("owner-a", "patient-a").single())
            assertTrue(db.local().operations("owner-b", "patient-a").isEmpty())
            assertTrue(db.local().operations("owner-a", "patient-b").isEmpty())
            db.local().remove("owner-b", "patient-a", saved.id)
            assertEquals(1, db.local().operations("owner-a", "patient-a").size)
            db.local().mark("owner-a", "patient-a", saved.id, "conflict")
            assertEquals("immutable-body", db.local().operations("owner-a", "patient-a").single().body)
            assertEquals("conflict", db.local().operations("owner-a", "patient-a").single().status)
        } finally { db.close(); context.deleteDatabase(name) }
    }
    @Test fun unreadableSessionCanBeRecoveredWithoutCrashing() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val secret = SecretStore(context, "test-corrupt-session.enc")
        java.io.File(context.noBackupFilesDir, "test-corrupt-session.enc").writeText("corrupt")
        try {
            val identity = Identity(secret)
            assertNull(identity.uid)
            assertTrue(identity.storageFailure)
        } finally { secret.clear() }
    }
    @Test fun sessionIsEncryptedAndSurvivesReopen() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = SecretStore(context, "test-identity.enc")
        val credentials = Credentials("synthetic-uid", "synthetic-token", "synthetic-refresh", 123)
        try {
            store.save(credentials)
            assertEquals(credentials, SecretStore(context, "test-identity.enc").read())
            assertFalse(java.io.File(context.noBackupFilesDir, "test-identity.enc").readText().contains("synthetic-token"))
        } finally { store.clear() }
    }
}
