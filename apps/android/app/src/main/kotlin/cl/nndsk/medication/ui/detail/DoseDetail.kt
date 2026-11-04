package cl.nndsk.medication.ui.detail

import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import java.time.*
import cl.nndsk.medication.ui.components.*

@Composable internal fun DoseDetail(model: PatientViewModel, state: AppState, id: String) {
    val snapshot = state.snapshot
    val dose = snapshot?.doses?.find { it.id == id }
    if (dose == null) { Text("Esta dosis ya no está en la agenda actual. Revisa los pendientes en Ajustes.", style = GraphiteTokens.Type.patientBody); return }
    val treatment = snapshot.treatments.find { it.id == dose.treatmentId }
    val pending = state.operations.find { it.dose == id }
    val now = Instant.now()
    val colors = MedicationTrackerTheme.colors
    var correcting by remember(id) { mutableStateOf(false) }
    var discard by remember(id) { mutableStateOf<PendingOperation?>(null) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        SectionCard {
            Column(verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xs)) {
                Text(doseTime(dose), style = GraphiteTokens.Type.patientDisplay)
                Text(longLocalDate(dose.localDate), style = GraphiteTokens.Type.patientLabel, color = colors.textMuted)
                Text(treatment?.name ?: "Tratamiento", style = GraphiteTokens.Type.patientTitle, modifier = Modifier.semantics { heading() })
                if (!treatment?.strength.isNullOrEmpty()) Text(treatment!!.strength, style = GraphiteTokens.Type.patientBody, color = colors.textMuted)
                Text("${quantityText(dose.quantity)} ${unitLabel(treatment?.unit)}", style = GraphiteTokens.Type.patientBody)
                if (dose.dstAdjusted) Note("Hora ajustada por el cambio de horario. Revisa la pauta con tu profesional.")
            }
            StatusChip(doseChip(dose, pending, now))
            if (pending == null && !dose.declared()) DeclarationActions(model, state, dose, now)
            if (pending?.status == "pending") Note("Tu declaración está guardada. Se enviará cuando haya conexión.")
        }
        if (pending != null && pending.status != "pending") SectionCard("Revisar registro") {
            InfoRow("Tu registro", declarationLabel(wireJson.decodeFromString<Command>(pending.body).eventType))
            StatusChip(doseChip(dose, null, now))
            Note("Es lo que tiene el servidor. Puedes conservarlo y descartar tu registro local.")
            DoseAction("Descartar mi registro") { discard = pending }
        }
        snapshot.inventory.find { it.treatmentId == dose.treatmentId }?.let { stock ->
            SectionCard("Inventario") {
                InfoRow("Saldo confirmado", "${quantityText(stock.balance)} ${unitLabel(stock.unit)}")
                if (state.operations.isNotEmpty()) {
                    val estimate = estimatedBalance(snapshot, state.operations, dose.treatmentId)
                    if (estimate == null) Note("Saldo estimado no disponible hasta revisar los pendientes.")
                    else InfoRow("Estimado con registros sin enviar", "${quantityText(estimate)} ${unitLabel(stock.unit)}")
                }
            }
        }
        if (!treatment?.instructions.isNullOrEmpty()) SectionCard("Instrucciones registradas") {
            Text(treatment!!.instructions, style = GraphiteTokens.Type.patientBody)
        }
        if (pending == null && dose.declared() && dose.eventId != null) DoseAction("Corregir este registro") { correcting = true }
        Note(missedGuidance)
        Spacer(Modifier.height(GraphiteTokens.Space.md))
    }
    if (correcting) CorrectionSheet(dose, onDismiss = { correcting = false }) { command ->
        correcting = false
        model.run { model.repository.record(snapshot.context, id, command) }
    }
    discard?.let { op -> AlertDialog(onDismissRequest = { discard = null }, title = { Text("Descartar declaración local") },
        text = { Text("El registro del servidor se conserva. Esta declaración local no se volverá a enviar.") },
        confirmButton = { TextButton(onClick = { discard = null; model.run { model.repository.discard(op.id) } }) { Text("Descartar") } },
        dismissButton = { TextButton(onClick = { discard = null }) { Text("Volver") } }) }
}

/** La corrección es una acción aparte: conserva el historial y exige motivo. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun CorrectionSheet(dose: Dose, onDismiss: () -> Unit, save: (Command) -> Unit) {
    val colors = MedicationTrackerTheme.colors
    var selected by remember { mutableStateOf("skipped") }
    var date by remember { mutableStateOf(dose.localDate) }; var time by remember { mutableStateOf("") }
    var selectedOffset by remember(date, time) { mutableStateOf<String?>(null) }
    var reason by remember { mutableStateOf("") }; var error by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = colors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            Text("Corregir registro", style = GraphiteTokens.Type.patientTitle, modifier = Modifier.semantics { heading() })
            SectionTitle("El registro correcto es")
            listOf("taken", "taken_late", "skipped").forEach { type ->
                Row(Modifier.fillMaxWidth().heightIn(min = GraphiteTokens.Size.minTouchAndroid).selectable(selected == type, role = Role.RadioButton) { selected = type; error = null },
                    horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected == type, onClick = null, colors = RadioButtonDefaults.colors(selectedColor = colors.action))
                    Text(declarationLabel(type), style = GraphiteTokens.Type.patientLabel)
                }
            }
            if (selected == "taken_late") {
                Note("Indica cuándo la tomaste, en la zona ${dose.timezone}.")
                EffectiveTimeFields(dose.timezone, date, { date = it; error = null }, time, { time = it; error = null }, selectedOffset) { selectedOffset = it }
            }
            OutlinedTextField(reason, { reason = it; error = null }, label = { Text("Motivo de la corrección") }, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it, color = colors.dangerFg) }
            DoseAction("Guardar corrección", prominent = true, enabled = reason.isNotBlank()) {
                try {
                    val occurred = if (selected == "taken_late") effectiveInstant(date, time, dose.timezone, selectedOffset) else null
                    save(declaration(dose, selected, occurred, reason))
                } catch (e: IllegalArgumentException) { error = e.message ?: "Revisa la fecha, hora y motivo." }
                catch (_: Exception) { error = "Usa una fecha y hora válidas." }
            }
            Note("El registro anterior se conserva en el historial. Si cambia el consumo, el inventario se ajusta con un movimiento compensatorio.")
            Spacer(Modifier.height(GraphiteTokens.Space.lg))
        }
    }
}
