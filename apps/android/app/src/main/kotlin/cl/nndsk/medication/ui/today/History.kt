package cl.nndsk.medication.ui.today

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import cl.nndsk.medication.core.*
import cl.nndsk.medication.ui.theme.GraphiteTokens
import java.time.*
import cl.nndsk.medication.ui.components.*

@Composable internal fun History(state: AppState, now: Instant, open: (String) -> Unit) {
    val snapshot = state.snapshot
    val days = historyDays(snapshot?.doses.orEmpty(), now)
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(GraphiteTokens.Space.md)) {
        if (days.isEmpty()) Text(if (snapshot?.refreshedAt == null) "Sin agenda guardada. Conéctate y sincroniza para cargar tus tomas." else "Todavía no hay tomas anteriores.", style = GraphiteTokens.Type.patientBody)
        days.forEach { (date, doses) ->
            SectionTitle(longLocalDate(date))
            doses.forEach { DoseRow(it, state, now, open = open) }
        }
        if (days.isNotEmpty()) Note("Muestra hoy y los últimos 7 días. Los registros son declaraciones y no demuestran ingestión.")
        Spacer(Modifier.height(GraphiteTokens.Space.md))
    }
}
