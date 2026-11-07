package cl.nndsk.medication.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SyncRequestsTest {
    @Test fun overlappingRequestsWaitForOneFollowingCycle() = runTest {
        val mutex = Mutex()
        val firstRelease = CompletableDeferred<Unit>()
        val nextRelease = CompletableDeferred<Unit>()
        var cycles = 0
        val requests = SyncRequests(backgroundScope)
        suspend fun request() = requests.request { begin -> mutex.withLock {
            if (begin()) {
                cycles++
                if (cycles == 1) firstRelease.await() else nextRelease.await()
            }
        } }
        val first = async { request() }
        runCurrent()
        val second = async { request() }
        val third = async { request() }
        runCurrent()
        assertEquals(1, cycles)
        firstRelease.complete(Unit)
        runCurrent()
        assertTrue(first.isCompleted)
        assertFalse(second.isCompleted)
        assertFalse(third.isCompleted)
        assertEquals(2, cycles)
        assertTrue(requests.busy)
        nextRelease.complete(Unit)
        second.await(); third.await()
        assertEquals(2, cycles)
        assertFalse(requests.busy)
    }

    @Test fun requestAfterSecondCycleBeginsNeedsThirdCycle() = runTest {
        val mutex = Mutex()
        val releases = List(3) { CompletableDeferred<Unit>() }
        var cycles = 0
        val requests = SyncRequests(backgroundScope)
        suspend fun request() = requests.request { begin -> mutex.withLock {
            if (begin()) releases[cycles++].await()
        } }
        val first = async { request() }; runCurrent()
        val second = async { request() }; runCurrent()
        releases[0].complete(Unit); runCurrent()
        val third = async { request() }; runCurrent()
        releases[1].complete(Unit); runCurrent()
        assertEquals(3, cycles)
        assertFalse(third.isCompleted)
        releases[2].complete(Unit)
        first.await(); second.await(); third.await()
    }

    @Test fun cancellingFirstWaiterDoesNotCancelSharedRunner() = runTest {
        val release = CompletableDeferred<Unit>()
        val requests = SyncRequests(backgroundScope)
        var completed = false
        val first = launch { requests.request { begin -> if (begin()) { release.await(); completed = true } } }
        runCurrent()
        first.cancelAndJoin()
        assertTrue(requests.busy)
        release.complete(Unit); runCurrent()
        assertTrue(completed)
        assertFalse(requests.busy)
    }

    @Test fun mutationBarrierPreventsJoiningAnEarlierPendingRefresh() = runTest {
        val mutex = Mutex(locked = true)
        val requests = SyncRequests(backgroundScope)
        var cycles = 0
        suspend fun request() = requests.request { begin -> mutex.withLock { if (begin()) cycles++ } }
        val first = async { request() }; runCurrent()
        requests.barrier()
        val second = async { request() }; runCurrent()
        mutex.unlock()
        first.await(); second.await()
        assertEquals(2, cycles)
    }

    @Test fun oldSessionPendingRequestDoesNotRunAfterInvalidation() = runTest {
        val mutex = Mutex(locked = true)
        val requests = SyncRequests(backgroundScope)
        var cycles = 0
        suspend fun request() = requests.request { begin -> mutex.withLock { if (begin()) cycles++ } }
        val old = async { request() }; runCurrent()
        requests.invalidate()
        val current = async { request() }; runCurrent()
        mutex.unlock()
        old.await(); current.await()
        assertEquals(1, cycles)
        assertFalse(requests.busy)
    }
}
