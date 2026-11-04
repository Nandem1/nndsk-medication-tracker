package cl.nndsk.medication.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import java.time.*

internal const val overdueHint = "Abre una toma para registrar lo que ocurrió. Esta app no indica tomarla ahora."
internal const val missedGuidance = "Si olvidaste una dosis o la tomaste tarde, sigue lo que te indicó tu profesional de salud o pregunta a un farmacéutico. Esta app no te indica cambiar ni reponer dosis."
/** Agrupa una parte de la pantalla sobre la superficie de tarjeta, como las secciones de iOS. */
@Composable internal fun SectionCard(title: String? = null, content: @Composable ColumnScope.() -> Unit) {
    val colors = MedicationTrackerTheme.colors
    Surface(color = colors.surface, shape = RoundedCornerShape(GraphiteTokens.Radius.lg), border = BorderStroke(1.dp, colors.border), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            title?.let { SectionTitle(it) }
            content()
        }
    }
}

@Composable internal fun InfoRow(label: String, value: String) {
    Column(Modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xxs)) {
        Text(label, style = GraphiteTokens.Type.caregiverBody, color = MedicationTrackerTheme.colors.textMuted)
        Text(value, style = GraphiteTokens.Type.patientLabel)
    }
}

@Composable internal fun Note(text: String) {
    Text(text, style = GraphiteTokens.Type.caregiverBody, color = MedicationTrackerTheme.colors.textMuted)
}
@Composable internal fun SectionTitle(text: String) {
    Text(text, style = GraphiteTokens.Type.patientLabel, modifier = Modifier.semantics { heading() })
}

/** Las tres declaraciones comparten alto y forma; sólo «Me lo tomé» va relleno. */
@Composable internal fun DoseAction(label: String, modifier: Modifier = Modifier.fillMaxWidth(), prominent: Boolean = false, enabled: Boolean = true, description: String? = null, action: () -> Unit) {
    val shape = RoundedCornerShape(GraphiteTokens.Radius.lg)
    val sized = modifier.heightIn(min = GraphiteTokens.Size.patientAction).let { base -> description?.let { text -> base.semantics { contentDescription = text } } ?: base }
    if (prominent) Button(onClick = action, enabled = enabled, shape = shape, modifier = sized) { Text(label, style = GraphiteTokens.Type.patientLabel, textAlign = TextAlign.Center) }
    else OutlinedButton(onClick = action, enabled = enabled, shape = shape, colors = ButtonDefaults.outlinedButtonColors(contentColor = MedicationTrackerTheme.colors.text), border = BorderStroke(GraphiteTokens.Size.borderWidth, if (enabled) MedicationTrackerTheme.colors.action else MedicationTrackerTheme.colors.borderStrong), modifier = sized) {
        Text(label, style = GraphiteTokens.Type.patientLabel, textAlign = TextAlign.Center)
    }
}

internal data class Chip(val text: String, val icon: Int, val foreground: Color, val background: Color)

/** Chip de estado: icono y texto, nunca sólo color. */
@Composable internal fun StatusChip(chip: Chip) {
    Surface(color = chip.background, contentColor = chip.foreground, shape = RoundedCornerShape(GraphiteTokens.Radius.lg)) {
        Row(Modifier.padding(horizontal = GraphiteTokens.Space.md, vertical = GraphiteTokens.Space.xs), horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xs), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(chip.icon), contentDescription = null, modifier = Modifier.size(20.dp))
            Text(chip.text, style = GraphiteTokens.Type.patientLabel)
        }
    }
}

@Composable internal fun doseChip(dose: Dose, operation: PendingOperation?, now: Instant): Chip {
    if (operation != null) return operationChip(operation.status)
    val colors = MedicationTrackerTheme.colors
    val label = stateLabel(dose, now)
    return when (dose.state) {
        "taken" -> Chip(label, R.drawable.ic_taken, colors.takenFg, colors.takenBg)
        "taken_late" -> Chip(label, R.drawable.ic_taken_late, colors.takenLateFg, colors.takenLateBg)
        "skipped" -> Chip(label, R.drawable.ic_skipped, colors.skippedFg, colors.skippedBg)
        else -> if (Instant.parse(dose.scheduledAt) <= now) Chip(label, R.drawable.ic_unconfirmed, colors.unconfirmedFg, colors.unconfirmedBg)
        else Chip(label, R.drawable.ic_scheduled, colors.scheduledFg, colors.scheduledBg)
    }
}

@Composable internal fun operationChip(status: String): Chip {
    val colors = MedicationTrackerTheme.colors
    return if (status == "pending") Chip(operationLabel(status), R.drawable.ic_sync, colors.syncFg, colors.syncBg)
    else Chip(operationLabel(status), R.drawable.ic_warning, colors.dangerFg, colors.dangerBg)
}

/** Sin conexión en lenguaje simple. El rojo sólo marca lo que el servidor rechazó. */
@Composable internal fun StatusBanner(state: AppState) {
    val colors = MedicationTrackerTheme.colors
    val text = state.message
    if (!state.offline && text == null) return
    val danger = text != null && (state.rejected || state.session != Session.Active)
    val foreground = if (danger) colors.dangerFg else colors.syncFg
    Surface(color = if (danger) colors.dangerBg else colors.syncBg, contentColor = foreground, shape = RoundedCornerShape(GraphiteTokens.Radius.md), modifier = Modifier.fillMaxWidth().padding(vertical = GraphiteTokens.Space.sm)) {
        Row(Modifier.padding(GraphiteTokens.Space.md).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
            Icon(painterResource(if (state.offline) R.drawable.ic_offline else R.drawable.ic_warning), contentDescription = null)
            Column {
                if (state.offline) {
                    Text("Sin conexión", style = GraphiteTokens.Type.patientLabel)
                    Text(style = GraphiteTokens.Type.caregiverBody, text = if (state.session == Session.Active) "Tus registros quedan guardados en este teléfono. Se enviarán cuando vuelva la conexión y sincronices." else "Revisa la conexión e intenta de nuevo.")
                    state.snapshot?.refreshedAt?.let { Text("Datos guardados de: ${formatInstant(it)}", style = GraphiteTokens.Type.caregiverCaption) }
                } else Text(text.orEmpty())
            }
        }
    }
}

internal fun formatInstant(value: String): String = runCatching { Instant.parse(value).atZone(ZoneId.systemDefault()).format(java.time.format.DateTimeFormatter.ofPattern("dd-MM-yyyy HH:mm")) }.getOrDefault(value)
internal fun declarationLabel(value: String) = when (value) { "taken" -> "Me lo tomé"; "taken_late" -> "Me lo tomé tarde"; else -> "No me lo tomé" }
internal fun operationLabel(value: String) = when (value) { "conflict" -> "Necesita revisión: cambió en el servidor"; "rejected" -> "Necesita revisión: datos rechazados"; "denied" -> "Necesita revisión: acceso denegado"; else -> "Guardada, falta enviar" }
internal fun doseTime(dose: Dose) = if (dose.timezone == ZoneId.systemDefault().id) dose.localTime else "${dose.localTime} (${dose.timezone})"
internal fun unitLabel(value: String?) = when (value) { "tablet" -> "comprimidos"; "capsule" -> "cápsulas"; "dose" -> "dosis"; "ml" -> "ml"; else -> "unidades" }
internal fun scopeLabel(value: String) = when (value) { "read" -> "Consultar información"; "doses" -> "Registrar y corregir tomas"; "inventory" -> "Administrar inventario"; "treatments" -> "Administrar tratamientos"; else -> value }
