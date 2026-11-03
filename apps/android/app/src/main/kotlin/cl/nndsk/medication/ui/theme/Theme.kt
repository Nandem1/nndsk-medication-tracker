package cl.nndsk.medication.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Adaptador de los tokens Graphite (packages/design-tokens) a Material 3.
 * Los colores de estado no tienen equivalente en Material y se leen con [MedicationTrackerTheme.colors].
 * Sin color dinámico: la paleta fija garantiza el contraste comprobado al generar los tokens.
 */
private val LocalGraphiteColors = staticCompositionLocalOf { GraphiteTokens.light }

private fun GraphiteColors.toMaterial(dark: Boolean): ColorScheme {
    val base = if (dark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = action,
        onPrimary = onAction,
        primaryContainer = surfaceRaised,
        onPrimaryContainer = text,
        secondary = textMuted,
        onSecondary = surface,
        secondaryContainer = surfaceRaised,
        onSecondaryContainer = text,
        tertiary = accent,
        onTertiary = if (dark) bg else onAccent,
        background = bg,
        onBackground = text,
        surface = surface,
        onSurface = text,
        surfaceVariant = surfaceRaised,
        onSurfaceVariant = textMuted,
        surfaceContainerLowest = bg,
        surfaceContainerLow = surface,
        surfaceContainer = surface,
        surfaceContainerHigh = surfaceRaised,
        surfaceContainerHighest = surfaceRaised,
        outline = borderStrong,
        outlineVariant = border,
        error = dangerFg,
        onError = if (dark) bg else surface,
        errorContainer = dangerBg,
        onErrorContainer = dangerFg,
    )
}

@Composable
fun MedicationTrackerTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val colors = if (darkTheme) GraphiteTokens.dark else GraphiteTokens.light
    CompositionLocalProvider(LocalGraphiteColors provides colors) {
        MaterialTheme(colorScheme = colors.toMaterial(darkTheme), typography = Typography, content = content)
    }
}

object MedicationTrackerTheme {
    val colors: GraphiteColors
        @Composable @ReadOnlyComposable get() = LocalGraphiteColors.current
}
