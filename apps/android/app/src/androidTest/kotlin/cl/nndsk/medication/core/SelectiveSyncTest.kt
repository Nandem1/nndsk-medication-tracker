package cl.nndsk.medication.core

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import retrofit2.Response
import java.io.IOException
import java.util.Collections
import java.util.UUID

class SelectiveSyncTest {
    @Test fun declarationRefreshesSharedInventoryAndReportsWithoutReloadingAgenda() = fixture {
        repository.record(snapshots[1].context, "dose-a", Command("declare-a", 1, "taken"))
        assertEquals("19.500", repository.state.value.patients["a"]!!.inventory.single().balance)
        assertEquals("19.500", repository.state.value.patients["b"]!!.inventory.single().balance)
        assertEquals(2, repository.state.value.patients["a"]!!.report!!.summary.confirmed)
        assertTrue(wire.gets.contains("v1/patients/a/inventory"))
        assertTrue(wire.gets.contains("v1/patients/b/inventory"))
        assertFalse(wire.gets.any { it.endsWith("/doses") || it.endsWith("/treatments") })
        assertFalse(wire.gets.any { it.contains("/unrelated/") })
        assertTrue(repository.state.value.operations.isEmpty())
    }

    @Test fun conflictRefreshesCurrentDoseWithoutRemovingTheRejectedOperation() = fixture {
        wire.conflictResponse = true
        repository.record(snapshots[1].context, "dose-a", Command("declare-a", 1, "taken"))
        val dose = repository.state.value.patients["a"]!!.doses.single()
        assertEquals(3, dose.version)
        assertEquals("event-from-other-actor", dose.eventId)
        assertEquals("taken_late", dose.state)
        assertEquals("conflict", repository.state.value.operations.single().status)
        assertTrue(wire.gets.contains("v1/patients/a/doses"))
        assertFalse(wire.gets.any { it.endsWith("/doses") && !it.contains("/a/") })
    }

    @Test fun profileRefreshRetriesInventoryLeftDirtyByAnEarlierPost() = fixture {
        wire.failInventory = "a"
        repository.record(snapshots[1].context, "dose-a", Command("declare-a", 1, "taken"))
        wire.failInventory = null
        wire.gets.clear()
        repository.updateProfile("unrelated", "Nuevo", 1, "profile-unrelated")
        assertTrue(wire.gets.contains("v1/patients/a/inventory"))
        assertEquals("19.500", repository.state.value.patients["a"]!!.inventory.single().balance)
    }

    @Test fun failedConflictReadIsRetriedWithoutRemovingConflict() = fixture {
        wire.conflictResponse = true
        wire.failDoses = true
        repository.record(snapshots[1].context, "dose-a", Command("declare-a", 1, "taken"))
        assertEquals(1, repository.state.value.patients["a"]!!.doses.single().version)
        wire.failDoses = false
        repository.updateProfile("unrelated", "Nuevo", 1, "profile-unrelated")
        assertEquals(3, repository.state.value.patients["a"]!!.doses.single().version)
        assertEquals("conflict", repository.state.value.operations.single().status)
    }

    @Test fun historicalConflictKeepsItsDateAcrossFullRefreshFailureAndRestart() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val databaseName = "historical-conflict-${UUID.randomUUID()}.db"
        val secret = SecretStore(context, "historical-conflict-${UUID.randomUUID()}.enc")
        secret.save(Credentials("owner", "synthetic-token", "synthetic-refresh", Long.MAX_VALUE))
        fun open() = Room.databaseBuilder(context, LocalDatabase::class.java, databaseName).build()
        var db = open()
        val wire = RecordingWire().apply { conflictResponse = true; conflictDay = "2025-01-02"; failHistoricalDoses = true }
        var identity = Identity(secret) { throw ApiFailure(401) }
        var repository = Repository(identity, Api(identity, wire), db)
        try {
            val patient = accesses.single { it.patientId == "a" }
            val dose = Dose("dose-a", "treatment-a", "2025-01-02T12:00:00Z", "2025-01-02", "09:00", "America/Santiago", false, "0.500", "unconfirmed", 1)
            val snapshot = Snapshot(PatientContext("owner", "own", "a"), doses = listOf(dose, dose.copy(id = "old-untracked")), access = patient)
            db.local().save(StoredSnapshot("owner", "a", wireJson.encodeToString(snapshot)))
            repository.setUse(true)
            repository.record(snapshot.context, dose.id, Command("historical-declaration", 1, "taken"))
            repository.sync()
            db.close()
            db = open()
            identity = Identity(secret) { throw ApiFailure(401) }
            repository = Repository(identity, Api(identity, wire), db)
            wire.failHistoricalDoses = false
            wire.doseQueries.clear()
            repository.restore()
            assertTrue(wire.doseQueries.any { it.first == "v1/patients/a/doses" && it.second["from"] == "2025-01-02" && it.second["to"] == "2025-01-03" })
            assertEquals(3, repository.state.value.patients["a"]!!.doses.single { it.id == "dose-a" }.version)
            assertEquals("event-from-other-actor", repository.state.value.patients["a"]!!.doses.single { it.id == "dose-a" }.eventId)
            assertFalse(repository.state.value.patients["a"]!!.doses.any { it.id == "old-untracked" })
            assertEquals("conflict", repository.state.value.operations.single().status)
        } finally { repository.logout(); db.close(); secret.clear(); context.deleteDatabase(databaseName) }
    }

    @Test fun knownDenialIsAppliedEvenWhenAnEarlierPatientFailed() = fixture {
        wire.failReads = mapOf("a" to 500, "b" to 403)
        repository.sync()
        assertNull(repository.state.value.patients["b"])
        assertNotNull(repository.state.value.patients["a"])
    }

    @Test fun knownExpiredSessionTakesPriorityOverEarlierServerFailure() = fixture {
        wire.failReads = mapOf("a" to 500, "b" to 401)
        repository.sync()
        assertEquals(Session.Expired, repository.state.value.session)
    }

    @Test fun oneDrainRefreshesEveryPatientItApplied() = fixture {
        val pending = Command("previous-a", 1, "taken")
        db.local().enqueue(PendingOperation(pending.id, "owner", "a", "dose-a", "v1/doses/dose-a/events", wireJson.encodeToString(pending), 1))
        repository.record(snapshots[3].context, "dose-unrelated", Command("declare-unrelated", 1, "taken"))
        assertTrue(repository.state.value.operations.isEmpty())
        assertTrue(wire.gets.containsAll(listOf("v1/patients/a/inventory", "v1/patients/b/inventory", "v1/patients/unrelated/inventory", "v1/patients/a/adherence", "v1/patients/unrelated/adherence")))
        assertFalse(wire.gets.any { it.endsWith("/doses") || it.endsWith("/treatments") })
    }

    @Test fun lostPostResponseKeepsOperationAndDoesNotReadItsPoolInventory() = fixture {
        wire.loseResponse = true
        repository.record(snapshots[1].context, "dose-a", Command("declare-a", 1, "taken"))
        assertTrue(wire.gets.isEmpty())
        assertEquals(1, repository.state.value.operations.count { it.status == "pending" })
        wire.gets.clear()
        repository.inventory("b", "account-b", "1.000", false, "", "movement-b", "20.000")
        assertFalse(wire.gets.any { it.endsWith("/inventory") && (it.contains("/a/") || it.contains("/b/")) })
        assertEquals("20.000", repository.state.value.patients["a"]!!.inventory.single().balance)
    }

    @Test fun failedGetAfterAppliedPostIsRetriedByNextSelectiveRefresh() = fixture {
        wire.failInventory = "a"
        repository.record(snapshots[1].context, "dose-a", Command("declare-a", 1, "taken"))
        assertTrue(repository.state.value.operations.isEmpty())
        assertEquals("20.000", repository.state.value.patients["a"]!!.inventory.single().balance)
        wire.failInventory = null
        wire.gets.clear()
        repository.record(snapshots[3].context, "dose-unrelated", Command("declare-unrelated", 1, "taken"))
        assertTrue(wire.gets.contains("v1/patients/a/inventory"))
        assertEquals("19.500", repository.state.value.patients["a"]!!.inventory.single().balance)
    }

    @Test fun profileOnlyRefreshesNamesAndPreservesAgendaAndReports() = fixture {
        repository.updateProfile("a", "Nuevo", 1, "profile-a")
        assertEquals(setOf("v1/me", "v1/patients", "v1/families"), wire.gets.toSet())
        val updated = repository.state.value.patients["a"]!!
        assertEquals("Nuevo", updated.access!!.displayName)
        assertEquals(snapshots[1].doses, updated.doses)
        assertEquals(snapshots[1].report, updated.report)
    }

    @Test fun familyRefreshLoadsOnlyNewPatientsAndRemovesRevokedOnes() = fixture {
        wire.accesses = accesses.filter { it.patientId != "b" } + PatientAccess("new", scopes = listOf("read"), timezone = "America/Santiago")
        repository.createFamily("Familia", "family-create")
        assertNull(repository.state.value.patients["b"])
        assertNotNull(repository.state.value.patients["new"])
        assertTrue(wire.gets.contains("v1/patients/new/doses"))
        assertFalse(wire.gets.any { it.endsWith("/doses") && !it.contains("/new/") })
    }

    @Test fun leavingPoolRefreshesPreviousLocalMembersOnly() = fixture {
        repository.leavePool("pool", "account-a", "leave-a")
        assertEquals(setOf("v1/patients/a/inventory", "v1/patients/b/inventory"), wire.gets.toSet())
    }

    private fun fixture(block: suspend Fixture.() -> Unit) = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val secret = SecretStore(context, "selective-${UUID.randomUUID()}.enc")
        secret.save(Credentials("owner", "synthetic-token", "synthetic-refresh", Long.MAX_VALUE))
        val identity = Identity(secret) { throw ApiFailure(401) }
        val db = Room.inMemoryDatabaseBuilder(context, LocalDatabase::class.java).build()
        val wire = RecordingWire()
        val repository = Repository(identity, Api(identity, wire), db)
        val snapshots = accesses.map { access ->
            val id = access.patientId
            Snapshot(PatientContext("owner", "own", id),
                doses = listOf(Dose("dose-$id", "treatment-$id", "2026-11-06T12:00:00Z", "2026-11-06", "09:00", "America/Santiago", false, "0.500", "unconfirmed", 1)),
                inventory = listOf(Inventory("treatment-$id", "20.000", "comprimido", "account-$id", pool = if (id in listOf("a", "b")) InventoryPool("pool", "active") else null)),
                access = access, profile = if (id == "own") Me("own", accesses) else null,
                report = if (id == "own") null else DailyReport("2026-11-06", "2026-11-07", "2026-11-06T12:00:00Z", DailyCounts(1, 2, 1)))
        }
        try {
            snapshots.forEach { db.local().save(StoredSnapshot("owner", it.context.patientId, wireJson.encodeToString(it))) }
            repository.setUse(true)
            Fixture(repository, wire, snapshots, db).block()
        } finally { repository.logout(); db.close(); secret.clear() }
    }

    private data class Fixture(val repository: Repository, val wire: RecordingWire, val snapshots: List<Snapshot>, val db: LocalDatabase)
    private class RecordingWire : WireApi {
        val gets = Collections.synchronizedList(mutableListOf<String>())
        val doseQueries = Collections.synchronizedList(mutableListOf<Pair<String, Map<String, String>>>())
        var conflictDay = "2026-11-06"
        var failHistoricalDoses = false
        var failDoses = false
        var failReads = emptyMap<String, Int>()
        var conflictResponse = false
        var loseResponse = false
        var failInventory: String? = null
        var accesses = SelectiveSyncTest.accesses
        override suspend fun get(path: String, token: String, query: Map<String, String>): Response<ResponseBody> {
            gets += path
            val patient = path.split('/').getOrNull(2)
            failReads[patient]?.let { status ->
                if (status == 401) throw ApiFailure(401)
                return Response.error(status, "{}".toResponseBody())
            }
            if (path.endsWith("/doses")) {
                doseQueries += path to query.toMap()
                if (failHistoricalDoses && query["from"] == conflictDay) throw IOException("Synthetic historical dose GET failure")
            }
            if (path.endsWith("/doses") && failDoses) throw IOException("Synthetic dose GET failure")
            if (path.endsWith("/inventory") && patient == failInventory) throw IOException("Synthetic response loss")
            val body = when {
                path == "v1/me" -> wireJson.encodeToString(Me("own", accesses, displayName = "Nuevo"))
                path == "v1/patients" -> wireJson.encodeToString(Page(accesses.map { if (it.patientId == "a") it.copy(displayName = "Nuevo", profileVersion = 2) else it }))
                path.endsWith("/inventory") -> wireJson.encodeToString(Page(listOf(Inventory("treatment-$patient", "19.500", "comprimido", "account-$patient", lowStock = true, pool = if (patient in listOf("a", "b")) InventoryPool("pool", "active") else null))))
                path.endsWith("/doses") && conflictResponse && conflictDay >= query.getValue("from") && conflictDay < query.getValue("to") -> wireJson.encodeToString(Page(listOf(Dose("dose-$patient", "treatment-$patient", "${conflictDay}T12:00:00Z", conflictDay, "09:00", "America/Santiago", false, "0.500", "taken_late", 3, "event-from-other-actor"))))
                path.endsWith("/adherence") -> wireJson.encodeToString(DailyReport("2026-11-06", "2026-11-07", "2026-11-06T12:00:00Z", DailyCounts(2, 2, 0)))
                else -> """{"items":[],"next_cursor":""}"""
            }
            return response(body)
        }
        override suspend fun post(path: String, token: String, body: RequestBody): Response<ResponseBody> {
            if (path.contains("/doses/")) {
                if (conflictResponse) return Response.error(409, "{}".toResponseBody())
                if (loseResponse) throw IOException("Synthetic lost POST response")
                val dose = path.split('/')[2]
                return response(wireJson.encodeToString(DoseResult(dose, "event-$dose", 2, "taken", "9.500")))
            }
            return response("{}")
        }
        override suspend fun put(path: String, token: String, body: RequestBody) = response("{}")
        override suspend fun delete(path: String, token: String) = response("{}")
        override suspend fun deleteBody(path: String, token: String, body: RequestBody) = response("{}")
        private fun response(body: String) = Response.success(body.toResponseBody("application/json".toMediaType()))
    }
    companion object {
        private val accesses = listOf("own", "a", "b", "unrelated").map { PatientAccess(it, scopes = listOf("read", "doses", "inventory", "treatments"), timezone = "America/Santiago") }
    }
}
