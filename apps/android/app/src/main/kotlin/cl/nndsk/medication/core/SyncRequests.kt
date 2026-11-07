package cl.nndsk.medication.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Sólo se comparte el trabajo que todavía no empezó a leer. */
internal class SyncRequests(private val scope: CoroutineScope, private val changed: () -> Unit = {}) {
    private class Request(val session: Long) {
        val completion = CompletableDeferred<Unit>()
    }
    private val lock = Any()
    private var session = 0L
    private var pending: Request? = null
    private var count = 0
    val busy: Boolean get() = synchronized(lock) { count != 0 }

    suspend fun request(run: suspend (() -> Boolean) -> Unit) {
        var created = false
        val request = synchronized(lock) {
            pending ?: Request(session).also { pending = it; count++; created = true }
        }
        if (created) {
            changed()
            scope.launch {
                try {
                    run {
                        synchronized(lock) {
                            if (pending === request) pending = null
                            request.session == session
                        }
                    }
                    request.completion.complete(Unit)
                } catch (error: Throwable) {
                    request.completion.completeExceptionally(error)
                } finally {
                    synchronized(lock) {
                        if (pending === request) pending = null
                        count--
                    }
                    changed()
                }
            }
        }
        request.completion.await()
    }

    fun barrier() { synchronized(lock) { pending = null } }
    fun invalidate() { synchronized(lock) { session++; pending = null } }
}
