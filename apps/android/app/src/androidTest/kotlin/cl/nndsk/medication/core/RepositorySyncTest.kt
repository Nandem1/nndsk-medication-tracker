package cl.nndsk.medication.core

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import retrofit2.Response
import java.util.Collections
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class RepositorySyncTest {
    @Test fun independentReadsOverlapAndDeniedPatientDoesNotCancelOthers() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val secrets = SecretStore(context, "test-sync-${UUID.randomUUID()}.enc")
        secrets.save(Credentials("owner", "synthetic-token", "synthetic-refresh", Long.MAX_VALUE))
        val identity = Identity(secrets) { throw ApiFailure(401) }
        val db = Room.inMemoryDatabaseBuilder(context, LocalDatabase::class.java).build()
        val wire = ConcurrentReads()
        val repository = Repository(identity, Api(identity, wire), db)
        try {
            withTimeout(10_000) { repository.restore() }
            assertNotNull(repository.state.value.own)
            assertNotNull(repository.state.value.patients["other"])
            assertNull(repository.state.value.patients["denied"])
            assertNull(repository.state.value.own?.report)
            assertNotNull(repository.state.value.patients["other"]?.report)
            assertFalse(wire.paths.contains("v1/patients/own/adherence"))
            assertTrue(repository.state.value.rejected)
            assertFalse(repository.state.value.busy)
        } finally {
            repository.logout()
            db.close()
            secrets.clear()
        }
    }

    @Test fun laterPatientFailureKeepsEarlierPatientSnapshots() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val secrets = SecretStore(context, "test-sync-failure-${UUID.randomUUID()}.enc")
        secrets.save(Credentials("owner", "synthetic-token", "synthetic-refresh", Long.MAX_VALUE))
        val identity = Identity(secrets) { throw ApiFailure(401) }
        val db = Room.inMemoryDatabaseBuilder(context, LocalDatabase::class.java).build()
        val repository = Repository(identity, Api(identity, ConcurrentReads(500)), db)
        try {
            withTimeout(10_000) { repository.restore() }
            assertNotNull(repository.state.value.own)
            assertNotNull(repository.state.value.patients["other"])
            assertNull(repository.state.value.patients["denied"])
            assertTrue(repository.state.value.message.orEmpty().contains("No se pudo sincronizar"))
            assertFalse(repository.state.value.busy)
        } finally {
            repository.logout()
            db.close()
            secrets.clear()
        }
    }

    private class ConcurrentReads(private val failureStatus: Int = 403) : WireApi {
        val paths = Collections.synchronizedList(mutableListOf<String>())
        private val initialCount = AtomicInteger()
        private val resourceCount = AtomicInteger()
        private val initial = CompletableDeferred<Unit>()
        private val resources = CompletableDeferred<Unit>()
        override suspend fun get(path: String, token: String, query: Map<String, String>): Response<ResponseBody> {
            paths += path
            if (path in listOf("v1/me", "v1/patients", "v1/families")) {
                if (initialCount.incrementAndGet() == 3) initial.complete(Unit)
                initial.await()
            } else if (!path.contains("/denied/")) {
                if (resourceCount.incrementAndGet() == 7) resources.complete(Unit)
                resources.await()
            }
            if (path.contains("/denied/")) return Response.error(failureStatus, "{}".toResponseBody())
            val body = when (path) {
                "v1/me" -> """{"user_id":"own","patients":[]}"""
                "v1/patients" -> """{"items":[{"patient_id":"own","scopes":["read"],"timezone":"America/Santiago"},{"patient_id":"other","scopes":["read"],"timezone":"America/Santiago"},{"patient_id":"denied","scopes":["read"],"timezone":"America/Santiago"}],"next_cursor":""}"""
                "v1/patients/other/adherence" -> """{"from":"2026-11-06","to":"2026-11-07","as_of":"2026-11-06T12:00:00Z","summary":{"confirmed":1,"evaluable":2,"unconfirmed":1}}"""
                else -> """{"items":[],"next_cursor":""}"""
            }
            return Response.success(body.toResponseBody("application/json".toMediaType()))
        }
        override suspend fun post(path: String, token: String, body: RequestBody): Response<ResponseBody> = error("Unexpected POST")
        override suspend fun put(path: String, token: String, body: RequestBody): Response<ResponseBody> = error("Unexpected PUT")
        override suspend fun delete(path: String, token: String): Response<ResponseBody> = error("Unexpected DELETE")
        override suspend fun deleteBody(path: String, token: String, body: RequestBody): Response<ResponseBody> = error("Unexpected DELETE")
    }
}
