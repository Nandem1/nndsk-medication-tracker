package cl.nndsk.medication.core

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.core.app.ApplicationProvider
import cl.nndsk.medication.MainActivity
import cl.nndsk.medication.MedicationApplication
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class SessionCleanupTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun signedOutCanRetryLocalCleanup() {
        val app = ApplicationProvider.getApplicationContext<MedicationApplication>()
        runBlocking { app.repository.logout() }
        compose.waitUntil(10_000) { !app.repository.state.value.busy }
        compose.onNodeWithText("Cerrar sesión y borrar datos locales").performClick()
        compose.onNodeWithText("Cerrar y borrar").performClick()
        compose.waitUntil(10_000) { !app.repository.state.value.busy }
        compose.onNodeWithText("Cerrar sesión y borrar datos locales").assertExists()
        assertEquals(Session.SignedOut, app.repository.state.value.session)
        assertNull(app.repository.state.value.snapshot)
        assertNull(app.identity.uid)
    }
}
