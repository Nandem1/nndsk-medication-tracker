package cl.nndsk.medication.core

import org.junit.Assert.*
import org.junit.Test

class RefreshTriggersTest {
    @Test fun onlineStartupDoesNotRepeatRestoreButRealResumeDoes() {
        val triggers = RefreshTriggers("network-a")
        assertFalse(triggers.resumed())
        assertFalse(triggers.available("network-a"))
        assertTrue(triggers.resumed())
    }
    @Test fun offlineStartupRecoversEvenBeforeTheRestoreFailureIsPublished() {
        val triggers = RefreshTriggers<String>(null)
        assertTrue(triggers.available("network-a"))
        assertFalse(triggers.available("network-a"))
    }
    @Test fun networkLossThenRecoveryRefreshesOnce() {
        val triggers = RefreshTriggers("network-a")
        triggers.lost("network-a")
        assertTrue(triggers.available("network-a"))
        assertFalse(triggers.available("network-a"))
    }
    @Test fun newDefaultNetworkRefreshesWithoutWaitingForLossOfPreviousNetwork() {
        val triggers = RefreshTriggers("network-a")
        assertTrue(triggers.available("network-b"))
        assertFalse(triggers.available("network-b"))
    }
    @Test fun lateLossOfOldNetworkDoesNotInvalidateTheNewDefault() {
        val triggers = RefreshTriggers("network-a")
        assertTrue(triggers.available("network-b"))
        triggers.lost("network-a")
        assertFalse(triggers.available("network-b"))
        triggers.lost("network-b")
        assertTrue(triggers.available("network-b"))
    }
}
