package cl.nndsk.medication.core

import android.content.Context
import android.app.NotificationManager
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.graphics.asAndroidBitmap
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.core.app.ApplicationProvider
import cl.nndsk.medication.BuildConfig
import cl.nndsk.medication.MainActivity
import cl.nndsk.medication.MedicationApplication
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID

class AndroidE2ETest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app get() = ApplicationProvider.getApplicationContext<MedicationApplication>()
    private val password = "synthetic-password-1"
    private fun call(path: String, token: String = "", body: JsonObject? = null, origin: String = "http://127.0.0.1:18083"): JsonObject {
        val request = Request.Builder().url(origin + path)
        if (token.isNotEmpty()) request.header("Authorization", "Bearer $token")
        if (body != null) request.post(body.toString().toRequestBody("application/json".toMediaType()))
        httpClient.newCall(request.build()).execute().use { response ->
            assertTrue("HTTP ${response.code} for test request", response.isSuccessful)
            val text = response.body!!.string()
            return if (text.isBlank()) buildJsonObject {} else wireJson.parseToJsonElement(text).jsonObject
        }
    }
    private fun signup(prefix: String): Pair<String, String> {
        val email = "$prefix-${UUID.randomUUID()}@example.test"
        val response = call("/identitytoolkit.googleapis.com/v1/accounts:signUp?key=e2e-public-placeholder", body = buildJsonObject {
            put("email", email); put("password", password); put("returnSecureToken", true)
        }, origin = "http://127.0.0.1:9099")
        return email to response.getValue("idToken").jsonPrimitive.content
    }
    private fun fault(mode: String) { call("/__fault/$mode", body = buildJsonObject {}, origin = "http://127.0.0.1:18084") }
    private fun shell(command: String): String = android.os.ParcelFileDescriptor.AutoCloseInputStream(
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
    ).bufferedReader().use { it.readText() }
    private fun waitFor(condition: () -> Boolean) { compose.waitUntil(60_000) { !app.repository.state.value.busy && condition() } }
    private fun balance(token: String, patient: String): String = call("/v1/patients/$patient/inventory", token).getValue("items").jsonArray.single().jsonObject.getValue("balance").jsonPrimitive.content

    @Test fun consentOfflineRetriesCorrectionAndConflictWithRealBackend() = runBlocking {
        assertEquals("e2e", BuildConfig.BUILD_TYPE)
        app.repository.logout()
        fault("online")
        try {
            val patient = signup("patient")
            val caregiver = signup("caregiver")
            val patientId = call("/v1/me", patient.second).getValue("user_id").jsonPrimitive.content
            val invitation = call("/v1/invitations", caregiver.second, buildJsonObject {
                put("client_operation_id", UUID.randomUUID().toString())
                put("scopes", JsonArray(listOf("read", "treatments", "doses", "inventory").map(::JsonPrimitive)))
            }).getValue("token").jsonPrimitive.content
            compose.onNodeWithText("Correo").performTextInput(patient.first)
            compose.onNodeWithText("Contraseña").performTextInput("synthetic-wrong-password")
            compose.onNodeWithText("Entrar").performClick()
            waitFor { app.repository.state.value.message == "Correo o contraseña incorrectos. Revisa tus datos." }
            assertEquals(Session.SignedOut, app.repository.state.value.session)
            compose.onNodeWithText("Contraseña").performTextInput(password)
            compose.onNodeWithText("Entrar").performClick()
            waitFor { app.repository.state.value.session == Session.Active }
            val consentOperation = app.identity.invitationOperation(invitation)
            app.repository.login(patient.first, password)
            assertEquals(consentOperation, app.identity.invitationOperation(invitation))
            compose.onNodeWithText("Ajustes").performClick()
            compose.onNodeWithText("Código de invitación").performScrollTo().performTextInput(invitation)
            compose.onNodeWithText("Revisar invitación").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Autorizar estos permisos").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Autorizar estos permisos").performScrollTo().performClick()
            waitFor { app.repository.state.value.snapshot?.links?.size == 1 }
            val now = Instant.now()
            val zone = listOf("America/Santiago", "UTC", "Asia/Tokyo", "Pacific/Auckland").map(ZoneId::of).first {
                now.minusSeconds(180).atZone(it).toLocalDate() == now.plusSeconds(90).atZone(it).toLocalDate()
            }
            val day = now.atZone(zone).toLocalDate().toString()
            val treatment = call("/v1/patients/$patientId/treatments", caregiver.second, buildJsonObject {
                put("client_operation_id", UUID.randomUUID().toString()); put("name", "Tratamiento sintético F5")
                put("strength_label", "Presentación sintética"); put("form", "comprimido"); put("instructions", "Texto sintético registrado.")
                put("unit", "tablet"); put("initial_stock", "10.000"); put("starts_on", day); put("ends_on", day)
                putJsonObject("schedule") {
                    put("timezone", zone.id); put("dst_policy", "next_valid_earliest")
                    put("weekdays", JsonArray((0..6).map(::JsonPrimitive)))
                    put("slots", JsonArray(listOf(-180L, 90L).map { offset -> buildJsonObject {
                        put("time", now.plusSeconds(offset).atZone(zone).format(DateTimeFormatter.ofPattern("HH:mm")))
                        put("quantity", "0.500")
                    } }))
                }
            })
            val account = treatment.getValue("account_id").jsonPrimitive.content
            compose.onNodeWithText("Hoy").performClick()
            compose.onNodeWithText("Sincronizar").performClick()
            waitFor { app.repository.state.value.snapshot?.doses?.size == 2 }
            java.io.File(app.filesDir, "e2e-agenda.png").outputStream().use { output ->
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output)
            }
            assertTrue(app.reminders.exact())
            val upcoming = app.repository.state.value.snapshot!!.doses.maxBy { it.scheduledAt }
            shell("dumpsys battery unplug")
            shell("input keyevent KEYCODE_SLEEP")
            try {
                shell("dumpsys deviceidle force-idle")
                assertEquals("IDLE", shell("dumpsys deviceidle get deep").trim())
                val manager = app.getSystemService(NotificationManager::class.java)
                val deadline = System.currentTimeMillis() + 120_000
                while (manager.activeNotifications.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(250)
                val delivered = manager.activeNotifications.single()
                assertEquals("Abre la app para revisar tu agenda.", delivered.notification.extras.getCharSequence("android.text").toString())
                shell("dumpsys deviceidle unforce")
                shell("dumpsys battery reset")
                shell("input keyevent KEYCODE_WAKEUP")
                shell("wm dismiss-keyguard")
                delivered.notification.contentIntent.send()
                compose.waitUntil(20_000) {
                    compose.onAllNodesWithText("${upcoming.localDate} ${upcoming.localTime} · ${upcoming.timezone}").fetchSemanticsNodes().isNotEmpty()
                }
                compose.onNodeWithText("Hoy").performClick()
            } finally {
                shell("dumpsys deviceidle unforce"); shell("dumpsys battery reset"); shell("input keyevent KEYCODE_WAKEUP"); shell("wm dismiss-keyguard")
            }
            compose.onAllNodesWithText("Tratamiento sintético F5").onFirst().performScrollTo().performClick()
            fault("offline")
            compose.onNodeWithText("Me lo tomé", useUnmergedTree = true).performScrollTo().performClick()
            compose.onNodeWithText("Revisar declaración").performScrollTo().performClick()
            compose.onNodeWithText("Guardar").performClick()
            waitFor { app.repository.state.value.operations.size == 1 }
            val pending = app.repository.state.value.operations.single()
            assertEquals("pending", pending.status)
            assertEquals("10.000", balance(patient.second, patientId))
            compose.activityRule.scenario.recreate()
            assertEquals(pending.body, app.database.local().operations(pending.owner, pending.patient).single().body)
            fault("lose-responses")
            repeat(3) { app.repository.sync() }
            assertEquals(pending.body, app.repository.state.value.operations.single().body)
            assertEquals("9.500", balance(patient.second, patientId))
            val movements = call("/v1/inventory/$account/movements", patient.second).getValue("items").jsonArray
            assertEquals(1, movements.count { it.jsonObject.getValue("reason").jsonPrimitive.content == "consumption" })
            fault("online"); app.repository.sync()
            assertTrue(app.repository.state.value.operations.isEmpty())
            val context = app.repository.state.value.snapshot!!.context
            val taken = app.repository.state.value.snapshot!!.doses.single { it.id == pending.dose }
            assertEquals("taken", taken.state)
            app.repository.record(context, taken.id, declaration(taken, "skipped", null, "Corrección sintética"))
            assertEquals("10.000", balance(patient.second, patientId))
            val skipped = app.repository.state.value.snapshot!!.doses.single { it.id == pending.dose }
            val reviewed = declaration(skipped, "taken", Instant.now().minusSeconds(60), "Declaración revisada antes de otro actor")
            val other = declaration(skipped, "taken_late", Instant.now().minusSeconds(60), "Corrección de cuidador sintético")
            call("/v1/doses/${skipped.id}/corrections", caregiver.second, wireJson.encodeToJsonElement(other).jsonObject)
            app.repository.sync()
            app.repository.record(context, skipped.id, reviewed)
            assertEquals("conflict", app.repository.state.value.operations.single().status)
            assertEquals(reviewed, wireJson.decodeFromString<Command>(app.repository.state.value.operations.single().body))
            assertEquals("9.500", balance(patient.second, patientId))
            app.repository.discard(reviewed.id)
            val before = app.repository.state.value.snapshot
            app.repository.accept("invalid-synthetic-invitation")
            assertEquals(before, app.repository.state.value.snapshot)
            app.repository.logout()
            assertTrue(app.database.local().snapshots(context.ownerUid).isEmpty())
            assertTrue(app.database.local().operations(context.ownerUid, context.patientId).isEmpty())
        } finally { fault("online"); app.repository.logout() }
    }
}
