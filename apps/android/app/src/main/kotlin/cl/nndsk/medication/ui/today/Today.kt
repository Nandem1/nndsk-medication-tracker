package cl.nndsk.medication.ui.today

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import cl.nndsk.medication.PatientViewModel
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import java.time.*
import cl.nndsk.medication.ui.components.*
import cl.nndsk.medication.ui.detail.DeclarationActions
import cl.nndsk.medication.ui.caregiver.PendingPoolCard

/** Cuenta registros, no tomas: una omisión también suma. Sin rachas ni metas. */
@Composable internal fun Today(model: PatientViewModel, state: PatientScreen, now: Instant, openAccess: (() -> Unit)? = null, open: (String) -> Unit) {
    val snapshot = state.snapshot
    val context = LocalContext.current
    val plan = todayPlan(snapshot?.doses.orEmpty(), state.operations, now)
    var permitted by remember { mutableStateOf(model.app.reminders.permitted()) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { permitted = model.app.reminders.permitted() }
    val colors = MedicationTrackerTheme.colors
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        val zone = snapshot?.doses?.firstOrNull()?.let { ZoneId.of(it.timezone) } ?: ZoneId.systemDefault()
        Text(longDate(now, zone), style = GraphiteTokens.Type.patientBody, color = colors.textMuted, modifier = Modifier.semantics { heading() })
        if (!state.caregiver && plan.total > 0) Column(Modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.sm)) {
            Text("${plan.registeredCount} de ${plan.total} registradas", style = GraphiteTokens.Type.patientLabel)
            LinearProgressIndicator({ plan.registeredCount.toFloat() / plan.total }, Modifier.fillMaxWidth(), color = colors.action, trackColor = colors.border, drawStopIndicator = {})
        }
        if (!state.caregiver) snapshot?.pendingPools.orEmpty().forEach { PendingPoolCard(model, it, state.busy || state.offline) }
        if (plan.review.isNotEmpty()) {
            SectionTitle("Por revisar")
            plan.review.forEach { DoseRow(it, state, now, open = open) }
        }
        plan.current?.let { NowCard(model, state, it, now, open) } ?: run {
            if (plan.total == 0) Text(when {
                snapshot?.refreshedAt != null -> "No hay tomas programadas para hoy."
                state.busy -> "Cargando tu agenda…"
                else -> "Sin agenda guardada. Conéctate y sincroniza para cargar tus tomas."
            }, style = GraphiteTokens.Type.patientBody)
            else if (plan.later.isEmpty() && plan.overdue.isEmpty()) Text("No quedan tomas por registrar hoy.", style = GraphiteTokens.Type.patientBody)
        }
        if (openAccess != null && plan.total == 0 && snapshot?.refreshedAt != null && snapshot.links.isEmpty()) SectionCard("¿Te invitó un cuidador?") {
            Note("Pega el código que te enviaron para revisar qué podrá hacer antes de autorizarlo.")
            SecondaryAction("Ingresar código") { openAccess() }
        }
        if (plan.later.isNotEmpty()) {
            SectionTitle("Más tarde")
            plan.later.forEach { DoseRow(it, state, now, open = open) }
        }
        if (plan.overdue.isNotEmpty()) {
            SectionTitle("Pasaron sin registrar")
            Text(overdueHint, color = colors.textMuted)
            plan.overdue.forEach { DoseRow(it, state, now, open = open) }
        }
        if (plan.registered.isNotEmpty()) {
            SectionTitle("Ya registradas")
            plan.registered.forEach { DoseRow(it, state, now, open = open) }
        }
        if (!state.caregiver && !permitted) {
            StatusChip(Chip("Recordatorios desactivados", R.drawable.ic_notifications_off, colors.unconfirmedFg, colors.unconfirmedBg))
            Text("Este teléfono no te avisará de tus tomas. Puedes activarlos en los ajustes de notificaciones.")
            DoseAction("Abrir ajustes de notificaciones") { context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)) }
        }
        Spacer(Modifier.height(GraphiteTokens.Space.md))
    }
}

/** La toma que falta registrar, con las tres declaraciones a la vista. */
@Composable private fun NowCard(model: PatientViewModel, state: PatientScreen, dose: Dose, now: Instant, open: (String) -> Unit) {
    val treatment = state.snapshot?.treatments?.find { it.id == dose.treatmentId }
    val due = Instant.parse(dose.scheduledAt) <= now
    Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(GraphiteTokens.Radius.lg), colors = CardDefaults.cardColors(containerColor = MedicationTrackerTheme.colors.surface), border = BorderStroke(1.dp, MedicationTrackerTheme.colors.border)) {
        Column(Modifier.padding(GraphiteTokens.Space.lg), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
            Text(if (due && state.caregiver) "Falta registrar" else if (due) "Ahora toca" else "Próxima toma", style = GraphiteTokens.Type.patientLabel, color = MedicationTrackerTheme.colors.textMuted, modifier = Modifier.semantics { heading() })
            Column(Modifier.fillMaxWidth().clickable(onClickLabel = "Abrir detalle") { open(dose.id) }, verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xs)) {
                Text(doseTime(dose), style = GraphiteTokens.Type.patientDisplay)
                Text(treatment?.name ?: "Tratamiento", style = GraphiteTokens.Type.patientTitle)
                if (!treatment?.strength.isNullOrEmpty()) Text(treatment!!.strength, style = GraphiteTokens.Type.patientBody, color = MedicationTrackerTheme.colors.textMuted)
                Text("${quantityText(dose.quantity)} ${unitLabel(treatment?.unit)}", style = GraphiteTokens.Type.patientBody)
                if (dose.dstAdjusted) Text("Hora ajustada por el cambio de horario.", color = MedicationTrackerTheme.colors.textMuted)
                StatusChip(doseChip(dose, null, now))
            }
            DeclarationActions(model, state, dose, now)
        }
    }
}
