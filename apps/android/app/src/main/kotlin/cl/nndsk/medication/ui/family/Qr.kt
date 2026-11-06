package cl.nndsk.medication.ui.family

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.zxing.qrcode.encoder.Encoder

/** QR del enlace de invitación. Siempre negro sobre blanco, también en modo oscuro: así lo leen las cámaras. */
@Composable internal fun QrCode(value: String, description: String, modifier: Modifier = Modifier.fillMaxWidth()) {
    val matrix = remember(value) { Encoder.encode(value, ErrorCorrectionLevel.M, mapOf(EncodeHintType.CHARACTER_SET to "UTF-8")).matrix }
    Canvas(modifier.aspectRatio(1f).semantics { contentDescription = description }) {
        val margin = 4
        val cell = size.width / (matrix.width + margin * 2)
        drawRect(Color.White)
        for (y in 0 until matrix.height) for (x in 0 until matrix.width) if (matrix.get(x, y).toInt() == 1)
            drawRect(Color(0xFF111111), Offset((x + margin) * cell, (y + margin) * cell), Size(cell + 0.5f, cell + 0.5f))
    }
}
