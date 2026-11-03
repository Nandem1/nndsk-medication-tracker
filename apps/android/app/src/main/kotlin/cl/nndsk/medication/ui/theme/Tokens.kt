// Generado por packages/design-tokens/build.mjs desde tokens.json. No editar a mano.
package cl.nndsk.medication.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Immutable
data class GraphiteColors(
    val bg: Color,
    val surface: Color,
    val surfaceRaised: Color,
    val border: Color,
    val borderStrong: Color,
    val text: Color,
    val textMuted: Color,
    val action: Color,
    val onAction: Color,
    val accent: Color,
    val accentFill: Color,
    val onAccent: Color,
    val scheduledFg: Color,
    val scheduledBg: Color,
    val unconfirmedFg: Color,
    val unconfirmedBg: Color,
    val takenFg: Color,
    val takenBg: Color,
    val takenLateFg: Color,
    val takenLateBg: Color,
    val skippedFg: Color,
    val skippedBg: Color,
    val syncFg: Color,
    val syncBg: Color,
    val dangerFg: Color,
    val dangerBg: Color,
    val chartTaken: Color,
    val chartTakenLate: Color,
    val chartSkipped: Color,
    val chartUnconfirmed: Color,
)

object GraphiteTokens {
    val light = GraphiteColors(
        bg = Color(0xFFF7F7F8),
        surface = Color(0xFFFFFFFF),
        surfaceRaised = Color(0xFFF0F0F2),
        border = Color(0xFFE4E4E7),
        borderStrong = Color(0xFF7C7C85),
        text = Color(0xFF17171A),
        textMuted = Color(0xFF5E5E66),
        action = Color(0xFF17171A),
        onAction = Color(0xFFFFFFFF),
        accent = Color(0xFF4338CA),
        accentFill = Color(0xFF4338CA),
        onAccent = Color(0xFFFFFFFF),
        scheduledFg = Color(0xFF47474E),
        scheduledBg = Color(0xFFF0F0F2),
        unconfirmedFg = Color(0xFF8A4B00),
        unconfirmedBg = Color(0xFFFFF1D6),
        takenFg = Color(0xFF17663A),
        takenBg = Color(0xFFE3F4EA),
        takenLateFg = Color(0xFF0F6874),
        takenLateBg = Color(0xFFE0F3F5),
        skippedFg = Color(0xFF47474E),
        skippedBg = Color(0xFFECECEF),
        syncFg = Color(0xFF3730A3),
        syncBg = Color(0xFFEEEDFE),
        dangerFg = Color(0xFFB42318),
        dangerBg = Color(0xFFFDECEA),
        chartTaken = Color(0xFF2E9E5B),
        chartTakenLate = Color(0xFF1C9AAA),
        chartSkipped = Color(0xFF8E8E98),
        chartUnconfirmed = Color(0xFFB86E00),
    )

    val dark = GraphiteColors(
        bg = Color(0xFF0F0F11),
        surface = Color(0xFF17171A),
        surfaceRaised = Color(0xFF1E1E22),
        border = Color(0xFF26262B),
        borderStrong = Color(0xFF7C7C85),
        text = Color(0xFFEDEDF0),
        textMuted = Color(0xFF9A9AA3),
        action = Color(0xFFEDEDF0),
        onAction = Color(0xFF0F0F11),
        accent = Color(0xFFA5A1FF),
        accentFill = Color(0xFF5B54E8),
        onAccent = Color(0xFFFFFFFF),
        scheduledFg = Color(0xFFC4C4CC),
        scheduledBg = Color(0xFF26262B),
        unconfirmedFg = Color(0xFFFFB95C),
        unconfirmedBg = Color(0xFF33240E),
        takenFg = Color(0xFF6EDB98),
        takenBg = Color(0xFF10301D),
        takenLateFg = Color(0xFF5FD3E0),
        takenLateBg = Color(0xFF0D2A2E),
        skippedFg = Color(0xFFC4C4CC),
        skippedBg = Color(0xFF26262B),
        syncFg = Color(0xFFC7C4FF),
        syncBg = Color(0xFF24224A),
        dangerFg = Color(0xFFFF8A80),
        dangerBg = Color(0xFF3A1512),
        chartTaken = Color(0xFF4CC37A),
        chartTakenLate = Color(0xFF8FE3EC),
        chartSkipped = Color(0xFF5E5E66),
        chartUnconfirmed = Color(0xFFF0A23A),
    )

    object Space {
        val xxs = 2.dp
        val xs = 4.dp
        val sm = 8.dp
        val md = 12.dp
        val lg = 16.dp
        val xl = 24.dp
        val xxl = 32.dp
        val xxxl = 48.dp
    }

    object Radius {
        val sm = 8.dp
        val md = 12.dp
        val lg = 16.dp
        val xl = 24.dp
        val pill = 999.dp
    }

    object Size {
        val minTouchIos = 44.dp
        val minTouchAndroid = 48.dp
        val patientAction = 64.dp
        val patientIcon = 64.dp
        val borderWidth = 2.dp
    }

    object Type {
        val patientDisplay = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight(800), fontSize = 34.sp, lineHeight = 40.sp)
        val patientTitle = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight(700), fontSize = 26.sp, lineHeight = 32.sp)
        val patientBody = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight(400), fontSize = 20.sp, lineHeight = 28.sp)
        val patientLabel = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight(600), fontSize = 17.sp, lineHeight = 22.sp)
        val caregiverMetric = TextStyle(fontFamily = FontFamily.Monospace, fontWeight = FontWeight(500), fontSize = 40.sp, lineHeight = 40.sp)
        val caregiverHeading = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight(600), fontSize = 22.sp, lineHeight = 28.sp)
        val caregiverBody = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight(400), fontSize = 15.sp, lineHeight = 22.sp)
        val caregiverCaption = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight(400), fontSize = 13.sp, lineHeight = 18.sp)
    }
}
