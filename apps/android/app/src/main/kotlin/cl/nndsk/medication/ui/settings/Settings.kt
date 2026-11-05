package cl.nndsk.medication.ui.settings

import cl.nndsk.medication.ui.account.AccountActions
import cl.nndsk.medication.ui.account.ProfileEditor
import cl.nndsk.medication.ui.caregiver.SharedInventory
import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import cl.nndsk.medication.ui.components.*

@Composable internal fun PatientSettings(model: PatientViewModel, state: AppState, openAccess: () -> Unit, open: (String, String) -> Unit) {
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
    var logout by remember { mutableStateOf(false) }
    var discard by remember { mutableStateOf<PendingOperation?>(null) }
    val notificationSettings = { context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        SectionCard("Acceso de cuidadores") {
            val links = state.own?.links.orEmpty()
            Note(when (links.size) { 0 -> "Ningún cuidador tiene acceso."; 1 -> "1 cuidador tiene acceso."; else -> "${links.size} cuidadores tienen acceso." })
            SecondaryAction("Pegar código o revisar accesos") { openAccess() }
        }
        SectionCard("Uso de la app") {
            Note("Organiza las pantallas. No cambia ningún permiso.")
            Column(Modifier.selectableGroup()) {
                listOf("Tomo mis medicamentos" to false, "Cuido a alguien" to true).forEach { (label, value) ->
                    Row(Modifier.fillMaxWidth().heightIn(min = GraphiteTokens.Size.minTouchAndroid).selectable(selected = state.caregiverPreference == value, role = Role.RadioButton) { model.run { model.repository.setUse(value) } },
                        horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm), verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = state.caregiverPreference == value, onClick = null)
                        Text(label, style = GraphiteTokens.Type.patientBody)
                    }
                }
            }
        }
        state.own?.let { ProfileEditor(model, it, state.busy) }
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
            SecondaryAction("Ajustes de notificaciones") { notificationSettings() }
        }
        if (model.app.remotePush.configured) SectionCard("Avisos remotos del cuidador") { Text(pushDiagnostic) }
        state.own?.let { own -> own.inventory.filter { it.pool != null }.forEach { stock ->
            SectionCard(own.treatments.find { it.id == stock.treatmentId }?.name ?: "Inventario") {
                SharedInventory(model, stock, true, state.busy || state.offline, propose = false)
            }
        } }
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
        state.own?.let { AccountActions(model, state.busy || state.offline) }
        SectionCard("Cuenta") {
            state.own?.refreshedAt?.let { InfoRow("Última actualización", formatInstant(it)) }
            Note("Estos registros son autodeclarados y no demuestran ingestión.")
            SecondaryAction("Cerrar sesión", enabled = !state.busy) { logout = true }
        }
        Spacer(Modifier.height(GraphiteTokens.Space.lg))
    }
    if (logout) AlertDialog(onDismissRequest = { logout = false }, title = { Text("Cerrar sesión") },
        text = { Text("Se borrarán la agenda, los recordatorios y ${state.operations.size} declaraciones locales pendientes de este teléfono. Sincroniza primero si deseas conservarlas en el servidor.") },
        confirmButton = { TextButton(onClick = { logout = false; model.run { model.repository.logout() } }) { Text("Cerrar y borrar datos locales") } },
        dismissButton = { TextButton(onClick = { logout = false }) { Text("Volver") } })
    discard?.let { op -> AlertDialog(onDismissRequest = { discard = null }, title = { Text("Descartar declaración local") },
        text = { Text("El registro del servidor se conserva. Esta declaración local no se volverá a enviar.") },
        confirmButton = { TextButton(onClick = { discard = null; model.run { model.repository.discard(op.id) } }) { Text("Descartar") } },
        dismissButton = { TextButton(onClick = { discard = null }) { Text("Volver") } }) }
}
