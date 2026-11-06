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
            val invitation = invite(caregiver.second, family(caregiver.second), "patient")
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
            compose.onNodeWithText("Abrir familia").performScrollTo().performClick()
            compose.onNodeWithText("Código de invitación").performScrollTo().performTextInput(invitation)
            compose.onNodeWithText("Revisar invitación").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Unirme a la familia").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Unirme a la familia").performScrollTo().performClick()
            waitFor { app.repository.state.value.own?.families?.size == 1 }
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
    private fun family(admin: String): String = call("/v1/families", admin, buildJsonObject {
        put("client_operation_id", UUID.randomUUID().toString()); put("name", "Familia sintética")
    }).getValue("family_id").jsonPrimitive.content
    private fun invite(admin: String, family: String, role: String): String = call("/v1/families/$family/invitations", admin, buildJsonObject {
        put("client_operation_id", UUID.randomUUID().toString()); put("role", role)
    }).getValue("token").jsonPrimitive.content
    private fun join(member: String, token: String) {
        call("/v1/family-invitations/accept", member, buildJsonObject { put("client_operation_id", UUID.randomUUID().toString()); put("token", token) })
    }
    /** Une a quien cuida con el paciente en una familia, con el rol que cubre los alcances. Devuelve la familia. */
    private fun link(caregiver: String, patient: String, scopes: List<String>): String {
        val role = when { "treatments" in scopes -> "admin"; "doses" in scopes || "inventory" in scopes -> "caregiver"; else -> "observer" }
        val admin = if (role == "admin") caregiver else signup("family-admin").second
        val id = family(admin)
        join(patient, invite(admin, id, "patient"))
        if (role != "admin") join(caregiver, invite(admin, id, role))
        return id
    }
    @Test fun familyAccountsConsentScopesTwoPatientsAndRevocation(): Unit = runBlocking {
        app.repository.logout(); fault("online")

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
            compose.onNodeWithText("Invitar a la familia").performScrollTo().performClick()
            compose.onNodeWithText("Nombre de la familia").performTextClearance()
            compose.onNodeWithText("Nombre de la familia").performTextInput("Familia Vicente")
            compose.onNodeWithText("Crear familia").performScrollTo().performClick()
            waitFor { app.repository.state.value.own?.families?.singleOrNull()?.name == "Familia Vicente" }
            capture("family-created")
            compose.onNodeWithText("Invitar a la familia").performScrollTo().performClick()
            compose.onNodeWithText("¿Cómo se llama? (opcional)").performTextInput("Mamá sintética")
            capture("family-invite")
            compose.onNodeWithText("Crear invitación").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Copiar mensaje").fetchSemanticsNodes().isNotEmpty() }
            capture("family-share")
            compose.onNodeWithText("Copiar mensaje").performScrollTo().performClick()
            val clipboard = app.getSystemService(android.content.ClipboardManager::class.java)
            val message = clipboard.primaryClip!!.getItemAt(0).text.toString()
            assertEquals(43, invitationToken(message).length)
            assertTrue(message.contains(invitationLink(invitationToken(message))))
            compose.onNodeWithText("Cerrar").performScrollTo().performClick()
            val caregiverToken = app.identity.token()
            val caregiverFamily = app.repository.state.value.own!!.families.single().id
            app.repository.logout()
            val patient = signup("family-patient")
            val second = signup("family-second")
            val reader = signup("family-reader")
            val patientId = call("/v1/me", patient.second).getValue("user_id").jsonPrimitive.content
            val secondId = call("/v1/me", second.second).getValue("user_id").jsonPrimitive.content
            profile(patient.second, "Paciente uno sintético"); profile(second.second, "Paciente dos sintético"); profile(reader.second, "Lector sintético")
            app.repository.login(patient.first, password); app.repository.setUse(false)
            waitFor { app.repository.state.value.own?.profile?.profileComplete == true }
            compose.waitUntil(20_000) { compose.onAllNodesWithText("¿Te invitó un cuidador?").fetchSemanticsNodes().isNotEmpty() }
            capture("family-today-invited")
            compose.onNodeWithText("Ingresar código").performScrollTo().performClick()
            compose.onNodeWithText("Pegar código").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Unirme a la familia").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Familia Vicente").performScrollTo().assertExists()
            compose.onNodeWithText("Cuidador sintético te invita como Paciente").performScrollTo().assertExists()
            compose.onNodeWithText("Unirme a la familia").performScrollTo()
            capture("family-consent")
            compose.onNodeWithText("Unirme a la familia").performScrollTo().performClick()
            waitFor { app.repository.state.value.own?.families?.singleOrNull()?.role == "patient" }
            // Las demás personas se unen a la misma familia: nadie vuelve a pegar códigos por cada paciente.
            join(second.second, invite(caregiverToken, caregiverFamily, "patient"))
            join(reader.second, invite(caregiverToken, caregiverFamily, "observer"))
            app.repository.sync()
            waitFor { app.repository.state.value.own?.families?.single()?.members?.size == 4 }
            compose.onNodeWithText("Hoy").performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Nuevo en Familia Vicente").fetchSemanticsNodes().isNotEmpty() }
            capture("family-new-members")
            treatment(patient.second, patientId); treatment(second.second, secondId)
            app.repository.logout(); app.repository.login(reader.first, password); app.repository.setUse(true)
            // Quien sólo mira hereda a todos los pacientes de la familia sin otra aprobación.
            waitFor { app.repository.state.value.patients.size == 2 }
            compose.onNode(hasText("Pacientes") and hasClickAction()).performClick()
            compose.onNodeWithText("Paciente uno sintético").performScrollTo().performClick()
            compose.onNodeWithText("Tu acceso permite sólo mirar").assertExists()
            compose.onAllNodesWithText("Se lo tomó").assertCountEquals(0)
            capture("family-read-only")
            app.repository.logout(); app.repository.login(caregiverEmail, password); app.repository.setUse(true)
            waitFor { app.repository.state.value.patients.size == 2 }
            compose.onNode(hasText("Pacientes") and hasClickAction()).performClick()
            capture("family-patients")
            compose.onNode(hasText("Pacientes") and hasClickAction()).performClick()
            compose.onNodeWithText("Paciente uno sintético").performScrollTo().performClick()
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
            compose.onNodeWithText("Ver movimientos").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Ocultar movimientos").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Stock inicial").performScrollTo().assertExists()
            capture("family-movements")
            compose.onNodeWithText("Saldo confirmado").performScrollTo().assertExists()
            capture("family-inventory")
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
            call("/v1/families/$caregiverFamily/members/$patientId", patient.second, method = "DELETE")
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

    /** Quien cuida marca la misma caja contándola. Consumo y salida con API y PostgreSQL reales. */
    @Test fun sharedBoxCountConsumptionAndLeave(): Unit = runBlocking {
        app.repository.logout(); fault("online")
        try {
            val mama = signup("pool-mama"); val papa = signup("pool-papa"); val caregiver = signup("pool-care")
            val mamaId = call("/v1/me", mama.second).getValue("user_id").jsonPrimitive.content
            val papaId = call("/v1/me", papa.second).getValue("user_id").jsonPrimitive.content
            profile(mama.second, "Mamá sintética"); profile(papa.second, "Papá sintético"); profile(caregiver.second, "Cuidadora sintética")
            val scopes = listOf("read", "treatments", "doses", "inventory")
            link(caregiver.second, mama.second, scopes); link(caregiver.second, papa.second, scopes)
            treatment(caregiver.second, mamaId); treatment(caregiver.second, papaId)
            val accountOf = { token: String, id: String -> call("/v1/patients/$id/inventory", token).getValue("items").jsonArray.single().jsonObject.getValue("account_id").jsonPrimitive.content }
            val mamaAccount = accountOf(mama.second, mamaId); val papaAccount = accountOf(papa.second, papaId)

            app.repository.login(caregiver.first, password); app.repository.setUse(true)
            waitFor { app.repository.state.value.patients.size == 2 }
            compose.onNodeWithText("Mamá sintética").performScrollTo().performClick()
            compose.onNodeWithText("Inventario").performClick()
            compose.onNodeWithText("¿Usan la misma caja?").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Misma caja que Papá sintético").fetchSemanticsNodes().isNotEmpty() }
            capture("pool-candidates")
            compose.onNodeWithText("Misma caja que Papá sintético").performClick()
            // Dos stocks de 10 eran la misma caja: al contarla quedan 10, no 20.
            compose.onNodeWithText("¿Cuántos comprimidos hay en la caja?").performTextInput("10")
            capture("pool-count")
            compose.onNodeWithText("Compartir la caja").performClick()
            waitFor { app.repository.state.value.patients.getValue(mamaId).inventory.single().pool?.status == "active" }
            compose.onNodeWithText("Misma caja que Papá sintético", substring = true).performScrollTo().assertExists()
            capture("pool-active")
            assertEquals("10.000", balance(caregiver.second, mamaId))
            assertEquals("10.000", balance(papa.second, papaId))
            app.repository.logout()

            app.repository.login(mama.first, password); app.repository.setUse(false)
            waitFor { app.repository.state.value.own?.inventory?.single()?.pool?.status == "active" }
            assertEquals("10.000", app.repository.state.value.own!!.inventory.single().balance)

            // Cada paciente consume de su propia cuenta y el saldo común baja una vez por dosis.
            val own = app.repository.state.value.own!!
            val dose = own.doses.first { !it.declared() }
            app.repository.record(own.context, dose.id, declaration(dose, "taken", null, null))
            val papaDose = call("/v1/patients/$papaId/doses?from=${dose.localDate}&to=${java.time.LocalDate.parse(dose.localDate).plusDays(1)}", papa.second)
                .getValue("items").jsonArray.first { it.jsonObject.getValue("state").jsonPrimitive.content == "unconfirmed" }.jsonObject
            call("/v1/doses/${papaDose.getValue("dose_id").jsonPrimitive.content}/events", papa.second, buildJsonObject {
                put("client_operation_id", UUID.randomUUID().toString()); put("event_type", "taken"); put("expected_version", papaDose.getValue("version").jsonPrimitive.int)
            })
            app.repository.sync()
            waitFor { app.repository.state.value.own?.inventory?.single()?.balance == "9.000" }
            assertEquals("9.000", balance(papa.second, papaId))

            compose.onNodeWithText("Ajustes").performClick()
            compose.onNodeWithText("Misma caja que Papá sintético", substring = true).performScrollTo().assertExists()
            capture("pool-settings")
            compose.onNodeWithText("Dejar de compartir").performScrollTo().performClick()
            compose.onNodeWithText("El saldo se queda con Papá sintético", substring = true).assertExists()
            capture("pool-leave")
            compose.onNodeWithText("Confirmar").performClick()
            waitFor { app.repository.state.value.own?.inventory?.single()?.pool == null }
            assertEquals("0.000", app.repository.state.value.own!!.inventory.single().balance)
            assertEquals("9.000", balance(papa.second, papaId))
            val reasons = call("/v1/inventory/$mamaAccount/movements", mama.second).getValue("items").jsonArray.map { it.jsonObject.getValue("reason").jsonPrimitive.content }
            assertEquals(1, reasons.count { it == "pool_transfer" })
            assertEquals(1, call("/v1/inventory/$papaAccount/movements", papa.second).getValue("items").jsonArray.count { it.jsonObject.getValue("reason").jsonPrimitive.content == "pool_transfer" })
        } catch (e: Throwable) { capture("pool-failed"); throw e }
        finally { fault("online"); app.repository.logout() }
    }

    /** Exporta con el selector nativo y elimina la cuenta: la historia del otro paciente queda intacta. */
    @Test fun exportAndDeleteAccountKeepOtherHistory(): Unit = runBlocking {
        app.repository.logout(); fault("online")
        try {
            val patient = signup("delete-patient"); val caregiver = signup("delete-care"); val other = signup("delete-other")
            val patientId = call("/v1/me", patient.second).getValue("user_id").jsonPrimitive.content
            val otherId = call("/v1/me", other.second).getValue("user_id").jsonPrimitive.content
            profile(patient.second, "Persona que se va"); profile(caregiver.second, "Cuidadora sintética"); profile(other.second, "Otra persona sintética")
            val scopes = listOf("read", "treatments", "doses", "inventory")
            link(caregiver.second, patient.second, scopes)
            // Quien se va también cuida a otra persona y registró en su historia.
            link(patient.second, other.second, scopes)
            treatment(patient.second, patientId); treatment(patient.second, otherId)
            val day = Instant.now().atZone(ZoneId.of("America/Santiago")).toLocalDate()
            val due = call("/v1/patients/$otherId/doses?from=$day&to=${day.plusDays(1)}", other.second)
                .getValue("items").jsonArray.first { it.jsonObject.getValue("state").jsonPrimitive.content == "unconfirmed" }.jsonObject
            call("/v1/doses/${due.getValue("dose_id").jsonPrimitive.content}/events", patient.second, buildJsonObject {
                put("client_operation_id", UUID.randomUUID().toString()); put("event_type", "taken"); put("expected_version", due.getValue("version").jsonPrimitive.int)
            })

            app.repository.login(patient.first, password); app.repository.setUse(false)
            waitFor { app.repository.state.value.own != null }
            val uid = app.identity.uid!!
            val exported = wireJson.parseToJsonElement(app.repository.exportAccount()).jsonObject
            assertEquals(patientId, exported.getValue("profile").jsonObject.getValue("user_id").jsonPrimitive.content)
            compose.onNodeWithText("Ajustes").performClick()
            compose.onNodeWithText("Descargar mis datos").performScrollTo().performClick()
            val exports = java.io.File(app.cacheDir, "exports")
            compose.waitUntil(20_000) { exports.listFiles().orEmpty().isNotEmpty() }
            Thread.sleep(1_500)
            shell("screencap -p /data/local/tmp/delete-chooser.png")
            shell("input keyevent 4")
            compose.waitUntil(20_000) { exports.listFiles().orEmpty().isEmpty() }
            // La ventana recupera el foco poco después de cerrar el selector nativo.
            compose.waitForIdle(); Thread.sleep(1_500)
            compose.onNodeWithText("Eliminar mi cuenta").performScrollTo().performClick()
            compose.waitUntil(20_000) { compose.onAllNodesWithText("Eliminar definitivamente").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Eliminar definitivamente").assertIsNotEnabled()
            compose.onNodeWithText("Escribe BORRAR").performTextInput("BORRAR")
            capture("delete-dialog")
            compose.onNodeWithText("Eliminar definitivamente").performClick()
            compose.waitUntil(30_000) { app.repository.state.value.session == Session.SignedOut && !app.repository.state.value.busy }
            assertNull(app.identity.uid)
            assertTrue(app.database.local().snapshots(uid).isEmpty())
            assertTrue(app.database.local().allOperations(uid).isEmpty())

            val caregiverAccess = runCatching { call("/v1/patients/$patientId/inventory", caregiver.second) }
            assertTrue("El cuidador ya no debe ver a la persona eliminada", caregiverAccess.isFailure)
            assertEquals("9.500", balance(other.second, otherId))
            val after = call("/v1/patients/$otherId/doses?from=$day&to=${day.plusDays(1)}", other.second).getValue("items").jsonArray
            assertEquals(1, after.count { it.jsonObject.getValue("state").jsonPrimitive.content == "taken" })
            // La identidad ya no existe: el correo no vuelve a entrar.
            app.repository.login(patient.first, password)
            assertEquals(Session.SignedOut, app.repository.state.value.session)
        } catch (e: Throwable) { capture("delete-failed"); throw e }
        finally { fault("online"); app.repository.logout() }
    }
}
