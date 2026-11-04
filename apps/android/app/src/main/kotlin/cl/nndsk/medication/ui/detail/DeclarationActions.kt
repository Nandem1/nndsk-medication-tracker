package cl.nndsk.medication.ui.detail

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import java.time.*
import cl.nndsk.medication.ui.components.*

/** Las tres declaraciones, sin penalización visual. Las dosis futuras no admiten registro, igual que en la API. */
@Composable internal fun DeclarationActions(model: PatientViewModel, state: AppState, dose: Dose, now: Instant) {
    var late by remember(dose.id) { mutableStateOf(false) }
    if (Instant.parse(dose.scheduledAt) > now) {
        Text("Podrás registrarla desde las ${dose.localTime}.", style = GraphiteTokens.Type.patientLabel, color = MedicationTrackerTheme.colors.textMuted)
        return
    }
    val context = state.snapshot?.context ?: return
    val declare = { type: String, occurred: Instant? -> model.run { model.repository.record(context, dose.id, declaration(dose, type, occurred, null)) } }
    Column(verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
        DoseAction("Me lo tomé", prominent = true) { declare("taken", null) }
        DoseAction("Me lo tomé tarde") { late = true }
        DoseAction("No me lo tomé") { declare("skipped", null) }
    }
    if (late) LateSheet(dose, onDismiss = { late = false }) { late = false; declare("taken_late", it) }
}

/** Pide la hora efectiva. El botón muestra la hora que se guardará y nunca admite una futura. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable private fun LateSheet(dose: Dose, onDismiss: () -> Unit, save: (Instant) -> Unit) {
    var occurred by remember { mutableStateOf(LateTime.floorToMinute(Instant.now())) }
    var manual by remember { mutableStateOf(false) }
    var date by remember { mutableStateOf("") }; var time by remember { mutableStateOf("") }
    var selectedOffset by remember(date, time) { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val label = LateTime.label(occurred, dose.timezone)
    val colors = MedicationTrackerTheme.colors
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = colors.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("¿A qué hora lo tomaste?", style = GraphiteTokens.Type.patientBody, modifier = Modifier.semantics { heading() })
            Text(label, style = GraphiteTokens.Type.patientDisplay, modifier = Modifier.semantics { contentDescription = "Hora de la toma: $label" })
            Text(longDate(occurred, ZoneId.of(dose.timezone)), style = GraphiteTokens.Type.patientLabel, color = colors.textMuted)
            if (dose.timezone != ZoneId.systemDefault().id) Text("Hora de ${dose.timezone}", color = colors.textMuted)
            if (LateTime.isRepeated(occurred, dose.timezone)) Text("Esta hora ocurrió dos veces por el cambio de horario. Usa −5 min o +5 min para elegir la correcta.", color = colors.textMuted, textAlign = TextAlign.Center)
            Row(horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
                DoseAction("−5 min", description = "Restar 5 minutos", modifier = Modifier.weight(1f)) { occurred = LateTime.stepped(occurred, -5, Instant.now()) }
                DoseAction("+5 min", description = "Sumar 5 minutos", enabled = LateTime.canAdvance(occurred, Instant.now()), modifier = Modifier.weight(1f)) { occurred = LateTime.stepped(occurred, 5, Instant.now()) }
            }
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
                listOf("Recién" to 0L, "Hace 30 min" to 30L, "Hace 1 hora" to 60L).forEach { (text, minutes) ->
                    OutlinedButton(onClick = { occurred = LateTime.ago(minutes, Instant.now()) }, colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.text), border = BorderStroke(1.dp, colors.borderStrong),
                        contentPadding = PaddingValues(horizontal = GraphiteTokens.Space.sm), modifier = Modifier.weight(1f).heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text(text, style = GraphiteTokens.Type.patientLabel, textAlign = TextAlign.Center) }
                }
            }
            TextButton(onClick = { manual = !manual }, modifier = Modifier.heightIn(min = GraphiteTokens.Size.minTouchAndroid)) { Text(if (manual) "Ocultar otra fecha u hora" else "Otra fecha u hora") }
            if (manual) {
                EffectiveTimeFields(dose.timezone, date, { date = it; error = null }, time, { time = it; error = null }, selectedOffset) { selectedOffset = it }
                error?.let { Text(it, color = colors.dangerFg) }
                DoseAction("Usar esta fecha y hora") {
                    try {
                        val chosen = effectiveInstant(date, time, dose.timezone, selectedOffset)
                        require(!chosen.isAfter(Instant.now())) { "La hora de toma no puede estar en el futuro." }
                        occurred = chosen; manual = false
                    } catch (e: IllegalArgumentException) { error = e.message ?: "Revisa la fecha y la hora." }
                    catch (_: Exception) { error = "Usa una fecha y hora válidas." }
                }
            }
            DoseAction("Guardar con las $label", prominent = true) { save(occurred) }
            Text(missedGuidance, color = colors.textMuted)
            Spacer(Modifier.height(GraphiteTokens.Space.lg))
        }
    }
}
