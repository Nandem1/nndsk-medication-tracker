package cl.nndsk.medication.ui.family

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import cl.nndsk.medication.core.initials
import cl.nndsk.medication.ui.theme.GraphiteTokens
import cl.nndsk.medication.ui.theme.MedicationTrackerTheme

/** Iniciales sobre un tono estable por persona. El nombre siempre va al lado: el avatar es decorativo. */
@Composable internal fun Avatar(name: String?, seed: String) {
    val colors = MedicationTrackerTheme.colors
    val tones = listOf(colors.scheduledBg, colors.takenBg, colors.takenLateBg, colors.unconfirmedBg, colors.syncBg, colors.skippedBg)
    Box(Modifier.size(44.dp).background(tones[Math.floorMod(seed.hashCode(), tones.size)], CircleShape).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
        Text(initials(name), style = GraphiteTokens.Type.patientLabel, color = colors.text)
    }
}
