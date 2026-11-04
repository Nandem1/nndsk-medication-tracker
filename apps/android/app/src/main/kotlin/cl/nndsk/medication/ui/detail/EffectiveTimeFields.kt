package cl.nndsk.medication.ui.detail

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.components.DoseAction

/** Fecha y hora escritas en la zona de la pauta. Una hora repetida por el cambio horario exige elegir cuál. */
@Composable internal fun EffectiveTimeFields(timezone: String, date: String, onDate: (String) -> Unit, time: String, onTime: (String) -> Unit, selectedOffset: String?, caregiver: Boolean = false, onOffset: (String) -> Unit) {
    val offsets = runCatching { effectiveOffsets(date, time, timezone) }.getOrDefault(emptyList())
    OutlinedTextField(date, onDate, label = { Text("Fecha (AAAA-MM-DD)") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(time, onTime, label = { Text("Hora (HH:mm)") }, modifier = Modifier.fillMaxWidth())
    if (offsets.size == 2) {
        Text(if (caregiver) "Esta hora ocurrió dos veces por el cambio horario. Elige cuándo se lo tomó." else "Esta hora ocurrió dos veces por el cambio horario. Elige cuándo la tomaste.")
        offsets.forEachIndexed { index, offset ->
            DoseAction("${if (selectedOffset == offset.id) "✓ " else ""}${if (index == 0) "Primera" else "Segunda"} vez · UTC${offset.id}") { onOffset(offset.id) }
        }
    }
}
