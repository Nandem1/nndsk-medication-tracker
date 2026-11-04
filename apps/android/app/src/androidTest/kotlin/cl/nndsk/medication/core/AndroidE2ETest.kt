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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
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
    private fun call(path: String, token: String = "", body: JsonObject? = null, origin: String = "http://127.0.0.1:18083", method: String = "POST"): JsonObject {
        val request = Request.Builder().url(origin + path)
        if (token.isNotEmpty()) request.header("Authorization", "Bearer $token")
        if (body != null) request.method(method, body.toString().toRequestBody("application/json".toMediaType()))
        else if (method == "DELETE") request.delete()
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
    private fun capture(name: String) {
        compose.waitForIdle()
        compose.activity.runOnUiThread {
            compose.activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java)
                .hideSoftInputFromWindow(compose.activity.window.decorView.windowToken, 0)
        }
        compose.waitForIdle()
        Thread.sleep(500)
        shell("screencap -p /data/local/tmp/$name.png")
    }
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
            compose.onNodeWithText("Nombre visible").performTextInput("Paciente sintético")
            compose.onNodeWithText("Guardar nombre").performClick()
            waitFor { app.repository.state.value.own?.profile?.profileComplete == true }
            compose.onNodeWithText("Tomo mis medicamentos").performClick()
            waitFor { app.repository.state.value.caregiverPreference == false }
            val consentOperation = app.identity.invitationOperation(invitation)
            app.repository.login(patient.first, password)
            assertEquals(consentOperation, app.identity.invitationOperation(invitation))
            compose.onNodeWithText("Ajustes").performClick()
            compose.onNodeWithText("Código de invitación").performScrollTo().performTextInput(invitation)
            compose.onNodeWithText("Revisar invitación").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Autorizar estos permisos").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Autorizar estos permisos").performScrollTo().performClick()
            waitFor { app.repository.state.value.own?.links?.size == 1 }
            shell("screencap -p /data/local/tmp/e2e-settings.png")
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
            waitFor { app.repository.state.value.own?.doses?.size == 2 }
            java.io.File(app.filesDir, "e2e-agenda.png").outputStream().use { output ->
                compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output)
            }
            assertTrue(app.reminders.exact())
            val upcoming = app.repository.state.value.own!!.doses.maxBy { it.scheduledAt }
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
                    compose.onAllNodesWithText("Detalle de la toma").fetchSemanticsNodes().isNotEmpty() &&
                        compose.onAllNodes(hasText(upcoming.localTime, substring = true)).fetchSemanticsNodes().isNotEmpty()
                }
                shell("screencap -p /data/local/tmp/e2e-detail.png")
                compose.onNodeWithContentDescription("Volver").performClick()
                compose.waitUntil(10_000) { compose.onAllNodes(hasText("Ahora toca", substring = true)).fetchSemanticsNodes().isNotEmpty() }
            } finally {
                shell("dumpsys deviceidle unforce"); shell("dumpsys battery reset"); shell("input keyevent KEYCODE_WAKEUP"); shell("wm dismiss-keyguard")
            }
            // La hoja tardía no admite horas futuras y sólo declara al guardar.
            compose.onNodeWithText("Me lo tomé tarde", useUnmergedTree = true).performScrollTo().performClick()
            compose.waitUntil(10_000) { compose.onAllNodes(hasText("Guardar con las", substring = true)).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("+5 min").assertIsNotEnabled()
            compose.onNodeWithText("−5 min").performClick()
            compose.onNodeWithText("+5 min").assertIsEnabled()
            shell("screencap -p /data/local/tmp/e2e-late.png")
            shell("input keyevent KEYCODE_BACK")
            compose.waitUntil(10_000) { compose.onAllNodes(hasText("Guardar con las", substring = true)).fetchSemanticsNodes().isEmpty() }
            assertTrue(app.repository.state.value.operations.isEmpty())
            waitFor { true }
            fault("offline")
            compose.onNodeWithText("Me lo tomé", useUnmergedTree = true).performScrollTo().performClick()
            waitFor { app.repository.state.value.operations.size == 1 }
            compose.onNodeWithText("Guardada, falta enviar").performScrollTo().assertExists()
            compose.onNodeWithText("Sin conexión").assertExists()
            // El historial incluye la toma de hoy.
            compose.onNodeWithText("Historial").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("Guardada, falta enviar").fetchSemanticsNodes().isNotEmpty() }
            shell("screencap -p /data/local/tmp/e2e-history.png")
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
            val context = app.repository.state.value.own!!.context
            val taken = app.repository.state.value.own!!.doses.single { it.id == pending.dose }
            assertEquals("taken", taken.state)
            app.repository.record(context, taken.id, declaration(taken, "skipped", null, "Corrección sintética"))
            assertEquals("10.000", balance(patient.second, patientId))
            val skipped = app.repository.state.value.own!!.doses.single { it.id == pending.dose }
            val reviewed = declaration(skipped, "taken", Instant.now().minusSeconds(60), "Declaración revisada antes de otro actor")
            val other = declaration(skipped, "taken_late", Instant.now().minusSeconds(60), "Corrección de cuidador sintético")
            call("/v1/doses/${skipped.id}/corrections", caregiver.second, wireJson.encodeToJsonElement(other).jsonObject)
            app.repository.sync()
            app.repository.record(context, skipped.id, reviewed)
            assertEquals("conflict", app.repository.state.value.operations.single().status)
            assertEquals(reviewed, wireJson.decodeFromString<Command>(app.repository.state.value.operations.single().body))
            assertEquals("9.500", balance(patient.second, patientId))
            app.repository.discard(reviewed.id)
            val before = app.repository.state.value.own
            app.repository.accept("invalid-synthetic-invitation")
            assertEquals(before, app.repository.state.value.own)
            // Una sincronización lenta no retrasa guardar: la declaración llega a disco mientras la red sigue retenida.
            val remaining = app.repository.state.value.own!!.doses.single { it.id != pending.dose }
            fault("stall")
            val syncing = launch(Dispatchers.Default) { app.repository.sync() }
            withTimeout(10_000) { while (!app.repository.state.value.busy) delay(50) }
            val held = declaration(remaining, "skipped", null, null)
            val recording = launch(Dispatchers.Default) { app.repository.record(context, remaining.id, held) }
            withTimeout(5_000) { while (app.database.local().operations(context.ownerUid, context.patientId).none { it.id == held.id }) delay(50) }
            assertTrue(app.repository.state.value.busy)
            assertEquals(held.id, app.repository.state.value.operations.single().id)
            fault("online")
            syncing.join(); recording.join()
            assertTrue(app.repository.state.value.operations.isEmpty())
            assertEquals("skipped", app.repository.state.value.own!!.doses.single { it.id == remaining.id }.state)
            app.repository.logout()
            assertTrue(app.database.local().snapshots(context.ownerUid).isEmpty())
            assertTrue(app.database.local().operations(context.ownerUid, context.patientId).isEmpty())
        } finally { fault("online"); app.repository.logout() }
    }
    private fun profile(token: String, name: String) {
        call("/v1/me/profile", token, buildJsonObject {
            put("client_operation_id", UUID.randomUUID().toString()); put("expected_version", 1); put("display_name", name)
        }, method = "PUT")
    }
    private fun treatment(token: String, patient: String) {
        val now = Instant.now()
        val zone = ZoneId.of("America/Santiago")
        val day = now.atZone(zone).toLocalDate().toString()
        call("/v1/patients/$patient/treatments", token, buildJsonObject {
            put("client_operation_id", UUID.randomUUID().toString()); put("name", "Tratamiento familiar sintético")
            put("strength_label", "Presentación sintética"); put("form", "comprimido"); put("instructions", "Instrucción sintética.")
            put("unit", "tablet"); put("initial_stock", "10.000"); put("starts_on", day); put("ends_on", day)
            putJsonObject("schedule") {
                put("timezone", zone.id); put("dst_policy", "next_valid_earliest")
                put("weekdays", JsonArray((0..6).map(::JsonPrimitive)))
                put("slots", JsonArray(listOf(-180L, -60L).map { offset -> buildJsonObject {
                    put("time", now.plusSeconds(offset).atZone(zone).format(DateTimeFormatter.ofPattern("HH:mm"))); put("quantity", "0.500")
                } }))
            }
        })
    }
    private fun link(caregiver: String, patient: String, scopes: List<String>): String {
        val token = call("/v1/invitations", caregiver, buildJsonObject {
            put("client_operation_id", UUID.randomUUID().toString()); put("scopes", JsonArray(scopes.map(::JsonPrimitive)))
        }).getValue("token").jsonPrimitive.content
        return call("/v1/invitations/accept", patient, buildJsonObject {
            put("client_operation_id", UUID.randomUUID().toString()); put("token", token)
        }).getValue("link_id").jsonPrimitive.content
    }
    @Test fun familyAccountsConsentScopesTwoPatientsAndRevocation(): Unit = runBlocking {
        app.repository.logout(); fault("online")
        // Cada bloque respeta el límite real de 120 solicitudes por minuto de la API.
        delay(61_000)
        try {
            val caregiverEmail = "family-${UUID.randomUUID()}@example.test"
            compose.onNodeWithText("Crear una cuenta").performClick()
            compose.onNodeWithText("Correo").performTextInput(caregiverEmail)
            compose.onNodeWithText("Contraseña").performTextInput(password)
            compose.onNode(hasText("Crear cuenta") and hasClickAction()).performClick()
            waitFor { app.repository.state.value.own != null }
            compose.onNodeWithText("Nombre visible").performTextInput("Cuidador sintético")
            capture("family-onboarding")
            compose.onNodeWithText("Guardar nombre").performClick()
            waitFor { app.repository.state.value.own?.profile?.profileComplete == true }
            compose.onNodeWithText("Cuido a alguien").performClick()
            waitFor { app.repository.state.value.caregiverPreference == true }
            compose.onNodeWithText("Invitar paciente").performScrollTo().performClick()
            compose.onNodeWithText("¿Cómo se llama? (opcional)").performTextInput("Mamá sintética")
            capture("family-invite")
            compose.onNodeWithText("Crear invitación").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Copiar mensaje").fetchSemanticsNodes().isNotEmpty() }
            capture("family-share")
            compose.onNodeWithText("Copiar mensaje").performScrollTo().performClick()
            val clipboard = app.getSystemService(android.content.ClipboardManager::class.java)
            val message = clipboard.primaryClip!!.getItemAt(0).text.toString()
            assertEquals(43, invitationToken(message).length)
            compose.onNodeWithText("Cerrar").performScrollTo().performClick()
            val caregiverToken = app.identity.token()
            app.repository.logout()
            val patient = signup("family-patient")
            val second = signup("family-second")
            val reader = signup("family-reader")
            val patientId = call("/v1/me", patient.second).getValue("user_id").jsonPrimitive.content
            val secondId = call("/v1/me", second.second).getValue("user_id").jsonPrimitive.content
            profile(patient.second, "Paciente uno sintético"); profile(second.second, "Paciente dos sintético"); profile(reader.second, "Lector sintético")
            app.repository.login(patient.first, password); app.repository.setUse(false)
            waitFor { app.repository.state.value.own?.profile?.profileComplete == true }
            compose.onNodeWithText("Ajustes").performClick()
            compose.onNodeWithText("Pegar código").performScrollTo().performClick()
            compose.onNodeWithText("Revisar invitación").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Autorizar estos permisos").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Cuidador sintético").performScrollTo().assertExists()
            compose.onNodeWithText("Autorizar estos permisos").performScrollTo()
            capture("family-consent")
            compose.onNodeWithText("Autorizar estos permisos").performScrollTo().performClick()
            waitFor { app.repository.state.value.own?.links?.size == 1 }
            val firstLink = app.repository.state.value.own!!.links.single().id
            link(caregiverToken, second.second, listOf("read", "doses", "inventory", "treatments"))
            link(reader.second, patient.second, listOf("read"))
            treatment(patient.second, patientId); treatment(second.second, secondId)
            app.repository.logout(); app.repository.login(reader.first, password); app.repository.setUse(true)
            waitFor { app.repository.state.value.patients.size == 1 }
            compose.onNode(hasText("Pacientes") and hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Ver a Paciente uno sintético").performScrollTo().performClick()
            compose.onNodeWithText("Tu acceso permite sólo mirar").assertExists()
            compose.onAllNodesWithText("Se lo tomó").assertCountEquals(0)
            capture("family-read-only")
            app.repository.logout(); app.repository.login(caregiverEmail, password); app.repository.setUse(true)
            waitFor { app.repository.state.value.patients.size == 2 }
            delay(61_000)
            compose.onNode(hasText("Pacientes") and hasClickAction()).performClick()
            capture("family-patients")
            compose.onNode(hasText("Pacientes") and hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Ver a Paciente uno sintético").performScrollTo().performClick()
            compose.onNodeWithText("Se lo tomó tarde").performScrollTo().performClick()
            compose.onNodeWithText("¿A qué hora se lo tomó?").assertExists()
            capture("family-late")
            shell("input keyevent KEYCODE_BACK")
            compose.waitUntil(10_000) { compose.onAllNodesWithText("¿A qué hora se lo tomó?").fetchSemanticsNodes().isEmpty() }
            compose.onNodeWithText("Se lo tomó").performScrollTo().performClick()
            waitFor { app.repository.state.value.patients[patientId]!!.doses.any { it.state == "taken" } }
            assertEquals("9.500", balance(patient.second, patientId))
            compose.onNodeWithText("Inventario").performClick()
            compose.onNodeWithText("Registrar reposición").performScrollTo().performClick()
            capture("family-replenish")
            compose.onNodeWithText("Cantidad recibida").performTextInput("1.250")
            compose.onNodeWithText("Guardar").performScrollTo().performClick()
            waitFor { app.repository.state.value.patients[patientId]!!.inventory.single().balance == "10.750" }
            compose.onNodeWithText("Conteo físico").performScrollTo().performClick()
            compose.onNodeWithText("Cantidad contada").performTextInput("10.500")
            compose.onNodeWithText("Motivo del ajuste").performTextInput("Conteo sintético")
            capture("family-count")
            compose.onNodeWithText("Guardar").performScrollTo().performClick()
            waitFor { app.repository.state.value.patients[patientId]!!.inventory.single().balance == "10.500" }
            val account = app.repository.state.value.patients.getValue(patientId).inventory.single().accountId
            val replenishOperation = UUID.randomUUID().toString()
            fault("lose-responses")
            repeat(2) { app.repository.inventory(patientId, account, "1.250", false, "", replenishOperation, "10.500"); assertTrue(app.repository.state.value.offline) }
            assertEquals("11.750", balance(patient.second, patientId))
            val countOperation = UUID.randomUUID().toString()
            repeat(2) { app.repository.inventory(patientId, account, "11.500", true, "Reintento sintético", countOperation, "11.750"); assertTrue(app.repository.state.value.offline) }
            assertEquals("11.500", balance(patient.second, patientId))
            fault("online")
            app.repository.inventory(patientId, account, "1.250", false, "", replenishOperation, "10.500")
            app.repository.inventory(patientId, account, "11.500", true, "Reintento sintético", countOperation, "11.750")
            assertEquals("11.500", balance(patient.second, patientId))
            val ledger = call("/v1/inventory/$account/movements", patient.second).getValue("items").jsonArray
            assertEquals(2, ledger.count { it.jsonObject.getValue("reason").jsonPrimitive.content == "replenishment" })
            assertEquals(2, ledger.count { it.jsonObject.getValue("reason").jsonPrimitive.content == "manual_adjustment" })
            delay(61_000)
            val first = app.repository.state.value.patients.getValue(patientId)
            val taken = first.doses.single { it.state == "taken" }
            val reviewed = declaration(taken, "skipped", null, "Corrección sintética revisada")
            call("/v1/doses/${taken.id}/corrections", patient.second, wireJson.encodeToJsonElement(declaration(taken, "taken_late", Instant.now().minusSeconds(60), "Otro actor")).jsonObject)
            app.repository.record(first.context, taken.id, reviewed)
            assertEquals("conflict", app.repository.state.value.operations.single().status)
            app.repository.discard(reviewed.id)
            val remaining = app.repository.state.value.patients.getValue(patientId).doses.single { !it.declared() }
            val secondSnapshot = app.repository.state.value.patients.getValue(secondId)
            val secondDose = secondSnapshot.doses.first()
            fault("stall")
            val syncing = launch(Dispatchers.Default) { app.repository.sync() }
            withTimeout(10_000) { while (!app.repository.state.value.busy) delay(25) }
            val one = declaration(remaining, "skipped", null, null)
            val two = declaration(secondDose, "skipped", null, null)
            val recordOne = launch(Dispatchers.Default) { app.repository.record(first.context, remaining.id, one) }
            val recordTwo = launch(Dispatchers.Default) { app.repository.record(secondSnapshot.context, secondDose.id, two) }
            withTimeout(5_000) { while (app.database.local().allOperations(first.context.ownerUid).size != 2) delay(25) }
            assertTrue("Network stays stalled while both records reach disk", app.repository.state.value.busy)
            call("/v1/caregiver-links/$firstLink", patient.second, method = "DELETE")
            fault("online"); syncing.join(); recordOne.join(); recordTwo.join()
            assertFalse(app.repository.state.value.patients.containsKey(patientId))
            assertTrue(app.repository.state.value.patients.containsKey(secondId))
            assertEquals("denied", app.repository.state.value.operations.single().status)
            assertEquals("skipped", app.repository.state.value.patients.getValue(secondId).doses.first { it.id == secondDose.id }.state)
            fault("offline")
            val restored = Repository(app.identity, Api(app.identity), app.database)
            restored.restore()
            assertNotNull(restored.state.value.own)
            assertEquals(setOf(secondId), restored.state.value.patients.keys)
            assertEquals("denied", restored.state.value.operations.single().status)
            assertTrue(restored.state.value.own!!.profile!!.profileComplete)
            compose.onNodeWithText("Ajustes").performClick()
            compose.onNodeWithText("Registros pendientes").performScrollTo().assertExists()
            capture("family-denied")
            app.repository.logout()
            compose.onNodeWithText("¿Olvidaste tu contraseña?").performClick()
            compose.onNodeWithText("Correo").performTextInput(caregiverEmail)
            compose.onNodeWithText("Enviar instrucciones").performClick()
            waitFor { app.repository.state.value.message?.startsWith("Si existe una cuenta") == true }
            capture("family-recovery")
        } catch (e: Throwable) { capture("family-failed"); throw e }
        finally { fault("online"); app.repository.logout() }
    }

}
