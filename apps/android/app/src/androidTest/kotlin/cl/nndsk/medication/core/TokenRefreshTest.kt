package cl.nndsk.medication.core

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.*
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.RequestBody
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import retrofit2.Response
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class TokenRefreshTest {
    @Test fun concurrentUnauthorizedResponsesRefreshOnceAndRetryEachRequestOnce() = fixture { secret ->
        val refreshes = AtomicInteger()
        val identity = Identity(secret) {
            refreshes.incrementAndGet()
            refreshedTokens()
        }
        val wire = UnauthorizedWire(20)
        val api = Api(identity, wire)
        withTimeout(10_000) {
            coroutineScope { List(20) { async { api.request("v1/me") } }.awaitAll() }
        }
        assertEquals(1, refreshes.get())
        assertEquals(20, wire.oldRequests.get())
        assertEquals(20, wire.newRequests.get())
        assertEquals("fresh-token", secret.read()!!.token)
    }

    @Test fun failedConcurrentRefreshIsSharedButLaterIndependentAttemptCanSucceed() = fixture { secret ->
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val refreshes = AtomicInteger()
        val identity = Identity(secret) {
            if (refreshes.incrementAndGet() == 1) {
                entered.complete(Unit)
                release.await()
                throw ApiFailure(503)
            }
            refreshedTokens()
        }
        withTimeout(10_000) {
            coroutineScope {
                val callers = List(20) { async(start = CoroutineStart.UNDISPATCHED) { runCatching { identity.token(rejectedToken = "old-token") } } }
                entered.await()
                release.complete(Unit)
                callers.awaitAll().forEach { assertEquals(503, (it.exceptionOrNull() as ApiFailure).status) }
            }
            assertEquals(1, refreshes.get())
            assertEquals("fresh-token", identity.token(rejectedToken = "old-token"))
        }
        assertEquals(2, refreshes.get())
    }

    @Test fun cancelledFirstWaiterDoesNotCancelRefreshForOtherWaiters() = fixture { secret ->
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val refreshes = AtomicInteger()
        val identity = Identity(secret) {
            refreshes.incrementAndGet()
            entered.complete(Unit)
            release.await()
            refreshedTokens()
        }
        withTimeout(10_000) {
            coroutineScope {
                val first = async { identity.token(rejectedToken = "old-token") }
                entered.await()
                val second = async(start = CoroutineStart.UNDISPATCHED) { identity.token(rejectedToken = "old-token") }
                first.cancel()
                release.complete(Unit)
                first.join()
                assertEquals("fresh-token", second.await())
            }
        }
        assertEquals(1, refreshes.get())
    }

    @Test fun logoutWaitsForRefreshAndLeavesNoCredentialsToRestore() = fixture { secret ->
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val identity = Identity(secret) {
            entered.complete(Unit)
            release.await()
            refreshedTokens()
        }
        withTimeout(10_000) {
            coroutineScope {
                val refresh = async { identity.token(rejectedToken = "old-token") }
                entered.await()
                val logout = async(start = CoroutineStart.UNDISPATCHED) { identity.clear() }
                release.complete(Unit)
                refresh.await()
                logout.await()
            }
        }
        assertNull(identity.uid)
        assertNull(secret.read())
        assertNull(Identity(secret).uid)
    }

    @Test fun secondUnauthorizedResponseEndsTheRequestWithoutAnotherRefresh() = fixture { secret ->
        val refreshes = AtomicInteger()
        val identity = Identity(secret) { refreshes.incrementAndGet(); refreshedTokens() }
        val wire = UnauthorizedWire(1, rejectFresh = true)
        val failure = runCatching { Api(identity, wire).request("v1/me") }.exceptionOrNull()
        assertEquals(401, (failure as ApiFailure).status)
        assertEquals(1, refreshes.get())
        assertEquals(1, wire.oldRequests.get())
        assertEquals(1, wire.newRequests.get())
    }

    private fun fixture(block: suspend CoroutineScope.(SecretStore) -> Unit) = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val secret = SecretStore(context, "token-refresh-${UUID.randomUUID()}.enc")
        secret.save(Credentials("synthetic-owner", "old-token", "synthetic-refresh", Long.MAX_VALUE))
        try { block(secret) } finally { secret.clear() }
    }

    private fun refreshedTokens() = buildJsonObject {
        put("id_token", "fresh-token"); put("refresh_token", "fresh-refresh"); put("expires_in", "3600")
    }

    private class UnauthorizedWire(private val callers: Int, private val rejectFresh: Boolean = false) : WireApi {
        val oldRequests = AtomicInteger()
        val newRequests = AtomicInteger()
        private val allOldRequests = CompletableDeferred<Unit>()
        override suspend fun get(path: String, token: String, query: Map<String, String>): Response<ResponseBody> {
            if (token == "Bearer old-token") {
                if (oldRequests.incrementAndGet() == callers) allOldRequests.complete(Unit)
                allOldRequests.await()
                return Response.error(401, "{}".toResponseBody())
            }
            assertEquals("Bearer fresh-token", token)
            newRequests.incrementAndGet()
            return if (rejectFresh) Response.error(401, "{}".toResponseBody()) else Response.success("{}".toResponseBody())
        }
        override suspend fun post(path: String, token: String, body: RequestBody): Response<ResponseBody> = error("Unexpected POST")
        override suspend fun put(path: String, token: String, body: RequestBody): Response<ResponseBody> = error("Unexpected PUT")
        override suspend fun delete(path: String, token: String): Response<ResponseBody> = error("Unexpected DELETE")
        override suspend fun deleteBody(path: String, token: String, body: RequestBody): Response<ResponseBody> = error("Unexpected DELETE")
    }
}
