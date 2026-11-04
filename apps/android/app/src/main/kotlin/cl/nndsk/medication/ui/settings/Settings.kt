package cl.nndsk.medication.ui.settings

import android.content.ClipboardManager
import cl.nndsk.medication.ui.account.ProfileEditor
import cl.nndsk.medication.ui.caregiver.InviteSheet
import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import cl.nndsk.medication.ui.components.*

@Composable internal fun PatientSettings(model: PatientViewModel, state: AppState, open: (String, String) -> Unit) {
    val context = LocalContext.current
    val colors = MedicationTrackerTheme.colors
    var diagnostic by remember { mutableStateOf(model.app.reminders.diagnostic()) }
    var permitted by remember { mutableStateOf(model.app.reminders.permitted()) }
    var exact by remember { mutableStateOf(model.app.reminders.exact()) }
    val refresh = { diagnostic = model.app.reminders.diagnostic(); permitted = model.app.reminders.permitted(); exact = model.app.reminders.exact() }
    val pushDiagnostic by model.app.remotePush.diagnostic.collectAsStateWithLifecycle()
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        model.run { model.app.reminders.reconcile(); model.app.remotePush.reconcile(); refresh() }
    }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { refresh() }
    var invite by remember { mutableStateOf(false) }
    var logout by remember { mutableStateOf(false) }
    var discard by remember { mutableStateOf<PendingOperation?>(null) }
    val notificationSettings = { context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        state.own?.let { ProfileEditor(model, it, state.busy) }
        SectionCard("Uso de la app") {
            DoseAction("Tomo mis medicamentos") { model.run { model.repository.setUse(false) } }
            DoseAction("Cuido a alguien") { model.run { model.repository.setUse(true) } }
            DoseAction("Invitar paciente") { invite = true }
        }
        SectionCard("Recordatorios") {
            StatusChip(when {
                !permitted -> Chip(diagnostic, R.drawable.ic_notifications_off, colors.unconfirmedFg, colors.unconfirmedBg)
                !exact -> Chip(diagnostic, R.drawable.ic_scheduled, colors.unconfirmedFg, colors.unconfirmedBg)
                else -> Chip(diagnostic, R.drawable.ic_taken, colors.takenFg, colors.takenBg)
            })
            Note("Los permisos, Doze y el ahorro de batería pueden retrasar o impedir avisos. Abre la app y sincroniza para renovar la agenda guardada.")
            if (!permitted) DoseAction("Permitir notificaciones", prominent = true) {
                if (Build.VERSION.SDK_INT >= 33) permission.launch(Manifest.permission.POST_NOTIFICATIONS) else notificationSettings()
            }
            if (Build.VERSION.SDK_INT >= 31 && !exact) DoseAction("Permitir mayor precisión") {
                context.startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}")))
            }
            DoseAction("Ajustes de notificaciones") { notificationSettings() }
        }
        if (model.app.remotePush.configured) SectionCard("Avisos remotos del cuidador") { Text(pushDiagnostic) }
        if (state.operations.isNotEmpty()) SectionCard("Registros pendientes") {
            state.operations.forEach { op ->
                val body = wireJson.decodeFromString<Command>(op.body)
                val dose = state.patient(op.patient)?.doses?.find { it.id == op.dose }
                val treatment = state.patient(op.patient)?.treatments?.find { it.id == dose?.treatmentId }
                Column(verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xs)) {
                    Text(treatment?.name ?: "Registro de paciente sin agenda disponible", style = GraphiteTokens.Type.patientLabel)
                    dose?.let { Note("${longLocalDate(it.localDate)} · ${doseTime(it)}") }
                    Note(declarationLabel(body.eventType, op.patient != state.own?.context?.patientId) + body.occurredAt?.let { " · ${formatInstant(it)}" }.orEmpty())
                    StatusChip(operationChip(op.status))
                    dose?.let { TextButton(onClick = { open(it.id, op.patient) }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text("Abrir dosis") } }
                    if (op.status != "pending") TextButton(onClick = { discard = op }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text("Descartar declaración local") }
                }
            }
        }
        Consent(model, state)
        SectionCard("Cuenta") {
            state.own?.refreshedAt?.let { InfoRow("Última actualización", formatInstant(it)) }
            Note("Estos registros son autodeclarados y no demuestran ingestión.")
            DoseAction("Cerrar sesión", enabled = !state.busy) { logout = true }
        }
        Spacer(Modifier.height(GraphiteTokens.Space.lg))
    }
    if (invite) InviteSheet(model) { invite = false }
    if (logout) AlertDialog(onDismissRequest = { logout = false }, title = { Text("Cerrar sesión") },
        text = { Text("Se borrarán la agenda, los recordatorios y ${state.operations.size} declaraciones locales pendientes de este teléfono. Sincroniza primero si deseas conservarlas en el servidor.") },
        confirmButton = { TextButton(onClick = { logout = false; model.run { model.repository.logout() } }) { Text("Cerrar y borrar datos locales") } },
        dismissButton = { TextButton(onClick = { logout = false }) { Text("Volver") } })
    discard?.let { op -> AlertDialog(onDismissRequest = { discard = null }, title = { Text("Descartar declaración local") },
        text = { Text("El registro del servidor se conserva. Esta declaración local no se volverá a enviar.") },
        confirmButton = { TextButton(onClick = { discard = null; model.run { model.repository.discard(op.id) } }) { Text("Descartar") } },
        dismissButton = { TextButton(onClick = { discard = null }) { Text("Volver") } }) }
}

@Composable private fun Consent(model: PatientViewModel, state: AppState) {
    val context = LocalContext.current
    var token by remember { mutableStateOf("") }; var preview by remember { mutableStateOf<Pair<String, Invitation>?>(null) }
    var previewBusy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }; var revoke by remember { mutableStateOf<Link?>(null) }
    SectionCard("Acceso de cuidadores") {
        Note("Tú autorizas el acceso y puedes revocarlo. Un teléfono sin conexión puede conservar su copia hasta volver a conectarse.")
        state.own?.links.orEmpty().forEach { link ->
            InfoRow(link.caregiverName ?: "Cuidador sin nombre", link.scopes.joinToString { scopeLabel(it) })
            DoseAction("Revocar acceso", enabled = !state.busy) { revoke = link }
        }
        OutlinedTextField(token, { token = it; preview = null; error = null }, label = { Text("Código de invitación") }, enabled = !previewBusy, modifier = Modifier.fillMaxWidth())
        DoseAction("Pegar código") { token = context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty(); preview = null }
        DoseAction("Revisar invitación", enabled = token.isNotBlank() && !state.busy && !previewBusy) {
            val requestedToken = token.trim()
            previewBusy = true
            model.run {
                try {
                    val result = model.repository.preview(requestedToken)
                    if (token.trim() == requestedToken) { preview = requestedToken to result; error = null }
                } catch (_: Exception) { error = "No se pudo revisar la invitación. Comprueba el código y la conexión." }
                finally { previewBusy = false }
            }
        }
        error?.let { Text(it, color = MedicationTrackerTheme.colors.dangerFg) }
        preview?.let { (reviewedToken, invitation) ->
            InfoRow("Cuidador", invitation.caregiverName ?: "Cuidador sin nombre")
            invitation.patientNameHint?.let { InfoRow("Nombre sugerido", it) }
            InfoRow("Permisos solicitados", invitation.scopes.joinToString { scopeLabel(it) })
            InfoRow("Vence", formatInstant(invitation.expiresAt))
            DoseAction("Autorizar estos permisos", prominent = true, enabled = !state.busy) { model.run { model.repository.accept(reviewedToken); preview = null } }
        }
    }
    revoke?.let { link -> AlertDialog(onDismissRequest = { revoke = null }, title = { Text("Revocar acceso") },
        text = { Text("El cuidador dejará de tener acceso al servidor. Un teléfono offline puede conservar su copia hasta detectar la revocación.") },
        confirmButton = { TextButton(onClick = { revoke = null; model.run { model.repository.revoke(link.id) } }) { Text("Revocar") } },
        dismissButton = { TextButton(onClick = { revoke = null }) { Text("Volver") } }) }
}
