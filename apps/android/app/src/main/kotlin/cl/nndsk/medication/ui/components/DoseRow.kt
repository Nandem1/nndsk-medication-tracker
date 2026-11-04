package cl.nndsk.medication.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.R
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme
import java.time.*

/** Fila de al menos 64 dp que abre el detalle; crece con la escala de fuente. */
@Composable internal fun DoseRow(dose: Dose, state: PatientScreen, now: Instant, open: (String) -> Unit) {
    val colors = MedicationTrackerTheme.colors
    val treatment = state.snapshot?.treatments?.find { it.id == dose.treatmentId }
    Surface(onClick = { open(dose.id) }, shape = RoundedCornerShape(GraphiteTokens.Radius.md), color = colors.surface, border = BorderStroke(1.dp, colors.border), modifier = Modifier.fillMaxWidth().heightIn(min = GraphiteTokens.Size.patientAction)) {
        Row(Modifier.padding(GraphiteTokens.Space.md), horizontalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md), verticalAlignment = Alignment.CenterVertically) {
            Text(doseTime(dose), style = GraphiteTokens.Type.patientLabel)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.xs)) {
                Text(treatment?.name ?: "Tratamiento", style = GraphiteTokens.Type.patientLabel)
                StatusChip(doseChip(dose, state.operations.find { it.dose == dose.id }, now))
                if (dose.dstAdjusted) Text("Hora ajustada por el cambio de horario.", color = colors.textMuted)
            }
            Icon(painterResource(R.drawable.ic_chevron), contentDescription = null, tint = colors.textMuted)
        }
    }
}
