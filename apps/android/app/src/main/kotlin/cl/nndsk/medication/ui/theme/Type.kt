package cl.nndsk.medication.ui.theme

import androidx.compose.material3.Typography

/** Roles tipográficos del paciente mapeados a Material 3. Los sp respetan la escala de fuente del sistema. */
val Typography = Typography(
    headlineLarge = GraphiteTokens.Type.patientDisplay,
    headlineMedium = GraphiteTokens.Type.patientTitle,
    headlineSmall = GraphiteTokens.Type.patientTitle,
    titleLarge = GraphiteTokens.Type.patientBody.copy(fontWeight = GraphiteTokens.Type.patientLabel.fontWeight),
    bodyLarge = GraphiteTokens.Type.patientBody,
    bodyMedium = GraphiteTokens.Type.patientLabel.copy(fontWeight = GraphiteTokens.Type.patientBody.fontWeight),
    labelLarge = GraphiteTokens.Type.patientLabel,
)
